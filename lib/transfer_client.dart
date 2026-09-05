import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'crypto.dart';
import 'models.dart';

/// 发送端：请求 → 等确认 → 多文件逐个上传
class TransferClient {
  final String deviceName;
  final void Function(TransferSession session) onProgress;

  TransferClient({required this.deviceName, required this.onProgress});

  Uri _uri(TransferSession session, String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: session.peerIp,
      port: kHttpPort,
      path: path,
      queryParameters: query,
    );
  }

  /// 第一步：告知对方要发哪些文件
  ///
  /// [crypto] 非空时进入加密模式：文件名加密后传输，盐值随清单一起发出，
  /// 对端据此派生同一把密钥。
  ///
  /// 返回 null 表示成功；否则返回失败原因（会直接显示给用户，
  /// 比如「口令不一致」—— 这类信息丢了就只能让用户干等超时）
  Future<String?> requestTransfer(TransferSession session,
      {TransferCrypto? crypto}) async {
    try {
      final files = <Map<String, dynamic>>[];
      for (final f in session.files) {
        final name =
            crypto != null ? await crypto.encryptName(f.name) : f.name;
        files.add({'name': name, 'size': f.size});
      }

      final body = <String, dynamic>{
        'transferId': session.id,
        'senderName': deviceName,
        'senderIp': session.peerIp,
        'files': files,
        if (crypto != null) 'crypto': {'salt': crypto.saltBase64},
      };

      final res = await http
          .post(
            _uri(session, '/transfer/request'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 || res.statusCode == 202) return null;

      // 4xx 通常是对端给出的具体原因（口令不一致、未设置口令等）
      if (res.statusCode >= 400 && res.statusCode < 500 && res.body.isNotEmpty) {
        return res.body;
      }
      return '对方返回 HTTP ${res.statusCode}';
    } on TimeoutException {
      return '连接超时，请确认对方已打开本应用';
    } catch (e) {
      return '无法连接: $e';
    }
  }

  /// 第二步：轮询对方是否接受（对方点确认是异步的，只能轮询）
  Future<bool> waitForDecision(
    TransferSession session, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final uri = _uri(session, '/transfer/status', {'transferId': session.id});
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (session.status == TransferStatus.cancelled) return false;
      try {
        final res = await http.get(uri).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            final status = decoded['status']?.toString();
            if (status == 'accepted' || status == 'completed') return true;
            if (status == 'rejected' || status == 'failed') return false;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  /// 第三步：多文件逐个上传
  Future<void> uploadFiles(TransferSession session, List<String> paths,
      {TransferCrypto? crypto}) async {
    for (var i = 0; i < paths.length && i < session.files.length; i++) {
      if (session.status == TransferStatus.cancelled) {
        await _notifyCancel(session);
        return;
      }

      session.fileIndex = i;
      session.fileBytes = 0;
      session.status = TransferStatus.transferring;
      onProgress(session);

      // 加密时文件名也要加密，对端用同一把密钥解回来
      final fileName = crypto != null
          ? await crypto.encryptName(session.files[i].name)
          : session.files[i].name;

      final uri = _uri(session, '/transfer/upload', {
        'transferId': session.id,
        'index': '$i',
        'filename': fileName,
      });

      final req = http.StreamedRequest('POST', uri);
      // 密文比明文长（每 64KB 多 32 字节），长度无法预先确定 → 交给 chunked 编码
      req.contentLength = crypto != null ? null : session.files[i].size;

      var sent = 0;
      // 进度按明文统计：加密后再数会多算约 0.05%，虽然无感但没必要
      final counted = _countBytes(File(paths[i]).openRead(), (n) {
        sent += n;
        session.fileBytes = sent;
        onProgress(session);
      });

      final source = crypto != null ? crypto.encrypt(counted) : counted;

      source.listen(
        (chunk) => req.sink.add(chunk),
        onDone: () => req.sink.close(),
        onError: (e) => req.sink.addError(e),
        cancelOnError: true,
      );

      final res = await req.send().timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) {
        final reason =
            await res.stream.bytesToString().catchError((_) => '');
        throw Exception(
            'HTTP ${res.statusCode}${reason.isNotEmpty ? ': $reason' : ''}');
      }

      session.bytesDone += session.files[i].size;
      session.fileBytes = 0;
      onProgress(session);
    }

    session.status = TransferStatus.completed;
    onProgress(session);
  }

  /// 统计流过的明文字节数（用于进度显示），数据原样透传
  Stream<List<int>> _countBytes(
      Stream<List<int>> source, void Function(int) onBytes) async* {
    await for (final chunk in source) {
      onBytes(chunk.length);
      yield chunk;
    }
  }

  Future<void> _notifyCancel(TransferSession session) async {
    try {
      await http
          .post(_uri(session, '/transfer/cancel', {'transferId': session.id}))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}
