import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 接收文件的保存位置
class SaveLocation {
  /// 实际保存目录
  final String path;

  /// 是否是用户能在文件管理器里直接看到的公共目录
  final bool isPublic;

  /// 没能落到公共目录时的说明（供 UI 提示）
  final String? note;

  SaveLocation(this.path, {this.isPublic = false, this.note});
}

/// 解析接收文件的保存目录
///
/// Android 优先公共 Downloads（/storage/emulated/0/Download/P2PTransfer）。
///
/// ⚠️ 注意：不要用 `getExternalStorageDirectories()` 的结果当公共目录 ——
/// 它走的是 `Context.getExternalFilesDirs()`，返回的是
/// `/storage/emulated/0/Android/data/<pkg>/files/Download`，是 **app 私有目录**。
/// Android 11+ 起文件管理器无法浏览 Android/data，表现为「传输成功但找不到文件」。
/// 真正的公共目录要从外部存储根拼出来，且需要「所有文件访问权限」
/// (MANAGE_EXTERNAL_STORAGE) 才能写入；该权限在 Play 上架受限，侧载分发不受影响。
Future<SaveLocation> resolveSaveLocation() async {
  if (Platform.isAndroid) {
    final public = await _androidPublicDownloads();
    if (public != null) {
      return SaveLocation(public, isPublic: true);
    }
    final fallback = await _androidFallback();
    return SaveLocation(
      fallback,
      note: '未获得「所有文件访问权限」，文件将保存到应用私有目录'
          '（文件管理器看不到，需在应用内查看）',
    );
  }

  // 桌面端：系统 Downloads，回退 Documents
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      final dir = Directory(p.join(downloads.path, 'P2PTransfer'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return SaveLocation(dir.path, isPublic: true);
    }
  } catch (_) {}
  final docs = await getApplicationDocumentsDirectory();
  return SaveLocation(docs.path);
}

/// Android 公共 Downloads 目录；无权限或不可写时返回 null
Future<String?> _androidPublicDownloads() async {
  try {
    final dirs = await getExternalStorageDirectories();
    if (dirs == null || dirs.isEmpty) return null;

    final root = _externalStorageRoot(dirs.first.path);
    if (root == null) return null;

    final dir = Directory(p.join(root, 'Download', 'P2PTransfer'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // 光建目录成功不代表能写，实测一次才算数
    if (await _isWritable(dir)) return dir.path;
    return null;
  } catch (_) {
    // 典型的没授予 MANAGE_EXTERNAL_STORAGE 时 create 会直接抛
    return null;
  }
}

/// 从 app 私有外部目录推导外部存储根：
/// /storage/emulated/0/Android/data/<pkg>/files -> /storage/emulated/0
String? _externalStorageRoot(String privatePath) {
  const marker = '/Android/data/';
  final idx = privatePath.indexOf(marker);
  if (idx > 0) return privatePath.substring(0, idx);
  return null;
}

/// 实际写一个探针文件验证目录可写
Future<bool> _isWritable(Directory dir) async {
  final probe =
      File(p.join(dir.path, '.p2p_probe_${DateTime.now().microsecondsSinceEpoch}'));
  try {
    await probe.writeAsString('probe');
    await probe.delete();
    return true;
  } catch (_) {
    try {
      await probe.delete();
    } catch (_) {}
    return false;
  }
}

/// Android 上拿不到公共目录时的回退：app 私有外部存储，再回退内部文档目录
Future<String> _androidFallback() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final dir = Directory(p.join(ext.path, 'P2PTransfer'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    }
  } catch (_) {}
  final docs = await getApplicationDocumentsDirectory();
  return docs.path;
}

/// 若目标文件名已存在，自动追加 _1 _2 ... 避免覆盖已有文件
Future<String> uniqueFilePath(String dir, String fileName) async {
  final base = p.join(dir, fileName);
  if (!await File(base).exists()) return base;

  final ext = p.extension(fileName);
  final stem = p.basenameWithoutExtension(fileName);
  for (var i = 1; i <= 999; i++) {
    final candidate = p.join(dir, '${stem}_$i$ext');
    if (!await File(candidate).exists()) return candidate;
  }
  return p.join(
      dir, '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
}
