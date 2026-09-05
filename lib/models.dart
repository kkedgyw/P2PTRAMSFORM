/// 传输协议端口常量
const int kHttpPort = 45678;
const int kUdpPort = 45679;

/// 传输方向
enum TransferDirection { send, receive }

/// 传输状态
enum TransferStatus {
  pending, // 等待对方确认
  accepted, // 对方已接受
  rejected, // 对方拒绝
  transferring, // 传输中
  completed, // 完成
  failed, // 失败
  cancelled, // 取消
}

/// 单个文件的元信息
class FileMeta {
  final String name;
  final int size;

  const FileMeta({required this.name, required this.size});

  Map<String, dynamic> toJson() => {'name': name, 'size': size};

  factory FileMeta.fromJson(Object? raw) {
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return FileMeta(
        name: map['name']?.toString() ?? 'unknown',
        size: (map['size'] as num?)?.toInt() ?? 0,
      );
    }
    return const FileMeta(name: 'unknown', size: 0);
  }
}

/// 一次传输会话（可包含多个文件）
class TransferSession {
  final String id;
  final TransferDirection direction;
  final String peerName;
  final String peerIp;
  final List<FileMeta> files;
  final DateTime startTime;

  TransferStatus status;
  int fileIndex; // 当前正在传第几个文件
  int fileBytes; // 当前文件已传字节
  int bytesDone; // 已完成文件累计字节
  String? error;
  final List<String> savedPaths; // 接收端落盘路径

  TransferSession({
    required this.id,
    required this.direction,
    required this.peerName,
    required this.peerIp,
    required this.files,
    DateTime? startTime,
    this.status = TransferStatus.pending,
    this.fileIndex = 0,
    this.fileBytes = 0,
    this.bytesDone = 0,
    this.error,
    List<String>? savedPaths,
  })  : startTime = startTime ?? DateTime.now(),
        savedPaths = savedPaths ?? [];

  int get totalBytes => files.fold<int>(0, (sum, f) => sum + f.size);

  /// 整体进度 0.0 ~ 1.0
  double get progress {
    final total = totalBytes;
    if (total <= 0) return 0.0;
    return ((bytesDone + fileBytes) / total).clamp(0.0, 1.0).toDouble();
  }

  FileMeta? get currentFile {
    if (fileIndex < 0 || fileIndex >= files.length) return null;
    return files[fileIndex];
  }

  bool get isActive =>
      status == TransferStatus.pending ||
      status == TransferStatus.accepted ||
      status == TransferStatus.transferring;

  bool get isFinished =>
      status == TransferStatus.completed ||
      status == TransferStatus.failed ||
      status == TransferStatus.rejected ||
      status == TransferStatus.cancelled;

  String get statusLabel {
    switch (status) {
      case TransferStatus.pending:
        return direction == TransferDirection.receive ? '待确认' : '等待对方确认';
      case TransferStatus.accepted:
        return '已接受，准备传输';
      case TransferStatus.rejected:
        return '对方已拒绝';
      case TransferStatus.transferring:
        return '传输中';
      case TransferStatus.completed:
        return '已完成';
      case TransferStatus.failed:
        return '失败';
      case TransferStatus.cancelled:
        return '已取消';
    }
    return '';
  }
}

/// 字节数格式化
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
