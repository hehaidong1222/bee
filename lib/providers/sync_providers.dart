import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../cloud/sync_service.dart';
import '../cloud/transactions_sync_manager.dart';
import '../cloud/crdt/crdt_transaction_service.dart';
import '../models/ledger_display_item.dart';
import 'database_providers.dart';
import 'ui_state_providers.dart';

// 同步状态（根据 ledgerId 与刷新 tick 缓存），避免因 UI 重建重复拉取
final syncStatusProvider =
    FutureProvider.family<SyncStatus, int>((ref, ledgerId) async {
  final sync = ref.watch(syncServiceProvider);
  // 依赖 tick，使得手动刷新时重新获取；否则保持缓存
  final refreshTick = ref.watch(syncStatusRefreshProvider);
  print('🟢 [syncStatusProvider] 开始获取状态: ledgerId=$ledgerId, tick=$refreshTick');

  // 直接获取状态，不再清理缓存
  // 缓存的清理由 markLocalChanged() 统一管理
  final status = await sync.getStatus(ledgerId: ledgerId);
  print('🟢 [syncStatusProvider] 状态已获取: ledgerId=$ledgerId, diff=${status.diff}');

  // 写入最近一次成功值，供 UI 在刷新期间显示旧值，避免闪烁
  ref.read(lastSyncStatusProvider(ledgerId).notifier).state = status;
  return status;
});

// 最近一次同步状态缓存（按 ledgerId）
final lastSyncStatusProvider =
    StateProvider.family<SyncStatus?, int>((ref, ledgerId) => null);

// 自动同步开关：值与设置
final autoSyncValueProvider = FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('auto_sync') ?? false;
});

class AutoSyncSetter {
  AutoSyncSetter(this._ref);
  final Ref _ref;
  Future<void> set(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync', v);
    // 使缓存失效，触发读取最新值
    _ref.invalidate(autoSyncValueProvider);
  }
}

final autoSyncSetterProvider = Provider<AutoSyncSetter>((ref) {
  return AutoSyncSetter(ref);
});

// ====== 云服务配置 ======

final cloudServiceStoreProvider =
    Provider<CloudServiceStore>((_) => CloudServiceStore());

// 当前激活配置（Future，因需读 SharedPreferences）
final activeCloudConfigProvider =
    FutureProvider<CloudServiceConfig>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadActive();
});

// Supabase配置(不管是否激活)
final supabaseConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadSupabase();
});

// WebDAV配置(不管是否激活)
final webdavConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadWebdav();
});

final authServiceProvider = FutureProvider<CloudAuthService>((ref) async {
  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) {
    return NoopAuthService();
  }

  final config = activeAsync.value!;
  if (!config.valid || config.type == CloudBackendType.local) {
    return NoopAuthService();
  }

  try {
    final services = await createCloudServices(config);
    if (services.auth != null) {
      return services.auth!;
    }
  } catch (e) {
    // 初始化失败，返回 NoopAuthService
  }

  return NoopAuthService();
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) return LocalOnlySyncService();

  final config = activeAsync.value!;
  if (!config.valid) return LocalOnlySyncService();

  final db = ref.watch(databaseProvider);
  final repo = ref.watch(repositoryProvider);

  switch (config.type) {
    case CloudBackendType.local:
      return LocalOnlySyncService();

    case CloudBackendType.supabase:
    case CloudBackendType.webdav:
      // 使用新的 TransactionsSyncManager (基于 flutter_cloud_sync 包)
      // 采用延迟初始化，首次使用时自动初始化
      return TransactionsSyncManager(
        config: config,
        db: db,
        repo: repo,
      );
  }
});

// 用于触发设置页同步状态的刷新（每次 +1 即可触发 FutureBuilder 重新获取）
final syncStatusRefreshProvider = StateProvider<int>((ref) => 0);

// ====== 账本同步相关 ======

/// 刷新账本列表的触发器
final ledgerListRefreshProvider = StateProvider<int>((ref) => 0);

/// 当前正在上传的账本ID集合
final uploadingLedgerIdsProvider = StateProvider<Set<int>>((ref) => {});

/// 本地账本列表（快速，仅本地）
final localLedgersProvider = FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器
  ref.watch(ledgerListRefreshProvider);

  // 使用 syncServiceProvider，TransactionsSyncManager 现在包含账本管理功能
  final syncService = ref.watch(syncServiceProvider);

  // 获取账户功能开启状态
  final accountFeatureEnabled = await ref.watch(accountFeatureEnabledProvider.future);

  // syncServiceProvider 是同步的，直接使用
  if (syncService is TransactionsSyncManager) {
    return syncService.getLocalLedgers(accountFeatureEnabled: accountFeatureEnabled);
  }

  // 如果是 LocalOnlySyncService，只返回本地账本
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(repositoryProvider);
  final localLedgers = await db.select(db.ledgers).get();

  final result = <LedgerDisplayItem>[];
  for (final ledger in localLedgers) {
    // 使用 getLedgerStats 一次性获取余额和交易数，内部会自动查询 transactions
    final stats = await repo.getLedgerStats(
      ledgerId: ledger.id,
      accountFeatureEnabled: accountFeatureEnabled,
    );

    result.add(LedgerDisplayItem.fromLocal(
      id: ledger.id,
      name: ledger.name,
      currency: ledger.currency,
      createdAt: ledger.createdAt,
      transactionCount: stats.transactionCount,
      balance: stats.balance,
    ));
  }

  return result;
});

