import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../data/repositories/local/local_mutation_event.dart';
import '../data/repositories/local/local_repository.dart';
import '../models/ledger_display_item.dart';
import '../services/custom_icon_service.dart';
import '../services/system/logger_service.dart';
import 'sync_service.dart';
import 'transactions_json.dart';

enum LedgerRoleResolveStatus {
  resolved,
  scopeDenied,
  unavailable,
}

class LedgerRoleResolveResult {
  const LedgerRoleResolveResult._({
    required this.status,
    this.role,
    this.detail,
  });

  const LedgerRoleResolveResult.resolved(String role)
      : this._(status: LedgerRoleResolveStatus.resolved, role: role);

  const LedgerRoleResolveResult.scopeDenied({String? detail})
      : this._(status: LedgerRoleResolveStatus.scopeDenied, detail: detail);

  const LedgerRoleResolveResult.unavailable({String? detail})
      : this._(status: LedgerRoleResolveStatus.unavailable, detail: detail);

  final LedgerRoleResolveStatus status;
  final String? role;
  final String? detail;

  bool get roleResolved =>
      status == LedgerRoleResolveStatus.resolved &&
      role != null &&
      role!.isNotEmpty;
}

class LocalSyncQueueSummary {
  const LocalSyncQueueSummary({
    required this.pending,
    required this.failed,
    this.lastError,
  });

  const LocalSyncQueueSummary.empty()
      : pending = 0,
        failed = 0,
        lastError = null;

  final int pending;
  final int failed;
  final String? lastError;
}

/// 账本交易的云同步管理器
///
/// 使用 flutter_cloud_sync 包实现云同步，保留 BeeCount 特定的业务逻辑
class TransactionsSyncManager implements SyncService {
  final fcs.CloudServiceConfig config;
  final BeeDatabase db;
  final BaseRepository repo;
  final void Function(Set<int> affectedLedgerIds)? onRemoteChangeApplied;
  final void Function(int ledgerId, bool inProgress)? onRemoteApplyStateChanged;

  fcs.CloudSyncManager<int>? _syncManager;
  fcs.CloudProvider? _provider;
  bool _isInitializing = false;
  bool _isInitialized = false;

  final Map<int, SyncStatus> _statusCache = {};
  final Map<int, DateTime> _recentLocalChangeAt = {};
  final Map<int, _RecentUpload> _recentUpload = {};
  final Map<int, String> _ledgerSyncIdCache = {};
  final Map<String, String> _ledgerRoleCache = {};
  final Map<int, String> _ledgerRoleCacheByLocalId = {};
  final Map<int, String> _remoteLedgerDisplayIdToSyncId = {};
  final Set<String> _knownRemoteLedgerSyncIds = <String>{};
  bool _ledgerSyncIdRepairDone = false;
  bool _ledgerSyncIdRepairInProgress = false;
  String? _ledgerSyncIdRepairUserId;
  StreamSubscription<LocalMutationEvent>? _localMutationSubscription;
  StreamSubscription<fcs.BeeCountCloudRealtimeEvent>? _realtimeSubscription;
  Timer? _pollTimer;
  bool _isPullingFromCloud = false;
  bool _hasPendingPull = false;
  int? _pendingTargetCursor;
  String _pendingPullReason = 'manual';
  bool _isPushingToCloud = false;
  bool _hasPendingPush = false;
  String _pendingPushReason = 'manual';
  DateTime? _lastPollAt;

  TransactionsSyncManager({
    required this.config,
    required this.db,
    required this.repo,
    this.onRemoteChangeApplied,
    this.onRemoteApplyStateChanged,
  });

  bool _isNotAuthenticatedError(Object error) {
    if (error is fcs.CloudNotAuthenticatedException) {
      return true;
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('not authenticated') ||
        lower.contains('unauthorized') ||
        lower.contains('session expired') ||
        lower.contains('invalid token');
  }

  /// 确保服务已初始化（延迟初始化）
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    if (_isInitializing) {
      // 等待初始化完成
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _isInitializing = true;
    try {
      await _initialize();
      _isInitialized = true;
    } finally {
      _isInitializing = false;
    }
  }

  /// 初始化 CloudProvider 和 SyncManager
  Future<void> _initialize() async {
    final services = await fcs.createCloudServices(config);
    _provider = services.provider;

    if (_provider == null) {
      // Provider 创建失败（如 iCloud 未登录），标记为已初始化但无法使用
      logger.warning('CloudSync', 'Provider not available for ${config.type}');
      return;
    }

    _syncManager = fcs.CloudSyncManager<int>(
      provider: _provider!,
      serializer: _TransactionSerializer(db),
      logger: fcs.CloudSyncLogger(onLog: (level, message) {
        switch (level) {
          case fcs.LogLevel.debug:
            logger.info('CloudSync', message);
            break;
          case fcs.LogLevel.info:
            logger.info('CloudSync', message);
            break;
          case fcs.LogLevel.warning:
            logger.warning('CloudSync', message);
            break;
          case fcs.LogLevel.error:
            logger.error('CloudSync', message);
            break;
        }
      }),
    );

    _startBeeCountCloudAutoSync();
    _bindLocalMutationEvents();
  }

  Future<String> _pathForLedger(int ledgerId) async {
    final cached = _ledgerSyncIdCache[ledgerId];
    if (cached != null &&
        cached.isNotEmpty &&
        !_isLegacySnapshotLedgerSyncId(cached)) {
      return cached;
    }
    if (config.type == fcs.CloudBackendType.beecountCloud) {
      final collabSyncId = await _collabLedgerSyncIdOrNull(ledgerId);
      if (collabSyncId != null &&
          collabSyncId.isNotEmpty &&
          !_isLegacySnapshotLedgerSyncId(collabSyncId)) {
        _ledgerSyncIdCache[ledgerId] = collabSyncId;
        return collabSyncId;
      }
    }
    try {
      final row = await db.customSelect(
        'SELECT sync_id, type FROM ledgers WHERE id = ? LIMIT 1',
        variables: [drift.Variable.withInt(ledgerId)],
      ).getSingleOrNull();
      final raw = row?.data['sync_id']?.toString().trim() ?? '';
      if (raw.isNotEmpty) {
        _ledgerSyncIdCache[ledgerId] = raw;
        return raw;
      }
      final ledgerType =
          (row?.data['type']?.toString() ?? '').trim().toLowerCase();
      if (config.type == fcs.CloudBackendType.beecountCloud &&
          ledgerType == 'personal') {
        final currentUserId = await _currentBeeCountCloudUserId();
        if (currentUserId != null && currentUserId.isNotEmpty) {
          final namespacedSyncId = _buildNamespacedPersonalLedgerSyncId(
            ledgerId: ledgerId,
            userId: currentUserId,
          );
          await db.customStatement(
            '''
            UPDATE ledgers
            SET sync_id = ?
            WHERE id = ? AND (sync_id IS NULL OR TRIM(sync_id) = '')
            ''',
            [namespacedSyncId, ledgerId],
          );
          _ledgerSyncIdCache[ledgerId] = namespacedSyncId;
          return namespacedSyncId;
        }
      }
    } catch (_) {
      // Keep fallback for legacy data where sync_id is absent.
    }
    final fallback = 'ledger_$ledgerId.json';
    _ledgerSyncIdCache[ledgerId] = fallback;
    return fallback;
  }

  bool _isLegacySnapshotLedgerSyncId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return RegExp(r'^ledger_\d+\.json$').hasMatch(normalized);
  }

