import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_route;

import 'crypto.dart';
import 'models.dart';
import 'storage.dart';

/// 收到传输请求时回调 UI 弹确认框，UI 通过 [decision] 回应用户选择
typedef ConfirmRequest = void Function(
    TransferSession session, Completer<bool> decision);

/// 接收端 HTTP 服务
///
/// 协议：
///   POST /transfer/request  发送方发起请求，携带文件清单 → 202 pending
///   GET  /transfer/status   发送方轮询确认结果
///   POST /transfer/upload   逐文件上传，文件名/序号在 query
///   POST /transfer/cancel   任一方取消
class TransferServer {
  /// 保存目录。授权状态可能中途变化（用户去设置页开了权限），故不做 final
  String saveDir;

  /// 本设备名称，/ping 与传输请求里带回给对端
  String deviceName;

  /// 端到端加密口令。为空表示本机未启用加密。
  /// 可中途变更（用户在设置里改），故不做 final
  String? passphrase;

  final ConfirmRequest onConfirmRequest;
  final void Function(TransferSession session) onSessionChanged;

  HttpServer? _server;
  final Map<String, TransferSession> _sessions = {};
  final Map<String, Completer<bool>> _decisions = {};

  /// 等待用户确认的最长时间，超时自动拒绝
  static const Duration _decisionTimeout = Duration(seconds: 60);

  TransferServer({
    required this.saveDir,
    required this.deviceName,
    required this.onConfirmRequest,
    required this.onSessionChanged,
    this.passphrase,
  });

  Future<void> start() async {
    final router = shelf_route.Router()
      ..post('/transfer/request', _handleRequest)
      ..get('/transfer/status', _handleStatus)
      ..post('/transfer/upload', _handleUpload)
      ..post('/transfer/cancel', _handleCancel)
      // 存活探测：网段扫描与手动添加设备都靠它确认对端是本应用
      ..get('/ping', _handlePing);

    _server =
        await shelf_io.serve(router.call, InternetAddress.anyIPv4, kHttpPort);
  }

