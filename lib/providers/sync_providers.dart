import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../cloud/sync_service.dart';
import '../cloud/transactions_sync_manager.dart';
import '../models/ledger_display_item.dart';
import '../services/system/logger_service.dart';
import 'database_providers.dart';
import 'ui_state_providers.dart';
import 'statistics_providers.dart';

String normalizeCollabRole(String? role) {
  final normalized = (role ?? '').trim().toLowerCase();
  if (normalized == 'owner' ||
      normalized == 'editor' ||
      normalized == 'viewer') {
    return normalized;
  }
  return '';
}

enum LedgerCollabCapabilityStatus {
  notApplicable,
  resolved,
  scopeDenied,
  unavailable,
}

class LedgerCollabCapability {
  const LedgerCollabCapability({
    required this.status,
    required this.role,
    this.detail,
  });

  final LedgerCollabCapabilityStatus status;
  final String? role;
  final String? detail;

  bool get roleResolved => normalizeCollabRole(role).isNotEmpty;
  bool get scopeDenied => status == LedgerCollabCapabilityStatus.scopeDenied;
}

class LedgerCollabPermission {
  const LedgerCollabPermission({
    required this.role,
    required this.roleResolved,
    required this.isSharedLedger,
    required this.canWrite,
    required this.canManage,
    required this.canLeave,
  });

  final String? role;
  final bool roleResolved;
  final bool isSharedLedger;
  final bool canWrite;
  final bool canManage;
  final bool canLeave;

  static const personal = LedgerCollabPermission(
    role: null,
    roleResolved: true,
    isSharedLedger: false,
    canWrite: true,
    canManage: true,
    canLeave: false,
  );

  static const unresolved = LedgerCollabPermission(
    role: null,
    roleResolved: false,
    isSharedLedger: true,
    canWrite: false,
    canManage: false,
    canLeave: false,
  );

  factory LedgerCollabPermission.fromRole(String? role) {
    final normalized = normalizeCollabRole(role);
    switch (normalized) {
      case 'owner':
        return const LedgerCollabPermission(
          role: 'owner',
          roleResolved: true,
          isSharedLedger: true,
          canWrite: true,
          canManage: true,
          canLeave: false,
        );
      case 'editor':
        return const LedgerCollabPermission(
          role: 'editor',
          roleResolved: true,
          isSharedLedger: true,
          canWrite: true,
          canManage: false,
          canLeave: true,
        );
      case 'viewer':
        return const LedgerCollabPermission(
          role: 'viewer',
          roleResolved: true,
          isSharedLedger: true,
          canWrite: false,
          canManage: false,
          canLeave: true,
        );
      default:
        return unresolved;
    }
  }
}

class LedgerCollabMemberSummary {
  const LedgerCollabMemberSummary({
    required this.userId,
    this.email,
    this.displayName,
    this.avatarUrl,
    this.avatarVersion,
    this.role,
    this.status,
    this.joinedAt,
  });

  final String userId;
  final String? email;
  final String? displayName;
  final String? avatarUrl;
  final int? avatarVersion;
  final String? role;
  final String? status;
  final DateTime? joinedAt;

  String get resolvedDisplayName {
    final display = (displayName ?? '').trim();
    if (display.isNotEmpty) {
      return display;
    }
    final mail = (email ?? '').trim();
    if (mail.isNotEmpty) {
      return mail;
    }
    final uid = userId.trim();
    if (uid.length <= 8) {
      return uid;
    }
    return uid.substring(0, 8);
  }
}

// 同步状态（根据 ledgerId 与刷新 tick 缓存），避免因 UI 重建重复拉取
final syncStatusProvider =
    FutureProvider.family<SyncStatus, int>((ref, ledgerId) async {
  final sync = ref.watch(syncServiceProvider);
  // 依赖 tick，使得手动刷新时重新获取；否则保持缓存
  ref.watch(syncStatusRefreshProvider);
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));

  // 直接获取状态，不再清理缓存
  // 缓存的清理由 markLocalChanged() 统一管理
  final status = await sync.getStatus(ledgerId: ledgerId);

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

// BeeCount Cloud 配置(不管是否激活)
final beecountCloudConfigProvider =
    FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadBeeCountCloud();
});

// WebDAV配置(不管是否激活)
final webdavConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadWebdav();
});

