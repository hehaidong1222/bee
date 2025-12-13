import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_providers.dart';
import 'theme_providers.dart';
import 'statistics_providers.dart';
import 'font_scale_provider.dart';
import 'update_providers.dart';
import 'cloud_mode_providers.dart';
import 'supabase_providers.dart';
import '../data/db.dart';
import '../data/models/transaction_display_item.dart';
import '../services/data/recurring_transaction_service.dart';
import '../services/system/logger_service.dart';
import '../services/ai/ai_constants.dart';
import '../services/platform/app_link_service.dart';

// 底部导航索引（0: 明细, 1: 图表, 2: 账本, 3: 我的）
final bottomTabIndexProvider = StateProvider<int>((ref) => 0);

// AppLink 待处理动作（用于通知 UI 层执行导航）
final pendingAppLinkActionProvider = StateProvider<AppLinkAction?>((ref) => null);

// 首页滚动到顶部触发器（每次改变值时触发滚动）
final homeScrollToTopProvider = StateProvider<int>((ref) => 0);

// Currently selected month (first day), default to now
final selectedMonthProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, 1);
});

// 视角：'month' 或 'year'
final selectedViewProvider = StateProvider<String>((ref) => 'month');

// 检查更新状态 - 防止重复点击
final checkUpdateLoadingProvider = StateProvider<bool>((ref) => false);

// 下载进度状态
final downloadProgressProvider = StateProvider<UpdateProgress?>((ref) => null);

// ---------- Analytics 提示持久化（本地 SharedPreferences） ----------
final analyticsHeaderHintDismissedProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('analytics_header_hint_dismissed') ?? false;
});

final analyticsChartHintDismissedProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('analytics_chart_hint_dismissed') ?? false;
});

class AnalyticsHintsSetter {
  Future<void> dismissHeader() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('analytics_header_hint_dismissed', true);
  }

  Future<void> dismissChart() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('analytics_chart_hint_dismissed', true);
  }
}

// ---------- FAB 长按提示持久化 ----------
final fabSpeedDialTipDismissedProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('fab_speed_dial_tip_dismissed') ?? false;
});

class FabSpeedDialTipSetter {
  Future<void> dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fab_speed_dial_tip_dismissed', true);
  }
}

final fabSpeedDialTipSetterProvider = Provider<FabSpeedDialTipSetter>((ref) {
  return FabSpeedDialTipSetter();
});

final analyticsHintsSetterProvider = Provider<AnalyticsHintsSetter>((ref) {
  return AnalyticsHintsSetter();
});

// 应用初始化状态
enum AppInitState {
  splash, // 显示启屏页
  loading, // 正在初始化
  ready // 初始化完成，显示主应用
}

// 应用初始化状态Provider
final appInitStateProvider =
    StateProvider<AppInitState>((ref) => AppInitState.splash);

// 搜索页面金额范围筛选开关持久化
final searchAmountFilterEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('search_amount_filter_enabled') ?? false;
});

class SearchSettingsSetter {
  Future<void> setAmountFilterEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('search_amount_filter_enabled', enabled);
  }
}

final searchSettingsSetterProvider = Provider<SearchSettingsSetter>((ref) {
  return SearchSettingsSetter();
});

// 账户功能启用状态持久化
final accountFeatureEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('account_feature_enabled') ?? true;
});

class AccountFeatureSetter {
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('account_feature_enabled', enabled);
  }
}

final accountFeatureSetterProvider = Provider<AccountFeatureSetter>((ref) {
  return AccountFeatureSetter();
});

// 缓存的交易数据Provider（用于首屏快速展示）- 旧版
final cachedTransactionsWithCategoryProvider =
    StateProvider<List<({Transaction t, Category? category})>?>((ref) => null);

// 缓存的首屏交易数据Provider（带完整详情：分类、标签、附件数量）
// 用于启动时预加载当月数据（或最近20条），实现首屏快速展示
final cachedInitialTransactionsProvider =
    StateProvider<List<TransactionDisplayItem>?>((ref) => null);

// 带完整详情的交易数据 Stream Provider（包含标签、附件数量等）
// 用于监听所有交易数据的变化
final transactionsWithDetailsProvider =
    StreamProvider.family<List<TransactionDisplayItem>, int>((ref, ledgerId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTransactionsWithDetails(ledgerId: ledgerId);
});

