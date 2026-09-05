import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'discovery.dart';
import 'foreground_service.dart';
import 'models.dart';
import 'storage.dart';
import 'subnet_scan.dart';
import 'transfer_client.dart';
import 'transfer_server.dart';

void main() {
  // flutter_foreground_task 要求：初始化 UI 与 TaskHandler 的通信端口
  FlutterForegroundTask.initCommunicationPort();
  runApp(const P2PTransferApp());
}

class P2PTransferApp extends StatelessWidget {
  const P2PTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '局域网极速互传',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<String> _localIps = [];
  String _deviceName = '未知设备';
  String _status = '就绪';
  String? _saveDir;
  bool _publicStorage = false;
  bool _saveDirCustom = false;
  String? _storageNote;
  bool _initializing = true;

  DeviceDiscovery? _discovery;
  StreamSubscription<DiscoveredDevice>? _discoverySub;
  Timer? _cleanupTimer;

  /// 网段扫描器（扫描进行中才有值）
  SubnetScanner? _scanner;
  bool _scanning = false;
  int _scanFound = 0;

  TransferServer? _server;
  TransferClient? _client;

  final Map<String, DiscoveredDevice> _devices = {};
  final List<TransferSession> _transfers = [];

  // ---------------------------------------------------------------- 生命周期

  @override
  void initState() {
    super.initState();
    BackgroundTransferService.init();
    _initApp();
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _discoverySub?.cancel();
    _discovery?.stop();
    _server?.stop();
    super.dispose();
  }

  Future<void> _initApp() async {
    if (Platform.isAndroid) {
      // notification: Android 13+ 前台服务通知需要运行时权限
      await [
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.notification,
      ].request();
    }

    _deviceName = _resolveDeviceName();
    _localIps = await refreshLocalIps();

    final location = await resolveSaveLocation();
    _applyLocationToState(location);

    _server = TransferServer(
      saveDir: _saveDir!,
      deviceName: _deviceName,
      onConfirmRequest: _onConfirmRequest,
      onSessionChanged: _onSessionChanged,
    );
    await _server!.start();

    _client =
        TransferClient(deviceName: _deviceName, onProgress: _onSessionChanged);

    await _startDiscovery();

    if (mounted) {
      setState(() {
        _initializing = false;
        _status = '就绪 · 接收保存到: $_saveDir';
      });
    }
  }

  String _resolveDeviceName() {
    if (Platform.isAndroid) return 'Android Phone';
    if (Platform.isWindows) {
      return Platform.environment['COMPUTERNAME'] ?? 'Windows PC';
    }
    if (Platform.isMacOS) return Platform.environment['USER'] ?? 'Mac';
    if (Platform.isLinux) return Platform.environment['HOSTNAME'] ?? 'Linux';
    return 'Device-${Platform.operatingSystem}';
  }