// S3配置(不管是否激活)
final s3ConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadS3();
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

    case CloudBackendType.beecountCloud:
    case CloudBackendType.supabase:
    case CloudBackendType.webdav:
    case CloudBackendType.icloud:
    case CloudBackendType.s3:
      // 使用新的 TransactionsSyncManager (基于 flutter_cloud_sync 包)
      // 采用延迟初始化，首次使用时自动初始化
      final manager = TransactionsSyncManager(
        config: config,
        db: db,
        repo: repo,
        onRemoteChangeApplied: (affectedLedgerIds) {
          // 远端变更只按账本粒度刷新，避免触发全局 loading 闪烁
          for (final ledgerId in affectedLedgerIds) {
            ref
                .read(syncStatusRefreshByLedgerProvider(ledgerId).notifier)
                .state++;
            ref
                .read(ledgerDataRefreshByLedgerProvider(ledgerId).notifier)
                .state++;
          }
        },
        onRemoteApplyStateChanged: (ledgerId, inProgress) {
          ref
              .read(remoteApplyInProgressByLedgerProvider(ledgerId).notifier)
              .state = inProgress;
        },
      );
      ref.onDispose(() {
        unawaited(manager.dispose());
      });
      return manager;
  }
});

// 用于触发设置页同步状态的刷新（每次 +1 即可触发 FutureBuilder 重新获取）
final syncStatusRefreshProvider = StateProvider<int>((ref) => 0);

/// 按账本触发同步状态刷新（用于远端增量拉取后的局部刷新）
final syncStatusRefreshByLedgerProvider =
    StateProvider.family<int, int>((ref, _) => 0);

/// 按账本触发页面数据刷新（减少全局刷新带来的闪烁）
final ledgerDataRefreshByLedgerProvider =
    StateProvider.family<int, int>((ref, _) => 0);

/// 按账本记录“远端变更应用中”状态，用于页面局部防闪渲染
final remoteApplyInProgressByLedgerProvider =
    StateProvider.family<bool, int>((ref, _) => false);

/// 当前账本协作能力状态（resolved / scopeDenied / unavailable）
final ledgerCollabCapabilityProvider =
    FutureProvider.family<LedgerCollabCapability, int>((ref, ledgerId) async {
  ref.watch(syncStatusRefreshProvider);
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));

  final db = ref.watch(databaseProvider);
  final ledgerTypeRow = await db.customSelect(
    '''
    SELECT type
    FROM ledgers
    WHERE id = ?
    LIMIT 1
    ''',
    variables: [
      Variable.withInt(ledgerId),
    ],
  ).getSingleOrNull();
  final ledgerType =
      (ledgerTypeRow?.data['type']?.toString() ?? '').trim().toLowerCase();
  if (ledgerType != 'shared') {
    return const LedgerCollabCapability(
      status: LedgerCollabCapabilityStatus.notApplicable,
      role: null,
      detail: 'ledger_not_shared',
    );
  }

  final config = await ref.watch(activeCloudConfigProvider.future);
  if (!config.valid || config.type != CloudBackendType.beecountCloud) {
    return const LedgerCollabCapability(
      status: LedgerCollabCapabilityStatus.unavailable,
      role: null,
      detail: 'backend_not_beecount_cloud',
    );
  }
  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) {
    return const LedgerCollabCapability(
      status: LedgerCollabCapabilityStatus.unavailable,
      role: null,
      detail: 'sync_service_unavailable',
    );
  }
  final result = await sync.resolveLedgerRole(ledgerId: ledgerId);
  switch (result.status) {
    case LedgerRoleResolveStatus.resolved:
      return LedgerCollabCapability(
        status: LedgerCollabCapabilityStatus.resolved,
        role: result.role,
      );
    case LedgerRoleResolveStatus.scopeDenied:
      return LedgerCollabCapability(
        status: LedgerCollabCapabilityStatus.scopeDenied,
        role: null,
        detail: result.detail,
      );
    case LedgerRoleResolveStatus.unavailable:
      return LedgerCollabCapability(
        status: LedgerCollabCapabilityStatus.unavailable,
        role: null,
        detail: result.detail,
      );
  }
});

/// 当前账本协作角色（仅 BeeCount Cloud 协作模式）
final ledgerCollabRoleProvider =
    FutureProvider.family<String?, int>((ref, ledgerId) async {
  final capability =
      await ref.watch(ledgerCollabCapabilityProvider(ledgerId).future);
  if (!capability.roleResolved) {
    return null;
  }
  final normalized = normalizeCollabRole(capability.role);
  if (normalized.isEmpty) {
    return null;
  }
  return normalized;
});

