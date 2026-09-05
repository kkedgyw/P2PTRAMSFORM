import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
  Future<bool> requestTransfer(TransferSession session) async {
    try {
      final res = await http
          .post(
            _uri(session, '/transfer/request'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'transferId': session.id,
              'senderName': deviceName,
              'senderIp': session.peerIp,
              'files': session.files.map((f) => f.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200 || res.statusCode == 202;
    } catch (_) {
      return false;
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
  Future<void> uploadFiles(
      TransferSession session, List<String> paths) async {
    for (var i = 0; i < paths.length && i < session.files.length; i++) {
      if (session.status == TransferStatus.cancelled) {
        await _notifyCancel(session);
        return;
      }

      session.fileIndex = i;
      session.fileBytes = 0;
      session.status = TransferStatus.transferring;
      onProgress(session);

      final uri = _uri(session, '/transfer/upload', {
        'transferId': session.id,
        'index': '$i',
        'filename': session.files[i].name,
      });

      final req = http.StreamedRequest('POST', uri);
      req.contentLength = session.files[i].size;

      var sent = 0;
      File(paths[i]).openRead().listen(
        (chunk) {
          sent += chunk.length;
          session.fileBytes = sent;
          onProgress(session);
          req.sink.add(chunk);
        },
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

  Future<void> _notifyCancel(TransferSession session) async {
    try {
      await http
          .post(_uri(session, '/transfer/cancel', {'transferId': session.id}))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}