// 首页交易列表 Provider（组合缓存数据和流数据）
// 策略：
// 1. 首次展示使用缓存的初始数据（当月或最近20条，带完整详情）
// 2. 同时订阅流数据，当流数据更新时自动切换为完整数据
// 3. 如果流数据与缓存数据相同，不触发更新（避免UI闪烁）
final homeTransactionsProvider =
    StreamProvider.family<List<TransactionDisplayItem>, int>((ref, ledgerId) async* {
  // 首先检查缓存，立即返回
  final cached = ref.read(cachedInitialTransactionsProvider);
  if (cached != null && cached.isNotEmpty) {
    print('📋 [首页] 使用缓存数据 ${cached.length}条');
    yield cached;
  }

  // 然后订阅流数据
  final repo = ref.watch(repositoryProvider);
  List<TransactionDisplayItem>? lastData = cached;

  await for (final data in repo.watchTransactionsWithDetails(ledgerId: ledgerId)) {
    // 检查数据是否真的变化了（比较ID列表和数量）
    final bool hasChanged = lastData == null ||
        data.length != lastData.length ||
        !_isSameTransactionList(data, lastData);

    if (hasChanged) {
      print('📋 [首页] 流数据更新 ${data.length}条 (变化: $hasChanged)');
      lastData = data;
      yield data;
    } else {
      print('📋 [首页] 流数据相同，跳过更新 ${data.length}条');
    }
  }
});

/// 比较两个交易列表是否相同（只比较ID和顺序）
bool _isSameTransactionList(List<TransactionDisplayItem> a, List<TransactionDisplayItem> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

/// 计时包装函数，用于诊断各个 Provider 的耗时
Future<String> _timedFuture<T>(String name, Future<T> future) async {
  final sw = Stopwatch()..start();
  await future;
  return '$name: ${sw.elapsedMilliseconds}ms';
}

/// 一次性加载所有偏好设置（优化启动性能）
/// 使用已获取的 SharedPreferences 实例，避免多次 getInstance() 调用
void _loadAllPreferences(Ref ref, SharedPreferences prefs) {
  // 1. 主题色
  final savedColor = prefs.getInt('primaryColor');
  if (savedColor != null) {
    ref.read(primaryColorProvider.notifier).state = Color(savedColor);
  }

  // 2. 主题模式
  final savedThemeMode = prefs.getString('themeMode');
  if (savedThemeMode != null) {
    switch (savedThemeMode) {
      case 'light':
        ref.read(themeModeProvider.notifier).state = ThemeMode.light;
        break;
      case 'dark':
        ref.read(themeModeProvider.notifier).state = ThemeMode.dark;
        break;
      default:
        ref.read(themeModeProvider.notifier).state = ThemeMode.system;
    }
  }

  // 3. 暗黑模式图案样式
  final savedPatternStyle = prefs.getString('darkModePatternStyle');
  if (savedPatternStyle != null) {
    ref.read(darkModePatternStyleProvider.notifier).state = savedPatternStyle;
  }

  // 4. 字体缩放档位
  final savedFontLevel = prefs.getInt('fontScaleLevel');
  if (savedFontLevel != null) {
    ref.read(fontScaleLevelProvider.notifier).state = savedFontLevel.clamp(-3, 4);
  }
  final savedCustomScale = prefs.getDouble('customFontScale');
  if (savedCustomScale != null) {
    ref.read(customFontScaleProvider.notifier).state = savedCustomScale.clamp(0.7, 1.5);
  }

  // 5. 隐藏金额
  final savedHideAmounts = prefs.getBool('hideAmounts');
  if (savedHideAmounts != null) {
    ref.read(hideAmountsProvider.notifier).state = savedHideAmounts;
  }

  // 6. 简洁金额显示
  final savedCompactAmount = prefs.getBool('compactAmount');
  if (savedCompactAmount != null) {
    ref.read(compactAmountProvider.notifier).state = savedCompactAmount;
  }

  // 7. 显示交易时间
  final savedShowTime = prefs.getBool('showTransactionTime');
  if (savedShowTime != null) {
    ref.read(showTransactionTimeProvider.notifier).state = savedShowTime;
  }

  // 8. 当前账本ID
  final savedLedgerId = prefs.getInt('current_ledger_id');
  if (savedLedgerId != null) {
    ref.read(currentLedgerIdProvider.notifier).state = savedLedgerId;
  }
}

// 首页交易列表数据（同步获取，优先使用缓存）
// 用于在 StreamProvider 还在 loading 时提供数据
final homeTransactionsCachedProvider =
    Provider.family<List<TransactionDisplayItem>?, int>((ref, ledgerId) {
  // 优先返回流数据
  final streamData = ref.watch(homeTransactionsProvider(ledgerId));
  if (streamData.hasValue) {
    return streamData.value;
  }
  // 流数据未就绪时返回缓存
  return ref.watch(cachedInitialTransactionsProvider);
});

// 应用初始化Provider - 管理数据预加载
final appSplashInitProvider = FutureProvider<void>((ref) async {
  final stopwatch = Stopwatch()..start();
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('🚀 [启动] 开始预加载 t=0ms');

  try {
    // 第一阶段：一次性获取 SharedPreferences 并读取所有配置
    // 优化：避免每个 Provider 独立调用 getInstance()
    final prefs = await SharedPreferences.getInstance();
    print('📦 [启动] SharedPreferences 就绪 t=${stopwatch.elapsedMilliseconds}ms');

    // 同步读取并设置所有配置项（SharedPreferences 读取是同步的）
    _loadAllPreferences(ref, prefs);
    print('📱 [启动] 基础配置完成 t=${stopwatch.elapsedMilliseconds}ms');

    // 获取 repository 和基础参数
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month, 1);
    final monthlyParams = (ledgerId: ledgerId, month: currentMonth);
    print('🗄️ [启动] Repository就绪 t=${stopwatch.elapsedMilliseconds}ms');

    // 第二阶段：并行加载首屏需要的所有数据
    final results = await Future.wait([
      // 1. 首屏交易数据（最重要）
      repo.getInitialTransactionsWithDetails(ledgerId: ledgerId, minCount: 20),
      // 2. 月度统计
      ref.read(monthlyTotalsProvider(monthlyParams).future),
      // 3. 账本统计
      ref.read(countsForLedgerProvider(ledgerId).future),
    ]);
    print('📦 [启动] 并行数据加载完成 t=${stopwatch.elapsedMilliseconds}ms');

    // 保存结果
    final initialTransactions = results[0] as List<TransactionDisplayItem>;
    final monthlyResult = results[1] as (double, double);

    ref.read(cachedInitialTransactionsProvider.notifier).state = initialTransactions;
    ref.read(lastMonthlyTotalsProvider(monthlyParams).notifier).state = monthlyResult;

    print('💳 [启动] 首屏数据: ${initialTransactions.length}条');

    // 生成待处理的周期交易（后台执行，不阻塞）
    RecurringTransactionService.generatePendingTransactionsStatic(
      repository: repo,
      verbose: false,
    ).then((_) {
      print('🔄 [后台] 周期交易生成完成');
    }).catchError((e) {
      print('❌ [后台] 周期交易生成失败: $e');
    });
  } catch (e) {
    print('❌ [启动] 预加载失败: $e');
  }

  print('🎉 [启动] 进入首页 t=${stopwatch.elapsedMilliseconds}ms');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  ref.read(appInitStateProvider.notifier).state = AppInitState.ready;
});