/// 当前账本协作权限（供 Mine/账本卡/共享页复用）
final ledgerCollabPermissionProvider =
    FutureProvider.family<LedgerCollabPermission, int>((ref, ledgerId) async {
  final config = await ref.watch(activeCloudConfigProvider.future);
  if (!config.valid || config.type != CloudBackendType.beecountCloud) {
    return LedgerCollabPermission.personal;
  }
  final capability =
      await ref.watch(ledgerCollabCapabilityProvider(ledgerId).future);
  if (capability.status == LedgerCollabCapabilityStatus.notApplicable) {
    return LedgerCollabPermission.personal;
  }
  if (!capability.roleResolved) {
    return LedgerCollabPermission.unresolved;
  }
  final role = normalizeCollabRole(capability.role);
  return LedgerCollabPermission.fromRole(role);
});

/// 待重试的头像上传本地路径（仅 BeeCount Cloud 协作模式使用）
final pendingAvatarUploadPathProvider = StateProvider<String?>((ref) => null);

/// 最近一次头像上传失败信息（用于云同步页提示）
final pendingAvatarUploadErrorProvider = StateProvider<String?>((ref) => null);

/// 当前用户云端资料（用于头像跨端显示回退）
final cloudMyProfileProvider =
    FutureProvider<BeeCountCloudProfile?>((ref) async {
  ref.watch(syncStatusRefreshProvider);
  final config = await ref.watch(activeCloudConfigProvider.future);
  if (!config.valid || config.type != CloudBackendType.beecountCloud) {
    return null;
  }
  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) {
    return null;
  }
  try {
    return await sync.getMyProfile();
  } catch (_) {
    return null;
  }
});

/// 当前账本本地协作队列摘要（待上传/失败）
final ledgerSyncQueueSummaryProvider =
    FutureProvider.family<LocalSyncQueueSummary, int>((ref, ledgerId) async {
  ref.watch(syncStatusRefreshProvider);
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));

  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) {
    return const LocalSyncQueueSummary.empty();
  }
  return sync.getLocalQueueSummary(ledgerId: ledgerId);
});

/// 当前账本共享成员摘要（用于账本卡、成员页、交易创建者显示）
final ledgerCollabMembersProvider =
    FutureProvider.family<List<LedgerCollabMemberSummary>, int>(
        (ref, ledgerId) async {
  ref.watch(syncStatusRefreshProvider);
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));
  ref.watch(ledgerDataRefreshByLedgerProvider(ledgerId));

  final config = await ref.watch(activeCloudConfigProvider.future);
  if (!config.valid || config.type != CloudBackendType.beecountCloud) {
    return const [];
  }
  final db = ref.watch(databaseProvider);
  final ledgerTypeRow = await db.customSelect(
    '''
    SELECT type
    FROM ledgers
    WHERE id = ?
    LIMIT 1
    ''',
    variables: [
      Variable.withInt(ledgerId),
    ],
  ).getSingleOrNull();
  final ledgerType =
      (ledgerTypeRow?.data['type']?.toString() ?? '').trim().toLowerCase();
  if (ledgerType != 'shared') {
    return const [];
  }

  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) {
    return const [];
  }

  try {
    final members = await sync.listShareMembers(ledgerId: ledgerId);
    final auth = await ref.watch(authServiceProvider.future);
    final currentUser = await auth.currentUser;
    final currentUserId = (currentUser?.id ?? '').trim();
    final myProfile = currentUserId.isEmpty
        ? null
        : await ref.watch(cloudMyProfileProvider.future);
    return members.map((member) {
      final userId = member.userId.trim();
      final isCurrentUser = currentUserId.isNotEmpty && userId == currentUserId;
      final fallbackAvatarUrl = isCurrentUser
          ? (myProfile?.avatarUrl?.trim().isNotEmpty == true
              ? myProfile!.avatarUrl
              : null)
          : null;
      final fallbackAvatarVersion =
          isCurrentUser ? myProfile?.avatarVersion : null;
      final fallbackDisplayName = isCurrentUser
          ? (myProfile?.displayName?.trim().isNotEmpty == true
              ? myProfile!.displayName
              : null)
          : null;
      return LedgerCollabMemberSummary(
        userId: member.userId,
        email: member.userEmail,
        displayName: member.userDisplayName ?? fallbackDisplayName,
        avatarUrl: member.userAvatarUrl ?? fallbackAvatarUrl,
        avatarVersion: member.userAvatarVersion ?? fallbackAvatarVersion,
        role: member.role,
        status: member.status,
        joinedAt: member.joinedAt,
      );
    }).toList(growable: false);
  } catch (_) {
    return const [];
  }
});

