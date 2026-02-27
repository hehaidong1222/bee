import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用模式枚举
/// - local: 本地优先模式，本地 SQLite + 可选云端同步
/// - cloud: 兼容保留值（启动时自动迁回 local）
enum AppMode {
  local('本地优先模式'),
  cloud('兼容模式（已迁回本地）');

  final String label;
  const AppMode(this.label);

  /// 从字符串解析
  static AppMode fromString(String value) {
    return AppMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppMode.local,
    );
  }
}

/// 当前应用模式 Provider
/// 默认为本地模式
final appModeProvider = StateNotifierProvider<AppModeNotifier, AppMode>((ref) {
  return AppModeNotifier();
});

/// AppMode 状态管理器
class AppModeNotifier extends StateNotifier<AppMode> {
  AppModeNotifier() : super(AppMode.local) {
    _loadMode();
  }

  /// 从 SharedPreferences 加载模式
  Future<void> _loadMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString('app_mode');
      if (modeStr != null) {
        final loaded = AppMode.fromString(modeStr);
        if (loaded == AppMode.cloud) {
          state = AppMode.local;
          await prefs.setString('app_mode', AppMode.local.name);
          await prefs.setBool('app_mode_cloud_retired', true);
        } else {
          state = loaded;
        }
      }
    } catch (e) {
      // 加载失败，保持默认的本地模式
      state = AppMode.local;
    }
  }

  /// 切换到指定模式
  Future<void> switchMode(AppMode mode) async {
    final normalized = mode == AppMode.cloud ? AppMode.local : mode;
    state = normalized;

    // 持久化到 SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_mode', normalized.name);
      if (mode == AppMode.cloud) {
        await prefs.setBool('app_mode_cloud_retired', true);
      }
    } catch (e) {
      // 保存失败，但状态已经切换
    }
  }

  /// 切换到本地模式
  Future<void> switchToLocal() => switchMode(AppMode.local);

  /// 切换到云端模式
  Future<void> switchToCloud() => switchMode(AppMode.cloud);
}

/// 判断当前是否为云端模式
final isCloudModeProvider = Provider<bool>((ref) {
  final mode = ref.watch(appModeProvider);
  return mode == AppMode.cloud;
});

/// 判断当前是否为本地模式
final isLocalModeProvider = Provider<bool>((ref) {
  final mode = ref.watch(appModeProvider);
  return mode == AppMode.local;
});
