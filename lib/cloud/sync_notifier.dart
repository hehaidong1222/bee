import 'dart:convert';

import '../data/db.dart';
import '../services/system/logger_service.dart';
import 'sync_backend.dart';
import 'sync_fk_resolver.dart';
import 'package:drift/drift.dart';

/// 写操作通知接口
///
/// Repository 层的写操作（增删改）完成后，调用此接口通知同步层。
/// 通知是 fire-and-forget 的，不阻塞写操作本身。
abstract class SyncNotifier {
  /// 记录数据变更
  ///
  /// [table] 表名（如 transactions, categories）
  /// [syncId] 记录的全局唯一标识
  /// [operation] 操作类型（upsert / delete）
  /// [localData] 本地记录数据（delete 时为 null）
  void onRecordChanged(
    String table,
    String syncId,
    SyncOperation operation,
    Map<String, dynamic>? localData,
  );
}

/// 无操作实现（同步未启用时使用）
class NoOpSyncNotifier implements SyncNotifier {
  @override
  void onRecordChanged(
    String table,
    String syncId,
    SyncOperation operation,
    Map<String, dynamic>? localData,
  ) {
    // 不做任何事
  }
}

/// 默认实现：将变更写入 PendingSyncChanges 队列
///
/// 异步执行 FK 转换并写入队列表，不阻塞调用方。
/// 队列中的记录后续由 SyncQueueProcessor 消费推送到远端。
class RecordSyncNotifier implements SyncNotifier {
  final BeeDatabase db;
  final SyncForeignKeyResolver fkResolver;

  RecordSyncNotifier({
    required this.db,
    required this.fkResolver,
  });

  @override
  void onRecordChanged(
    String table,
    String syncId,
    SyncOperation operation,
    Map<String, dynamic>? localData,
  ) {
    // fire-and-forget: 异步处理，不阻塞写操作
    _enqueue(table, syncId, operation, localData);
  }

  Future<void> _enqueue(
    String table,
    String syncId,
    SyncOperation operation,
    Map<String, dynamic>? localData,
  ) async {
    try {
      String? payload;

      if (operation == SyncOperation.upsert && localData != null) {
        // FK 转换：本地 int FK → syncId FK
        final syncPayload = await fkResolver.toSyncPayload(table, localData);
        payload = jsonEncode(syncPayload);
      }

      await db.into(db.pendingSyncChanges).insert(
            PendingSyncChangesCompanion.insert(
              syncTable: table,
              recordSyncId: syncId,
              operation: operation.name,
              payload: Value(payload),
            ),
          );

      logger.debug('SyncNotifier', '$table.$syncId → ${operation.name} 已入队');
    } catch (e, stackTrace) {
      logger.error('SyncNotifier', '入队失败: $table.$syncId', e, stackTrace);
    }
  }

  /// 获取待同步变更数量
  Future<int> getPendingCount() async {
    final count = await db.pendingSyncChanges.count().getSingle();
    return count;
  }

  /// 获取待推送的变更记录（按创建时间排序）
  Future<List<PendingSyncChange>> getPendingChanges({int limit = 50}) async {
    return (db.select(db.pendingSyncChanges)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  /// 标记变更已推送成功，从队列中移除
  Future<void> markPushed(List<int> ids) async {
    await (db.delete(db.pendingSyncChanges)
          ..where((t) => t.id.isIn(ids)))
        .go();
  }

  /// 标记变更推送失败，增加重试次数
  Future<void> markRetry(int id) async {
    await db.customUpdate(
      'UPDATE pending_sync_changes SET retry_count = retry_count + 1 WHERE id = ?',
      variables: [Variable.withInt(id)],
      updates: {db.pendingSyncChanges},
    );
  }

  /// 清空所有待同步变更（用于重置同步状态）
  Future<void> clearAll() async {
    await db.delete(db.pendingSyncChanges).go();
  }
}