final ledgerCollabMemberMapProvider =
    FutureProvider.family<Map<String, LedgerCollabMemberSummary>, int>(
        (ref, ledgerId) async {
  final members = await ref.watch(ledgerCollabMembersProvider(ledgerId).future);
  final map = <String, LedgerCollabMemberSummary>{};
  for (final member in members) {
    final key = member.userId.trim();
    if (key.isEmpty) {
      continue;
    }
    map[key] = member;
  }
  return map;
});

/// 当前账本交易创建者映射（transaction_id -> created_by_user_id）
final ledgerTransactionCreatorMapProvider =
    FutureProvider.family<Map<int, String>, int>((ref, ledgerId) async {
  ref.watch(syncStatusRefreshProvider);
  ref.watch(ledgerDataRefreshByLedgerProvider(ledgerId));
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));
  ref.watch(statsRefreshProvider);

  final db = ref.watch(databaseProvider);
  final rows = await db.customSelect(
    '''
    SELECT id, created_by_user_id
    FROM transactions
    WHERE ledger_id = ?
    ''',
    variables: [
      Variable.withInt(ledgerId),
    ],
  ).get();
  final result = <int, String>{};
  for (final row in rows) {
    final txId = (row.data['id'] as num?)?.toInt();
    if (txId == null) {
      continue;
    }
    final userId = (row.data['created_by_user_id']?.toString() ?? '').trim();
    if (userId.isEmpty) {
      continue;
    }
    result[txId] = userId;
  }
  return result;
});

// ====== 账本同步相关 ======

/// 刷新账本列表的触发器
final ledgerListRefreshProvider = StateProvider<int>((ref) => 0);

/// 当前正在上传的账本ID集合
final uploadingLedgerIdsProvider = StateProvider<Set<int>>((ref) => {});

/// 本地账本列表（快速，仅本地）
final localLedgersProvider =
    FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器（账本列表和统计信息）
  ref.watch(ledgerListRefreshProvider);
  ref.watch(statsRefreshProvider); // 监听统计刷新，确保自动记账后刷新

  try {
    // 使用 syncServiceProvider，TransactionsSyncManager 现在包含账本管理功能
    final syncService = ref.watch(syncServiceProvider);

    // 获取账户功能开启状态
    final accountFeatureEnabled =
        await ref.watch(accountFeatureEnabledProvider.future);

    // syncServiceProvider 是同步的，直接使用
    if (syncService is TransactionsSyncManager) {
      return syncService.getLocalLedgers(
          accountFeatureEnabled: accountFeatureEnabled);
    }

    // 如果是 LocalOnlySyncService，只返回本地账本
    final repo = ref.watch(repositoryProvider);

    final localLedgers = await repo.getAllLedgers();

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
        ledgerType: ledger.type,
      ));
    }

    return result;
  } catch (e, stackTrace) {
    logger.error('LocalLedgers', '获取本地账本列表失败', e, stackTrace);
    return [];
  }
});

/// 远程账本列表（慢速，网络请求）
final remoteLedgersProvider =
    FutureProvider<List<LedgerDisplayItem>>((ref) async {
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

  try {
    // 使用 syncServiceProvider，TransactionsSyncManager 现在包含账本管理功能
    final syncService = ref.watch(syncServiceProvider);

    // syncServiceProvider 是同步的，直接使用
    if (syncService is TransactionsSyncManager) {
      return syncService.getAllLedgers();
    }

    // 如果是 LocalOnlySyncService，只返回本地账本
    final repo = ref.watch(repositoryProvider);

    final localLedgers = await repo.getAllLedgers();

    final result = <LedgerDisplayItem>[];
    for (final ledger in localLedgers) {
      // 使用 Repository 的 getLedgerStats 方法获取统计数据
      final stats = await repo.getLedgerStats(
        ledgerId: ledger.id,
        accountFeatureEnabled: false, // 这里使用默认值，实际应该从provider读取
      );

      result.add(LedgerDisplayItem.fromLocal(
        id: ledger.id,
        name: ledger.name,
        currency: ledger.currency,
        createdAt: ledger.createdAt,
        transactionCount: stats.transactionCount,
        balance: stats.balance,
        ledgerType: ledger.type,
      ));
    }

    return result;
  } catch (e, stackTrace) {
    logger.error('AllLedgers', '获取账本列表失败', e, stackTrace);
    return [];
  }
});
