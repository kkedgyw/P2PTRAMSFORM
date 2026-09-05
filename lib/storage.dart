import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 解析接收文件的保存目录
///
/// Android：优先公共 Downloads 目录（/storage/emulated/0/Download）。
/// 注意：Android 11+ 写入公共目录需要「所有文件访问权限」(MANAGE_EXTERNAL_STORAGE)，
/// 该权限在 Google Play 上架时受限，但侧载分发不受影响（本项目即侧载场景）。
/// 逐级回退到 app 私有外部存储。
///
/// 桌面端：系统 Downloads，再回退到 Documents。
Future<String> resolveSaveDir() async {
  if (Platform.isAndroid) {
    try {
      final dirs =
          await getExternalStorageDirectories(type: StorageDirectory.downloads);
      if (dirs != null && dirs.isNotEmpty) {
        final dir = Directory(dirs.first.path);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir.path;
      }
    } catch (_) {}
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext.path;
    } catch (_) {}
  }

  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
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
