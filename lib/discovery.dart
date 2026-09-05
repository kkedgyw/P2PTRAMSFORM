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

/// UDP 设备发现
///
/// ⚠️ Android 接收 UDP **广播**不可靠：系统会过滤掉非发给本机的包，要稳定接收得持有
/// `WifiManager.MulticastLock`，而纯 Dart 拿不到这个锁。典型症状：
/// 「PC 能看到安卓，安卓看不到 PC」或「安卓偶尔看到、几秒后消失」。
///
/// 解法：**发现不依赖广播接收**。
///   1. 谁收到广播/探测，就向源 IP **单播**回一份自己的信息 —— 单播在 Android 上可靠
///   2. 每个周期额外向「已知对端」单播探测，双方借此持续刷新在线状态
/// 只要有一个方向能通（哪怕安卓一次广播都收不到），双方就能稳定互相看到。
class DeviceDiscovery {
  final String deviceName;
  final List<String> Function() localIpsProvider;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final _controller = StreamController<DiscoveredDevice>.broadcast();

  /// 已知对端 IP → 最近一次从它收到包的时间（用于单播探测维持在线）
  final Map<String, DateTime> _knownPeers = {};

  /// 用户手动指定的对端：跳过同子网校验（跨网段直连正是手动添加的意义）
  final Set<String> _manualPeers = {};

  /// 每个对端上次收到回复的时间，避免每收到一个包就回一个造成风暴
  final Map<String, DateTime> _lastReplyAt = {};

  /// 超过这个时间没再见到就从探测列表移除
  static const Duration _peerTtl = Duration(seconds: 90);

  /// 回复限流：同一对端 1.2 秒内最多回一次
  static const Duration _replyThrottle = Duration(milliseconds: 1200);

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

          // 第 4 段是包类型，老版本没有则按 announce 处理（需要回复）
          final type = parts.length >= 4 ? parts[3] : 'announce';

          final remoteIp = datagram.address.address;
          final localIps = localIpsProvider();

          // 只接受「私网地址 且 与本机处于同一 /24 子网」的对端。
          // 少了任一条件，VPN 隧道等不可达 IP 都会混进设备列表，
          // 表现为「能看到设备，但一点发送就报错」。
          if (localIps.contains(remoteIp)) return;
          if (remoteIp == '127.0.0.1') return;
          // 手动添加的对端是用户明确指定的，跳过私网/同子网校验以支持跨网段直连
          if (!_manualPeers.contains(remoteIp)) {
            if (!isPrivateLanIp(remoteIp)) return;
            if (!isSameSubnetAsLocal(remoteIp, localIps)) return;
          }

          // 记入已知对端，后续靠单播探测维持在线
          _knownPeers[remoteIp] = DateTime.now();

          // 收到广播/探测就单播回一份自己；reply 不回，否则两家互踢
          if (type != 'reply') {
            _replyTo(remoteIp);
          }

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

  /// 手动添加对端：跨网段、广播不通时的兜底通道
  void addPeer(String ip) {
    final trimmed = ip.trim();
    if (trimmed.isEmpty) return;
    _manualPeers.add(trimmed);
    _knownPeers[trimmed] = DateTime.now();
    _lastReplyAt.remove(trimmed); // 允许立刻探测，不等下一个周期
    _replyTo(trimmed);
  }

  /// 向对端单播一份自己的信息（单播在 Android 上不受广播过滤影响）
  void _replyTo(String peerIp) {
    final socket = _socket;
    if (socket == null) return;

    final last = _lastReplyAt[peerIp];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _replyThrottle) return;
    _lastReplyAt[peerIp] = now;

    try {
      socket.send(
        utf8.encode(
            'P2P_DISCOVER|$deviceName|${Platform.operatingSystem}|reply'),
        InternetAddress(peerIp),
        kUdpPort,
      );
    } catch (_) {}
  }

  void _broadcast() {
    final socket = _socket;
    if (socket == null) return;
    final localIps = localIpsProvider();

    final announce = utf8.encode(
        'P2P_DISCOVER|$deviceName|${Platform.operatingSystem}|announce');
    final probe = utf8.encode(
        'P2P_DISCOVER|$deviceName|${Platform.operatingSystem}|probe');

    try {
      socket.send(announce, InternetAddress('255.255.255.255'), kUdpPort);
    } catch (_) {}

    // 针对当前网段的定向广播（如 192.168.1.255）
    // 部分路由器/交换机不转发全局广播，定向广播可提升发现成功率
    for (final ip in localIps) {
      final segs = ip.split('.');
      if (segs.length != 4) continue;
      try {
        socket.send(announce,
            InternetAddress('${segs[0]}.${segs[1]}.${segs[2]}.255'), kUdpPort);
      } catch (_) {}
    }

    // 向已知对端单播探测：这是安卓端发现对端的主力通道
    // （广播它收不到，但单播一定能收到）
    final now = DateTime.now();
    _knownPeers.removeWhere((ip, seen) {
      if (now.difference(seen) > _peerTtl) {
        _lastReplyAt.remove(ip);
        return true;
      }
      return false;
    });
    for (final peer in _knownPeers.keys) {
      try {
        socket.send(probe, InternetAddress(peer), kUdpPort);
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
