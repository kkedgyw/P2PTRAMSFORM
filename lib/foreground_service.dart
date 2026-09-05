import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务回调：必须是顶层函数或静态函数
@pragma('vm:entry-point')
void p2pForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_P2PTaskHandler());
}

/// 9.2.2 的 TaskHandler 有 7 个方法需要覆写
class _P2PTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}

/// Android 后台保活封装
///
/// 所有方法都做了平台判断 + try/catch：非 Android 平台直接 no-op，
/// 万一插件在真机上出问题也不会让传输功能整体崩掉。
class BackgroundTransferService {
  static bool _inited = false;

  static void init() {
    if (!Platform.isAndroid || _inited) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'p2p_transfer',
          channelName: 'P2P 文件传输',
          channelDescription: '文件传输进行中的常驻通知',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      _inited = true;
    } catch (_) {}
  }

  /// 有传输任务时开启前台服务
  static Future<void> start(String text) async {
    if (!Platform.isAndroid || !_inited) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'P2P 传输进行中',
        notificationText: text,
        callback: p2pForegroundCallback,
      );
    } catch (_) {}
  }

  /// 刷新通知上的进度文案
  static Future<void> update(String text) async {
    if (!Platform.isAndroid || !_inited) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
      }
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_inited) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
