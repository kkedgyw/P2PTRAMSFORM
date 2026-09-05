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

  // 是否为局域网私网地址（RFC1918）
  // 关键：用白名单而非黑名单，天然排除 VPN 隧道（如 iKuuuVPN 的 198.18.0.0/15
  // fake-ip 段）、CGNAT(100.64.0.0/10)、APIPA(169.254.0.0/16) 等伪网卡。
  // 这类地址会导致「能发现设备，但一发送就报错」——因为对端拿到的源 IP 不可达。
  bool _isPrivateLanIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    return false;
  }

  // 对端 IP 是否与本机任一局域网 IP 处于同一 /24 子网
  bool _isSameSubnetAsLocal(String ip) {
    final segs = ip.split('.');
    if (segs.length != 4) return false;
    final prefix = '${segs[0]}.${segs[1]}.${segs[2]}';
    return _localIps.any((local) => local.startsWith('$prefix.'));
  }

  // 获取本机所有有效的局域网 IPv4 地址（支持以太网/Wi-Fi）
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
        if (name.contains('vethernet') ||
            name.contains('vmware') ||
            name.contains('vbox') ||
            name.contains('docker')) {
          continue;
        }
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && _isPrivateLanIp(addr.address)) {
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
      IOSink? sink;

      setState(() {
        _status = '正在接收文件: $fileName';
      });

      try {
        sink = file.openWrite();
        await req.read().pipe(sink);
        setState(() {
          _status = '文件接收完成！保存在: $savePath/$fileName';
        });
        return Response.ok('Success');
      } catch (e) {
        // 出错时务必关闭 sink，否则会残留一个被占用且只写了一半的文件
        await sink?.close().catchError((_) {});
        setState(() {
          _status = '接收失败: $e';
        });
        // 把具体原因回传给发送方，避免只看到一个光秃秃的 500
        return Response.internalServerError(body: '接收失败: $e');
      }
    });

    _server =
        await shelf_io.serve(router.call, InternetAddress.anyIPv4, _httpPort);
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

              // 只接受「私网地址 且 与本机处于同一 /24 子网」的对端。
              // 若不做子网校验，VPN 隧道等不可达 IP 会混进设备列表，
              // 表现为「能看到设备，但一点发送就报错」。
              if (!_localIps.contains(remoteIp) &&
                  remoteIp != '127.0.0.1' &&
                  _isPrivateLanIp(remoteIp) &&
                  _isSameSubnetAsLocal(remoteIp)) {
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

        // 1. 全局广播
        try {
          _udpSocket?.send(
              data, InternetAddress('255.255.255.255'), _udpPort);
        } catch (_) {}

        // 2. 针对当前网段的定向广播 (如 192.168.1.255)
        // 部分路由器/交换机不转发全局广播，定向广播可提升发现成功率
        for (final ip in _localIps) {
          final segments = ip.split('.');
          if (segments.length == 4) {
            final subnetBroadcast =
                '${segments[0]}.${segments[1]}.${segments[2]}.255';
            try {
              _udpSocket?.send(
                  data, InternetAddress(subnetBroadcast), _udpPort);
            } catch (_) {}
          }
        }
      });

      _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        final now = DateTime.now();
        setState(() {
          _devices.removeWhere(
              (_, device) => now.difference(device.lastSeen).inSeconds > 6);
        });
      });
    } catch (e) {
      setState(() => _status = 'UDP 启动异常: $e');
    }
  }

  Future<void> _sendFileToDevice(DiscoveredDevice target) async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final file = File(filePath);
    final fileName = Uri.encodeComponent(result.files.single.name);
    final uri =
        Uri.parse('http://${target.ip}:$_httpPort/upload?filename=$fileName');

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

      final res =
          await req.send().timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        setState(() => _status = '发送成功！');
      } else {
        setState(() => _status = '发送失败: HTTP ${res.statusCode}');
      }
    } on TimeoutException {
      setState(
          () => _status = '发送超时(30s)：对端无响应，请检查 ${target.ip} 的防火墙');
    } on SocketException catch (e) {
      setState(() => _status =
          '连接失败 ${target.ip}:$_httpPort（${e.osError?.message ?? e.message}）');
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
    final ipDisplay =
        _localIps.isEmpty ? '未获取到有效 IP' : _localIps.join(' / ');

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
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('本机 IP: $ipDisplay',
                    style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
          ),
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('在线设备 (${deviceList.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: deviceList.isEmpty
                ? const Center(
                    child: Text(
                      '正在持续搜索局域网设备...\n'
                      '请确保两台设备在同一子网（已自动排除 VPN 隧道网卡），\n'
                      '且 Windows 防火墙已允许该程序',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: deviceList.length,
                    itemBuilder: (context, index) {
                      final target = deviceList[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        child: ListTile(
                          leading:
                              CircleAvatar(child: Icon(_getDeviceIcon(target.os))),
                          title: Text(target.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle:
                              Text('${target.os.toUpperCase()} • ${target.ip}'),
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
