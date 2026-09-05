import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 接收文件的保存位置
class SaveLocation {
  /// 实际保存目录
  final String path;

  /// 是否是用户能在文件管理器里直接看到的公共目录
  final bool isPublic;

  /// 是否是用户在设置里手动指定的目录
  final bool isCustom;

  /// 没能落到公共目录时的说明（供 UI 提示）
  final String? note;

  SaveLocation(this.path,
      {this.isPublic = false, this.isCustom = false, this.note});
}

/// 应用设置持久化（保存目录 / 加密口令等），存在应用支持目录下的一个 JSON 文件。
///
/// 用文件而不是 shared_preferences，是为了不再引入新依赖（桌面端各平台的
/// 注册表/GSettings 后端行为不一致，反而更容易出问题）。
class AppPrefs {
  static const _fileName = 'prefs.json';
  static const _keySaveDir = 'saveDir';
  static const _keyPassphrase = 'passphrase';

  static Future<File> _prefsFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, _fileName));
  }

  static Future<Map<String, dynamic>> _read() async {
    try {
      final file = await _prefsFile();
      if (!await file.exists()) return {};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }

  static Future<void> _write(Map<String, dynamic> data) async {
    await (await _prefsFile()).writeAsString(jsonEncode(data));
  }

  static Future<String?> _get(String key) async {
    final value = (await _read())[key];
    return value?.toString();
  }

  static Future<void> _set(String key, String? value) async {
    final data = await _read();
    if (value == null || value.isEmpty) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    await _write(data);
  }

  static Future<String?> loadSaveDir() => _get(_keySaveDir);

  static Future<void> saveSaveDir(String path) => _set(_keySaveDir, path);

  static Future<void> clearSaveDir() => _set(_keySaveDir, null);

  /// 端到端加密口令。为空表示不加密
  static Future<String?> loadPassphrase() => _get(_keyPassphrase);

  static Future<void> savePassphrase(String? value) =>
      _set(_keyPassphrase, value);
}

/// 让用户选择接收目录。
///
/// ⚠️ 只在桌面端（Windows/macOS/Linux）可用。Android 上 file_picker 的
/// getDirectoryPath 走 SAF，返回的是 content:// 形式或受限路径，Dart 侧的
/// File API 直接写会失败（需要拿 URI 持久化权限），Android 端仍走公共 Downloads。
Future<String?> pickSaveDirectory({String? initialDirectory}) async {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    return await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择接收文件的保存目录',
      initialDirectory: initialDirectory,
    );
  } catch (_) {
    return null;
  }
}

/// 解析接收文件的保存目录
///
/// 优先级：用户手动指定的目录（仍可写时）> 平台默认目录。
/// 自定义目录失效（被删 / 权限丢失）时不静默丢弃，而是回退并给出可读原因。
Future<SaveLocation> resolveSaveLocation() async {
  final custom = await AppPrefs.loadSaveDir();
  if (custom != null && custom.isNotEmpty) {
    final dir = Directory(custom);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {}
    if (await _isWritable(dir)) {
      return SaveLocation(custom, isPublic: true, isCustom: true);
    }

    final fallback = await _defaultLocation();
    return SaveLocation(
      fallback.path,
      isPublic: fallback.isPublic,
      isCustom: true,
      note: '自定义的接收目录已失效（被删除或无写入权限）：$custom\n'
          '已临时改用: ${fallback.path}',
    );
  }
  return _defaultLocation();
}

/// 平台默认保存目录
Future<SaveLocation> _defaultLocation() async {
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