  Future<void> _startDiscovery() async {
    _discovery = DeviceDiscovery(
      deviceName: _deviceName,
      localIpsProvider: () => _localIps,
    );

    _discoverySub = _discovery!.onDeviceFound.listen((device) {
      if (!mounted) return;
      setState(() => _devices[device.ip] = device);
    });

    final ok = await _discovery!.start();
    if (!ok && mounted) {
      setState(() => _status = 'UDP 启动异常: ${_discovery!.lastError}');
    }

    // 单播探测每 2 秒一次，宽限到 10 秒可避免对端偶尔丢一个包就被判定离线
    _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        _devices
            .removeWhere((_, d) => now.difference(d.lastSeen).inSeconds > 10);
      });
    });
  }

  // ---------------------------------------------------------------- 传输逻辑

  /// 会话状态变化：刷新 UI + 同步 Android 常驻通知
  void _onSessionChanged(TransferSession session) {
    if (!mounted) return;
    setState(() {
      final idx = _transfers.indexWhere((t) => t.id == session.id);
      if (idx >= 0) {
        _transfers[idx] = session;
      } else {
        _transfers.insert(0, session);
      }
    });

    if (session.isActive) {
      final verb = session.direction == TransferDirection.send ? '发送' : '接收';
      BackgroundTransferService.update(
          '$verb ${(session.progress * 100).toStringAsFixed(0)}%');
    } else {
      unawaited(_maybeStopBackground());
    }
  }

  /// 收到对端传输请求 → 弹确认框
  void _onConfirmRequest(TransferSession session, Completer<bool> decision) {
    if (!mounted) {
      decision.complete(false);
      return;
    }
    setState(() {
      if (!_transfers.any((t) => t.id == session.id)) {
        _transfers.insert(0, session);
      }
    });

    Timer? autoReject;

    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConfirmDialog(session: session),
    ).then((ok) {
      autoReject?.cancel();
      final accepted = ok == true;
      _server?.resolve(session.id, accepted);
      if (mounted) {
        setState(() => _status = accepted ? '已接受传输，等待接收' : '已拒绝该传输');
      }
    });

    // 用户 55 秒未响应则自动关闭对话框（服务端 60 秒超时拒绝）
    autoReject = Timer(const Duration(seconds: 55), () {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(false);
      }
    });
  }

  /// 多文件发送
  Future<void> _sendFilesTo(DiscoveredDevice target) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final files = <FileMeta>[];
    final paths = <String>[];
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      files.add(FileMeta(name: f.name, size: f.size));
      paths.add(path);
    }
    if (files.isEmpty) return;

    final session = TransferSession(
      id: _newTransferId(),
      direction: TransferDirection.send,
      peerName: target.name,
      peerIp: target.ip,
      files: files,
    );
    _onSessionChanged(session);

    setState(() => _status = '等待 ${target.name} 确认...');
    await BackgroundTransferService.start('等待 ${target.name} 确认');

    try {
      final requested = await _client!.requestTransfer(session);
      if (!requested) {
        _markFailed(session, '无法连接 ${target.name}，请确认对方在线');
        return;
      }

      final accepted = await _client!.waitForDecision(session);
      if (!accepted) {
        session.status = TransferStatus.rejected;
        _onSessionChanged(session);
        setState(() => _status = '${target.name} 拒绝了传输');
        return;
      }

      session.status = TransferStatus.accepted;
      _onSessionChanged(session);
      setState(() => _status = '正在发送给 ${target.name}...');

      await _client!.uploadFiles(session, paths);
      setState(() => _status = '已发送 ${files.length} 个文件到 ${target.name}');
    } catch (e) {
      _markFailed(session, e.toString());
    } finally {
      await _maybeStopBackground();
    }
  }

  void _markFailed(TransferSession session, String error) {
    session.status = TransferStatus.failed;
    session.error = error;
    _onSessionChanged(session);
    if (mounted) setState(() => _status = '发送失败: $error');
  }

  void _cancelTransfer(TransferSession session) {
    session.status = TransferStatus.cancelled;
    _onSessionChanged(session);
    unawaited(_maybeStopBackground());
  }

  /// 手动添加设备：广播发现不到时的兜底（Android 广播过滤 / 跨网段 / 路由器隔离）
  Future<void> _addManualPeer() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '对方 IP 地址',
            hintText: '例如 192.168.1.50',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ip == null || ip.isEmpty || !mounted) return;

    setState(() => _status = '正在连接 $ip ...');
    final ok = await _probePeer(ip);
    if (!mounted) return;

    if (ok) {
      _discovery?.addPeer(ip);
      setState(() => _status = '已添加 $ip，稍等即出现在设备列表');
    } else {
      setState(() => _status = '连接 $ip:$kHttpPort 失败 —— 请确认对方已打开本应用、'
          'IP 填写正确，且未被防火墙拦截');
    }
  }

  /// 扫描本机各网卡所在的 /24 网段。
  ///
  /// 这是外网（虚拟组网）场景的主力发现方式：EasyTier 的 UDP 广播中继默认关闭
  /// 且仅 Windows 可用，Android 又天生收不好广播，只有 TCP 探测最可靠。
  Future<void> _scanSubnets() async {
    if (_scanning) {
      _scanner?.cancel();
      if (mounted) setState(() => _status = '已取消扫描');
      return;
    }

    _localIps = await refreshLocalIps();
    if (!mounted) return;
    if (_localIps.isEmpty) {
      setState(() => _status = '未获取到本机 IP，无法扫描');
      return;
    }

    setState(() {
      _scanning = true;
      _scanFound = 0;
      _status = '正在扫描 ${_localIps.length} 个网段...';
    });

    _scanner = SubnetScanner(timeout: const Duration(milliseconds: 800));
    final prefixes = _localIps
        .map(subnetPrefixOf)
        .whereType<String>()
        .toSet()
        .join('、');

    await for (final device in _scanner!.scan(_localIps)) {
      if (!mounted) break;
      // 交给发现层做单播维持，之后不用反复扫描
      _discovery?.addPeer(device.ip, trusted: false);
      setState(() {
        _devices[device.ip] = device;
        _scanFound++;
      });
    }

    if (!mounted) return;
    setState(() {
      _scanning = false;
      _status = _scanFound > 0
          ? '扫描完成（$prefixes），发现 $_scanFound 台设备'
          : '扫描完成（$prefixes），未发现设备。'
              '请确认对方已打开本应用且防火墙放行 $kHttpPort 端口';
    });
  }

  /// 探测对端 HTTP 服务是否可达（复用网段扫描的探测逻辑）
  Future<bool> _probePeer(String ip) async {
    final info = await probePeer(ip, timeout: const Duration(seconds: 3));
    return info != null;
  }

  /// 没有活跃传输时关闭前台服务
  Future<void> _maybeStopBackground() async {
    final anyActive = _transfers.any((t) => t.isActive);
    if (!anyActive) await BackgroundTransferService.stop();
  }

  String _newTransferId() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 30)}';
  }

  // ---------------------------------------------------------------- 界面

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
            icon: Icon(_scanning ? Icons.stop_circle_outlined : Icons.travel_explore),
            tooltip: _scanning ? '停止扫描' : '扫描网段（虚拟组网 / 跨网段设备用这个）',
            onPressed: _scanSubnets,
          ),
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: '手动添加设备（发现不到时用 IP 直连）',
            onPressed: _addManualPeer,
          ),
          if (_canPickSaveDir)
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: '选择接收目录',
              onPressed: _pickSaveDir,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新扫描',
            onPressed: () async {
              _localIps = await refreshLocalIps();
              if (!mounted) return;
              setState(() => _devices.clear());
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSelfCard(ipDisplay),
          if (_transfers.isNotEmpty) _buildTransferPanel(),
          _buildDeviceHeader(deviceList.length),
          Expanded(child: _buildDeviceList(deviceList)),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildSelfCard(String ipDisplay) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_deviceIcon(Platform.operatingSystem), size: 28),
              const SizedBox(width: 8),
              Text(_deviceName,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 6),
          Text('本机 IP: $ipDisplay',
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
          if (_saveDir != null) _buildSaveDirInfo(),
        ],
      ),
    );
  }

  /// 保存位置 + 权限提示。拿不到公共目录时给出明确原因和去授权的入口
  Widget _buildSaveDirInfo() {
    final dir = _saveDir;
    if (dir == null) return const SizedBox.shrink();
    final warning = !_publicStorage && Platform.isAndroid;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(warning ? Icons.folder_off : Icons.folder_open,
                  size: 14, color: warning ? Colors.orange : Colors.grey),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    '接收保存到${_saveDirCustom ? '（自定义）' : ''}: $dir',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ],
          ),
          if (_storageNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 18),
              child: Text(_storageNote!,
                  style: const TextStyle(color: Colors.orange, fontSize: 11)),
            ),
          if (warning)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _openStorageSettings,
                child: const Text('去设置授予「所有文件访问权限」',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          // 桌面端可自由指定接收目录；Android 走系统公共 Downloads，不提供该项
          if (_canPickSaveDir)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  style: _smallButtonStyle,
                  onPressed: _pickSaveDir,
                  child: const Text('更改', style: TextStyle(fontSize: 12)),
                ),
                if (_saveDirCustom)
                  TextButton(
                    style: _smallButtonStyle,
                    onPressed: _resetSaveDir,
                    child:
                        const Text('恢复默认', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  ButtonStyle get _smallButtonStyle => TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  /// 桌面端才能让用户选目录（Android 的 SAF 路径 Dart 侧写不了）
  bool get _canPickSaveDir => !Platform.isAndroid && !Platform.isIOS;

  /// 跳系统设置页授权，返回后重新解析保存位置
  Future<void> _openStorageSettings() async {
    await openAppSettings();
    await _refreshSaveLocation();
  }

  /// 重新解析保存位置并热更新接收端（无需重启应用）
  Future<void> _refreshSaveLocation() async {
    final loc = await resolveSaveLocation();
    if (!mounted) return;
    setState(() => _applyLocationToState(loc));
    _server?.saveDir = loc.path;
  }

  void _applyLocationToState(SaveLocation loc) {
    _saveDir = loc.path;
    _publicStorage = loc.isPublic;
    _saveDirCustom = loc.isCustom;
    _storageNote = loc.note;
  }

  /// 选择接收目录（桌面端）
  Future<void> _pickSaveDir() async {
    final picked = await pickSaveDirectory(initialDirectory: _saveDir);
    if (picked == null || !mounted) return;
    try {
      await SaveDirPrefs.save(picked);
    } catch (e) {
      if (mounted) setState(() => _status = '保存目录设置失败: $e');
      return;
    }
    await _refreshSaveLocation();
    if (!mounted) return;
    setState(() => _status = '接收保存到: $_saveDir');
  }

  /// 恢复平台默认接收目录
  Future<void> _resetSaveDir() async {
    await SaveDirPrefs.clear();
    await _refreshSaveLocation();
    if (!mounted) return;
    setState(() => _status = '已恢复默认接收目录: $_saveDir');
  }

  Widget _buildTransferPanel() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 230),
      child: Container(
        decoration: BoxDecoration(
          border:
              Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _transfers.length,
          itemBuilder: (context, index) =>
              _buildTransferTile(_transfers[index]),
        ),
      ),
    );
  }

  Widget _buildTransferTile(TransferSession s) {
    final isSend = s.direction == TransferDirection.send;
    final color = _statusColor(s.status);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isSend ? Icons.upload : Icons.download,
                    size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${isSend ? '发给' : '来自'} ${s.peerName} · '
                    '${s.files.length} 个文件 · ${formatBytes(s.totalBytes)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(s.statusLabel,
                    style: TextStyle(fontSize: 12, color: color)),
              ],
            ),
            const SizedBox(height: 6),
            if (s.status == TransferStatus.transferring)
              LinearProgressIndicator(value: s.progress),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _progressText(s),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 待确认的接收请求：除了弹窗，列表里也给一组按钮兜底
                if (s.status == TransferStatus.pending &&
                    s.direction == TransferDirection.receive) ...[
                  TextButton(
                    onPressed: () => _server?.resolve(s.id, false),
                    child: const Text('拒绝'),
                  ),
                  TextButton(
                    onPressed: () => _server?.resolve(s.id, true),
                    child: const Text('接受'),
                  ),
                ],
                if (s.isActive)
                  TextButton(
                    onPressed: () => _cancelTransfer(s),
                    child: const Text('取消'),
                  ),
              ],
            ),
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('错误: ${s.error}',
                    style: const TextStyle(fontSize: 11, color: Colors.red)),
              ),
            if (s.savedPaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已保存 ${s.savedPaths.length} 个文件:',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                    ...s.savedPaths.take(5).map(
                          (path) => Padding(
                            padding: const EdgeInsets.only(left: 6, top: 1),
                            child: Text('· ${p.basename(path)}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ),
                    if (s.savedPaths.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, top: 1),
                        child: Text('· 还有 ${s.savedPaths.length - 5} 个…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, top: 2),
                      child: Text('目录: ${p.dirname(s.savedPaths.first)}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.blueGrey)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceHeader(int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('在线设备 ($count)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDeviceList(List<DiscoveredDevice> deviceList) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (deviceList.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '暂未发现设备。\n\n'
            '同一局域网：等待自动发现，或点右上角扫描。\n'
            '外网 / 异地（EasyTier、Tailscale 等虚拟组网）：'
            '两端都装好组网工具并加入同一网络后，点右上角扫描，'
            '再用「手动添加」填对方虚拟 IP 直连。',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: deviceList.length,
      itemBuilder: (context, index) {
        final target = deviceList[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: ListTile(
            leading: CircleAvatar(child: Icon(_deviceIcon(target.os))),
            title: Text(target.name,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
                '${target.os.toUpperCase()} • ${target.ip}'
                '${target.viaScan ? ' • 扫描发现' : ''}'),
            trailing: ElevatedButton.icon(
              onPressed: () => _sendFilesTo(target),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('发送'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.black12,
      child: Text(
        '状态: $_status',
        style: const TextStyle(fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _progressText(TransferSession s) {
    switch (s.status) {
      case TransferStatus.transferring:
        final name = s.currentFile?.name ?? '';
        final pct = (s.progress * 100).toStringAsFixed(0);
        return '$name · ${formatBytes(s.bytesDone + s.fileBytes)}'
            '/${formatBytes(s.totalBytes)} ($pct%)';
      case TransferStatus.completed:
        return '完成 · ${formatBytes(s.totalBytes)}';
      case TransferStatus.pending:
        return s.direction == TransferDirection.receive
            ? '等待你确认'
            : '等待对方确认';
      default:
        return s.statusLabel;
    }
  }

  Color _statusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
        return Colors.red;
      case TransferStatus.rejected:
      case TransferStatus.cancelled:
        return Colors.grey;
      default:
        return Colors.blue;
    }
  }

  IconData _deviceIcon(String os) {
    final o = os.toLowerCase();
    if (o.contains('android')) return Icons.phone_android;
    if (o.contains('windows')) return Icons.desktop_windows;
    if (o.contains('macos')) return Icons.laptop_mac;
    if (o.contains('linux')) return Icons.computer;
    return Icons.devices;
  }
}

/// 接收确认对话框
class _ConfirmDialog extends StatelessWidget {
  final TransferSession session;
  const _ConfirmDialog({required this.session});

  @override
  Widget build(BuildContext context) {
    final files = session.files;
    return AlertDialog(
      title: const Text('收到传输请求'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('来自：${session.peerName}'
                '${session.peerIp.isEmpty ? '' : '（${session.peerIp}）'}'),
            const SizedBox(height: 8),
            Text(
              '共 ${files.length} 个文件，${formatBytes(session.totalBytes)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...files.take(5).map((f) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('• ${f.name}（${formatBytes(f.size)}）'),
                )),
            if (files.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('…等共 ${files.length} 个'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('接受'),
        ),
      ],
    );
  }
}