// 是否应该显示欢迎页面的Provider
final shouldShowWelcomeProvider = StateProvider<bool>((ref) => false);

// 初始化检查是否需要显示欢迎页面
final welcomeCheckProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final welcomeShown = prefs.getBool('welcome_shown') ?? false;
  if (!welcomeShown) {
    print('👋 首次启动，需要展示欢迎页面');
    ref.read(shouldShowWelcomeProvider.notifier).state = true;
    return true;
  }
  return false;
});

// 默认收入账户ID持久化
final defaultIncomeAccountIdProvider =
    FutureProvider.autoDispose<int?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getInt('default_income_account_id');
});

// 默认支出账户ID持久化
final defaultExpenseAccountIdProvider =
    FutureProvider.autoDispose<int?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getInt('default_expense_account_id');
});

class DefaultAccountSetter {
  Future<void> setDefaultIncomeAccountId(int? accountId) async {
    final prefs = await SharedPreferences.getInstance();
    if (accountId == null) {
      await prefs.remove('default_income_account_id');
    } else {
      await prefs.setInt('default_income_account_id', accountId);
    }
  }

  Future<void> setDefaultExpenseAccountId(int? accountId) async {
    final prefs = await SharedPreferences.getInstance();
    if (accountId == null) {
      await prefs.remove('default_expense_account_id');
    } else {
      await prefs.setInt('default_expense_account_id', accountId);
    }
  }
}

final defaultAccountSetterProvider = Provider<DefaultAccountSetter>((ref) {
  return DefaultAccountSetter();
});

// AI小助手开关状态持久化
final aiAssistantEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool(AIConstants.keyAiBillExtractionEnabled) ?? true; // 默认开启
});

class AIAssistantSetter {
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AIConstants.keyAiBillExtractionEnabled, enabled);
  }
}

final aiAssistantSetterProvider = Provider<AIAssistantSetter>((ref) {
  return AIAssistantSetter();
});

