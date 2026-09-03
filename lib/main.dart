import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart' hide Router;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_route;
import 'package:http/http.dart' as http;

void main() {
  runApp(const MaterialApp(
    home: P2PTransferScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class DiscoveredDevice {
  final String ip;
  final String name;
  final String os;
  DateTime lastSeen;

  DiscoveredDevice({
    required this.ip,
    required this.name,
    required this.os,
    required this.lastSeen,
  });
}

class P2PTransferScreen extends StatefulWidget {
  const P2PTransferScreen({super.key});

  @override
  State<P2PTransferScreen> createState() => _P2PTransferScreenState();
}

class _P2PTransferScreenState extends State<P2PTransferScreen> {
  List<String> _localIps = [];
  String _deviceName = '未知设备';
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;

  final Map<String, DiscoveredDevice> _devices = {};
  String _status = '就绪';
  double _progress = 0.0;

  static const int _httpPort = 45678;
  static const int _udpPort = 45679;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    if (Platform.isAndroid) {
      await [Permission.storage, Permission.manageExternalStorage].request();
      _deviceName = 'Android Phone';
    } else if (Platform.isWindows) {
      _deviceName = Platform.environment['COMPUTERNAME'] ?? 'Windows PC';
    } else if (Platform.isMacOS) {
      _deviceName = Platform.environment['USER'] ?? 'Mac';
    } else {
      _deviceName = 'Device-${Platform.operatingSystem}';
    }

    await _refreshLocalIps();
    await _startReceiverServer();
    await _startUdpDiscovery();
  }

  // 获取本机所有有效的 IPv4 地址（支持以太网/Wi-Fi）
  Future<void> _refreshLocalIps() async {
    List<String> ips = [];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (var interface in interfaces) {
        // 过滤虚拟机/虚拟网卡（如 WSL, Docker, VMware）
        final name = interface.name.toLowerCase();
        if (name.contains('vethernet') || name.contains('vmware') || name.contains('vbox') || name.contains('docker')) {
          continue;
        }
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (_) {}

    setState(() {
      _localIps = ips;
    });
  }

  // 1. 启动 HTTP 接收服务（监听 0.0.0.0 涵盖所有网卡）
  Future<void> _startReceiverServer() async {
    final router = shelf_route.Router();
    final dir = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getApplicationDocumentsDirectory();
    final savePath = dir?.path ?? '.';

    router.post('/upload', (Request req) async {
      final fileName = req.url.queryParameters['filename'] ??
          'file_${DateTime.now().millisecondsSinceEpoch}';
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

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, _httpPort);
  }

  // 2. 启动 UDP 广播（支持有线/无线双向发现）
  Future<void> _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket?.broadcastEnabled = true;

      _udpSocket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket?.receive();
          if (datagram == null) return;

          try {
            final message = utf8.decode(datagram.data);
            final parts = message.split('|');
            if (parts.length >= 3 && parts[0] == 'P2P_DISCOVER') {
              final remoteDeviceName = parts[1];
              final remoteOs = parts[2];
              final remoteIp = datagram.address.address;

              // 排除本机的所有网卡 IP
              if (!_localIps.contains(remoteIp) && remoteIp != '127.0.0.1') {
                setState(() {
                  _devices[remoteIp] = DiscoveredDevice(
                    ip: remoteIp,
                    name: remoteDeviceName,
                    os: remoteOs,
                    lastSeen: DateTime.now(),
                  );
                });
              }
            }
          } catch (_) {}
        }
      });

      _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_udpSocket == null || _localIps.isEmpty) return;
        final packet = 'P2P_DISCOVER|$_deviceName|${Platform.operatingSystem}';
        final data = utf8.encode(packet);
        _udpSocket?.send(
          data,
          InternetAddress('255.255.255.255'),
          _udpPort,
        );
      });

      _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        final now = DateTime.now();
        setState(() {
          _devices.removeWhere(
              (_, device) => now.difference(device.lastSeen).inSeconds > 6);
        });
      });
    } catch (e) {
      setState(() => _status = 'UDP 初始化异常: $e');
    }
  }

  Future<void> _sendFileToDevice(DiscoveredDevice target) async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final file = File(filePath);
    final fileName = Uri.encodeComponent(result.files.single.name);
    final uri = Uri.parse('http://${target.ip}:$_httpPort/upload?filename=$fileName');

    setState(() {
      _status = '正在发送至 ${target.name}...';
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
        setState(() => _status = '发送失败: ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _status = '发送异常: $e');
    }
  }

  @override
  void dispose() {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _udpSocket?.close();
    _server?.close(force: true);
    super.dispose();
  }

  IconData _getDeviceIcon(String os) {
    if (os.toLowerCase().contains('android')) return Icons.phone_android;
    if (os.toLowerCase().contains('windows')) return Icons.desktop_windows;
    if (os.toLowerCase().contains('macos')) return Icons.laptop_mac;
    return Icons.devices;
  }

  @override
  Widget build(BuildContext context) {
    final deviceList = _devices.values.toList();
    final ipDisplay = _localIps.isEmpty ? '未获取到有效 IP' : _localIps.join(' / ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网极速互传'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _refreshLocalIps();
              setState(() => _devices.clear());
            },
            tooltip: '重新扫描',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_getDeviceIcon(Platform.operatingSystem), size: 28),
                    const SizedBox(width: 8),
                    Text(
                      _deviceName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('本机 IP: $ipDisplay', style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
          ),
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('在线设备 (${deviceList.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: deviceList.isEmpty
                ? const Center(
                    child: Text(
                      '正在持续搜索局域网设备...\n请确保两台设备在同一子网，且 Windows 防火墙已允许该程序',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: deviceList.length,
                    itemBuilder: (context, index) {
                      final target = deviceList[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(child: Icon(_getDeviceIcon(target.os))),
                          title: Text(target.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${target.os.toUpperCase()} • ${target.ip}'),
                          trailing: ElevatedButton.icon(
                            onPressed: () => _sendFileToDevice(target),
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('发送'),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.black12,
            child: Text(
              '状态: $_status',
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