  bool _isNamespacedPersonalLedgerSyncId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return RegExp(r'^local_[A-Za-z0-9_-]+_ledger_\d+\.json$')
        .hasMatch(normalized);
  }

  Future<String?> _collabLedgerSyncIdOrNull(int ledgerId) async {
    if (config.type == fcs.CloudBackendType.beecountCloud) {
      await _runOneTimeLedgerSyncIdRepair();
    }
    final cached = _ledgerSyncIdCache[ledgerId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final row = await db.customSelect(
        '''
        SELECT sync_id, type
        FROM ledgers
        WHERE id = ?
        LIMIT 1
        ''',
        variables: [drift.Variable.withInt(ledgerId)],
      ).getSingleOrNull();
      final raw = row?.data['sync_id']?.toString().trim() ?? '';
      final ledgerType = (row?.data['type']?.toString() ?? '').trim();
      if (raw.isNotEmpty && !_isLegacySnapshotLedgerSyncId(raw)) {
        _ledgerSyncIdCache[ledgerId] = raw;
        return raw;
      }

      if (ledgerType.toLowerCase() != 'shared') {
        if (raw.isNotEmpty) {
          _ledgerSyncIdCache[ledgerId] = raw;
          return raw;
        }
        return null;
      }

      if (raw.isNotEmpty) {
        if (config.type == fcs.CloudBackendType.beecountCloud &&
            _isLegacySnapshotLedgerSyncId(raw) &&
            _knownRemoteLedgerSyncIds.isNotEmpty &&
            !_knownRemoteLedgerSyncIds.contains(raw)) {
          logger.warning(
            'CloudSync',
            '共享账本 sync_id 与云端账本身份不一致，已阻止 legacy 回落: ledgerId=$ledgerId, syncId=$raw',
          );
          return null;
        }
        // Keep using the current sync_id even if it matches legacy naming.
        // Some self-hosted instances may still use this external id format.
        _ledgerSyncIdCache[ledgerId] = raw;
        return raw;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  void _startBeeCountCloudAutoSync() {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return;
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return;
    }
    if (_realtimeSubscription != null || _pollTimer != null) {
      return;
    }

    unawaited(provider.startRealtime());
    _realtimeSubscription = provider.realtimeEvents.listen((event) {
      if (event.type == 'sync_change' || event.type == 'backup_restore') {
        _queueIncrementalPull(
          reason: 'realtime:${event.type}',
          targetCursor: event.serverCursor,
        );
      }
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _queueIncrementalPull(reason: 'poll', isPoll: true);
    });

    unawaited(_runOneTimeLedgerSyncIdRepair());
    _queueIncrementalPull(reason: 'bootstrap');
  }

  void _bindLocalMutationEvents() {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return;
    }
    if (repo is! LocalRepository) {
      return;
    }
    if (_localMutationSubscription != null) {
      return;
    }
    final localRepo = repo as LocalRepository;
    _localMutationSubscription = localRepo.mutationEvents.listen((event) {
      unawaited(() async {
        await _enqueueLocalMutationEvent(event);
        _queuePush(
            reason: 'local:${event.entityType.name}.${event.action.name}');
      }());
    });
    _queuePush(reason: 'bootstrap');
  }

  void _queuePush({required String reason}) {
    _hasPendingPush = true;
    _pendingPushReason = reason;
    if (_isPushingToCloud) {
      return;
    }
    unawaited(_drainPushQueue());
  }

  Future<void> _drainPushQueue() async {
    if (_isPushingToCloud) return;
    _isPushingToCloud = true;
    try {
      while (_hasPendingPush) {
        final reason = _pendingPushReason;
        _hasPendingPush = false;
        await _pushPendingMutations(reason: reason);
      }
    } finally {
      _isPushingToCloud = false;
    }
  }

  Future<void> _pushPendingMutations({required String reason}) async {
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return;
    }
    try {
      await _runOneTimeLedgerSyncIdRepair();
      await _normalizePendingQueueLedgerSyncIds();
      var rounds = 0;
      while (rounds < 5) {
        final items = await _loadPendingQueueItems(limit: 40);
        if (items.isEmpty) {
          break;
        }
        rounds++;
        for (final item in items) {
          try {
            final commit = await _dispatchQueuedMutation(
              provider: provider,
              item: item,
            );
            await _markQueueDone(item.id);
            if (commit != null) {
              await _markPushState(
                ledgerSyncId: item.ledgerSyncId,
                lastChangeId: commit.newChangeId,
              );
              await _applyCommitEntitySyncId(item: item, commit: commit);
            }
          } catch (e, stackTrace) {
            final error = e.toString();
            logger.warning(
              'CloudSync',
              '协作写入失败(${item.entityType}/${item.action}): $error; queueId=${item.id}, ledgerSyncId=${item.ledgerSyncId}, entitySyncId=${item.entitySyncId}, localEntityId=${item.payloadJson['local_entity_id']}',
            );
            logger.debug('CloudSync', '协作写入堆栈: $stackTrace');
            final isConflict =
                error.contains('HTTP 409') || error.contains('Write conflict');
            final isNotFound = error.contains('HTTP 404') ||
                error.contains('Entity not found');
            if (isNotFound) {
              final recovered = await _recoverNotFoundMutation(
                provider: provider,
                item: item,
              );
              if (recovered) {
                continue;
              }
            }
            final keepPending = !isNotFound && item.attemptCount + 1 < 8;
            await _markQueueAttempt(
              item.id,
              error: error,
              keepPending: keepPending,
            );
            if (isConflict) {
              _queueIncrementalPull(reason: 'push_conflict');
              return;
            }
            if (e is fcs.CloudNotAuthenticatedException) {
              return;
            }
          }
        }
      }
    } catch (e, stackTrace) {
      if (_isNotAuthenticatedError(e)) {
        logger.debug('CloudSync', '本地队列推送跳过（未登录）: $e');
        return;
      }
      logger.warning('CloudSync', '本地队列推送失败($reason): $e');
      logger.debug('CloudSync', '本地队列推送堆栈: $stackTrace');
    }
  }

  Future<void> _normalizePendingQueueLedgerSyncIds() async {
    final rows = await db.customSelect(
      '''
      SELECT id, ledger_sync_id
      FROM sync_queue
      WHERE source = 'local'
        AND status IN ('pending', 'failed')
      ORDER BY id ASC
      LIMIT 200
      ''',
    ).get();
    for (final row in rows) {
      final queueId = _toIntOrNull(row.data['id']);
      if (queueId == null) {
        continue;
      }
      final ledgerSyncId =
          (row.data['ledger_sync_id']?.toString() ?? '').trim();
      if (ledgerSyncId.isEmpty) {
        continue;
      }
      var localLedgerId = await _resolveLocalLedgerId(ledgerSyncId);
      String? resolved;
      if (localLedgerId == null &&
          config.type == fcs.CloudBackendType.beecountCloud &&
          _isLegacySnapshotLedgerSyncId(ledgerSyncId)) {
        final legacyLedgerId = _extractLedgerId(ledgerSyncId);
        if (legacyLedgerId != null) {
          final typeRow = await db.customSelect(
            '''
            SELECT type
            FROM ledgers
            WHERE id = ?
            LIMIT 1
            ''',
            variables: [drift.Variable.withInt(legacyLedgerId)],
          ).getSingleOrNull();
          if (typeRow != null) {
            final ledgerType =
                (typeRow.data['type']?.toString() ?? '').trim().toLowerCase();
            localLedgerId = legacyLedgerId;
            if (ledgerType == 'shared') {
              resolved = await _collabLedgerSyncIdOrNull(legacyLedgerId);
            } else {
              resolved = await _pathForLedger(legacyLedgerId);
            }
          }
        }
      }
      if (localLedgerId == null) {
        continue;
      }
      resolved ??= await _collabLedgerSyncIdOrNull(localLedgerId);
      if (resolved == null || resolved.isEmpty || resolved == ledgerSyncId) {
        continue;
      }
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET ledger_sync_id = ?
        WHERE id = ?
        ''',
        [resolved, queueId],
      );
    }
  }

  Future<List<_QueuedMutation>> _loadPendingQueueItems({
    int limit = 40,
  }) async {
    final rows = await db.customSelect(
      '''
      SELECT
        id,
        ledger_sync_id,
        entity_type,
        entity_sync_id,
        action,
        payload_json,
        base_change_id,
        request_id,
        idempotency_key,
        attempt_count
      FROM sync_queue
      WHERE status = 'pending' AND source = 'local'
      ORDER BY id ASC
      LIMIT ?
      ''',
      variables: [drift.Variable.withInt(limit)],
    ).get();

    final out = <_QueuedMutation>[];
    for (final row in rows) {
      final id = _toIntOrNull(row.data['id']);
      if (id == null) continue;
      Map<String, dynamic> payloadJson = const {};
      final rawPayload = row.data['payload_json']?.toString() ?? '';
      if (rawPayload.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawPayload);
          if (decoded is Map<String, dynamic>) {
            payloadJson = decoded;
          }
        } catch (_) {}
      }
      out.add(
        _QueuedMutation(
          id: id,
          ledgerSyncId: row.data['ledger_sync_id']?.toString() ?? '',
          entityType: row.data['entity_type']?.toString() ?? '',
          entitySyncId: row.data['entity_sync_id']?.toString() ?? '',
          action: row.data['action']?.toString() ?? '',
          payloadJson: payloadJson,
          baseChangeId: _toIntOrNull(row.data['base_change_id']),
          requestId: _nullIfBlank(row.data['request_id']?.toString()),
          idempotencyKey: _nullIfBlank(row.data['idempotency_key']?.toString()),
          attemptCount: _toIntOrNull(row.data['attempt_count']) ?? 0,
        ),
      );
    }
    return out;
  }

  Future<void> _markQueueDone(int queueId) async {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET status = 'done', last_error = NULL, updated_at = ?
      WHERE id = ?
      ''',
      [nowSec, queueId],
    );
  }

  Future<void> _markQueueAttempt(
    int queueId, {
    required String error,
    required bool keepPending,
  }) async {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET
        attempt_count = attempt_count + 1,
        last_error = ?,
        status = ?,
        updated_at = ?
      WHERE id = ?
      ''',
      [error, keepPending ? 'pending' : 'failed', nowSec, queueId],
    );
  }

  Future<void> _requeueFailedMutationsForLedger({
    required String ledgerSyncId,
  }) async {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET status = 'pending', updated_at = ?
      WHERE ledger_sync_id = ? AND source = 'local' AND status = 'failed'
      ''',
      [nowSec, ledgerSyncId],
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchQueuedMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
  }) async {
    final normalizedLedgerSyncId =
        await _resolveQueueLedgerSyncId(item.ledgerSyncId);
    if (normalizedLedgerSyncId == null ||
        normalizedLedgerSyncId.trim().isEmpty) {
      throw fcs.CloudSyncException('Ledger sync id is not ready');
    }
    final ledgerSyncId = normalizedLedgerSyncId.trim();
    var normalizedItem = item;
    if (ledgerSyncId != item.ledgerSyncId) {
      normalizedItem = item.copyWith(ledgerSyncId: ledgerSyncId);
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET ledger_sync_id = ?
        WHERE id = ?
        ''',
        [ledgerSyncId, item.id],
      );
    }
    final action = normalizedItem.action.trim();
    if (action != 'create' && action != 'update' && action != 'delete') {
      return null;
    }
    final baseChangeId = await _resolveBaseChangeId(
      provider: provider,
      item: normalizedItem,
    );

    switch (normalizedItem.entityType.trim()) {
      case 'ledger':
        return _dispatchLedgerMutation(
          provider: provider,
          item: normalizedItem,
          baseChangeId: baseChangeId,
        );
      case 'transaction':
        return _dispatchTransactionMutation(
          provider: provider,
          item: normalizedItem,
          baseChangeId: baseChangeId,
        );
      case 'account':
        return _dispatchAccountMutation(
          provider: provider,
          item: normalizedItem,
          baseChangeId: baseChangeId,
        );
      case 'category':
        return _dispatchCategoryMutation(
          provider: provider,
          item: normalizedItem,
          baseChangeId: baseChangeId,
        );
      case 'tag':
        return _dispatchTagMutation(
          provider: provider,
          item: normalizedItem,
          baseChangeId: baseChangeId,
        );
      default:
        return null;
    }
  }

  Future<bool> _localEntityExistsForQueuedMutation(_QueuedMutation item) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    if (localId == null) {
      return false;
    }
    switch (item.entityType.trim()) {
      case 'transaction':
        return await repo.getTransactionById(localId) != null;
      case 'account':
        return await repo.getAccount(localId) != null;
      case 'category':
        return await repo.getCategoryById(localId) != null;
      case 'tag':
        return await repo.getTagById(localId) != null;
      default:
        return false;
    }
  }

  Future<bool> _recoverNotFoundMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
  }) async {
    final action = item.action.trim();
    final entityType = item.entityType.trim();
    if (entityType != 'transaction' &&
        entityType != 'account' &&
        entityType != 'category' &&
        entityType != 'tag') {
      return false;
    }
    if (action == 'delete') {
      await _markQueueDone(item.id);
      logger.info(
        'CloudSync',
        '协作删除命中 Entity not found，按已完成处理: ${item.entityType}, queueId=${item.id}',
      );
      return true;
    }
    if (action != 'update') {
      return false;
    }
    if (entityType == 'transaction') {
      final relinked = await _tryRelinkTransactionQueueEntitySyncId(item);
      if (relinked) {
        logger.warning(
          'CloudSync',
          'transaction/update 命中 Entity not found，已通过重拉重绑 sync_id 后重试: queueId=${item.id}',
        );
        return true;
      }
      logger.warning(
        'CloudSync',
        'transaction/update 命中 Entity not found，但未找到可重绑实体，已停止自动 create 以避免重复记录: queueId=${item.id}',
      );
      return false;
    }
    final exists = await _localEntityExistsForQueuedMutation(item);
    if (!exists) {
      await _markQueueDone(item.id);
      logger.info(
        'CloudSync',
        '检测到僵尸队列项（实体已不存在），已跳过: ${item.entityType}/${item.action}, queueId=${item.id}',
      );
      return true;
    }

    final recoverySeed = item.requestId ??
        item.idempotencyKey ??
        '${item.entityType}-${item.id}-${DateTime.now().millisecondsSinceEpoch}';
    final recoveryItem = item.copyWith(
      action: 'create',
      requestId: '$recoverySeed-recover-create',
      idempotencyKey: '$recoverySeed-recover-create',
    );
    try {
      final baseChangeId = await _resolveBaseChangeId(
        provider: provider,
        item: item,
      );
      fcs.BeeCountCloudWriteCommitMeta? commit;
      switch (entityType) {
        case 'account':
          commit = await _dispatchAccountMutation(
            provider: provider,
            item: recoveryItem,
            baseChangeId: baseChangeId,
          );
          break;
        case 'category':
          commit = await _dispatchCategoryMutation(
            provider: provider,
            item: recoveryItem,
            baseChangeId: baseChangeId,
          );
          break;
        case 'tag':
          commit = await _dispatchTagMutation(
            provider: provider,
            item: recoveryItem,
            baseChangeId: baseChangeId,
          );
          break;
      }
      if (commit == null) {
        return false;
      }
      await _markQueueDone(item.id);
      await _markPushState(
        ledgerSyncId: item.ledgerSyncId,
        lastChangeId: commit.newChangeId,
      );
      await _applyCommitEntitySyncId(
        item: recoveryItem,
        commit: commit,
      );
      logger.warning(
        'CloudSync',
        '协作写入 update 命中 Entity not found，已自动改为 create 重建: ${item.entityType}, queueId=${item.id}',
      );
      return true;
    } catch (e, stackTrace) {
      logger.warning(
        'CloudSync',
        'Entity not found 自动恢复失败(${item.entityType}): $e',
      );
      logger.debug('CloudSync', 'Entity not found 自动恢复堆栈: $stackTrace');
      return false;
    }
  }

  Future<bool> _tryRelinkTransactionQueueEntitySyncId(
    _QueuedMutation item,
  ) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    if (localId == null) {
      return false;
    }
    await _applyRemoteLedgerProjection(item.ledgerSyncId);
    final latestSyncId =
        await _querySyncIdByTable(table: 'transactions', localId: localId);
    final normalizedLatest = _nullIfBlank(latestSyncId);
    if (normalizedLatest == null || normalizedLatest == item.entitySyncId) {
      return false;
    }
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET entity_sync_id = ?, updated_at = ?, last_error = NULL
      WHERE id = ?
      ''',
      [normalizedLatest, nowSec, item.id],
    );
    logger.info(
      'CloudSync',
      '已重绑 transaction 队列 sync_id: queueId=${item.id}, from=${item.entitySyncId}, to=$normalizedLatest',
    );
    return true;
  }

  Future<String?> _resolveQueueLedgerSyncId(String rawLedgerSyncId) async {
    final normalized = rawLedgerSyncId.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (!_isLegacySnapshotLedgerSyncId(normalized)) {
      return normalized;
    }
    final localLedgerId = await _resolveLocalLedgerId(normalized);
    if (localLedgerId == null) {
      return normalized;
    }
    final remapped = await _collabLedgerSyncIdOrNull(localLedgerId);
    if (remapped == null || remapped.trim().isEmpty) {
      if (_knownRemoteLedgerSyncIds.isNotEmpty &&
          !_knownRemoteLedgerSyncIds.contains(normalized)) {
        return null;
      }
      return normalized;
    }
    final resolved = remapped.trim();
    if (_isLegacySnapshotLedgerSyncId(resolved) &&
        _knownRemoteLedgerSyncIds.isNotEmpty &&
        !_knownRemoteLedgerSyncIds.contains(resolved)) {
      return null;
    }
    return resolved;
  }

  Future<int> _resolveBaseChangeId({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
  }) async {
    final fromState = await _readLedgerChangeId(item.ledgerSyncId);
    if (fromState != null && fromState > 0) {
      return fromState;
    }
    final detail = await provider.readLedgerDetail(ledgerId: item.ledgerSyncId);
    await _upsertLedgerSyncState(
      ledgerSyncId: item.ledgerSyncId,
      lastChangeId: detail.sourceChangeId,
    );
    return detail.sourceChangeId;
  }

  Future<int?> _readLedgerChangeId(String ledgerSyncId) async {
    final row = await db.customSelect(
      '''
      SELECT last_change_id
      FROM sync_state
      WHERE ledger_sync_id = ?
      LIMIT 1
      ''',
      variables: [drift.Variable.withString(ledgerSyncId)],
    ).getSingleOrNull();
    return _toIntOrNull(row?.data['last_change_id']);
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchLedgerMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
  }) async {
    final localLedgerId = _toIntOrNull(item.payloadJson['local_ledger_id']) ??
        _toIntOrNull(item.payloadJson['local_entity_id']);
    if (localLedgerId == null) {
      return null;
    }
    final ledger = await repo.getLedgerById(localLedgerId);
    final action = item.action.trim();
    if (action == 'delete' || ledger == null) {
      return null;
    }
    if (action == 'create') {
      return provider.writeCreateLedger(
        ledgerId: _nullIfBlank(item.entitySyncId),
        ledgerName: ledger.name,
        currency: ledger.currency,
        idempotencyKey: item.idempotencyKey,
      );
    }
    return provider.writeLedgerMeta(
      ledgerId: item.ledgerSyncId,
      baseChangeId: baseChangeId,
      ledgerName: ledger.name,
      currency: ledger.currency,
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchAccountMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
  }) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    final action = item.action.trim();
    if (action == 'delete') {
      final accountSyncId = _nullIfBlank(item.entitySyncId);
      if (accountSyncId == null) {
        return null;
      }
      return provider.writeDeleteAccount(
        ledgerId: item.ledgerSyncId,
        accountId: accountSyncId,
        baseChangeId: baseChangeId,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    if (localId == null) {
      return null;
    }
    final account = await repo.getAccount(localId);
    if (account == null) {
      return null;
    }
    if (action == 'create') {
      return provider.writeCreateAccount(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: account.name,
        accountType: account.type,
        currency: account.currency,
        initialBalance: account.initialBalance,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    var accountSyncId = _nullIfBlank(item.entitySyncId);
    final accountSyncIdFromDb =
        await _querySyncIdByTable(table: 'accounts', localId: localId);
    if (accountSyncIdFromDb != null &&
        accountSyncIdFromDb.isNotEmpty &&
        accountSyncIdFromDb != accountSyncId) {
      accountSyncId = accountSyncIdFromDb;
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET entity_sync_id = ?
        WHERE id = ?
        ''',
        [accountSyncIdFromDb, item.id],
      );
    }
    if (accountSyncId == null) {
      return provider.writeCreateAccount(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: account.name,
        accountType: account.type,
        currency: account.currency,
        initialBalance: account.initialBalance,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    return provider.writeUpdateAccount(
      ledgerId: item.ledgerSyncId,
      accountId: accountSyncId,
      baseChangeId: baseChangeId,
      name: account.name,
      accountType: account.type,
      currency: account.currency,
      initialBalance: account.initialBalance,
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchCategoryMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
  }) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    final action = item.action.trim();
    if (action == 'delete') {
      final categorySyncId = _nullIfBlank(item.entitySyncId);
      if (categorySyncId == null) {
        return null;
      }
      return provider.writeDeleteCategory(
        ledgerId: item.ledgerSyncId,
        categoryId: categorySyncId,
        baseChangeId: baseChangeId,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    if (localId == null) {
      return null;
    }
    final category = await repo.getCategoryById(localId);
    if (category == null) {
      return null;
    }
    final parentName = category.parentId == null
        ? null
        : _nullIfBlank((await repo.getCategoryById(category.parentId!))?.name);
    final name = _nullIfBlank(category.name);
    if (name == null) {
      return null;
    }
    final kind = _nullIfBlank(category.kind) ?? 'expense';
    final iconType = _nullIfBlank(category.iconType);
    if (action == 'create') {
      return provider.writeCreateCategory(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: name,
        kind: kind,
        level: category.level,
        sortOrder: category.sortOrder,
        icon: _nullIfBlank(category.icon),
        iconType: iconType,
        customIconPath: _nullIfBlank(category.customIconPath),
        parentName: parentName,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    var categorySyncId = _nullIfBlank(item.entitySyncId);
    final categorySyncIdFromDb =
        await _querySyncIdByTable(table: 'categories', localId: localId);
    if (categorySyncIdFromDb != null &&
        categorySyncIdFromDb.isNotEmpty &&
        categorySyncIdFromDb != categorySyncId) {
      categorySyncId = categorySyncIdFromDb;
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET entity_sync_id = ?
        WHERE id = ?
        ''',
        [categorySyncIdFromDb, item.id],
      );
    }
    if (categorySyncId == null) {
      return provider.writeCreateCategory(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: name,
        kind: kind,
        level: category.level,
        sortOrder: category.sortOrder,
        icon: _nullIfBlank(category.icon),
        iconType: iconType,
        customIconPath: _nullIfBlank(category.customIconPath),
        parentName: parentName,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    return provider.writeUpdateCategory(
      ledgerId: item.ledgerSyncId,
      categoryId: categorySyncId,
      baseChangeId: baseChangeId,
      name: name,
      kind: kind,
      level: category.level,
      sortOrder: category.sortOrder,
      icon: _nullIfBlank(category.icon),
      iconType: iconType,
      customIconPath: _nullIfBlank(category.customIconPath),
      parentName: parentName,
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchTagMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
  }) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    final action = item.action.trim();
    if (action == 'delete') {
      final tagSyncId = _nullIfBlank(item.entitySyncId);
      if (tagSyncId == null) {
        return null;
      }
      return provider.writeDeleteTag(
        ledgerId: item.ledgerSyncId,
        tagId: tagSyncId,
        baseChangeId: baseChangeId,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    if (localId == null) {
      return null;
    }
    final tag = await repo.getTagById(localId);
    if (tag == null) {
      return null;
    }
    final name = _nullIfBlank(tag.name);
    if (name == null) {
      return null;
    }
    if (action == 'create') {
      return provider.writeCreateTag(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: name,
        color: _nullIfBlank(tag.color),
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    var tagSyncId = _nullIfBlank(item.entitySyncId);
    final tagSyncIdFromDb =
        await _querySyncIdByTable(table: 'tags', localId: localId);
    if (tagSyncIdFromDb != null &&
        tagSyncIdFromDb.isNotEmpty &&
        tagSyncIdFromDb != tagSyncId) {
      tagSyncId = tagSyncIdFromDb;
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET entity_sync_id = ?
        WHERE id = ?
        ''',
        [tagSyncIdFromDb, item.id],
      );
    }
    if (tagSyncId == null) {
      return provider.writeCreateTag(
        ledgerId: item.ledgerSyncId,
        baseChangeId: baseChangeId,
        name: name,
        color: _nullIfBlank(tag.color),
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    return provider.writeUpdateTag(
      ledgerId: item.ledgerSyncId,
      tagId: tagSyncId,
      baseChangeId: baseChangeId,
      name: name,
      color: _nullIfBlank(tag.color),
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _dispatchTransactionMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
  }) async {
    final localId = _toIntOrNull(item.payloadJson['local_entity_id']);
    final action = item.action.trim();
    if (action == 'delete') {
      final txSyncId = _nullIfBlank(item.entitySyncId);
      if (txSyncId == null) {
        return null;
      }
      return provider.writeDeleteTransaction(
        ledgerId: item.ledgerSyncId,
        txId: txSyncId,
        baseChangeId: baseChangeId,
        requestId: item.requestId,
        idempotencyKey: item.idempotencyKey,
      );
    }
    if (localId == null) {
      return null;
    }
    if (action == 'create') {
      return _createTransactionMutation(
        provider: provider,
        item: item,
        baseChangeId: baseChangeId,
        localId: localId,
        includeReferenceIds: true,
      );
    }
    final tx = await repo.getTransactionById(localId);
    if (tx == null) {
      return null;
    }
    final category = tx.categoryId != null
        ? await repo.getCategoryById(tx.categoryId!)
        : null;
    final account =
        tx.accountId != null ? await repo.getAccount(tx.accountId!) : null;
    final toAccount =
        tx.toAccountId != null ? await repo.getAccount(tx.toAccountId!) : null;
    final tagRows = await repo.getTagsForTransaction(localId);
    final attachmentRows = await repo.getAttachmentsByTransaction(localId);

    final tagNames = tagRows
        .map((t) => t.name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final tagSyncIds = <String>[];
    for (final tag in tagRows) {
      final syncId = await _querySyncIdByTable(table: 'tags', localId: tag.id);
      if (syncId != null && syncId.isNotEmpty) {
        tagSyncIds.add(syncId);
      }
    }

    final categorySyncId = tx.categoryId == null
        ? null
        : await _querySyncIdByTable(
            table: 'categories', localId: tx.categoryId!);
    final accountSyncId = tx.accountId == null
        ? null
        : await _querySyncIdByTable(table: 'accounts', localId: tx.accountId!);
    final toAccountSyncId = tx.toAccountId == null
        ? null
        : await _querySyncIdByTable(
            table: 'accounts', localId: tx.toAccountId!);

    final attachments = attachmentRows.map((row) {
      return <String, dynamic>{
        'fileName': row.fileName,
        if (row.originalName != null) 'originalName': row.originalName,
        if (row.fileSize != null) 'fileSize': row.fileSize,
        if (row.width != null) 'width': row.width,
        if (row.height != null) 'height': row.height,
        'sortOrder': row.sortOrder,
      };
    }).toList(growable: false);

    var txSyncId = _nullIfBlank(item.entitySyncId);
    final txSyncIdFromDb =
        await _querySyncIdByTable(table: 'transactions', localId: localId);
    if (txSyncIdFromDb != null &&
        txSyncIdFromDb.isNotEmpty &&
        txSyncIdFromDb != txSyncId) {
      txSyncId = txSyncIdFromDb;
      await db.customStatement(
        '''
        UPDATE sync_queue
        SET entity_sync_id = ?
        WHERE id = ?
        ''',
        [txSyncIdFromDb, item.id],
      );
    }
    if (txSyncId == null) {
      // Never downgrade an update to create for transactions; this can
      // duplicate existing remote records when local sync_id is missing.
      final relinked = await _tryRelinkTransactionQueueEntitySyncId(item);
      if (relinked) {
        final reboundSyncId =
            await _querySyncIdByTable(table: 'transactions', localId: localId);
        final normalizedReboundSyncId = _nullIfBlank(reboundSyncId);
        if (normalizedReboundSyncId != null) {
          txSyncId = normalizedReboundSyncId;
        }
      }
    }
    if (txSyncId == null) {
      throw fcs.CloudSyncException(
        'Transaction update skipped: missing transaction sync id',
      );
    }
    return provider.writeUpdateTransaction(
      ledgerId: item.ledgerSyncId,
      txId: txSyncId,
      baseChangeId: baseChangeId,
      txType: tx.type,
      amount: tx.amount,
      happenedAt: tx.happenedAt,
      note: _nullIfBlank(tx.note),
      categoryName: _nullIfBlank(category?.name),
      categoryKind: _nullIfBlank(category?.kind),
      accountName: tx.type == 'transfer' ? null : _nullIfBlank(account?.name),
      fromAccountName:
          tx.type == 'transfer' ? _nullIfBlank(account?.name) : null,
      toAccountName:
          tx.type == 'transfer' ? _nullIfBlank(toAccount?.name) : null,
      categoryId: categorySyncId,
      accountId: tx.type == 'transfer' ? null : accountSyncId,
      fromAccountId: tx.type == 'transfer' ? accountSyncId : null,
      toAccountId: tx.type == 'transfer' ? toAccountSyncId : null,
      tags: tagNames.join(','),
      tagIds: tagSyncIds.isEmpty ? null : tagSyncIds,
      attachments: attachments.isEmpty ? null : attachments,
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<fcs.BeeCountCloudWriteCommitMeta?> _createTransactionMutation({
    required fcs.BeeCountCloudProvider provider,
    required _QueuedMutation item,
    required int baseChangeId,
    required int localId,
    required bool includeReferenceIds,
  }) async {
    final tx = await repo.getTransactionById(localId);
    if (tx == null) {
      return null;
    }
    final category = tx.categoryId != null
        ? await repo.getCategoryById(tx.categoryId!)
        : null;
    final account =
        tx.accountId != null ? await repo.getAccount(tx.accountId!) : null;
    final toAccount =
        tx.toAccountId != null ? await repo.getAccount(tx.toAccountId!) : null;
    final tagRows = await repo.getTagsForTransaction(localId);
    final attachmentRows = await repo.getAttachmentsByTransaction(localId);

    final tagNames = tagRows
        .map((t) => t.name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final tagSyncIds = <String>[];
    for (final tag in tagRows) {
      final syncId = await _querySyncIdByTable(table: 'tags', localId: tag.id);
      if (syncId != null && syncId.isNotEmpty) {
        tagSyncIds.add(syncId);
      }
    }

    final categorySyncId = tx.categoryId == null
        ? null
        : await _querySyncIdByTable(
            table: 'categories',
            localId: tx.categoryId!,
          );
    final accountSyncId = tx.accountId == null
        ? null
        : await _querySyncIdByTable(table: 'accounts', localId: tx.accountId!);
    final toAccountSyncId = tx.toAccountId == null
        ? null
        : await _querySyncIdByTable(
            table: 'accounts',
            localId: tx.toAccountId!,
          );

    final attachments = attachmentRows.map((row) {
      return <String, dynamic>{
        'fileName': row.fileName,
        if (row.originalName != null) 'originalName': row.originalName,
        if (row.fileSize != null) 'fileSize': row.fileSize,
        if (row.width != null) 'width': row.width,
        if (row.height != null) 'height': row.height,
        'sortOrder': row.sortOrder,
      };
    }).toList(growable: false);

    return provider.writeCreateTransaction(
      ledgerId: item.ledgerSyncId,
      baseChangeId: baseChangeId,
      txType: tx.type,
      amount: tx.amount,
      happenedAt: tx.happenedAt,
      note: _nullIfBlank(tx.note),
      categoryName: _nullIfBlank(category?.name),
      categoryKind: _nullIfBlank(category?.kind),
      accountName: tx.type == 'transfer' ? null : _nullIfBlank(account?.name),
      fromAccountName:
          tx.type == 'transfer' ? _nullIfBlank(account?.name) : null,
      toAccountName:
          tx.type == 'transfer' ? _nullIfBlank(toAccount?.name) : null,
      categoryId: includeReferenceIds ? categorySyncId : null,
      accountId: tx.type == 'transfer'
          ? null
          : (includeReferenceIds ? accountSyncId : null),
      fromAccountId: tx.type == 'transfer'
          ? (includeReferenceIds ? accountSyncId : null)
          : null,
      toAccountId: tx.type == 'transfer'
          ? (includeReferenceIds ? toAccountSyncId : null)
          : null,
      tags: tagNames.join(','),
      tagIds: includeReferenceIds && tagSyncIds.isNotEmpty ? tagSyncIds : null,
      attachments: attachments.isEmpty ? null : attachments,
      requestId: item.requestId,
      idempotencyKey: item.idempotencyKey,
    );
  }

  Future<void> _applyCommitEntitySyncId({
    required _QueuedMutation item,
    required fcs.BeeCountCloudWriteCommitMeta commit,
  }) async {
    final localEntityId = _toIntOrNull(item.payloadJson['local_entity_id']);
    if (localEntityId == null) {
      return;
    }
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final newEntitySyncId = _nullIfBlank(commit.entityId);

    switch (item.entityType) {
      case 'ledger':
        await db.customStatement(
          'UPDATE ledgers SET last_change_id = ? WHERE id = ?',
          [commit.newChangeId, localEntityId],
        );
        if (newEntitySyncId != null && newEntitySyncId != item.ledgerSyncId) {
          await db.customStatement(
            'UPDATE ledgers SET sync_id = ? WHERE id = ?',
            [newEntitySyncId, localEntityId],
          );
          _ledgerSyncIdCache[localEntityId] = newEntitySyncId;
          await db.customStatement(
            '''
            UPDATE sync_queue
            SET ledger_sync_id = ?, updated_at = ?
            WHERE ledger_sync_id = ? AND status = 'pending'
            ''',
            [newEntitySyncId, nowSec, item.ledgerSyncId],
          );
        }
        break;
      case 'transaction':
        await db.customStatement(
          'UPDATE transactions SET last_change_id = ? WHERE id = ?',
          [commit.newChangeId, localEntityId],
        );
        if (newEntitySyncId != null && newEntitySyncId != item.entitySyncId) {
          await db.customStatement(
            'UPDATE transactions SET sync_id = ? WHERE id = ?',
            [newEntitySyncId, localEntityId],
          );
          await _updatePendingEntitySyncId(
            ledgerSyncId: item.ledgerSyncId,
            entityType: item.entityType,
            oldSyncId: item.entitySyncId,
            newSyncId: newEntitySyncId,
          );
        }
        break;
      case 'account':
        await db.customStatement(
          'UPDATE accounts SET last_change_id = ? WHERE id = ?',
          [commit.newChangeId, localEntityId],
        );
        if (newEntitySyncId != null && newEntitySyncId != item.entitySyncId) {
          await db.customStatement(
            'UPDATE accounts SET sync_id = ? WHERE id = ?',
            [newEntitySyncId, localEntityId],
          );
          await _updatePendingEntitySyncId(
            ledgerSyncId: item.ledgerSyncId,
            entityType: item.entityType,
            oldSyncId: item.entitySyncId,
            newSyncId: newEntitySyncId,
          );
        }
        break;
      case 'category':
        await db.customStatement(
          'UPDATE categories SET last_change_id = ? WHERE id = ?',
          [commit.newChangeId, localEntityId],
        );
        if (newEntitySyncId != null && newEntitySyncId != item.entitySyncId) {
          await db.customStatement(
            'UPDATE categories SET sync_id = ? WHERE id = ?',
            [newEntitySyncId, localEntityId],
          );
          await _updatePendingEntitySyncId(
            ledgerSyncId: item.ledgerSyncId,
            entityType: item.entityType,
            oldSyncId: item.entitySyncId,
            newSyncId: newEntitySyncId,
          );
        }
        break;
      case 'tag':
        await db.customStatement(
          'UPDATE tags SET last_change_id = ? WHERE id = ?',
          [commit.newChangeId, localEntityId],
        );
        if (newEntitySyncId != null && newEntitySyncId != item.entitySyncId) {
          await db.customStatement(
            'UPDATE tags SET sync_id = ? WHERE id = ?',
            [newEntitySyncId, localEntityId],
          );
          await _updatePendingEntitySyncId(
            ledgerSyncId: item.ledgerSyncId,
            entityType: item.entityType,
            oldSyncId: item.entitySyncId,
            newSyncId: newEntitySyncId,
          );
        }
        break;
      default:
        break;
    }
  }

  Future<void> _updatePendingEntitySyncId({
    required String ledgerSyncId,
    required String entityType,
    required String oldSyncId,
    required String newSyncId,
  }) async {
    final oldValue = oldSyncId.trim();
    final newValue = newSyncId.trim();
    if (oldValue.isEmpty || newValue.isEmpty || oldValue == newValue) {
      return;
    }
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET entity_sync_id = ?, updated_at = ?
      WHERE ledger_sync_id = ? AND entity_type = ? AND entity_sync_id = ? AND status = 'pending'
      ''',
      [newValue, nowSec, ledgerSyncId, entityType, oldValue],
    );
  }

  void _queueIncrementalPull({
    required String reason,
    int? targetCursor,
    bool isPoll = false,
  }) {
    if (isPoll) {
      final now = DateTime.now();
      if (_lastPollAt != null &&
          now.difference(_lastPollAt!) < const Duration(seconds: 1)) {
        return;
      }
      _lastPollAt = now;
    }
    _hasPendingPull = true;
    _pendingPullReason = reason;
    if (targetCursor != null) {
      final existing = _pendingTargetCursor ?? 0;
      if (targetCursor > existing) {
        _pendingTargetCursor = targetCursor;
      }
    }
    if (_isPullingFromCloud) {
      return;
    }
    unawaited(_drainPullQueue());
  }

  Future<void> _drainPullQueue() async {
    if (_isPullingFromCloud) return;
    _isPullingFromCloud = true;
    try {
      while (_hasPendingPull) {
        final reason = _pendingPullReason;
        final targetCursor = _pendingTargetCursor;
        _hasPendingPull = false;
        _pendingTargetCursor = null;
        await _pullIncrementalFromCloud(
          reason: reason,
          targetCursor: targetCursor,
        );
      }
    } finally {
      _isPullingFromCloud = false;
    }
  }

  Future<void> _pullIncrementalFromCloud({
    required String reason,
    int? targetCursor,
  }) async {
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return;
    }
    final currentUser = await provider.auth.currentUser;
    if (currentUser == null) {
      return;
    }

    try {
      await _runOneTimeLedgerSyncIdRepair();
      var batch = 0;
      var hasMore = true;
      var observedCursor = 0;
      var emptyRetry = 0;
      final affectedLedgerIds = <int>{};
      final pulledLedgerSyncIds = <String>{};
      while (batch < 10) {
        final pull = await provider.pullChanges(limit: 200);
        hasMore = pull.hasMore;
        observedCursor = pull.serverCursor > observedCursor
            ? pull.serverCursor
            : observedCursor;
        batch++;

        if (pull.changes.isNotEmpty) {
          final latestByLedger = <String, fcs.BeeCountCloudSyncChange>{};
          for (final change in pull.changes) {
            pulledLedgerSyncIds.add(change.ledgerId);
            final existing = latestByLedger[change.ledgerId];
            if (existing == null || change.changeId >= existing.changeId) {
              latestByLedger[change.ledgerId] = change;
            }
          }

          final toApply = latestByLedger.values.toList()
            ..sort((a, b) => a.changeId.compareTo(b.changeId));
          for (final change in toApply) {
            final appliedLedgerId =
                await _applyRemoteLedgerProjection(change.ledgerId);
            if (appliedLedgerId != null) {
              affectedLedgerIds.add(appliedLedgerId);
            }
          }
        }

        if (pull.changes.isEmpty && !hasMore) {
          final reachedTarget =
              targetCursor == null || observedCursor >= targetCursor;
          if (!reachedTarget && emptyRetry < 3) {
            emptyRetry++;
            await Future.delayed(const Duration(milliseconds: 250));
            continue;
          }
          break;
        }

        final reachedTarget =
            targetCursor == null || observedCursor >= targetCursor;
        if (!hasMore && reachedTarget) {
          break;
        }
      }

      if (affectedLedgerIds.isNotEmpty) {
        onRemoteChangeApplied?.call(affectedLedgerIds);
      }
      if (observedCursor > 0) {
        unawaited(_markPullState(
          cursor: observedCursor,
          ledgerSyncIds: pulledLedgerSyncIds,
        ));
      }
      if (config.type == fcs.CloudBackendType.beecountCloud) {
        _queuePush(reason: 'after_pull');
      }

      if (targetCursor != null && observedCursor < targetCursor) {
        _queueIncrementalPull(
          reason: 'catchup:$reason',
          targetCursor: targetCursor,
        );
      }
    } catch (e, stackTrace) {
      logger.warning('CloudSync', '增量拉取失败($reason): $e');
      logger.debug('CloudSync', '增量拉取堆栈: $stackTrace');
    }
  }

  Future<int?> _applyRemoteLedgerProjection(String ledgerSyncId) async {
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return null;
    }
    final existingLedgerId = await _resolveLocalLedgerId(ledgerSyncId);
    if (existingLedgerId != null) {
      onRemoteApplyStateChanged?.call(existingLedgerId, true);
    }

    try {
      final detail = await provider.readLedgerDetail(ledgerId: ledgerSyncId);
      final normalizedRole = detail.role.trim().toLowerCase();
      if (normalizedRole.isNotEmpty) {
        _ledgerRoleCache[ledgerSyncId] = normalizedRole;
      }
      final accounts = await provider.readAccounts(ledgerId: ledgerSyncId);
      final categories = await provider.readCategories(ledgerId: ledgerSyncId);
      final tags = await provider.readTags(ledgerId: ledgerSyncId);
      final transactions = await _readAllTransactions(
        provider: provider,
        ledgerSyncId: ledgerSyncId,
      );

      final localLedgerId = await _runWithLocalMutationSuppressed(() async {
        return db.transaction(() async {
          final id = await _upsertLocalLedgerFromRead(
            ledgerSyncId: ledgerSyncId,
            detail: detail,
          );
          await _upsertAccountsFromRead(ledgerId: id, rows: accounts);
          await _upsertCategoriesFromRead(
              rows: categories, scopedLedgerId: id);
          await _upsertTagsFromRead(rows: tags, scopedLedgerId: id);
          await _upsertTransactionsFromRead(
            ledgerId: id,
            ledgerSyncId: ledgerSyncId,
            rows: transactions,
          );
          await _upsertLedgerSyncState(
            ledgerSyncId: ledgerSyncId,
            lastChangeId: detail.sourceChangeId,
          );
          return id;
        });
      });

      _ledgerSyncIdCache[localLedgerId] = ledgerSyncId;
      final cachedRole = _ledgerRoleCache[ledgerSyncId];
      if (cachedRole != null && cachedRole.isNotEmpty) {
        _ledgerRoleCacheByLocalId[localLedgerId] = cachedRole;
      }
      _recentLocalChangeAt.remove(localLedgerId);
      _recentUpload.remove(localLedgerId);
      _statusCache.remove(localLedgerId);
      return localLedgerId;
    } catch (e, stackTrace) {
      logger.warning('CloudSync', '远端协作账本应用失败($ledgerSyncId): $e');
      logger.debug('CloudSync', '远端协作账本应用堆栈: $stackTrace');
      return existingLedgerId;
    } finally {
      final targetLedgerId =
          existingLedgerId ?? await _resolveLocalLedgerId(ledgerSyncId);
      if (targetLedgerId != null) {
        onRemoteApplyStateChanged?.call(targetLedgerId, false);
      }
    }
  }

  Future<List<fcs.BeeCountCloudReadTransaction>> _readAllTransactions({
    required fcs.BeeCountCloudProvider provider,
    required String ledgerSyncId,
    int pageSize = 200,
  }) async {
    final all = <fcs.BeeCountCloudReadTransaction>[];
    var offset = 0;
    while (true) {
      final page = await provider.readTransactions(
        ledgerId: ledgerSyncId,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }
      all.addAll(page);
      if (page.length < pageSize) {
        break;
      }
      offset += page.length;
      if (offset > 100000) {
        break;
      }
    }
    return all;
  }

  Future<T> _runWithLocalMutationSuppressed<T>(
      Future<T> Function() action) async {
    final localRepo = repo;
    if (localRepo is LocalRepository) {
      return localRepo.runWithMutationSuppressed(action);
    }
    return action();
  }

  Future<int> _upsertLocalLedgerFromRead({
    required String ledgerSyncId,
    required fcs.BeeCountCloudReadLedgerDetail detail,
  }) async {
    final ledgerType = detail.isShared ? 'shared' : 'personal';
    var localLedgerId = await _resolveLocalLedgerId(ledgerSyncId);
    if (localLedgerId != null && detail.isShared) {
      final existingRow = await db.customSelect(
        '''
        SELECT type, sync_id
        FROM ledgers
        WHERE id = ?
        LIMIT 1
        ''',
        variables: [drift.Variable.withInt(localLedgerId)],
      ).getSingleOrNull();
      final existingType =
          (existingRow?.data['type']?.toString() ?? '').trim().toLowerCase();
      final existingSyncId =
          (existingRow?.data['sync_id']?.toString() ?? '').trim();
      if (existingType != 'shared') {
        final currentUserId = await _currentBeeCountCloudUserId();
        final personalSyncId = _buildNamespacedPersonalLedgerSyncId(
          ledgerId: localLedgerId,
          userId: currentUserId ?? 'anon',
        );
        await db.customStatement(
          '''
          UPDATE ledgers
          SET sync_id = ?, type = 'personal'
          WHERE id = ?
          ''',
          [personalSyncId, localLedgerId],
        );
        if (existingSyncId.isNotEmpty && existingSyncId != personalSyncId) {
          await _rebindLedgerSyncIdReferences(
            fromSyncId: existingSyncId,
            toSyncId: personalSyncId,
          );
          await _copyRemoteSnapshotIfMissing(
            fromPath: existingSyncId,
            toPath: personalSyncId,
          );
        }
        _ledgerSyncIdCache[localLedgerId] = personalSyncId;
        logger.warning(
          'CloudSync',
          '检测到共享账本映射覆盖个人账本风险，已先重映射个人账本: ledgerId=$localLedgerId, from=$existingSyncId, to=$personalSyncId',
        );
        localLedgerId = null;
      }
    }
    if (localLedgerId == null) {
      localLedgerId = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(
              name: detail.ledgerName,
              currency: drift.Value(detail.currency),
              type: drift.Value(ledgerType),
            ),
          );
    } else {
      await (db.update(db.ledgers)..where((t) => t.id.equals(localLedgerId!)))
          .write(
        LedgersCompanion(
          name: drift.Value(detail.ledgerName),
          currency: drift.Value(detail.currency),
          type: drift.Value(ledgerType),
        ),
      );
    }
    final normalizedRole = detail.role.trim().toLowerCase();
    final currentUserId = await _currentBeeCountCloudUserId();
    final ownerUserId = normalizedRole == 'owner' ? currentUserId : null;

    await db.customStatement(
      '''
      UPDATE ledgers
      SET sync_id = ?, last_change_id = ?, type = ?, created_by_user_id = COALESCE(?, created_by_user_id)
      WHERE id = ?
      ''',
      [
        ledgerSyncId,
        detail.sourceChangeId,
        ledgerType,
        ownerUserId,
        localLedgerId,
      ],
    );
    return localLedgerId;
  }

  Future<void> _upsertAccountsFromRead({
    required int ledgerId,
    required List<fcs.BeeCountCloudReadAccount> rows,
  }) async {
    final now = DateTime.now();
    for (final row in rows) {
      final syncId = row.id.trim();
      if (syncId.isEmpty) continue;
      final name = row.name.trim();
      if (name.isEmpty) continue;
      final type = row.accountType?.trim().isNotEmpty == true
          ? row.accountType!.trim()
          : 'cash';
      final currency = row.currency?.trim().isNotEmpty == true
          ? row.currency!.trim().toUpperCase()
          : 'CNY';
      final initialBalance = row.initialBalance ?? 0.0;

      var localId = await _queryLocalIdBySyncId(
        table: 'accounts',
        syncId: syncId,
      );
      // BeeCount Cloud 模式下禁用名称回退，避免多用户同名实体错误合并
      if (localId == null &&
          config.type != fcs.CloudBackendType.beecountCloud) {
        localId = await _queryAccountIdByLedgerAndName(
          ledgerId: ledgerId,
          name: name,
        );
      }
      if (localId == null) {
        localId = await db.into(db.accounts).insert(
              AccountsCompanion.insert(
                ledgerId: ledgerId,
                name: name,
                type: drift.Value(type),
                currency: drift.Value(currency),
                initialBalance: drift.Value(initialBalance),
                createdAt: drift.Value(now),
                updatedAt: drift.Value(now),
              ),
            );
      } else {
        await (db.update(db.accounts)..where((t) => t.id.equals(localId!)))
            .write(
          AccountsCompanion(
            ledgerId: drift.Value(ledgerId),
            name: drift.Value(name),
            type: drift.Value(type),
            currency: drift.Value(currency),
            initialBalance: drift.Value(initialBalance),
            updatedAt: drift.Value(now),
          ),
        );
      }

      await db.customStatement(
        '''
        UPDATE accounts
        SET sync_id = ?, last_change_id = ?, created_by_user_id = COALESCE(?, created_by_user_id)
        WHERE id = ?
        ''',
        [syncId, row.lastChangeId, _nullIfBlank(row.createdByUserId), localId],
      );
    }
  }

  Future<void> _upsertCategoriesFromRead({
    required List<fcs.BeeCountCloudReadCategory> rows,
    int? scopedLedgerId,
  }) async {
    final byKindAndName = <String, int>{};
    final pendingParents = <int, ({String kind, String parentName})>{};

    for (final row in rows) {
      final syncId = row.id.trim();
      if (syncId.isEmpty) continue;
      final name = row.name.trim();
      if (name.isEmpty) continue;
      final kind = row.kind.trim().isNotEmpty ? row.kind.trim() : 'expense';
      final level =
          row.level ?? (row.parentName?.trim().isNotEmpty == true ? 2 : 1);
      final sortOrder = row.sortOrder ?? 0;
      final iconType = row.iconType?.trim().isNotEmpty == true
          ? row.iconType!.trim()
          : 'material';

      var localId = await _queryLocalIdBySyncId(
        table: 'categories',
        syncId: syncId,
      );
      // BeeCount Cloud 模式下禁用名称回退，避免多用户同名实体错误合并
      if (localId == null &&
          config.type != fcs.CloudBackendType.beecountCloud) {
        localId = await _queryCategoryIdByKindAndName(kind: kind, name: name);
      }
      if (localId == null) {
        localId = await db.into(db.categories).insert(
              CategoriesCompanion.insert(
                name: name,
                kind: kind,
                icon: drift.Value(_nullIfBlank(row.icon)),
                sortOrder: drift.Value(sortOrder),
                parentId: const drift.Value.absent(),
                level: drift.Value(level),
                iconType: drift.Value(iconType),
                customIconPath: drift.Value(_nullIfBlank(row.customIconPath)),
                communityIconId: const drift.Value(null),
                ledgerId: drift.Value(scopedLedgerId),
              ),
            );
      } else {
        await (db.update(db.categories)..where((t) => t.id.equals(localId!)))
            .write(
          CategoriesCompanion(
            name: drift.Value(name),
            kind: drift.Value(kind),
            icon: drift.Value(_nullIfBlank(row.icon)),
            sortOrder: drift.Value(sortOrder),
            level: drift.Value(level),
            iconType: drift.Value(iconType),
            customIconPath: drift.Value(_nullIfBlank(row.customIconPath)),
          ),
        );
      }

      await db.customStatement(
        '''
        UPDATE categories
        SET sync_id = ?, last_change_id = ?, created_by_user_id = COALESCE(?, created_by_user_id)
        WHERE id = ?
        ''',
        [syncId, row.lastChangeId, _nullIfBlank(row.createdByUserId), localId],
      );

      // 共享账本拉取的分类打上 ledger_id 标记
      if (scopedLedgerId != null) {
        await db.customStatement(
          'UPDATE categories SET ledger_id = ? WHERE id = ? AND ledger_id IS NULL',
          [scopedLedgerId, localId],
        );
      }

      byKindAndName[_kindNameKey(kind: kind, name: name)] = localId;
      final parentName = row.parentName?.trim() ?? '';
      if (parentName.isNotEmpty) {
        pendingParents[localId] = (kind: kind, parentName: parentName);
      }
    }

    for (final entry in pendingParents.entries) {
      final parentId = byKindAndName[_kindNameKey(
        kind: entry.value.kind,
        name: entry.value.parentName,
      )];
      if (parentId == null || parentId == entry.key) {
        continue;
      }
      await (db.update(db.categories)..where((t) => t.id.equals(entry.key)))
          .write(
        CategoriesCompanion(
          parentId: drift.Value(parentId),
          level: const drift.Value(2),
        ),
      );
    }
  }

  Future<void> _upsertTagsFromRead({
    required List<fcs.BeeCountCloudReadTag> rows,
    int? scopedLedgerId,
  }) async {
    for (final row in rows) {
      final syncId = row.id.trim();
      if (syncId.isEmpty) continue;
      final name = row.name.trim();
      if (name.isEmpty) continue;

      var localId = await _queryLocalIdBySyncId(
        table: 'tags',
        syncId: syncId,
      );
      // BeeCount Cloud 模式下禁用名称回退，避免多用户同名实体错误合并
      if (localId == null &&
          config.type != fcs.CloudBackendType.beecountCloud) {
        localId = await _queryTagIdByName(name: name);
      }
      if (localId == null) {
        localId = await db.into(db.tags).insert(
              TagsCompanion.insert(
                name: name,
                color: drift.Value(_nullIfBlank(row.color)),
                ledgerId: drift.Value(scopedLedgerId),
              ),
            );
      } else {
        await (db.update(db.tags)..where((t) => t.id.equals(localId!))).write(
          TagsCompanion(
            name: drift.Value(name),
            color: drift.Value(_nullIfBlank(row.color)),
          ),
        );
      }

      await db.customStatement(
        '''
        UPDATE tags
        SET sync_id = ?, last_change_id = ?, created_by_user_id = COALESCE(?, created_by_user_id)
        WHERE id = ?
        ''',
        [syncId, row.lastChangeId, _nullIfBlank(row.createdByUserId), localId],
      );

      // 共享账本拉取的标签打上 ledger_id 标记
      if (scopedLedgerId != null) {
        await db.customStatement(
          'UPDATE tags SET ledger_id = ? WHERE id = ? AND ledger_id IS NULL',
          [scopedLedgerId, localId],
        );
      }
    }
  }

  Future<void> _upsertTransactionsFromRead({
    required int ledgerId,
    required String ledgerSyncId,
    required List<fcs.BeeCountCloudReadTransaction> rows,
  }) async {
    final pendingSyncIds = await _loadPendingEntitySyncIds(
      ledgerSyncId: ledgerSyncId,
      entityType: 'transaction',
    );
    final remoteSyncIds = <String>{};

    for (final row in rows) {
      final txSyncId = row.id.trim();
      if (txSyncId.isEmpty) continue;
      remoteSyncIds.add(txSyncId);

      var localId = await _queryLocalIdBySyncId(
        table: 'transactions',
        syncId: txSyncId,
      );
      final categoryId = await _resolveCategoryLocalIdForTx(row);
      final accountId = await _resolveAccountLocalId(
        ledgerId: ledgerId,
        syncId: row.txType == 'transfer'
            ? (row.fromAccountId ?? row.accountId)
            : row.accountId,
        name: row.txType == 'transfer'
            ? (row.fromAccountName ?? row.accountName)
            : row.accountName,
      );
      final toAccountId = await _resolveAccountLocalId(
        ledgerId: ledgerId,
        syncId: row.toAccountId,
        name: row.toAccountName,
      );
      final happenedAt = row.happenedAt?.toLocal() ?? DateTime.now();
      final safeType =
          row.txType.trim().isEmpty ? 'expense' : row.txType.trim();

      if (localId == null) {
        localId = await db.into(db.transactions).insert(
              TransactionsCompanion.insert(
                ledgerId: ledgerId,
                type: safeType,
                amount: row.amount,
                categoryId:
                    drift.Value(safeType == 'transfer' ? null : categoryId),
                accountId: drift.Value(accountId),
                toAccountId:
                    drift.Value(safeType == 'transfer' ? toAccountId : null),
                happenedAt: drift.Value(happenedAt),
                note: drift.Value(_nullIfBlank(row.note)),
              ),
            );
      } else {
        await (db.update(db.transactions)..where((t) => t.id.equals(localId!)))
            .write(
          TransactionsCompanion(
            ledgerId: drift.Value(ledgerId),
            type: drift.Value(safeType),
            amount: drift.Value(row.amount),
            categoryId: drift.Value(safeType == 'transfer' ? null : categoryId),
            accountId: drift.Value(accountId),
            toAccountId:
                drift.Value(safeType == 'transfer' ? toAccountId : null),
            happenedAt: drift.Value(happenedAt),
            note: drift.Value(_nullIfBlank(row.note)),
          ),
        );
      }

      await db.customStatement(
        '''
        UPDATE transactions
        SET sync_id = ?, last_change_id = ?, created_by_user_id = COALESCE(?, created_by_user_id)
        WHERE id = ?
        ''',
        [
          txSyncId,
          row.lastChangeId,
          _nullIfBlank(row.createdByUserId),
          localId
        ],
      );

      final tagIds = await _resolveTagLocalIdsForTx(row);
      await _replaceTransactionTags(transactionId: localId, tagIds: tagIds);
      await _replaceTransactionAttachments(
        transactionId: localId,
        attachments: row.attachments,
      );
    }

    final localRows = await db.customSelect(
      '''
      SELECT id, sync_id FROM transactions
      WHERE ledger_id = ? AND sync_id IS NOT NULL AND TRIM(sync_id) <> ''
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).get();
    for (final localRow in localRows) {
      final rawId = localRow.data['id'];
      final localId = rawId is int ? rawId : int.tryParse('$rawId');
      if (localId == null) continue;
      final syncId = (localRow.data['sync_id']?.toString() ?? '').trim();
      if (syncId.isEmpty) continue;
      if (remoteSyncIds.contains(syncId) || pendingSyncIds.contains(syncId)) {
        continue;
      }
      await db.customStatement(
        'DELETE FROM transaction_tags WHERE transaction_id = ?',
        [localId],
      );
      await db.customStatement(
        'DELETE FROM transaction_attachments WHERE transaction_id = ?',
        [localId],
      );
      await db.customStatement(
        'DELETE FROM transactions WHERE id = ?',
        [localId],
      );
    }
  }

  Future<int?> _queryLocalIdBySyncId({
    required String table,
    required String syncId,
  }) async {
    final normalized = syncId.trim();
    if (normalized.isEmpty) return null;
    final row = await db.customSelect(
      'SELECT id FROM $table WHERE sync_id = ? LIMIT 1',
      variables: [drift.Variable.withString(normalized)],
    ).getSingleOrNull();
    final raw = row?.data['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<int?> _queryAccountIdByLedgerAndName({
    required int ledgerId,
    required String name,
  }) async {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final row = await db.customSelect(
      '''
      SELECT id FROM accounts
      WHERE ledger_id = ? AND lower(name) = ?
      LIMIT 1
      ''',
      variables: [
        drift.Variable.withInt(ledgerId),
        drift.Variable.withString(normalized),
      ],
    ).getSingleOrNull();
    final raw = row?.data['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<int?> _queryCategoryIdByKindAndName({
    required String kind,
    required String name,
  }) async {
    final normalizedKind = kind.trim().toLowerCase();
    final normalizedName = name.trim().toLowerCase();
    if (normalizedKind.isEmpty || normalizedName.isEmpty) return null;
    final row = await db.customSelect(
      '''
      SELECT id FROM categories
      WHERE lower(kind) = ? AND lower(name) = ?
      LIMIT 1
      ''',
      variables: [
        drift.Variable.withString(normalizedKind),
        drift.Variable.withString(normalizedName),
      ],
    ).getSingleOrNull();
    final raw = row?.data['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<int?> _queryTagIdByName({required String name}) async {
    final normalizedName = name.trim().toLowerCase();
    if (normalizedName.isEmpty) return null;
    final row = await db.customSelect(
      '''
      SELECT id FROM tags
      WHERE lower(name) = ?
      LIMIT 1
      ''',
      variables: [drift.Variable.withString(normalizedName)],
    ).getSingleOrNull();
    final raw = row?.data['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<int?> _resolveCategoryLocalIdForTx(
      fcs.BeeCountCloudReadTransaction tx) async {
    final syncId = tx.categoryId?.trim() ?? '';
    if (syncId.isNotEmpty) {
      final id =
          await _queryLocalIdBySyncId(table: 'categories', syncId: syncId);
      if (id != null) return id;
    }
    final name = tx.categoryName?.trim() ?? '';
    final kind = tx.categoryKind?.trim().isNotEmpty == true
        ? tx.categoryKind!.trim()
        : 'expense';
    if (name.isEmpty) return null;
    // BeeCount Cloud 模式下禁用名称回退
    int? id;
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      id = await _queryCategoryIdByKindAndName(kind: kind, name: name);
    }
    id ??= await db.into(db.categories).insert(
          CategoriesCompanion.insert(
            name: name,
            kind: kind,
            icon: const drift.Value(null),
          ),
        );
    if (syncId.isNotEmpty) {
      await db.customStatement(
        '''
        UPDATE categories
        SET sync_id = ?, last_change_id = ?
        WHERE id = ?
        ''',
        [syncId, tx.lastChangeId, id],
      );
    }
    return id;
  }

  Future<int?> _resolveAccountLocalId({
    required int ledgerId,
    String? syncId,
    String? name,
  }) async {
    final normalizedSyncId = syncId?.trim() ?? '';
    if (normalizedSyncId.isNotEmpty) {
      final id = await _queryLocalIdBySyncId(
        table: 'accounts',
        syncId: normalizedSyncId,
      );
      if (id != null) return id;
    }
    final normalizedName = name?.trim() ?? '';
    if (normalizedName.isEmpty) return null;
    // BeeCount Cloud 模式下禁用名称回退
    int? id;
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      id = await _queryAccountIdByLedgerAndName(
        ledgerId: ledgerId,
        name: normalizedName,
      );
    }
    id ??= await db.into(db.accounts).insert(
          AccountsCompanion.insert(
            ledgerId: ledgerId,
            name: normalizedName,
            type: const drift.Value('cash'),
          ),
        );
    if (normalizedSyncId.isNotEmpty) {
      await db.customStatement(
        '''
        UPDATE accounts
        SET sync_id = ?
        WHERE id = ?
        ''',
        [normalizedSyncId, id],
      );
    }
    return id;
  }

  Future<List<int>> _resolveTagLocalIdsForTx(
      fcs.BeeCountCloudReadTransaction tx) async {
    final out = <int>{};
    for (final syncId in tx.tagIds) {
      final id = await _queryLocalIdBySyncId(table: 'tags', syncId: syncId);
      if (id != null) {
        out.add(id);
      }
    }
    for (final tagName in tx.tagsList) {
      final normalizedName = tagName.trim();
      if (normalizedName.isEmpty) continue;
      // BeeCount Cloud 模式下禁用名称回退
      int? id;
      if (config.type != fcs.CloudBackendType.beecountCloud) {
        id = await _queryTagIdByName(name: normalizedName);
      }
      id ??= await db.into(db.tags).insert(
            TagsCompanion.insert(name: normalizedName),
          );
      out.add(id);
    }
    return out.toList(growable: false);
  }

  Future<void> _replaceTransactionTags({
    required int transactionId,
    required List<int> tagIds,
  }) async {
    await db.customStatement(
      'DELETE FROM transaction_tags WHERE transaction_id = ?',
      [transactionId],
    );
    if (tagIds.isEmpty) return;
    final unique = tagIds.toSet();
    for (final tagId in unique) {
      await db.customStatement(
        'INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (?, ?)',
        [transactionId, tagId],
      );
    }
  }

  Future<void> _replaceTransactionAttachments({
    required int transactionId,
    required List<Map<String, dynamic>>? attachments,
  }) async {
    await db.customStatement(
      'DELETE FROM transaction_attachments WHERE transaction_id = ?',
      [transactionId],
    );
    if (attachments == null || attachments.isEmpty) {
      return;
    }
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < attachments.length; i++) {
      final row = attachments[i];
      final fileName = (row['fileName'] as String?)?.trim() ?? '';
      if (fileName.isEmpty) continue;
      final originalName = _nullIfBlank(row['originalName'] as String?);
      final fileSize = _toIntOrNull(row['fileSize']);
      final width = _toIntOrNull(row['width']);
      final height = _toIntOrNull(row['height']);
      final sortOrder = _toIntOrNull(row['sortOrder']) ?? i;
      await db.customStatement(
        '''
        INSERT INTO transaction_attachments (
          transaction_id, file_name, original_name, file_size, width, height, sort_order, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          transactionId,
          fileName,
          originalName,
          fileSize,
          width,
          height,
          sortOrder,
          nowSec,
        ],
      );
    }
  }

  Future<void> _upsertLedgerSyncState({
    required String ledgerSyncId,
    required int lastChangeId,
  }) async {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      '''
      INSERT INTO sync_state (ledger_sync_id, last_change_id, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(ledger_sync_id) DO UPDATE SET
        last_change_id = CASE
          WHEN excluded.last_change_id > sync_state.last_change_id THEN excluded.last_change_id
          ELSE sync_state.last_change_id
        END,
        updated_at = excluded.updated_at
      ''',
      [ledgerSyncId, lastChangeId, nowSec],
    );
  }

  Future<Set<String>> _loadPendingEntitySyncIds({
    required String ledgerSyncId,
    required String entityType,
  }) async {
    final rows = await db.customSelect(
      '''
      SELECT entity_sync_id
      FROM sync_queue
      WHERE ledger_sync_id = ? AND entity_type = ? AND status = 'pending' AND source = 'local'
      ''',
      variables: [
        drift.Variable.withString(ledgerSyncId),
        drift.Variable.withString(entityType),
      ],
    ).get();
    final out = <String>{};
    for (final row in rows) {
      final syncId = (row.data['entity_sync_id']?.toString() ?? '').trim();
      if (syncId.isNotEmpty) {
        out.add(syncId);
      }
    }
    return out;
  }

  String _kindNameKey({required String kind, required String name}) {
    return '${kind.trim().toLowerCase()}|${name.trim().toLowerCase()}';
  }

  int? _toIntOrNull(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  String? _nullIfBlank(String? raw) {
    final normalized = raw?.trim() ?? '';
    if (normalized.isEmpty) return null;
    return normalized;
  }

  // ignore: unused_element
  Future<int?> _applyRemoteLedgerChange(
      fcs.BeeCountCloudSyncChange change) async {
    final remoteLedgerId = await _resolveLocalLedgerId(change.ledgerId);
    if (remoteLedgerId == null && change.action == 'delete') {
      return null;
    }

    if (change.action == 'delete') {
      if (remoteLedgerId == null) {
        return null;
      }
      _statusCache.remove(remoteLedgerId);
      _recentUpload.remove(remoteLedgerId);
      return remoteLedgerId;
    }

    if (remoteLedgerId == null) {
      return null;
    }

    final applyStartedAt = DateTime.now();
    onRemoteApplyStateChanged?.call(remoteLedgerId, true);
    try {
      final remoteContent =
          await _provider!.storage.download(path: change.ledgerId);
      if (remoteContent == null) {
        return null;
      }

      final payload = _tryDecodePayload(remoteContent);
      final remoteFingerprint =
          payload == null ? null : _contentFingerprintFromMap(payload);
      final remoteCount = payload == null
          ? null
          : ((payload['count'] as num?)?.toInt() ??
              (payload['items'] as List?)?.length ??
              0);
      final remoteExportedAt = payload == null
          ? _parseDateTimeOrNull(change.updatedAt)
          : _parseDateTimeOrNull(payload['exportedAt']) ??
              _parseDateTimeOrNull(change.updatedAt);

      void cacheAlignedStatus(int ledgerId) {
        if (remoteFingerprint == null || remoteCount == null) {
          _statusCache.remove(ledgerId);
          return;
        }
        _statusCache[ledgerId] = SyncStatus(
          diff: SyncDiff.inSync,
          localCount: remoteCount,
          localFingerprint: remoteFingerprint,
          cloudCount: remoteCount,
          cloudFingerprint: remoteFingerprint,
          cloudExportedAt: remoteExportedAt ?? DateTime.now(),
        );
      }

      final ledger = await (db.select(db.ledgers)
            ..where((t) => t.id.equals(remoteLedgerId)))
          .getSingleOrNull();
      if (ledger != null) {
        if (payload != null) {
          await _downloadMissingCategoryIcons(
            payload: payload,
            ledgerId: remoteLedgerId,
            stage: 'apply_change',
          );
        }
        final importContent =
            payload == null ? remoteContent : jsonEncode(payload);
        await _runWithLocalMutationSuppressed(() {
          return importTransactionsJson(
            repo,
            remoteLedgerId,
            importContent,
            mode: ImportMode.replace,
          );
        });
        unawaited(_downloadMissingAttachments(
          payload: payload,
          ledgerId: remoteLedgerId,
          stage: 'apply_change',
        ));
        cacheAlignedStatus(remoteLedgerId);
        _ledgerSyncIdCache[remoteLedgerId] = change.ledgerId;
        _recentLocalChangeAt.remove(remoteLedgerId);
        _recentUpload.remove(remoteLedgerId);
        logger.info('CloudSync', '已应用远端更新: ${change.ledgerId}');
        return remoteLedgerId;
      }

      if (payload == null) {
        logger.warning('CloudSync', '远端快照格式无效，无法创建本地账本: ${change.ledgerId}');
        return null;
      }

      try {
        final name = payload['ledgerName'] as String? ??
            payload['name'] as String? ??
            'Imported';
        final currency = payload['currency'] as String? ?? 'CNY';
        final ledgerId = await downloadRemoteLedger(
          name: name,
          currency: currency,
          remotePath: change.ledgerId,
        );
        logger.info('CloudSync', '已拉取新远端账本: ${change.ledgerId}');
        if (ledgerId != null) {
          await _downloadMissingCategoryIcons(
            payload: payload,
            ledgerId: ledgerId,
            stage: 'apply_new_ledger',
          );
          cacheAlignedStatus(ledgerId);
          _ledgerSyncIdCache[ledgerId] = change.ledgerId;
          unawaited(_downloadMissingAttachments(
            payload: payload,
            ledgerId: ledgerId,
            stage: 'apply_new_ledger',
          ));
        }
        return ledgerId;
      } catch (e) {
        logger.warning('CloudSync', '应用远端账本失败(${change.ledgerId}): $e');
        return null;
      }
    } finally {
      const minVisible = Duration(milliseconds: 300);
      final elapsed = DateTime.now().difference(applyStartedAt);
      if (elapsed < minVisible) {
        await Future.delayed(minVisible - elapsed);
      }
      onRemoteApplyStateChanged?.call(remoteLedgerId, false);
    }
  }

  Map<String, dynamic>? _tryDecodePayload(String raw) {
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  DateTime? _parseDateTimeOrNull(Object? value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  int? _extractLedgerId(String remotePath) {
    final normalized = remotePath.trim();
    final match = RegExp(r'^ledger_(\d+)\.json$').firstMatch(normalized);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  Future<int?> _resolveLocalLedgerId(String remoteLedgerSyncId) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      final byLegacyPath = _extractLedgerId(remoteLedgerSyncId);
      if (byLegacyPath != null) {
        return byLegacyPath;
      }
    }
    try {
      final row = await db.customSelect(
        'SELECT id FROM ledgers WHERE sync_id = ? LIMIT 1',
        variables: [drift.Variable.withString(remoteLedgerSyncId)],
      ).getSingleOrNull();
      final raw = row?.data['id'];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      if (raw is String) return int.tryParse(raw);
    } catch (_) {}
    return null;
  }

  Future<int> _queryLedgerTransactionCount(int ledgerId) async {
    final row = await db.customSelect(
      '''
      SELECT COUNT(*) AS c
      FROM transactions
      WHERE ledger_id = ?
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).getSingleOrNull();
    return _toIntOrNull(row?.data['c']) ?? 0;
  }

  int _rememberRemoteDisplayId(String remoteLedgerSyncId) {
    final shouldKeepLegacyDisplayId =
        config.type != fcs.CloudBackendType.beecountCloud;
    final legacyId =
        shouldKeepLegacyDisplayId ? _extractLedgerId(remoteLedgerSyncId) : null;
    var displayId = legacyId ?? -remoteLedgerSyncId.hashCode.abs();
    if (displayId == 0) {
      displayId = -1;
    }
    _remoteLedgerDisplayIdToSyncId[displayId] = remoteLedgerSyncId;
    return displayId;
  }

  String? _resolveRemoteLedgerSyncIdFromDisplayId(int displayId) {
    return _remoteLedgerDisplayIdToSyncId[displayId];
  }

  String _sanitizeSyncNamespaceComponent(String raw) {
    final normalized = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return 'anon';
  }

  String _buildNamespacedPersonalLedgerSyncId({
    required int ledgerId,
    required String userId,
  }) {
    final safeUserId = _sanitizeSyncNamespaceComponent(userId);
    return 'local_${safeUserId}_ledger_$ledgerId.json';
  }

  Future<void> _rebindLedgerSyncIdReferences({
    required String fromSyncId,
    required String toSyncId,
  }) async {
    final from = fromSyncId.trim();
    final to = toSyncId.trim();
    if (from.isEmpty || to.isEmpty || from == to) {
      return;
    }
    await db.customStatement(
      '''
      UPDATE sync_queue
      SET ledger_sync_id = ?
      WHERE ledger_sync_id = ? AND source = 'local'
      ''',
      [to, from],
    );
    await db.customStatement(
      '''
      DELETE FROM sync_state
      WHERE ledger_sync_id = ?
      ''',
      [to],
    );
    await db.customStatement(
      '''
      UPDATE sync_state
      SET ledger_sync_id = ?
      WHERE ledger_sync_id = ?
      ''',
      [to, from],
    );
  }

  Future<void> _copyRemoteSnapshotIfMissing({
    required String fromPath,
    required String toPath,
  }) async {
    final from = fromPath.trim();
    final to = toPath.trim();
    if (from.isEmpty || to.isEmpty || from == to) {
      return;
    }
    final provider = _provider;
    if (provider == null) {
      return;
    }
    try {
      final targetSnapshot = await provider.storage.download(path: to);
      if (targetSnapshot != null) {
        return;
      }
      final sourceSnapshot = await provider.storage.download(path: from);
      if (sourceSnapshot == null) {
        return;
      }
      await provider.storage.upload(
        path: to,
        data: sourceSnapshot,
        metadata: <String, String>{
          'migrated_from': from,
          'migrated_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
      logger.info('CloudSync', '已复制旧备份路径到新路径: $from -> $to');
    } catch (e) {
      logger.warning('CloudSync', '复制旧备份路径失败(忽略): $from -> $to, $e');
    }
  }

  Future<bool> _ledgerHasAnonymousTransactions(int ledgerId) async {
    final row = await db.customSelect(
      '''
      SELECT COUNT(*) AS c
      FROM transactions
      WHERE ledger_id = ? AND (created_by_user_id IS NULL OR TRIM(created_by_user_id) = '')
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).getSingleOrNull();
    return (_toIntOrNull(row?.data['c']) ?? 0) > 0;
  }

  Future<void> _runOneTimeLedgerSyncIdRepair() async {
    if (_ledgerSyncIdRepairInProgress ||
        config.type != fcs.CloudBackendType.beecountCloud) {
      return;
    }
    final repairUserIdRaw = await _currentBeeCountCloudUserId();
    final repairUserId = (repairUserIdRaw ?? '').trim().isNotEmpty
        ? repairUserIdRaw?.trim()
        : null;
    if (_ledgerSyncIdRepairDone && _ledgerSyncIdRepairUserId == repairUserId) {
      return;
    }
    _ledgerSyncIdRepairInProgress = true;
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      _ledgerSyncIdRepairInProgress = false;
      return;
    }
    try {
      final remoteLedgers = await provider.readLedgers();
      if (remoteLedgers.isEmpty) {
        _knownRemoteLedgerSyncIds.clear();
        _ledgerSyncIdRepairUserId = repairUserId;
        return;
      }
      _knownRemoteLedgerSyncIds
        ..clear()
        ..addAll(
          remoteLedgers
              .map((ledger) => ledger.ledgerId.trim())
              .where((value) => value.isNotEmpty),
        );
      final bySyncId = <String, fcs.BeeCountCloudReadLedger>{};
      for (final remote in remoteLedgers) {
        final syncId = remote.ledgerId.trim();
        if (syncId.isEmpty) continue;
        bySyncId[syncId] = remote;
      }
      final currentUserId = repairUserId;

      final localRows = await db.customSelect(
        '''
        SELECT id, name, currency, sync_id, type
        FROM ledgers
        ORDER BY id ASC
        ''',
      ).get();
      for (final local in localRows) {
        final localLedgerId = _toIntOrNull(local.data['id']);
        if (localLedgerId == null) continue;
        final localName = (local.data['name']?.toString() ?? '').trim();
        final localCurrency =
            (local.data['currency']?.toString() ?? '').trim().toUpperCase();
        final localSyncId = (local.data['sync_id']?.toString() ?? '').trim();
        final localType =
            (local.data['type']?.toString() ?? '').trim().toLowerCase();
        final remoteByCurrentSyncId =
            localSyncId.isEmpty ? null : bySyncId[localSyncId];
        final collidesWithRemoteShared =
            remoteByCurrentSyncId?.isShared == true;
        final desiredPersonalSyncId = _buildNamespacedPersonalLedgerSyncId(
          ledgerId: localLedgerId,
          userId: currentUserId ?? 'anon',
        );

        if (localType == 'personal') {
          var shouldRemapPersonal = collidesWithRemoteShared;
          if (!shouldRemapPersonal && localSyncId.isNotEmpty) {
            final isLegacyPersonalSyncId =
                _isLegacySnapshotLedgerSyncId(localSyncId) &&
                    !bySyncId.containsKey(localSyncId);
            final isDifferentUserNamespace =
                _isNamespacedPersonalLedgerSyncId(localSyncId) &&
                    localSyncId != desiredPersonalSyncId &&
                    !bySyncId.containsKey(localSyncId);
            shouldRemapPersonal =
                isLegacyPersonalSyncId || isDifferentUserNamespace;
          }
          if (shouldRemapPersonal && desiredPersonalSyncId != localSyncId) {
            await db.customStatement(
              '''
              UPDATE ledgers
              SET sync_id = ?, type = 'personal'
              WHERE id = ?
              ''',
              [desiredPersonalSyncId, localLedgerId],
            );
            if (localSyncId.isNotEmpty) {
              await _rebindLedgerSyncIdReferences(
                fromSyncId: localSyncId,
                toSyncId: desiredPersonalSyncId,
              );
              await _copyRemoteSnapshotIfMissing(
                fromPath: localSyncId,
                toPath: desiredPersonalSyncId,
              );
            }
            _ledgerSyncIdCache[localLedgerId] = desiredPersonalSyncId;
            logger.warning(
              'CloudSync',
              '检测到个人账本 sync_id 需要收敛，已自动重映射: ledgerId=$localLedgerId, from=$localSyncId, to=$desiredPersonalSyncId',
            );
          } else if (localSyncId.isNotEmpty) {
            _ledgerSyncIdCache[localLedgerId] = localSyncId;
          }
          continue;
        }

        if (localType == 'shared' &&
            collidesWithRemoteShared &&
            _isLegacySnapshotLedgerSyncId(localSyncId)) {
          final legacyId = _extractLedgerId(localSyncId);
          if (legacyId != null && legacyId == localLedgerId) {
            final hasAnonymous =
                await _ledgerHasAnonymousTransactions(localLedgerId);
            final remoteName =
                (remoteByCurrentSyncId?.ledgerName ?? '').trim().toLowerCase();
            final remoteCurrency =
                (remoteByCurrentSyncId?.currency ?? '').trim().toUpperCase();
            final identityMismatch = remoteName.isNotEmpty &&
                localName.isNotEmpty &&
                (localName.toLowerCase() != remoteName ||
                    (remoteCurrency.isNotEmpty &&
                        localCurrency.isNotEmpty &&
                        localCurrency != remoteCurrency));
            if (hasAnonymous || identityMismatch) {
              await db.customStatement(
                '''
                UPDATE ledgers
                SET sync_id = ?, type = 'personal'
                WHERE id = ?
                ''',
                [desiredPersonalSyncId, localLedgerId],
              );
              await _rebindLedgerSyncIdReferences(
                fromSyncId: localSyncId,
                toSyncId: desiredPersonalSyncId,
              );
              await _copyRemoteSnapshotIfMissing(
                fromPath: localSyncId,
                toPath: desiredPersonalSyncId,
              );
              _ledgerSyncIdCache[localLedgerId] = desiredPersonalSyncId;
              logger.warning(
                'CloudSync',
                '检测到可疑共享映射污染，已将账本回退为个人路径: ledgerId=$localLedgerId, from=$localSyncId, to=$desiredPersonalSyncId',
              );
              continue;
            }
          }
        }

        if (localType != 'shared') {
          if (localSyncId.isNotEmpty) {
            _ledgerSyncIdCache[localLedgerId] = localSyncId;
          }
          continue;
        }

        fcs.BeeCountCloudReadLedger? matched =
            localSyncId.isEmpty ? null : bySyncId[localSyncId];
        if (matched != null && !matched.isShared) {
          matched = null;
        }
        if (matched == null) continue;

        final targetSyncId = matched.ledgerId.trim();
        if (targetSyncId.isEmpty) continue;
        final targetType = matched.isShared ? 'shared' : 'personal';
        await db.customStatement(
          '''
          UPDATE ledgers
          SET sync_id = ?, type = ?, name = ?, currency = ?
          WHERE id = ?
          ''',
          [
            targetSyncId,
            targetType,
            matched.ledgerName,
            matched.currency,
            localLedgerId,
          ],
        );
        if (localSyncId.isNotEmpty && localSyncId != targetSyncId) {
          await _rebindLedgerSyncIdReferences(
            fromSyncId: localSyncId,
            toSyncId: targetSyncId,
          );
        }
        _ledgerSyncIdCache[localLedgerId] = targetSyncId;
        final normalizedRole = matched.role.trim().toLowerCase();
        if (normalizedRole.isNotEmpty) {
          _ledgerRoleCache[targetSyncId] = normalizedRole;
          _ledgerRoleCacheByLocalId[localLedgerId] = normalizedRole;
        }
      }
      _ledgerSyncIdRepairDone = true;
      _ledgerSyncIdRepairUserId = repairUserId;
    } catch (e) {
      if (_isNotAuthenticatedError(e)) {
        _ledgerSyncIdRepairDone = true;
        _ledgerSyncIdRepairUserId = repairUserId;
        logger.debug('CloudSync', '一次性账本映射修复跳过（未登录）');
      } else {
        logger.warning('CloudSync', '一次性账本映射修复失败(忽略): $e');
      }
    } finally {
      _ledgerSyncIdRepairInProgress = false;
    }
  }

  Future<void> reconcileBeeCountCloudLedgerIdentity() async {
    await _ensureInitialized();
    await _runOneTimeLedgerSyncIdRepair();
  }

  Future<void> dispose() async {
    await _localMutationSubscription?.cancel();
    _localMutationSubscription = null;
    await _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;

    final provider = _provider;
    if (provider is fcs.BeeCountCloudProvider) {
      await provider.stopRealtime();
    }
    if (provider != null) {
      await provider.dispose();
    }
    _provider = null;
    _syncManager = null;
  }

  /// 获取本地最大发生时间（用于方向判断）
  DateTime? _getLocalUpdatedAt(int ledgerId) {
    // 优先使用最近修改时间
    final recentChange = _recentLocalChangeAt[ledgerId];
    if (recentChange != null) {
      return recentChange;
    }

    // TODO: 可以从数据库查询最大 happenedAt
    // 暂时返回 null，让包使用 count 判断
    return null;
  }

  Future<bool> _shouldTreatBeeCountCloudOutOfSyncAsInSync(int ledgerId) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return false;
    }
    final row = await db.customSelect(
      '''
      SELECT type, sync_id
      FROM ledgers
      WHERE id = ?
      LIMIT 1
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).getSingleOrNull();
    if (row == null) {
      return false;
    }
    final ledgerType =
        (row.data['type']?.toString() ?? '').trim().toLowerCase();
    if (ledgerType != 'shared') {
      return false;
    }
    final ledgerSyncId = (row.data['sync_id']?.toString() ?? '').trim();
    if (ledgerSyncId.isEmpty || _isLegacySnapshotLedgerSyncId(ledgerSyncId)) {
      return false;
    }
    return true;
  }

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    await _ensureInitialized();

    if (_syncManager == null || _provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始上传账本 $ledgerId');
      final isSharedLedger = await _isSharedLedgerLocal(ledgerId);
      String remotePath;
      var sharedCollabMode = false;
      if (config.type == fcs.CloudBackendType.beecountCloud && isSharedLedger) {
        final collabLedgerSyncId = await _collabLedgerSyncIdOrNull(ledgerId);
        if (collabLedgerSyncId == null || collabLedgerSyncId.isEmpty) {
          throw fcs.CloudSyncException(
            'Shared ledger sync id is not ready',
          );
        }
        remotePath = collabLedgerSyncId;
        sharedCollabMode = true;
      } else {
        remotePath = await _pathForLedger(ledgerId);
      }
      if (config.type == fcs.CloudBackendType.beecountCloud) {
        await _requeueFailedMutationsForLedger(ledgerSyncId: remotePath);
        _hasPendingPush = true;
        _pendingPushReason = 'manual_upload';
        await _drainPushQueue();
      }

      // 上传前先计算本地指纹（用于记录上传快照）
      String? localFp;
      int? localCount;
      if (config.type == fcs.CloudBackendType.beecountCloud &&
          _provider is fcs.BeeCountCloudProvider) {
        final jsonStr = await exportTransactionsJson(db, ledgerId);
        final rawMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        final uploadMap = await _attachCloudAttachmentRefsIfNeeded(
          ledgerId: ledgerId,
          payload: rawMap,
        );
        final uploadData = jsonEncode(uploadMap);
        try {
          localFp = _contentFingerprintFromMap(uploadMap);
          localCount = (uploadMap['count'] as num?)?.toInt();
        } catch (e) {
          logger.warning('CloudSync', '计算本地指纹失败: $e');
        }
        if (!sharedCollabMode) {
          await _provider!.storage.upload(
            path: remotePath,
            data: uploadData,
            metadata: {
              if (localFp != null) 'fingerprint': localFp,
              'version': '2',
              'uploadedAt': DateTime.now().toUtc().toIso8601String(),
              'ledgerId': ledgerId.toString(),
            },
          );
        }
      } else {
        try {
          final jsonStr = await exportTransactionsJson(db, ledgerId);
          final map = jsonDecode(jsonStr) as Map<String, dynamic>;
          localFp = _contentFingerprintFromMap(map);
          localCount = (map['count'] as num?)?.toInt();
        } catch (e) {
          logger.warning('CloudSync', '计算本地指纹失败: $e');
        }
        await _syncManager!.upload(
          data: ledgerId,
          path: remotePath,
          metadata: {
            'version': '2',
            'uploadedAt': DateTime.now().toUtc().toIso8601String(),
            'ledgerId': ledgerId.toString(),
          },
        );
      }

      // 记录近期上传，用于处理 CDN 缓存延迟
      if (localFp != null && localCount != null) {
        _recentUpload[ledgerId] = _RecentUpload(
          at: DateTime.now(),
          fp: localFp,
          count: localCount,
        );
        // 立即更新缓存为"已同步"状态
        _statusCache[ledgerId] = SyncStatus(
          diff: SyncDiff.inSync,
          localCount: localCount,
          localFingerprint: localFp,
          cloudCount: localCount,
          cloudFingerprint: localFp,
          cloudExportedAt: DateTime.now(),
        );
      } else {
        // 指纹计算失败，清除缓存等待下次查询
        _statusCache.remove(ledgerId);
      }

      // 清除本地变更标记
      _recentLocalChangeAt.remove(ledgerId);
      unawaited(_markPushState(ledgerSyncId: remotePath));
      if (sharedCollabMode) {
        _queueIncrementalPull(reason: 'manual_upload');
      }

      logger.info('CloudSync', '上传完成: $ledgerId');
    } catch (e, stack) {
      logger.error('CloudSync', '上传失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) async {
    await _ensureInitialized();

    if (_provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始下载账本 $ledgerId');
      final isSharedLedger = await _isSharedLedgerLocal(ledgerId);
      if (config.type == fcs.CloudBackendType.beecountCloud && isSharedLedger) {
        final collabLedgerSyncId = await _cloudLedgerExternalId(ledgerId);
        final beforeCount = await _queryLedgerTransactionCount(ledgerId);
        final appliedLedgerId =
            await _applyRemoteLedgerProjection(collabLedgerSyncId);
        if (appliedLedgerId == null) {
          return (inserted: 0, deletedDup: 0);
        }
        final afterCount = await _queryLedgerTransactionCount(appliedLedgerId);
        _statusCache.remove(appliedLedgerId);
        _recentLocalChangeAt.remove(appliedLedgerId);
        _recentUpload.remove(appliedLedgerId);
        return (
          inserted: (afterCount - beforeCount).clamp(0, 1 << 30).toInt(),
          deletedDup: 0,
        );
      }
      final remotePath = await _pathForLedger(ledgerId);

      // 直接使用 storage 下载原始 JSON 字符串
      final jsonStr = await _provider!.storage.download(path: remotePath);

      if (jsonStr == null) {
        logger.warning('CloudSync', '云端备份不存在');
        return (inserted: 0, deletedDup: 0);
      }

      final payload = _tryDecodePayload(jsonStr);
      if (payload != null) {
        await _downloadMissingCategoryIcons(
          payload: payload,
          ledgerId: ledgerId,
          stage: 'manual_download',
        );
      }
      final importContent = payload == null ? jsonStr : jsonEncode(payload);

      // 导入数据
      final result = await _runWithLocalMutationSuppressed(() {
        return importTransactionsJson(
          repo,
          ledgerId,
          importContent,
          mode: ImportMode.merge,
        );
      });
      unawaited(_downloadMissingAttachments(
        payload: payload,
        ledgerId: ledgerId,
        stage: 'manual_download',
      ));

      logger.info('CloudSync', '下载完成: inserted=${result.inserted}');

      // 清除缓存
      _statusCache.remove(ledgerId);
      _recentLocalChangeAt.remove(ledgerId);
      _recentUpload.remove(ledgerId);

      return (
        inserted: result.inserted,
        deletedDup: 0,
      );
    } catch (e, stack) {
      logger.error('CloudSync', '下载失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);

      // 如果是 404,返回空结果
      if (e.toString().contains('404') || e.toString().contains('not found')) {
        return (inserted: 0, deletedDup: 0);
      }

      rethrow;
    }
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async {
    await _ensureInitialized();

    // 如果 provider 不可用，返回未登录状态
    if (_syncManager == null || _provider == null) {
      return SyncStatus(
        diff: SyncDiff.notLoggedIn,
        localCount: 0,
        localFingerprint: '',
        message: '云服务不可用，请检查配置或登录状态',
      );
    }

    // 检查缓存
    final cached = _statusCache[ledgerId];
    if (cached != null) {
      return cached;
    }

    try {
      // 计算本地指纹
      final jsonStr = await exportTransactionsJson(db, ledgerId);
      final localMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final localFp = _contentFingerprintFromMap(localMap);
      final localCount = (localMap['count'] as num).toInt();

      // 若刚刚上传成功且在短时间窗口内（15秒），且本地指纹与上传时一致，直接认定已同步
      final ru = _recentUpload[ledgerId];
      if (ru != null) {
        final age = DateTime.now().difference(ru.at);
        if (age < const Duration(seconds: 15) && ru.fp == localFp) {
          final st = SyncStatus(
            diff: SyncDiff.inSync,
            localCount: localCount,
            localFingerprint: localFp,
            cloudCount: ru.count,
            cloudFingerprint: ru.fp,
            cloudExportedAt: ru.at,
          );
          _statusCache[ledgerId] = st;
          logger.info('CloudSync', '使用近期上传缓存: $ledgerId -> 已同步');
          return st;
        }
      }

      final treatOutOfSyncAsInSync =
          await _shouldTreatBeeCountCloudOutOfSyncAsInSync(ledgerId);
      if (treatOutOfSyncAsInSync) {
        final st = SyncStatus(
          diff: SyncDiff.inSync,
          localCount: localCount,
          localFingerprint: localFp,
          cloudCount: localCount,
          cloudFingerprint: localFp,
          cloudExportedAt: null,
        );
        _statusCache[ledgerId] = st;
        return st;
      }

      logger.info('CloudSync', '获取同步状态: $ledgerId');
      final remotePath = await _pathForLedger(ledgerId);

      // 调用包的 getStatus，传入时间戳用于方向判断
      final fcsStatus = await _syncManager!.getStatus(
          data: ledgerId,
          path: remotePath,
          localUpdatedAt: _getLocalUpdatedAt(ledgerId),
          forceRefresh: true);

      // 转换包的 SyncStatus 为 BeeCount 的 SyncStatus
      final status = _convertSyncStatus(
        fcsStatus,
        treatOutOfSyncAsInSync: treatOutOfSyncAsInSync,
      );

      _statusCache[ledgerId] = status;
      logger.info('CloudSync', '同步状态: $ledgerId -> ${status.diff}');

      return status;
    } catch (e, stack) {
      logger.error('CloudSync', '获取状态失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈: $stack', null);

      // 返回错误状态
      final status = SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: e.toString(),
      );

      _statusCache[ledgerId] = status;

      return status;
    }
  }

  /// 转换包的 SyncStatus 为 BeeCount 的 SyncStatus
  SyncStatus _convertSyncStatus(
    fcs.SyncStatus fcsStatus, {
    required bool treatOutOfSyncAsInSync,
  }) {
    SyncDiff diff;

    switch (fcsStatus.state) {
      case fcs.SyncState.notConfigured:
        diff = SyncDiff.notConfigured;
        break;
      case fcs.SyncState.notAuthenticated:
        diff = SyncDiff.notLoggedIn;
        break;
      case fcs.SyncState.localOnly:
        diff = SyncDiff.noRemote;
        break;
      case fcs.SyncState.synced:
        diff = SyncDiff.inSync;
        break;
      case fcs.SyncState.outOfSync:
        if (treatOutOfSyncAsInSync) {
          // 协同云模式不再使用“指纹差异=不同步”的备份语义，避免误导。
          diff = SyncDiff.inSync;
          break;
        }
        // 根据方向确定
        if (fcsStatus.direction == fcs.SyncDirection.localNewer) {
          diff = SyncDiff.localNewer;
        } else if (fcsStatus.direction == fcs.SyncDirection.cloudNewer) {
          diff = SyncDiff.cloudNewer;
        } else {
          diff = SyncDiff.different;
        }
        break;
      case fcs.SyncState.error:
        final message = (fcsStatus.message ?? '').toLowerCase();
        if (message.contains('not authenticated') ||
            message.contains('session expired') ||
            message.contains('unauthorized')) {
          diff = SyncDiff.notLoggedIn;
          break;
        }
        diff = SyncDiff.error;
        break;
      default:
        diff = SyncDiff.different;
    }

    return SyncStatus(
      diff: diff,
      localCount: fcsStatus.localCount ?? 0,
      cloudCount: fcsStatus.cloudCount,
      localFingerprint: fcsStatus.localFingerprint ?? '',
      cloudFingerprint: fcsStatus.cloudFingerprint,
      cloudExportedAt: fcsStatus.cloudUpdatedAt,
      message: fcsStatus.message,
    );
  }

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    await _ensureInitialized();

    try {
      logger.info('CloudSync', '刷新云端指纹: $ledgerId');
      final remotePath = await _pathForLedger(ledgerId);

      // 强制刷新状态
      final status = await _syncManager!.getStatus(
        data: ledgerId,
        path: remotePath,
        localUpdatedAt: _getLocalUpdatedAt(ledgerId),
        forceRefresh: true,
      );

      // 清除缓存以便下次 getStatus 重新获取
      _statusCache.remove(ledgerId);

      logger.info('CloudSync',
          '云端指纹: 指纹=${status.cloudFingerprint} 条数=${status.cloudCount} 时间=${status.cloudUpdatedAt}');

      return (
        fingerprint: status.cloudFingerprint,
        count: status.cloudCount,
        exportedAt: status.cloudUpdatedAt,
      );
    } catch (e) {
      logger.warning('CloudSync', '刷新云端指纹失败: $ledgerId - $e');
      return (fingerprint: null, count: null, exportedAt: null);
    }
  }

  @override
  void markLocalChanged({required int ledgerId}) {
    _statusCache.remove(ledgerId);
    _recentLocalChangeAt[ledgerId] = DateTime.now();
    if (config.type == fcs.CloudBackendType.beecountCloud) {
      _queuePush(reason: 'mark_local_changed');
    }
    logger.info('CloudSync', '标记本地变更: $ledgerId');
  }

  Future<List<int>> _resolveCandidateLedgerIdsForEvent(
      LocalMutationEvent event) async {
    if (event.ledgerId != null) {
      final ledgerId = event.ledgerId!;
      if (!await _isSharedLedgerLocal(ledgerId)) {
        return const [];
      }
      final collabLedgerSyncId = await _collabLedgerSyncIdOrNull(ledgerId);
      if (collabLedgerSyncId == null) {
        return const [];
      }
      return [ledgerId];
    }
    if (event.entityType != LocalMutationEntityType.category &&
        event.entityType != LocalMutationEntityType.tag) {
      return const [];
    }
    final rows = await db.customSelect(
      '''
      SELECT l.id
      FROM ledgers l
      WHERE l.type = 'shared'
      ORDER BY l.id ASC
      ''',
    ).get();
    final out = <int>[];
    for (final row in rows) {
      final id = _toIntOrNull(row.data['id']);
      if (id != null) {
        final syncId = await _collabLedgerSyncIdOrNull(id);
        if (syncId == null || syncId.isEmpty) {
          continue;
        }
        out.add(id);
      }
    }
    return out;
  }

  Future<void> _enqueueLocalMutationEvent(LocalMutationEvent event) async {
    try {
      if (event.entityType == LocalMutationEntityType.transaction &&
          event.action == LocalMutationAction.create &&
          event.ledgerId != null) {
        await _ensureLocalTransactionCreatorOnCreate(
          ledgerId: event.ledgerId!,
          transactionId: event.entityId,
        );
      }
      final ledgerIds = await _resolveCandidateLedgerIdsForEvent(event);
      if (ledgerIds.isEmpty) {
        return;
      }
      final now = DateTime.now().toUtc();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      final nowMs = now.millisecondsSinceEpoch;
      for (final ledgerId in ledgerIds) {
        final ledgerSyncId = await _collabLedgerSyncIdOrNull(ledgerId);
        if (ledgerSyncId == null || ledgerSyncId.isEmpty) {
          continue;
        }
        final payloadMap = <String, dynamic>{
          'source': 'app_local',
          'at': (event.occurredAt ?? now).toUtc().toIso8601String(),
          'local_ledger_id': ledgerId,
          'local_entity_id': event.entityId,
          'entity_type': event.entityType.name,
          'action': event.action.name,
        };
        var entitySyncId = (event.entitySyncId ?? '').trim();
        if (entitySyncId.isEmpty) {
          entitySyncId = await _resolveEntitySyncIdForQueue(
            event: event,
            ledgerSyncId: ledgerSyncId,
          );
        }
        if (entitySyncId.isEmpty) {
          continue;
        }
        payloadMap['entity_sync_id'] = entitySyncId;
        final requestId =
            'local-${event.entityType.name}-${event.action.name}-${event.entityId}-$ledgerId-$nowMs';
        final payload = jsonEncode({
          ...payloadMap,
        });
        await db.customStatement(
          '''
          INSERT INTO sync_queue (
            ledger_sync_id,
            entity_type,
            entity_sync_id,
            action,
            payload_json,
            request_id,
            idempotency_key,
            status,
            source,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 'local', ?, ?)
          ''',
          [
            ledgerSyncId,
            event.entityType.name,
            entitySyncId,
            event.action.name,
            payload,
            requestId,
            requestId,
            nowSec,
            nowSec,
          ],
        );
        await db.customStatement(
          '''
          INSERT INTO sync_state (ledger_sync_id, updated_at)
          VALUES (?, ?)
          ON CONFLICT(ledger_sync_id) DO UPDATE SET updated_at = excluded.updated_at
          ''',
          [ledgerSyncId, nowSec],
        );
      }
    } catch (e) {
      logger.debug('CloudSync', '本地实体变更入队失败(忽略): $e');
    }
  }

  Future<void> _ensureLocalTransactionCreatorOnCreate({
    required int ledgerId,
    required int transactionId,
  }) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return;
    }
    final isSharedLedger = await _isSharedLedgerLocal(ledgerId);
    if (!isSharedLedger) {
      return;
    }
    final currentUserId = await _currentBeeCountCloudUserId();
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }
    await db.customStatement(
      '''
      UPDATE transactions
      SET created_by_user_id = ?
      WHERE id = ? AND ledger_id = ? AND (created_by_user_id IS NULL OR TRIM(created_by_user_id) = '')
      ''',
      [currentUserId, transactionId, ledgerId],
    );
    onRemoteChangeApplied?.call({ledgerId});
  }

  Future<String> _resolveEntitySyncIdForQueue({
    required LocalMutationEvent event,
    required String ledgerSyncId,
  }) async {
    switch (event.entityType) {
      case LocalMutationEntityType.ledger:
        return ledgerSyncId;
      case LocalMutationEntityType.transaction:
        final existing = await _querySyncIdByTable(
          table: 'transactions',
          localId: event.entityId,
        );
        if (existing != null && existing.isNotEmpty) return existing;
        final fallback = 'tx_${event.ledgerId}_${event.entityId}';
        await _ensureLocalSyncId(
          table: 'transactions',
          localId: event.entityId,
          syncId: fallback,
        );
        return fallback;
      case LocalMutationEntityType.account:
        final existing = await _querySyncIdByTable(
          table: 'accounts',
          localId: event.entityId,
        );
        if (existing != null && existing.isNotEmpty) return existing;
        final fallback = 'account_${event.ledgerId}_${event.entityId}';
        await _ensureLocalSyncId(
          table: 'accounts',
          localId: event.entityId,
          syncId: fallback,
        );
        return fallback;
      case LocalMutationEntityType.category:
        final existing = await _querySyncIdByTable(
          table: 'categories',
          localId: event.entityId,
        );
        if (existing != null && existing.isNotEmpty) return existing;
        final fallback = 'category_${event.entityId}';
        await _ensureLocalSyncId(
          table: 'categories',
          localId: event.entityId,
          syncId: fallback,
        );
        return fallback;
      case LocalMutationEntityType.tag:
        final existing = await _querySyncIdByTable(
          table: 'tags',
          localId: event.entityId,
        );
        if (existing != null && existing.isNotEmpty) return existing;
        final fallback = 'tag_${event.entityId}';
        await _ensureLocalSyncId(
          table: 'tags',
          localId: event.entityId,
          syncId: fallback,
        );
        return fallback;
    }
  }

  Future<String?> _querySyncIdByTable({
    required String table,
    required int localId,
  }) async {
    final row = await db.customSelect(
      'SELECT sync_id FROM $table WHERE id = ? LIMIT 1',
      variables: [drift.Variable.withInt(localId)],
    ).getSingleOrNull();
    final raw = row?.data['sync_id']?.toString().trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return raw;
  }

  Future<void> _ensureLocalSyncId({
    required String table,
    required int localId,
    required String syncId,
  }) async {
    await db.customStatement(
      '''
      UPDATE $table
      SET sync_id = ?
      WHERE id = ? AND (sync_id IS NULL OR TRIM(sync_id) = '')
      ''',
      [syncId, localId],
    );
  }

  Future<void> _markPushState({
    required String ledgerSyncId,
    int? lastChangeId,
  }) async {
    try {
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await db.customStatement(
        '''
        INSERT INTO sync_state (ledger_sync_id, last_change_id, last_push_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(ledger_sync_id) DO UPDATE SET
          last_change_id = CASE
            WHEN excluded.last_change_id > sync_state.last_change_id THEN excluded.last_change_id
            ELSE sync_state.last_change_id
          END,
          last_push_at = excluded.last_push_at,
          updated_at = excluded.updated_at
        ''',
        [ledgerSyncId, lastChangeId ?? 0, nowSec, nowSec],
      );
    } catch (e) {
      logger.debug('CloudSync', '记录 push 状态失败(忽略): $e');
    }
  }

  Future<void> _markPullState({
    required int cursor,
    required Set<String> ledgerSyncIds,
  }) async {
    try {
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final targets =
          ledgerSyncIds.isEmpty ? <String>{'global'} : ledgerSyncIds;
      for (final ledgerSyncId in targets) {
        await db.customStatement(
          '''
          INSERT INTO sync_state (ledger_sync_id, server_cursor, last_pull_at, updated_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(ledger_sync_id) DO UPDATE SET
            server_cursor = CASE
              WHEN excluded.server_cursor > sync_state.server_cursor THEN excluded.server_cursor
              ELSE sync_state.server_cursor
            END,
            last_pull_at = excluded.last_pull_at,
            updated_at = excluded.updated_at
          ''',
          [ledgerSyncId, cursor, nowSec, nowSec],
        );
      }
    } catch (e) {
      logger.debug('CloudSync', '记录 pull 状态失败(忽略): $e');
    }
  }

  /// 从 JSON payload 计算内容指纹（与旧实现保持一致）
  String _contentFingerprintFromMap(Map<String, dynamic> payload) {
    return _snapshotFingerprintFromPayload(payload);
  }

  Future<Map<String, dynamic>> _attachCloudAttachmentRefsIfNeeded({
    required int ledgerId,
    required Map<String, dynamic> payload,
  }) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return payload;
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return payload;
    }
    final items = payload['items'];
    final txRows = items is List ? items : const <dynamic>[];

    final attachmentDir = await _getAttachmentDirectory();
    final bySha = <String, _AttachmentUploadCandidate>{};
    final txRefsBySha = <String, List<Map<String, dynamic>>>{};
    final categoryRefsBySha = <String, List<Map<String, dynamic>>>{};

    for (final row in txRows) {
      if (row is! Map<String, dynamic>) continue;
      final attachments = row['attachments'];
      if (attachments is! List) continue;
      for (final raw in attachments) {
        if (raw is! Map<String, dynamic>) continue;
        final fileName = (raw['fileName'] as String?)?.trim();
        if (fileName == null || fileName.isEmpty) continue;
        final file = File(path.join(attachmentDir.path, fileName));
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final sha = sha256.convert(bytes).toString();
        bySha.putIfAbsent(
          sha,
          () => _AttachmentUploadCandidate(
            fileName: fileName,
            bytes: bytes,
            mimeType: _guessMimeType(fileName),
          ),
        );
        txRefsBySha.putIfAbsent(sha, () => []).add(raw);
        raw['cloudSha256'] = sha;
      }
    }

    final categories = payload['categories'];
    if (categories is List) {
      for (final raw in categories) {
        if (raw is! Map<String, dynamic>) continue;
        final iconType = (raw['iconType'] as String?)?.trim().toLowerCase();
        if (iconType != 'custom') continue;
        final customIconPath = (raw['customIconPath'] as String?)?.trim() ?? '';
        if (customIconPath.isEmpty) continue;
        final iconFile = await _resolveCustomIconFile(customIconPath);
        if (iconFile == null) continue;
        final bytes = await iconFile.readAsBytes();
        if (bytes.isEmpty) continue;
        final sha = sha256.convert(bytes).toString();
        final fileName = path.basename(iconFile.path);
        bySha.putIfAbsent(
          sha,
          () => _AttachmentUploadCandidate(
            fileName: fileName,
            bytes: bytes,
            mimeType: _guessMimeType(fileName),
          ),
        );
        categoryRefsBySha.putIfAbsent(sha, () => []).add(raw);
        raw['iconCloudSha256'] = sha;
      }
    }

    if (bySha.isEmpty) {
      return payload;
    }

    final remoteLedgerId = await _pathForLedger(ledgerId);
    final existsMap = await provider.attachmentBatchExists(
      ledgerId: remoteLedgerId,
      sha256List: bySha.keys.toList(growable: false),
    );

    for (final entry in bySha.entries) {
      final sha = entry.key;
      final existing = existsMap[sha];
      String? fileId = existing?.fileId;
      if (fileId == null || fileId.isEmpty) {
        final uploaded = await provider.uploadAttachment(
          ledgerId: remoteLedgerId,
          bytes: entry.value.bytes,
          fileName: entry.value.fileName,
          mimeType: entry.value.mimeType,
        );
        fileId = uploaded.fileId;
      }
      if (fileId.isEmpty) continue;
      final txRefs = txRefsBySha[sha];
      if (txRefs != null) {
        for (final ref in txRefs) {
          ref['cloudFileId'] = fileId;
        }
      }
      final categoryRefs = categoryRefsBySha[sha];
      if (categoryRefs != null) {
        for (final ref in categoryRefs) {
          ref['iconCloudFileId'] = fileId;
        }
      }
    }

    return payload;
  }

  Future<File?> _resolveCustomIconFile(String customIconPath) async {
    final pathValue = customIconPath.trim();
    if (pathValue.isEmpty) return null;
    final direct = File(pathValue);
    if (await direct.exists()) {
      return direct;
    }
    try {
      final resolved = await CustomIconService().resolveIconPath(pathValue);
      final resolvedFile = File(resolved);
      if (await resolvedFile.exists()) {
        return resolvedFile;
      }
    } catch (_) {}
    return null;
  }

  Future<_MediaDownloadResult> _downloadMissingCategoryIcons({
    required Map<String, dynamic> payload,
    int? ledgerId,
    String stage = 'sync_apply',
  }) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return _MediaDownloadResult.empty;
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return _MediaDownloadResult.empty;
    }
    final categories = payload['categories'];
    if (categories is! List) {
      return _MediaDownloadResult.empty;
    }

    var downloaded = 0;
    var failed = 0;
    for (final raw in categories) {
      if (raw is! Map<String, dynamic>) continue;
      final iconType = (raw['iconType'] as String?)?.trim().toLowerCase();
      if (iconType != 'custom') continue;
      final fileId = (raw['iconCloudFileId'] as String?)?.trim();
      if (fileId == null || fileId.isEmpty) continue;

      var customIconPath = (raw['customIconPath'] as String?)?.trim() ?? '';
      if (customIconPath.isEmpty) {
        customIconPath = 'custom_icons/$fileId.png';
        raw['customIconPath'] = customIconPath;
      }
      final targetPath =
          await CustomIconService().resolveIconPath(customIconPath);
      final localFile = File(targetPath);
      if (await localFile.exists()) continue;

      try {
        final bytes = await provider.downloadAttachment(fileId: fileId);
        await localFile.parent.create(recursive: true);
        await localFile.writeAsBytes(bytes, flush: true);
        downloaded++;
      } catch (e) {
        failed++;
        logger.warning(
          'CloudSync',
          '[stage=$stage] 分类图标下载失败 '
              'ledgerId=${ledgerId ?? '-'} '
              'fileId=$fileId '
              'path=$customIconPath '
              'name=${raw['name'] ?? '-'}: $e',
        );
      }
    }
    return _MediaDownloadResult(downloaded: downloaded, failed: failed);
  }

  Future<_MediaDownloadResult> _downloadMissingAttachments({
    required Map<String, dynamic>? payload,
    int? ledgerId,
    String stage = 'sync_apply',
  }) async {
    if (payload == null || config.type != fcs.CloudBackendType.beecountCloud) {
      return _MediaDownloadResult.empty;
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return _MediaDownloadResult.empty;
    }
    final items = payload['items'];
    if (items is! List) {
      return _MediaDownloadResult.empty;
    }

    var downloaded = 0;
    var failed = 0;
    final attachmentDir = await _getAttachmentDirectory();
    final targets = <String, _AttachmentDownloadTarget>{};
    for (final row in items) {
      if (row is! Map<String, dynamic>) continue;
      final attachments = row['attachments'];
      if (attachments is! List) continue;
      for (final raw in attachments) {
        if (raw is! Map<String, dynamic>) continue;
        final fileName = (raw['fileName'] as String?)?.trim();
        final fileId = (raw['cloudFileId'] as String?)?.trim();
        if (fileName == null || fileName.isEmpty) continue;
        if (fileId == null || fileId.isEmpty) continue;
        targets.putIfAbsent(
          fileId,
          () => _AttachmentDownloadTarget(fileId: fileId, fileName: fileName),
        );
      }
    }

    for (final target in targets.values) {
      final file = File(path.join(attachmentDir.path, target.fileName));
      if (await file.exists()) continue;
      try {
        final bytes = await provider.downloadAttachment(fileId: target.fileId);
        await file.writeAsBytes(bytes, flush: true);
        downloaded++;
      } catch (e) {
        failed++;
        logger.warning(
          'CloudSync',
          '[stage=$stage] 附件下载失败 '
              'ledgerId=${ledgerId ?? '-'} '
              'fileId=${target.fileId} '
              'fileName=${target.fileName}: $e',
        );
      }
    }

    return _MediaDownloadResult(downloaded: downloaded, failed: failed);
  }

  Future<Directory> _getAttachmentDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(appDir.path, 'attachments'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String? _guessMimeType(String fileName) {
    switch (path.extension(fileName).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.heic':
        return 'image/heic';
      default:
        return null;
    }
  }

  fcs.BeeCountCloudProvider _requireBeeCountCloudProvider() {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      throw UnsupportedError('Current backend is not BeeCount Cloud');
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      throw fcs.CloudSyncException('BeeCount Cloud provider is unavailable');
    }
    return provider;
  }

  Future<String?> _currentBeeCountCloudUserId() async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return null;
    }
    final provider = _provider;
    if (provider is! fcs.BeeCountCloudProvider) {
      return null;
    }
    final user = await provider.auth.currentUser;
    final userId = user?.id.trim() ?? '';
    if (userId.isEmpty) {
      return null;
    }
    return userId;
  }

  Future<String?> ledgerRole({
    required int ledgerId,
    bool forceRefresh = false,
  }) async {
    final result = await resolveLedgerRole(
      ledgerId: ledgerId,
      forceRefresh: forceRefresh,
    );
    return result.role;
  }

  Future<LedgerRoleResolveResult> resolveLedgerRole({
    required int ledgerId,
    bool forceRefresh = false,
  }) async {
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return const LedgerRoleResolveResult.unavailable(
        detail: 'backend_not_beecount_cloud',
      );
    }
    try {
      await _ensureInitialized();
      final provider = _requireBeeCountCloudProvider();
      if (!forceRefresh) {
        final cachedByLocal = _ledgerRoleCacheByLocalId[ledgerId];
        if (cachedByLocal != null && cachedByLocal.isNotEmpty) {
          return LedgerRoleResolveResult.resolved(cachedByLocal);
        }
      }
      final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
      if (!forceRefresh) {
        final cached = _ledgerRoleCache[externalLedgerId];
        if (cached != null && cached.isNotEmpty) {
          _ledgerRoleCacheByLocalId[ledgerId] = cached;
          return LedgerRoleResolveResult.resolved(cached);
        }
      }
      final detail =
          await provider.readLedgerDetail(ledgerId: externalLedgerId);
      final normalizedRole = detail.role.trim().toLowerCase();
      if (normalizedRole.isEmpty) {
        return const LedgerRoleResolveResult.unavailable(detail: 'empty_role');
      }
      _ledgerRoleCache[externalLedgerId] = normalizedRole;
      _ledgerRoleCacheByLocalId[ledgerId] = normalizedRole;
      return LedgerRoleResolveResult.resolved(normalizedRole);
    } catch (e) {
      final lower = e.toString().toLowerCase();
      if (lower.contains('insufficient scope')) {
        return const LedgerRoleResolveResult.scopeDenied(
          detail: 'insufficient_scope',
        );
      }
      final cachedByLocal = _ledgerRoleCacheByLocalId[ledgerId];
      if (cachedByLocal != null && cachedByLocal.isNotEmpty) {
        return LedgerRoleResolveResult.resolved(cachedByLocal);
      }
      return LedgerRoleResolveResult.unavailable(detail: e.toString());
    }
  }

  Future<bool> _isSharedLedgerLocal(int ledgerId) async {
    final row = await db.customSelect(
      '''
      SELECT type
      FROM ledgers
      WHERE id = ?
      LIMIT 1
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).getSingleOrNull();
    if (row == null) {
      return false;
    }
    return (row.data['type']?.toString() ?? '').trim().toLowerCase() ==
        'shared';
  }

  Future<bool> _isCurrentUserLedgerOwnerLocal(int ledgerId) async {
    final currentUserId = await _currentBeeCountCloudUserId();
    if (currentUserId == null || currentUserId.isEmpty) {
      return false;
    }
    final row = await db.customSelect(
      '''
      SELECT created_by_user_id
      FROM ledgers
      WHERE id = ?
      LIMIT 1
      ''',
      variables: [drift.Variable.withInt(ledgerId)],
    ).getSingleOrNull();
    if (row == null) {
      return false;
    }
    final createdByUserId =
        (row.data['created_by_user_id']?.toString() ?? '').trim();
    return createdByUserId.isNotEmpty && createdByUserId == currentUserId;
  }

  String _normalizeRole(String? role) {
    final normalized = (role ?? '').trim().toLowerCase();
    if (normalized == 'owner' ||
        normalized == 'editor' ||
        normalized == 'viewer') {
      return normalized;
    }
    return '';
  }

  Future<bool> canWriteLedger({
    required int ledgerId,
  }) async {
    final result = await resolveLedgerRole(ledgerId: ledgerId);
    final role = result.role;
    if (role == null) {
      if (await _isSharedLedgerLocal(ledgerId)) {
        if (result.status == LedgerRoleResolveStatus.scopeDenied) {
          return false;
        }
        final cached = _normalizeRole(_ledgerRoleCacheByLocalId[ledgerId]);
        if (cached == 'owner' || cached == 'editor') {
          return true;
        }
        if (await _isCurrentUserLedgerOwnerLocal(ledgerId)) {
          return true;
        }
        final currentUserId = await _currentBeeCountCloudUserId();
        if (currentUserId != null && currentUserId.isNotEmpty) {
          if (result.status == LedgerRoleResolveStatus.unavailable) {
            // Experimental mode fallback: prefer availability over false-negative
            // lockouts, while server-side write policy remains the final guard.
            return true;
          }
          final row = await db.customSelect(
            '''
            SELECT id
            FROM transactions
            WHERE ledger_id = ? AND created_by_user_id = ?
            LIMIT 1
            ''',
            variables: [
              drift.Variable.withInt(ledgerId),
              drift.Variable.withString(currentUserId),
            ],
          ).getSingleOrNull();
          if (row != null) {
            return true;
          }
        }
        return false;
      }
      return true;
    }
    return role == 'owner' || role == 'editor';
  }

  Future<bool> canManageLedger({
    required int ledgerId,
  }) async {
    final result = await resolveLedgerRole(ledgerId: ledgerId);
    final role = result.role;
    if (role == null) {
      if (await _isSharedLedgerLocal(ledgerId)) {
        if (result.status == LedgerRoleResolveStatus.scopeDenied) {
          return false;
        }
        final cached = _normalizeRole(_ledgerRoleCacheByLocalId[ledgerId]);
        if (cached == 'owner') {
          return true;
        }
        if (await _isCurrentUserLedgerOwnerLocal(ledgerId)) {
          return true;
        }
        return false;
      }
      return true;
    }
    return role == 'owner';
  }

  Future<bool> canModifyTransaction({
    required int ledgerId,
    required int transactionId,
  }) async {
    final result = await resolveLedgerRole(ledgerId: ledgerId);
    final role = result.role;
    if (role == null) {
      if (await _isSharedLedgerLocal(ledgerId)) {
        if (result.status == LedgerRoleResolveStatus.scopeDenied) {
          return false;
        }
        final cached = _normalizeRole(_ledgerRoleCacheByLocalId[ledgerId]);
        if (cached == 'owner') {
          return true;
        }
        if (await _isCurrentUserLedgerOwnerLocal(ledgerId)) {
          return true;
        }
        final currentUserId = await _currentBeeCountCloudUserId();
        if (currentUserId == null || currentUserId.isEmpty) {
          return false;
        }
        final row = await db.customSelect(
          '''
          SELECT created_by_user_id
          FROM transactions
          WHERE id = ? AND ledger_id = ?
          LIMIT 1
          ''',
          variables: [
            drift.Variable.withInt(transactionId),
            drift.Variable.withInt(ledgerId),
          ],
        ).getSingleOrNull();
        if (row == null) {
          if (result.status == LedgerRoleResolveStatus.unavailable) {
            return true;
          }
          return false;
        }
        final createdByUserId =
            (row.data['created_by_user_id']?.toString() ?? '').trim();
        if (createdByUserId.isEmpty &&
            result.status == LedgerRoleResolveStatus.unavailable) {
          return true;
        }
        return createdByUserId.isNotEmpty && createdByUserId == currentUserId;
      }
      return true;
    }
    if (role == 'owner') {
      return true;
    }
    if (role == 'viewer') {
      return false;
    }
    if (role != 'editor') {
      return false;
    }

    final row = await db.customSelect(
      '''
      SELECT created_by_user_id
      FROM transactions
      WHERE id = ? AND ledger_id = ?
      LIMIT 1
      ''',
      variables: [
        drift.Variable.withInt(transactionId),
        drift.Variable.withInt(ledgerId),
      ],
    ).getSingleOrNull();
    if (row == null) {
      return false;
    }
    final createdByUserId =
        (row.data['created_by_user_id']?.toString() ?? '').trim();
    if (createdByUserId.isEmpty) {
      return false;
    }
    final currentUserId = await _currentBeeCountCloudUserId();
    if (currentUserId == null || currentUserId.isEmpty) {
      return false;
    }
    return createdByUserId == currentUserId;
  }

  Future<String> _cloudLedgerExternalId(int ledgerId) async {
    await _runOneTimeLedgerSyncIdRepair();
    final collabLedgerSyncId = await _collabLedgerSyncIdOrNull(ledgerId);
    if (collabLedgerSyncId == null || collabLedgerSyncId.isEmpty) {
      throw fcs.CloudSyncException(
        'Ledger collaborative sync id is not ready',
      );
    }
    return collabLedgerSyncId;
  }

  Future<List<fcs.BeeCountCloudShareMember>> listShareMembers({
    required int ledgerId,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
    return provider.listShareMembers(
      ledgerId: externalLedgerId,
    );
  }

  Future<LocalSyncQueueSummary> getLocalQueueSummary({
    required int ledgerId,
  }) async {
    await _ensureInitialized();
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return const LocalSyncQueueSummary.empty();
    }

    final isSharedLedger = await _isSharedLedgerLocal(ledgerId);
    final ledgerSyncId = isSharedLedger
        ? (await _collabLedgerSyncIdOrNull(ledgerId) ??
            await _pathForLedger(ledgerId))
        : await _pathForLedger(ledgerId);
    final countRow = await db.customSelect(
      '''
      SELECT
        SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending_count,
        SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_count
      FROM sync_queue
      WHERE ledger_sync_id = ?
        AND source = 'local'
        AND status IN ('pending', 'failed')
      ''',
      variables: [
        drift.Variable.withString(ledgerSyncId),
      ],
    ).getSingleOrNull();

    final pending = _toIntOrNull(countRow?.data['pending_count']) ?? 0;
    final failed = _toIntOrNull(countRow?.data['failed_count']) ?? 0;

    String? lastError;
    if (failed > 0) {
      final errRow = await db.customSelect(
        '''
        SELECT last_error
        FROM sync_queue
        WHERE ledger_sync_id = ?
          AND source = 'local'
          AND status = 'failed'
          AND last_error IS NOT NULL
          AND TRIM(last_error) <> ''
        ORDER BY updated_at DESC, id DESC
        LIMIT 1
        ''',
        variables: [
          drift.Variable.withString(ledgerSyncId),
        ],
      ).getSingleOrNull();
      final normalized = (errRow?.data['last_error']?.toString() ?? '').trim();
      if (normalized.isNotEmpty) {
        lastError = normalized;
      }
    }

    return LocalSyncQueueSummary(
      pending: pending,
      failed: failed,
      lastError: lastError,
    );
  }

  Future<fcs.BeeCountCloudProfile> getMyProfile() async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    return provider.getMyProfile();
  }

  Future<fcs.BeeCountCloudAvatarUploadResult> uploadMyAvatar({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    return provider.uploadMyAvatar(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );
  }

  Future<List<fcs.BeeCountCloudShareInvite>> listShareInvites({
    required int ledgerId,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
    return provider.listShareInvites(
      ledgerId: externalLedgerId,
    );
  }

  Future<fcs.BeeCountCloudShareInviteCreateResult> createShareInvite({
    required int ledgerId,
    String role = 'editor',
    int maxUses = 1,
    int expiresInHours = 168,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
    return provider.createShareInvite(
      ledgerId: externalLedgerId,
      role: role,
      maxUses: maxUses,
      expiresInHours: expiresInHours,
    );
  }

  Future<void> revokeShareInvite({required String inviteId}) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    await provider.revokeShareInvite(inviteId: inviteId);
  }

  Future<void> joinShare({required String inviteCode}) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    await provider.joinShare(inviteCode: inviteCode);
  }

  Future<void> leaveShare({required int ledgerId}) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
    await provider.leaveShare(ledgerId: externalLedgerId);
    _ledgerRoleCache.remove(externalLedgerId);
  }

  Future<void> updateShareMemberRole({
    required int ledgerId,
    required String userId,
    required String role,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    final externalLedgerId = await _cloudLedgerExternalId(ledgerId);
    await provider.updateShareMemberRole(
      ledgerId: externalLedgerId,
      userId: userId,
      role: role,
    );
  }

  Future<List<fcs.BeeCountCloudDevice>> listDevices({
    String view = 'deduped',
    int activeWithinDays = 30,
  }) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    return provider.listDevices(
      view: view,
      activeWithinDays: activeWithinDays,
    );
  }

  Future<void> revokeDevice({required String deviceId}) async {
    await _ensureInitialized();
    final provider = _requireBeeCountCloudProvider();
    await provider.revokeDevice(deviceId: deviceId);
  }

  Future<({int downloaded, int failed})> retryMissingMediaDownloads({
    required int ledgerId,
  }) async {
    await _ensureInitialized();
    if (config.type != fcs.CloudBackendType.beecountCloud) {
      return (downloaded: 0, failed: 0);
    }
    if (_provider == null) {
      return (downloaded: 0, failed: 0);
    }

    final remotePath = await _pathForLedger(ledgerId);
    final jsonStr = await _provider!.storage.download(path: remotePath);
    if (jsonStr == null) {
      return (downloaded: 0, failed: 0);
    }
    final payload = _tryDecodePayload(jsonStr);
    if (payload == null) {
      return (downloaded: 0, failed: 0);
    }

    final iconResult = await _downloadMissingCategoryIcons(
      payload: payload,
      ledgerId: ledgerId,
      stage: 'manual_media_retry',
    );
    final attachmentResult = await _downloadMissingAttachments(
      payload: payload,
      ledgerId: ledgerId,
      stage: 'manual_media_retry',
    );
    return (
      downloaded: iconResult.downloaded + attachmentResult.downloaded,
      failed: iconResult.failed + attachmentResult.failed,
    );
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    await _ensureInitialized();

    if (_syncManager == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '删除云端备份: $ledgerId');
      final remotePath = await _pathForLedger(ledgerId);

      await _syncManager!.deleteRemote(path: remotePath);

      // 清除缓存
      _statusCache.remove(ledgerId);
      _recentLocalChangeAt.remove(ledgerId);
      _recentUpload.remove(ledgerId);

      logger.info('CloudSync', '删除完成: $ledgerId');
    } catch (e) {
      // 忽略 404 错误
      if (e.toString().contains('404') || e.toString().contains('not found')) {
        logger.warning('CloudSync', '云端备份不存在（忽略）: $ledgerId');
        return;
      }

      logger.error('CloudSync', '删除失败: $ledgerId', e);
      rethrow;
    }
  }

  /// 获取本地账本列表
  Future<List<LedgerDisplayItem>> getLocalLedgers(
      {bool accountFeatureEnabled = true}) async {
    await _ensureInitialized();

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
        ledgerType: ledger.type,
      ));
    }

    logger.info('CloudSync', '已加载本地账本: ${result.length} 个');
    return result;
  }

  /// 获取远程账本列表（仅云端，不在本地）
  Future<List<LedgerDisplayItem>> getRemoteLedgers() async {
    await _ensureInitialized();

    _remoteLedgerDisplayIdToSyncId.clear();
    if (config.type == fcs.CloudBackendType.beecountCloud) {
      await _runOneTimeLedgerSyncIdRepair();
    }

    // 获取本地账本ID列表（用于过滤）
    final localLedgers = await db.select(db.ledgers).get();
    final localLedgerIds = localLedgers.map((l) => l.id).toSet();
    final localSyncRows = await db.customSelect(
      '''
      SELECT id, sync_id, type
      FROM ledgers
      WHERE sync_id IS NOT NULL AND TRIM(sync_id) <> ''
      ''',
    ).get();
    final localSyncIds = <String>{};
    final localLedgerIdBySyncId = <String, int>{};
    final localLedgerTypeBySyncId = <String, String>{};
    for (final row in localSyncRows) {
      final syncId = (row.data['sync_id']?.toString() ?? '').trim();
      if (syncId.isEmpty) {
        continue;
      }
      localSyncIds.add(syncId);
      final localLedgerId = _toIntOrNull(row.data['id']);
      if (localLedgerId != null) {
        localLedgerIdBySyncId[syncId] = localLedgerId;
      }
      localLedgerTypeBySyncId[syncId] =
          (row.data['type']?.toString() ?? '').trim().toLowerCase();
    }

    final result = <LedgerDisplayItem>[];

    if (config.type == fcs.CloudBackendType.beecountCloud &&
        _provider is fcs.BeeCountCloudProvider) {
      final provider = _provider as fcs.BeeCountCloudProvider;
      try {
        final ledgers = await provider.readLedgers();
        for (final row in ledgers) {
          final remoteSyncId = row.ledgerId.trim();
          if (remoteSyncId.isEmpty) {
            continue;
          }

          final existingLocalId = localLedgerIdBySyncId[remoteSyncId];
          if (existingLocalId != null) {
            final existingType =
                (localLedgerTypeBySyncId[remoteSyncId] ?? '').toLowerCase();
            if (row.isShared && existingType == 'personal') {
              final remoteId = _rememberRemoteDisplayId(remoteSyncId);
              final updatedAt =
                  row.updatedAt ?? row.exportedAt ?? DateTime.now();
              result.add(
                LedgerDisplayItem.fromRemote(
                  remoteId: remoteId,
                  name: row.ledgerName,
                  currency: row.currency,
                  updatedAt: updatedAt,
                  transactionCount: row.transactionCount,
                  balance: row.balance,
                  ledgerType: 'shared',
                ),
              );
              continue;
            }
            await db.customStatement(
              '''
              UPDATE ledgers
              SET name = ?, currency = ?, type = ?
              WHERE id = ?
              ''',
              [
                row.ledgerName,
                row.currency,
                row.isShared ? 'shared' : 'personal',
                existingLocalId,
              ],
            );
            _ledgerSyncIdCache[existingLocalId] = remoteSyncId;
            continue;
          }

          final remoteId = _rememberRemoteDisplayId(remoteSyncId);
          final updatedAt = row.updatedAt ?? row.exportedAt ?? DateTime.now();
          result.add(
            LedgerDisplayItem.fromRemote(
              remoteId: remoteId,
              name: row.ledgerName,
              currency: row.currency,
              updatedAt: updatedAt,
              transactionCount: row.transactionCount,
              balance: row.balance,
              ledgerType: row.isShared ? 'shared' : 'personal',
            ),
          );
        }
        logger.info('CloudSync', '已加载协作远程账本: ${result.length} 个');
      } catch (e) {
        logger.warning('CloudSync', '读取协作远程账本失败: $e');
      }
      return result;
    }

    // 直接从云端文件列表获取远程账本
    try {
      final files = await _provider!.storage.list(path: '');
      logger.info('CloudSync', '云端文件列表: ${files.map((f) => f.name).toList()}');
      int remoteCount = 0;

      for (final file in files) {
        try {
          final remoteSyncId = file.name.trim();
          if (remoteSyncId.isEmpty) continue;

          // 如果本地已存在同 syncId，跳过
          if (localSyncIds.contains(remoteSyncId)) continue;

          // 兼容旧路径：如果是 legacy ledger_*.json 且本地已有同 ID，也跳过
          final remoteId = _rememberRemoteDisplayId(remoteSyncId);
          if (_extractLedgerId(remoteSyncId) != null &&
              localLedgerIds.contains(remoteId)) {
            continue;
          }

          // 下载文件获取账本元数据（使用 file.name 而非 file.path，避免路径重复）
          logger.info('CloudSync',
              '尝试下载远程账本: file.name=${file.name}, file.path=${file.path}');
          final jsonStr = await _provider!.storage.download(path: remoteSyncId);
          if (jsonStr == null) {
            logger.warning('CloudSync', '下载结果为空: ${file.name}');
            continue;
          }

          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          final name = json['ledgerName'] as String? ??
              json['name'] as String? ??
              'Unknown';
          final currency = json['currency'] as String? ?? 'CNY';
          final updatedAtStr = json['exportedAt'] as String?;
          final transactionCount = json['count'] as int? ?? 0;
          final ledgerType =
              (json['type'] as String? ?? 'personal').trim().toLowerCase();

          // 优先使用 balance 字段，没有则从 items 计算
          double balance;
          if (json.containsKey('balance')) {
            balance = (json['balance'] as num?)?.toDouble() ?? 0.0;
          } else {
            balance = 0.0;
            final items =
                (json['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
            for (final item in items) {
              final type = item['type'] as String?;
              final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
              if (type == 'income') {
                balance += amount;
              } else if (type == 'expense') {
                balance -= amount;
              }
            }
          }

          DateTime updatedAt;
          try {
            updatedAt = DateTime.parse(updatedAtStr ?? '');
          } catch (_) {
            updatedAt = DateTime.now();
          }

          result.add(LedgerDisplayItem.fromRemote(
            remoteId: remoteId,
            name: name,
            currency: currency,
            updatedAt: updatedAt,
            transactionCount: transactionCount,
            balance: balance,
            ledgerType: ledgerType == 'shared' ? 'shared' : 'personal',
          ));

          remoteCount++;
        } catch (e) {
          logger.warning('CloudSync', '解析远程账本文件失败: ${file.name} - $e');
          continue;
        }
      }

      logger.info('CloudSync', '已加载远程账本: $remoteCount 个');
    } catch (e) {
      logger.warning('CloudSync', '获取远程账本失败: $e');
      // 失败不影响，返回空列表
    }

    return result;
  }

  String resolveRemoteLedgerPathForDisplayId(int displayId) {
    final mapped = _resolveRemoteLedgerSyncIdFromDisplayId(displayId);
    if (mapped != null && mapped.trim().isNotEmpty) {
      return mapped;
    }
    return 'ledger_$displayId.json';
  }

  /// 获取所有账本（本地 + 云端）
  Future<List<LedgerDisplayItem>> getAllLedgers() async {
    await _ensureInitialized();

    // 并行获取本地和远程账本
    final results = await Future.wait([
      getLocalLedgers(),
      getRemoteLedgers(),
    ]);

    final localLedgers = results[0];
    final remoteLedgers = results[1];

    // 组合结果
    final allLedgers = [...localLedgers, ...remoteLedgers];

    logger.info('CloudSync',
        '已加载所有账本: 本地=${localLedgers.length}, 远程=${remoteLedgers.length}, 总计=${allLedgers.length}');

    return allLedgers;
  }

  /// 刷新所有账本的同步状态（后台预热缓存）
  Future<void> refreshAllLedgersStatus() async {
    await _ensureInitialized();

    try {
      final ledgers = await db.select(db.ledgers).get();

      for (final ledger in ledgers) {
        try {
          await getStatus(ledgerId: ledger.id);
        } catch (e) {
          logger.warning('CloudSync', '刷新账本 ${ledger.id} 状态失败: $e');
        }
      }

      logger.info('CloudSync', '已刷新 ${ledgers.length} 个账本的同步状态');
    } catch (e) {
      logger.error('CloudSync', '刷新所有账本状态失败', e);
    }
  }

  /// 下载远程账本（创建新的本地账本或复用同名账本）
  ///
  /// 优先级：
  /// 1. 如果本地存在同名账本，复用该账本（不创建新账本）
  /// 2. 如果本地不存在同名账本但不存在远程 ID，复用远程 ID
  /// 3. 否则创建新 ID
  Future<int?> downloadRemoteLedger({
    required String name,
    required String currency,
    required String remotePath,
  }) async {
    await _ensureInitialized();

    try {
      logger.info('CloudSync', '下载远程账本: $remotePath');

      if (config.type == fcs.CloudBackendType.beecountCloud &&
          _provider is fcs.BeeCountCloudProvider &&
          !_isLegacySnapshotLedgerSyncId(remotePath)) {
        final localLedgerId = await _applyRemoteLedgerProjection(remotePath);
        if (localLedgerId != null) {
          return localLedgerId;
        }
        throw fcs.CloudSyncException(
            'Read collaborative ledger failed: $remotePath');
      }

      // 从远程路径提取账本ID
      final remoteId = _extractLedgerId(remotePath);

      // 优先检查本地是否已存在同名账本
      final existingByName = await (db.select(db.ledgers)
            ..where((t) => t.name.equals(name)))
          .getSingleOrNull();

      final int ledgerId;
      final bool reuseExistingByName = existingByName != null;
      bool reuseRemoteId = false;

      if (reuseExistingByName) {
        // 复用同名账本的 ID（不创建新账本）
        ledgerId = existingByName.id;
        logger.info('CloudSync', '本地已存在同名账本，复用账本ID: $ledgerId (名称: $name)');
      } else {
        // 检查本地是否已存在该远程 ID
        final existingById = remoteId != null
            ? await (db.select(db.ledgers)..where((t) => t.id.equals(remoteId)))
                .getSingleOrNull()
            : null;

        reuseRemoteId = remoteId != null && existingById == null;

        if (reuseRemoteId) {
          // 复用远程 ID
          logger.info('CloudSync', '复用远程ID: $remoteId');
          await db.into(db.ledgers).insert(
                LedgersCompanion.insert(
                  id: drift.Value(remoteId),
                  name: name,
                  currency: drift.Value(currency),
                ),
              );
          ledgerId = remoteId;
        } else {
          // 创建新 ID（自动递增）
          logger.info('CloudSync', '本地ID冲突或无效，创建新ID');
          ledgerId = await db.into(db.ledgers).insert(
                LedgersCompanion.insert(
                  name: name,
                  currency: drift.Value(currency),
                ),
              );
        }
      }

      try {
        await db.customStatement(
          'UPDATE ledgers SET sync_id = ? WHERE id = ? AND (sync_id IS NULL OR TRIM(sync_id) = \'\')',
          [remotePath, ledgerId],
        );
      } catch (_) {}
      _ledgerSyncIdCache[ledgerId] = remotePath;

      // 下载数据
      final jsonStr = await _provider!.storage.download(path: remotePath);

      if (jsonStr == null) {
        logger.warning('CloudSync', '云端账本不存在: $remotePath');
        // 只有新创建的账本才需要删除
        if (!reuseExistingByName) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId)))
              .go();
        }
        return null;
      }

      final payload = _tryDecodePayload(jsonStr);
      if (payload != null) {
        await _downloadMissingCategoryIcons(
          payload: payload,
          ledgerId: ledgerId,
          stage: 'remote_ledger_download',
        );
      }
      final importContent = payload == null ? jsonStr : jsonEncode(payload);

      // 导入数据
      final result = await _runWithLocalMutationSuppressed(() {
        return importTransactionsJson(
          repo,
          ledgerId,
          importContent,
          mode: ImportMode.replace,
        );
      });
      unawaited(_downloadMissingAttachments(
        payload: payload,
        ledgerId: ledgerId,
        stage: 'remote_ledger_download',
      ));

      logger.info(
          'CloudSync', '下载完成: ledgerId=$ledgerId, inserted=${result.inserted}');

      // 处理云端文件更新
      if (reuseExistingByName) {
        // 复用了同名账本，本地 ID 可能和云端不同
        // 需要删除旧的云端文件，并上传新的（使用本地 ID）
        if (remoteId != null && remoteId != ledgerId) {
          try {
            await _provider!.storage.delete(path: remotePath);
            logger.info('CloudSync',
                '旧远程文件已删除: $remotePath (远程ID: $remoteId != 本地ID: $ledgerId)');
          } catch (e) {
            logger.warning('CloudSync', '删除旧远程文件失败（忽略）: $e');
          }
          // 上传本地账本到云端（使用本地 ID）
          try {
            await uploadCurrentLedger(ledgerId: ledgerId);
            logger.info('CloudSync', '账本已上传到云端: ledger_$ledgerId.json');
          } catch (e) {
            logger.warning('CloudSync', '上传账本失败（忽略）: $e');
          }
        } else {
          logger.info('CloudSync', '复用同名账本，ID相同无需更新云端文件');
        }
      } else if (reuseRemoteId) {
        // 复用了远程ID，无需删除和重新上传
        logger.info('CloudSync', '复用远程ID，无需更新云端文件');
      } else {
        // 创建了新 ID，需要删除旧文件并上传新文件
        try {
          await _provider!.storage.delete(path: remotePath);
          logger.info('CloudSync', '旧远程文件已删除: $remotePath');
        } catch (e) {
          logger.warning('CloudSync', '删除旧远程文件失败（忽略）: $e');
        }
        // 上传新创建的本地账本到云端
        try {
          await uploadCurrentLedger(ledgerId: ledgerId);
          logger.info('CloudSync', '新账本已上传到云端: ledger_$ledgerId.json');
        } catch (e) {
          logger.warning('CloudSync', '上传新账本失败（忽略）: $e');
        }
      }

      return ledgerId;
    } catch (e, stack) {
      logger.error('CloudSync', '下载远程账本失败: $remotePath', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  /// 删除远程账本（仅云端）
  Future<void> deleteRemoteLedger({required String remotePath}) async {
    await _ensureInitialized();

    try {
      logger.info('CloudSync', '删除远程账本: $remotePath');

      await _provider!.storage.delete(path: remotePath);

      logger.info('CloudSync', '删除完成: $remotePath');
    } catch (e) {
      // 忽略 404 错误
      if (e.toString().contains('404') || e.toString().contains('not found')) {
        logger.warning('CloudSync', '远程账本不存在（忽略）: $remotePath');
        return;
      }

      logger.error('CloudSync', '删除远程账本失败: $remotePath', e);
      rethrow;
    }
  }

  /// 恢复所有远程账本到本地（并行执行）
  Future<({int success, int failed})> restoreAllRemoteLedgers() async {
    await _ensureInitialized();

    try {
      logger.info('CloudSync', '开始恢复所有远程账本');
      if (config.type == fcs.CloudBackendType.beecountCloud) {
        await _runOneTimeLedgerSyncIdRepair();
      }

      // 获取本地已存在的账本ID
      final localLedgers = await db.select(db.ledgers).get();
      final localLedgerIds = localLedgers.map((l) => l.id).toSet();
      final localSyncRows = await db
          .customSelect(
            "SELECT sync_id FROM ledgers WHERE sync_id IS NOT NULL AND TRIM(sync_id) <> ''",
          )
          .get();
      final localSyncIds = localSyncRows
          .map((row) => row.data['sync_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      logger.info('CloudSync', '本地已存在账本: $localLedgerIds');

      if (config.type == fcs.CloudBackendType.beecountCloud &&
          _provider is fcs.BeeCountCloudProvider) {
        final provider = _provider as fcs.BeeCountCloudProvider;
        final remoteLedgers = await provider.readLedgers();
        var success = 0;
        var failed = 0;
        for (final remote in remoteLedgers) {
          final remoteSyncId = remote.ledgerId.trim();
          if (remoteSyncId.isEmpty) {
            continue;
          }

          if (localSyncIds.contains(remoteSyncId)) {
            continue;
          }

          try {
            final restoredId = await _applyRemoteLedgerProjection(remoteSyncId);
            if (restoredId != null) {
              success++;
            } else {
              failed++;
            }
          } catch (e) {
            logger.warning('CloudSync', '恢复协作账本失败: $remoteSyncId - $e');
            failed++;
          }
        }
        logger.info('CloudSync', '恢复完成: 成功=$success, 失败=$failed');
        return (success: success, failed: failed);
      }

      // 列出所有远程账本文件
      final files = await _provider!.storage.list(path: '');

      // 过滤出账本文件，并排除本地已存在的
      final ledgerFiles = files.where((file) {
        final remoteSyncId = file.name.trim();
        if (remoteSyncId.isEmpty) {
          return false;
        }

        if (localSyncIds.contains(remoteSyncId)) {
          logger.info('CloudSync', '跳过已存在的账本: $remoteSyncId (sync_id)');
          return false;
        }

        final remoteId = _extractLedgerId(remoteSyncId);
        if (remoteId != null && localLedgerIds.contains(remoteId)) {
          logger.info('CloudSync', '跳过已存在的账本: $remoteSyncId (ID=$remoteId)');
          return false;
        }

        return true;
      }).toList();

      logger.info('CloudSync', '找到 ${ledgerFiles.length} 个需要恢复的远程账本文件');

      // 并行恢复所有账本
      final results = await Future.wait(
        ledgerFiles.map((file) async {
          try {
            // 下载文件内容以获取账本信息（使用 file.name 而非 file.path）
            final jsonStr = await _provider!.storage.download(path: file.name);
            if (jsonStr == null) {
              logger.warning('CloudSync', '下载失败: ${file.name}');
              return false;
            }

            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final name = json['ledgerName'] as String? ??
                json['name'] as String? ??
                'Unknown';
            final currency = json['currency'] as String? ?? 'CNY';

            // 下载远程账本
            final ledgerId = await downloadRemoteLedger(
              name: name,
              currency: currency,
              remotePath: file.name,
            );

            if (ledgerId != null) {
              logger.info(
                  'CloudSync', '恢复成功: ${file.name} -> ledgerId=$ledgerId');
              return true;
            } else {
              logger.warning('CloudSync', '恢复失败: ${file.name}');
              return false;
            }
          } catch (e) {
            logger.warning('CloudSync', '恢复账本失败: ${file.name} - $e');
            return false;
          }
        }),
      );

      // 统计结果
      final success = results.where((r) => r).length;
      final failed = results.where((r) => !r).length;

      logger.info('CloudSync', '恢复完成: 成功=$success, 失败=$failed');
      return (success: success, failed: failed);
    } catch (e, stack) {
      logger.error('CloudSync', '恢复所有远程账本失败', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }
}

class _QueuedMutation {
  const _QueuedMutation({
    required this.id,
    required this.ledgerSyncId,
    required this.entityType,
    required this.entitySyncId,
    required this.action,
    required this.payloadJson,
    required this.baseChangeId,
    required this.requestId,
    required this.idempotencyKey,
    required this.attemptCount,
  });

  final int id;
  final String ledgerSyncId;
  final String entityType;
  final String entitySyncId;
  final String action;
  final Map<String, dynamic> payloadJson;
  final int? baseChangeId;
  final String? requestId;
  final String? idempotencyKey;
  final int attemptCount;

  _QueuedMutation copyWith({
    String? ledgerSyncId,
    String? entitySyncId,
    String? action,
    String? requestId,
    String? idempotencyKey,
  }) {
    return _QueuedMutation(
      id: id,
      ledgerSyncId: ledgerSyncId ?? this.ledgerSyncId,
      entityType: entityType,
      entitySyncId: entitySyncId ?? this.entitySyncId,
      action: action ?? this.action,
      payloadJson: payloadJson,
      baseChangeId: baseChangeId,
      requestId: requestId ?? this.requestId,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      attemptCount: attemptCount,
    );
  }
}

/// 账本交易数据序列化器
class _TransactionSerializer implements fcs.DataSerializer<int> {
  final BeeDatabase db;

  _TransactionSerializer(this.db);

  @override
  Future<String> serialize(int ledgerId) async {
    return await exportTransactionsJson(db, ledgerId);
  }

  @override
  Future<int> deserialize(String data) async {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return json['ledgerId'] as int;
  }

  @override
  String fingerprint(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return _contentFingerprintFromMap(json);
  }

  /// 从 payload 计算内容指纹（与原实现保持一致）
  String _contentFingerprintFromMap(Map<String, dynamic> payload) {
    return _snapshotFingerprintFromPayload(payload);
  }
}

String _snapshotFingerprintFromPayload(Map<String, dynamic> payload) {
  final rawItems = payload['items'];
  if (rawItems is! List) {
    return sha256.convert(utf8.encode('[]')).toString();
  }

  final canon = rawItems.map((raw) {
    final item = raw is Map<String, dynamic>
        ? raw
        : (raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{});
    return <String, String>{
      'happenedAt': _normalizeHappenedAt(item['happenedAt']),
      'type': _normalizeText(item['type']),
      'amount': _normalizeAmount(item['amount']),
      'categoryName': _normalizeText(item['categoryName']),
      'categoryKind': _normalizeText(item['categoryKind']),
      'note': _normalizeText(item['note']),
    };
  }).toList();

  canon.sort((a, b) {
    final c1 = a['happenedAt']!.compareTo(b['happenedAt']!);
    if (c1 != 0) return c1;
    final c2 = a['type']!.compareTo(b['type']!);
    if (c2 != 0) return c2;
    final c3 = a['amount']!.compareTo(b['amount']!);
    if (c3 != 0) return c3;
    final c4 = a['categoryName']!.compareTo(b['categoryName']!);
    if (c4 != 0) return c4;
    final c5 = a['categoryKind']!.compareTo(b['categoryKind']!);
    if (c5 != 0) return c5;
    return a['note']!.compareTo(b['note']!);
  });

  final bytes = utf8.encode(jsonEncode(canon));
  return sha256.convert(bytes).toString();
}

String _normalizeText(Object? value) {
  return value?.toString().trim() ?? '';
}

String _normalizeAmount(Object? value) {
  final raw = _normalizeText(value);
  if (raw.isEmpty) return '0';

  final parsed = num.tryParse(raw);
  if (parsed == null) {
    return raw;
  }
  if (parsed == parsed.toInt()) {
    return parsed.toInt().toString();
  }
  final fixed = parsed.toStringAsFixed(8);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _normalizeHappenedAt(Object? value) {
  final raw = _normalizeText(value);
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    return raw;
  }
  return parsed.toUtc().toIso8601String();
}

class _AttachmentUploadCandidate {
  _AttachmentUploadCandidate({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });

  final String fileName;
  final Uint8List bytes;
  final String? mimeType;
}

class _AttachmentDownloadTarget {
  _AttachmentDownloadTarget({
    required this.fileId,
    required this.fileName,
  });

  final String fileId;
  final String fileName;
}

class _MediaDownloadResult {
  const _MediaDownloadResult({
    required this.downloaded,
    required this.failed,
  });

  static const empty = _MediaDownloadResult(downloaded: 0, failed: 0);

  final int downloaded;
  final int failed;
}

/// 近期上传记录（用于处理 CDN 缓存延迟）
class _RecentUpload {
  final DateTime at;
  final String fp;
  final int count;

  _RecentUpload({
    required this.at,
    required this.fp,
    required this.count,
  });
}
