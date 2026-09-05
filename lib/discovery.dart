import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 发现到的对端设备
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

/// 是否为局域网私网地址（RFC1918）
///
/// 用**白名单**而非黑名单，天然排除 VPN 隧道（如 iKuuuVPN 的 198.18.0.0/15
/// fake-ip 段）、CGNAT(100.64.0.0/10)、APIPA(169.254.0.0/16) 等伪网卡。
/// 这类地址会导致「能发现设备，但一发送就报错」——对端拿到的源 IP 不可达。
bool isPrivateLanIp(String ip) {
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

/// 对端 IP 是否与本机任一局域网 IP 处于同一 /24 子网
bool isSameSubnetAsLocal(String ip, List<String> localIps) {
  final segs = ip.split('.');
  if (segs.length != 4) return false;
  final prefix = '${segs[0]}.${segs[1]}.${segs[2]}';
  return localIps.any((local) => local.startsWith('$prefix.'));
}

/// 获取本机所有有效的局域网 IPv4 地址（以太网 / Wi-Fi）
Future<List<String>> refreshLocalIps() async {
  final ips = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      // 过滤虚拟机/虚拟网卡（如 WSL, Docker, VMware）
      final name = interface.name.toLowerCase();
      if (name.contains('vethernet') ||
          name.contains('vmware') ||
          name.contains('vbox') ||
          name.contains('docker')) {
        continue;
      }
      for (final addr in interface.addresses) {
        if (!addr.isLoopback && isPrivateLanIp(addr.address)) {
          ips.add(addr.address);
        }
      }
    }
  } catch (_) {}
  return ips;
}

/// UDP 广播设备发现
class DeviceDiscovery {
  final String deviceName;
  final List<String> Function() localIpsProvider;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final _controller = StreamController<DiscoveredDevice>.broadcast();

  Stream<DiscoveredDevice> get onDeviceFound => _controller.stream;

  String? lastError;

  DeviceDiscovery({
    required this.deviceName,
    required this.localIpsProvider,
  });

  Future<bool> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kUdpPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket?.broadcastEnabled = true;

      _socket?.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = _socket?.receive();
        if (datagram == null) return;

        try {
          final message = utf8.decode(datagram.data);
          final parts = message.split('|');
          if (parts.length < 3 || parts[0] != 'P2P_DISCOVER') return;

          final remoteIp = datagram.address.address;
          final localIps = localIpsProvider();

          // 只接受「私网地址 且 与本机处于同一 /24 子网」的对端。
          // 少了任一条件，VPN 隧道等不可达 IP 都会混进设备列表，
          // 表现为「能看到设备，但一点发送就报错」。
          if (localIps.contains(remoteIp)) return;
          if (remoteIp == '127.0.0.1') return;
          if (!isPrivateLanIp(remoteIp)) return;
          if (!isSameSubnetAsLocal(remoteIp, localIps)) return;

          _controller.add(DiscoveredDevice(
            ip: remoteIp,
            name: parts[1],
            os: parts[2],
            lastSeen: DateTime.now(),
          ));
        } catch (_) {}
      });

      _broadcastTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _broadcast());
      _broadcast();
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  void _broadcast() {
    final socket = _socket;
    if (socket == null) return;
    final localIps = localIpsProvider();
    if (localIps.isEmpty) return;

    final data = utf8.encode('P2P_DISCOVER|$deviceName|${Platform.operatingSystem}');
    try {
      socket.send(data, InternetAddress('255.255.255.255'), kUdpPort);
    } catch (_) {}

    // 针对当前网段的定向广播（如 192.168.1.255）
    // 部分路由器/交换机不转发全局广播，定向广播可提升发现成功率
    for (final ip in localIps) {
      final segs = ip.split('.');
      if (segs.length != 4) continue;
      try {
        socket.send(data, InternetAddress('${segs[0]}.${segs[1]}.${segs[2]}.255'),
            kUdpPort);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _socket?.close();
    _socket = null;
    await _controller.close();
  }
}