  Response _handlePing(Request req) {
    return Response.ok(
      jsonEncode({
        'app': 'p2p_transfer',
        'name': deviceName,
        'os': Platform.operatingSystem,
        'port': kHttpPort,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// UI 调用：用户对某个待确认请求做出接受/拒绝
  void resolve(String transferId, bool accepted) {
    final completer = _decisions.remove(transferId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(accepted);
    }
  }

  // ---------------------------------------------------------------- 请求处理

  Future<Response> _handleRequest(Request req) async {
    try {
      final body = await req.readAsString();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return Response.badRequest(body: 'invalid json');
      }
      final json = Map<String, dynamic>.from(decoded);

      final transferId = json['transferId']?.toString() ?? '';
      final senderName = json['senderName']?.toString() ?? '未知设备';

      // 加密盐值：非空表示对方这次是加密传输
      final cryptoRaw = json['crypto'];
      String? salt;
      if (cryptoRaw is Map) {
        salt = Map<String, dynamic>.from(cryptoRaw)['salt']?.toString();
      }

      TransferCrypto? crypto;
      if (salt != null && salt.isNotEmpty) {
        final pwd = passphrase;
        if (pwd == null || pwd.isEmpty) {
          return Response.badRequest(
              body: '对方启用了加密传输，但本机没有设置口令');
        }
        try {
          crypto = await TransferCrypto.fromSaltBase64(pwd, salt);
        } catch (e) {
          return Response.badRequest(body: '密钥派生失败: $e');
        }
      }

      final rawFiles = json['files'];
      final files = <FileMeta>[];
      if (rawFiles is List) {
        for (final f in rawFiles) {
          final meta = FileMeta.fromJson(f);
          if (crypto == null) {
            files.add(meta);
            continue;
          }
          try {
            final name = await crypto.decryptName(meta.name);
            files.add(FileMeta(name: name, size: meta.size));
          } catch (_) {
            // GCM 认证失败 = 口令不一致。明确告诉发送方，而不是让它干等超时
            return Response.badRequest(
                body: '口令不一致，无法解密文件名，请双方核对口令');
          }
        }
      }
      if (transferId.isEmpty || files.isEmpty) {
        return Response.badRequest(body: 'invalid request');
      }

      final session = TransferSession(
        id: transferId,
        direction: TransferDirection.receive,
        peerName: senderName,
        peerIp: _peerIpOf(req, json),
        files: files,
        cryptoSalt: salt,
      );
      _sessions[transferId] = session;

      final decision = Completer<bool>();
      _decisions[transferId] = decision;

      onSessionChanged(session);
      onConfirmRequest(session, decision);

      // 用户做出选择后更新状态；超时未响应自动拒绝
      unawaited(decision.future
          .timeout(_decisionTimeout, onTimeout: () => false)
          .then((accepted) {
        final s = _sessions[transferId];
        if (s == null) return;
        if (s.status == TransferStatus.pending) {
          s.status =
              accepted ? TransferStatus.accepted : TransferStatus.rejected;
          onSessionChanged(s);
        }
        if (!accepted) {
          // 给发送方留出轮询到结果的时间，之后再清理
          Future.delayed(const Duration(seconds: 15), () {
            _sessions.remove(transferId);
          });
        }
      }));

      return Response(202,
          body: jsonEncode({'status': 'pending'}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.badRequest(body: 'bad request: $e');
    }
  }

  Future<Response> _handleStatus(Request req) async {
    final id = req.url.queryParameters['transferId'] ?? '';
    final session = _sessions[id];
    if (session == null) {
      return Response.notFound(jsonEncode({'status': 'unknown'}),
          headers: {'Content-Type': 'application/json'});
    }

    // 显式给默认值：避免依赖 switch 穷尽性推导做确定性赋值
    String status = 'pending';
    switch (session.status) {
      case TransferStatus.pending:
        status = 'pending';
        break;
      case TransferStatus.accepted:
      case TransferStatus.transferring:
        status = 'accepted';
        break;
      case TransferStatus.rejected:
        status = 'rejected';
        break;
      case TransferStatus.completed:
        status = 'completed';
        break;
      case TransferStatus.failed:
        status = 'failed';
        break;
      case TransferStatus.cancelled:
        status = 'cancelled';
        break;
    }

    return Response.ok(jsonEncode({'status': status}),
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _handleUpload(Request req) async {
    final id = req.url.queryParameters['transferId'] ?? '';
    final index = int.tryParse(req.url.queryParameters['index'] ?? '0') ?? 0;
    final name = req.url.queryParameters['filename'] ?? 'file';

    final session = _sessions[id];
    if (session == null) {
      return Response.notFound('unknown transfer');
    }
    if (session.status != TransferStatus.accepted &&
        session.status != TransferStatus.transferring) {
      return Response.forbidden('transfer not accepted');
    }

    session.status = TransferStatus.transferring;
    session.fileIndex = index;
    session.fileBytes = 0;
    onSessionChanged(session);

    IOSink? sink;
    try {
      // 加密传输：内容要解密后再落盘
      TransferCrypto? crypto;
      final salt = session.cryptoSalt;
      if (salt != null && salt.isNotEmpty) {
        final pwd = passphrase;
        if (pwd == null || pwd.isEmpty) {
          return Response.badRequest(body: '本机未设置口令，无法接收加密文件');
        }
        crypto = await TransferCrypto.fromSaltBase64(pwd, salt);
      }

      final path = await uniqueFilePath(saveDir, name);
      sink = File(path).openWrite();

      // 逐块读取，实时刷新进度
      var received = 0;
      if (crypto != null) {
        await for (final chunk in crypto.decrypt(req.read())) {
          sink.add(chunk);
          received += chunk.length;
          session.fileBytes = received;
          onSessionChanged(session);
        }
      } else {
        await for (final chunk in req.read()) {
          sink.add(chunk);
          received += chunk.length;
          session.fileBytes = received;
          onSessionChanged(session);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      session.savedPaths.add(path);
      session.bytesDone += received;
      session.fileBytes = 0;

      // 全部文件收完则标记完成
      if (session.savedPaths.length >= session.files.length) {
        session.status = TransferStatus.completed;
      }
      onSessionChanged(session);
      return Response.ok('ok');
    } catch (e) {
      // 出错务必关闭 sink，否则会残留一个被占用且只写了一半的文件
      await sink?.close().catchError((_) {});
      session.status = TransferStatus.failed;
      session.error = e.toString();
      onSessionChanged(session);
      return Response.internalServerError(body: '接收失败: $e');
    }
  }

  Future<Response> _handleCancel(Request req) async {
    final id = req.url.queryParameters['transferId'] ?? '';
    final session = _sessions[id];
    if (session != null) {
      session.status = TransferStatus.cancelled;
      onSessionChanged(session);
    }
    return Response.ok('ok');
  }

  /// 取发送方 IP：优先 TCP 连接信息，回退到请求体里自带的 senderIp
  String _peerIpOf(Request req, Map<String, dynamic> json) {
    try {
      final info = req.context['shelf.io.connection_info'];
      if (info is HttpConnectionInfo) {
        return info.remoteAddress.address;
      }
    } catch (_) {}
    return json['senderIp']?.toString() ?? '';
  }
}
