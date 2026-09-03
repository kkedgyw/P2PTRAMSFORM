import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MaterialApp(
    home: P2PTransferScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class P2PTransferScreen extends StatefulWidget {
  const P2PTransferScreen({super.key});

  @override
  State<P2PTransferScreen> createState() => _P2PTransferScreenState();
}

class _P2PTransferScreenState extends State<P2PTransferScreen> {
  String _localIp = '正在获取...';
  HttpServer? _server;
  final TextEditingController _targetIpController = TextEditingController();
  String _status = '就绪';
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _initNetworkAndServer();
  }

  Future<void> _initNetworkAndServer() async {
    if (Platform.isAndroid) {
      await [Permission.storage, Permission.manageExternalStorage].request();
    }

    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    setState(() {
      _localIp = ip ?? '未连接 WiFi 或无法识别';
    });

    _startReceiverServer();
  }

  Future<void> _startReceiverServer() async {
    final router = Router();
    final dir = Platform.isAndroid 
        ? await getExternalStorageDirectory() 
        : await getApplicationDocumentsDirectory();
    final savePath = dir?.path ?? '.';

    router.post('/upload', (Request req) async {
      final fileName = req.url.queryParameters['filename'] ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
      final file = File('$savePath/$fileName');
      final sink = file.openWrite();

      setState(() {
        _status = '正在接收文件: $fileName';
      });

      try {
        await req.read().pipe(sink);
        setState(() {
          _status = '文件接收完成！保存在: $savePath/$fileName';
        });
        return Response.ok('Success');
      } catch (e) {
        setState(() {
          _status = '接收失败: $e';
        });
        return Response.internalServerError();
      }
    });

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, 45678);
  }

  Future<void> _pickAndSendFile() async {
    final targetIp = _targetIpController.text.trim();
    if (targetIp.isEmpty) {
      setState(() => _status = '请先输入对方 IP 地址');
      return;
    }

    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final file = File(filePath);
    final fileName = Uri.encodeComponent(result.files.single.name);
    final uri = Uri.parse('http://$targetIp:45678/upload?filename=$fileName');

    setState(() {
      _status = '正在发送中...';
      _progress = 0.0;
    });

    try {
      final req = http.StreamedRequest('POST', uri);
      final total = await file.length();
      req.contentLength = total;

      int sent = 0;
      file.openRead().listen(
        (chunk) {
          sent += chunk.length;
          setState(() {
            _progress = total > 0 ? sent / total : 0;
          });
          req.sink.add(chunk);
        },
        onDone: () => req.sink.close(),
        onError: (e) => req.sink.addError(e),
        cancelOnError: true,
      );

      final res = await req.send();
      if (res.statusCode == 200) {
        setState(() => _status = '发送成功！');
      } else {
        setState(() => _status = '发送失败，状态码: ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _status = '发送出错: $e');
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _targetIpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('P2P 文件极速传输')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text('本机 IP 地址 (让对方填这个):', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_localIp, style: const TextStyle(fontSize: 18, color: Colors.blueAccent)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _targetIpController,
              decoration: const InputDecoration(
                labelText: '对方的 IP 地址',
                hintText: '如 192.168.1.5',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _pickAndSendFile,
              icon: const Icon(Icons.send),
              label: const Text('选择文件并发送'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
            const SizedBox(height: 20),
            if (_progress > 0 && _progress < 1)
              LinearProgressIndicator(value: _progress),
            const SizedBox(height: 12),
            Text('当前状态: $_status', style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