/// 远程账本列表（慢速，网络请求）
final remoteLedgersProvider = FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器
  ref.watch(ledgerListRefreshProvider);

  // 使用 syncServiceProvider
  final syncService = ref.watch(syncServiceProvider);

  // 只有 TransactionsSyncManager 才有远程账本
  if (syncService is TransactionsSyncManager) {
    return syncService.getRemoteLedgers();
  }

  // LocalOnlySyncService 没有远程账本
  return [];
});

/// 账本列表（带刷新支持）- 兼容旧代码
final allLedgersProvider = FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器
  ref.watch(ledgerListRefreshProvider);

  // 使用 syncServiceProvider，TransactionsSyncManager 现在包含账本管理功能
  final syncService = ref.watch(syncServiceProvider);

  // syncServiceProvider 是同步的，直接使用
  if (syncService is TransactionsSyncManager) {
    return syncService.getAllLedgers();
  }

  // 如果是 LocalOnlySyncService，只返回本地账本
  final db = ref.watch(databaseProvider);
  final localLedgers = await db.select(db.ledgers).get();

  final result = <LedgerDisplayItem>[];
  for (final ledger in localLedgers) {
    // 获取账单数据
    final transactions = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledger.id)))
        .get();

    // 计算账单数量和余额
    final count = transactions.length;
    double balance = 0.0;

    for (final t in transactions) {
      if (t.type == 'income') {
        balance += t.amount;
      } else if (t.type == 'expense') {
        balance -= t.amount;
      }
    }

    result.add(LedgerDisplayItem.fromLocal(
      id: ledger.id,
      name: ledger.name,
      currency: ledger.currency,
      createdAt: ledger.createdAt,
      transactionCount: count,
      balance: balance,
    ));
  }

  return result;
});

// ====== CRDT 多设备同步相关 ======

/// 多设备同步开关
final multiDeviceSyncEnabledProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('multi_device_sync_enabled') ?? false;
});

/// 多设备同步开关设置器
class MultiDeviceSyncSetter {
  MultiDeviceSyncSetter(this._ref);
  final Ref _ref;

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('multi_device_sync_enabled', enabled);
    _ref.invalidate(multiDeviceSyncEnabledProvider);
  }
}

final multiDeviceSyncSetterProvider = Provider<MultiDeviceSyncSetter>((ref) {
  return MultiDeviceSyncSetter(ref);
});

/// 设备 ID Provider
final deviceIdProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  var deviceId = prefs.getString('crdt_device_id');

  if (deviceId == null) {
    // 生成新的设备 ID
    deviceId = _generateDeviceId();
    await prefs.setString('crdt_device_id', deviceId);
  }

  return deviceId;
});

String _generateDeviceId() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final random = now % 1000000;
  return 'device_${now}_$random';
}

/// CRDT 交易服务 Provider
final crdtTransactionServiceProvider = FutureProvider<CRDTTransactionService?>((ref) async {
  // 检查是否启用云服务
  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) return null;

  final config = activeAsync.value!;
  if (!config.valid || config.type == CloudBackendType.local) return null;

  // 创建服务实例
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(repositoryProvider);

  final service = await CRDTTransactionService.create(db: db, repo: repo);

  // 监听多设备同步开关变化
  final multiDeviceEnabled = await ref.watch(multiDeviceSyncEnabledProvider.future);
  service.setMultiDeviceSyncEnabled(multiDeviceEnabled);

  return service;
});

// ====== CRDT 同步状态 ======

/// CRDT 同步状态模型
class CRDTSyncStatus {
  final int unsyncedCount;
  final DateTime? lastSyncAt;
  final bool isSyncing;
  final String? error;

  const CRDTSyncStatus({
    this.unsyncedCount = 0,
    this.lastSyncAt,
    this.isSyncing = false,
    this.error,
  });

  CRDTSyncStatus copyWith({
    int? unsyncedCount,
    DateTime? lastSyncAt,
    bool? isSyncing,
    String? error,
  }) {
    return CRDTSyncStatus(
      unsyncedCount: unsyncedCount ?? this.unsyncedCount,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
    );
  }
}

/// CRDT 同步状态 Provider
final crdtSyncStatusProvider = StateProvider.family<CRDTSyncStatus, int>(
  (ref, ledgerId) => const CRDTSyncStatus(),
);

/// CRDT 同步状态刷新触发器
final crdtSyncRefreshProvider = StateProvider<int>((ref) => 0);

/// 获取未同步的操作数量
final unsyncedOperationsCountProvider = FutureProvider.family<int, int>((ref, ledgerId) async {
  ref.watch(crdtSyncRefreshProvider);
  final db = ref.watch(databaseProvider);
  return await db.getUnsyncedOperationsCount(ledgerId);
});
