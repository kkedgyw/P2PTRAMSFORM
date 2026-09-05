import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'discovery.dart';
import 'models.dart';

/// 对端 /ping 返回的信息
class PeerInfo {
  final String name;
  final String os;

  PeerInfo({required this.name, required this.os});

  factory PeerInfo.fromJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('not a json object');
    final map = Map<String, dynamic>.from(decoded);

    // 应用标识校验：局域网里可能有别的服务恰好占了同一个端口。
    // 老版本返回的是纯文本 'pong'，jsonDecode 会抛异常 → 探测结果为 null，
    // 即老版本不会被扫出来（两端都升级即可）。
    final app = map['app']?.toString();
    if (app != null && app != 'p2p_transfer') {
      throw const FormatException('not p2p_transfer');
    }

    return PeerInfo(
      name: map['name']?.toString() ?? '未知设备',
      os: map['os']?.toString() ?? 'unknown',
    );
  }
}

/// 探测单个 IP 上是否跑着本应用。
///
/// 直接用 Socket 发一个最小 HTTP/1.0 请求，而不用 http 包 —— 扫描时要并发
/// 上百个连接，http 包的连接池和额外开销会让超时控制变得不可控。
Future<PeerInfo?> probePeer(String ip,
    {Duration timeout = const Duration(milliseconds: 600)}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, kHttpPort, timeout: timeout);
    socket.write('GET /ping HTTP/1.0\r\nHost: $ip\r\nConnection: close\r\n\r\n');
    await socket.flush();

    final builder = BytesBuilder();
    await socket.timeout(timeout).fold<List<int>>(
          <int>[],
          (_, chunk) {
            builder.add(chunk);
            return <int>[];
          },
        );

    final raw = utf8.decode(builder.takeBytes(), allowMalformed: true);
    // 取响应体：空行之后的内容
    final idx = raw.indexOf('\r\n\r\n');
    final body = idx >= 0 ? raw.substring(idx + 4) : raw;
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;

    final info = PeerInfo.fromJson(trimmed);
    // 应用标识校验：避免局域网里恰好有个服务占用了同端口导致误判
    return info;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

/// 网段扫描器
///
/// 用途：广播发现不到设备时的兜底，也是**虚拟组网（EasyTier 等）场景的主力发现方式**。
///
/// 为什么必须要有它：
/// - Android 接收 UDP 广播本身就不可靠（需要 MulticastLock，纯 Dart 拿不到）
/// - EasyTier 的 UDP 广播中继是 v2.6.4 才加的，**仅 Windows、默认关闭、需管理员权限**
///   （--enable-udp-broadcast-relay），虚拟网里不能指望广播
///
/// 因此直接对本地各网卡所在的 /24 网段做 TCP 探测，能连上且 /ping 返回本应用
/// 标识的就算一台设备。TCP 探测不依赖任何广播/组播能力。
class SubnetScanner {
  /// 每批并发探测的数量。太大容易触发路由器/系统限流，太小扫得慢
  static const int _batchSize = 64;

  /// 单个 IP 的连接+响应超时。局域网内 600ms 足够，
  /// 虚拟网（可能跨省、走中继）建议由调用方调大
  static const Duration _defaultTimeout = Duration(milliseconds: 600);

  final Duration timeout;

  /// 扫描过程中是否已被取消
  bool _cancelled = false;

  SubnetScanner({Duration? timeout}) : timeout = timeout ?? _defaultTimeout;

  void cancel() => _cancelled = true;

  /// 扫描 [localIps] 所在的全部 /24 网段，逐个 yield 发现的设备
  Stream<DiscoveredDevice> scan(List<String> localIps) async* {
    _cancelled = false;

    final prefixes = <String>{};
    for (final ip in localIps) {
      final prefix = subnetPrefixOf(ip);
      if (prefix != null) prefixes.add(prefix);
    }
    if (prefixes.isEmpty) return;

    for (final prefix in prefixes) {
      final targets = <String>[];
      for (var i = 1; i <= 254; i++) {
        final ip = '$prefix.$i';
        if (localIps.contains(ip)) continue; // 跳过自己
        targets.add(ip);
      }

      for (var i = 0; i < targets.length; i += _batchSize) {
        if (_cancelled) return;
        final batch = targets.skip(i).take(_batchSize).toList();

        final results = await Future.wait(batch.map((ip) async {
          final info = await probePeer(ip, timeout: timeout);
          if (info == null) return null;
          return DiscoveredDevice(
            ip: ip,
            name: info.name,
            os: info.os,
            lastSeen: DateTime.now(),
            viaScan: true,
          );
        }));

        for (final device in results) {
          if (device != null && !_cancelled) yield device;
        }
      }
    }
  }
}
