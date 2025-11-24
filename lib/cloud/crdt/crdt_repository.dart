import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db.dart';
import 'operation.dart';

/// CRDT 仓库扩展
///
/// 提供 CRDT 相关的数据库操作方法
extension CrdtRepositoryExtension on BeeDatabase {
  /// 获取未同步的操作
  Future<List<Operation>> getUnsyncedOperations(int ledgerId) async {
    final rows = await (select(crdtOperations)
          ..where((o) => o.ledgerId.equals(ledgerId))
          ..where((o) => o.synced.equals(false))
          ..orderBy([(o) => OrderingTerm.asc(o.timestamp)]))
        .get();

    return rows.map(_rowToOperation).toList();
  }

  /// 获取所有操作
  Future<List<Operation>> getAllOperations(int ledgerId) async {
    final rows = await (select(crdtOperations)
          ..where((o) => o.ledgerId.equals(ledgerId))
          ..orderBy([(o) => OrderingTerm.asc(o.timestamp)]))
        .get();

    return rows.map(_rowToOperation).toList();
  }

  /// 获取操作数量
  Future<int> getOperationsCount(int ledgerId) async {
    final countExp = crdtOperations.opId.count();
    final query = selectOnly(crdtOperations)
      ..addColumns([countExp])
      ..where(crdtOperations.ledgerId.equals(ledgerId));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// 获取未同步的操作数量
  Future<int> getUnsyncedOperationsCount(int ledgerId) async {
    final countExp = crdtOperations.opId.count();
    final query = selectOnly(crdtOperations)
      ..addColumns([countExp])
      ..where(crdtOperations.ledgerId.equals(ledgerId))
      ..where(crdtOperations.synced.equals(false));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// 标记操作为已同步
  Future<void> markOperationsSynced(List<String> opIds) async {
    if (opIds.isEmpty) return;

    await (update(crdtOperations)..where((o) => o.opId.isIn(opIds)))
        .write(const CrdtOperationsCompanion(synced: Value(true)));
  }

  /// 检查操作是否存在
  Future<bool> hasOperation(String opId) async {
    final rows = await (select(crdtOperations)
          ..where((o) => o.opId.equals(opId))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// 获取同步状态
  Future<CrdtSyncStateData?> getSyncState(int ledgerId) async {
    final rows = await (select(crdtSyncState)
          ..where((s) => s.ledgerId.equals(ledgerId)))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 更新同步状态
  Future<void> updateSyncState({
    required int ledgerId,
    required String deviceId,
    int? localClock,
    int? syncedSnapshotVersion,
    DateTime? lastSyncAt,
  }) async {
    final existing = await getSyncState(ledgerId);

    if (existing == null) {
      await into(crdtSyncState).insert(
        CrdtSyncStateCompanion.insert(
          ledgerId: Value(ledgerId),
          deviceId: deviceId,
          localClock: Value(localClock ?? 0),
          syncedSnapshotVersion: Value(syncedSnapshotVersion ?? 0),
          lastSyncAt: Value(lastSyncAt),
        ),
      );
    } else {
      await (update(crdtSyncState)..where((s) => s.ledgerId.equals(ledgerId)))
          .write(
        CrdtSyncStateCompanion(
          localClock: localClock != null ? Value(localClock) : const Value.absent(),
          syncedSnapshotVersion: syncedSnapshotVersion != null
              ? Value(syncedSnapshotVersion)
              : const Value.absent(),
          lastSyncAt: lastSyncAt != null ? Value(lastSyncAt) : const Value.absent(),
        ),
      );
    }
  }

  /// 根据 UUID 查找交易记录
  Future<Transaction?> findTransactionByUuid(String uuid) async {
    final rows = await (select(transactions)..where((t) => t.uuid.equals(uuid))).get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 获取需要生成 UUID 的交易记录
  Future<List<Transaction>> getTransactionsWithoutUuid(int ledgerId) async {
    final rows = await (select(transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..where((t) => t.uuid.isNull()))
        .get();
    return rows;
  }

  /// 为交易记录设置 UUID
  Future<void> setTransactionUuid(int id, String uuid) async {
    await (update(transactions)..where((t) => t.id.equals(id)))
        .write(TransactionsCompanion(uuid: Value(uuid)));
  }

  /// 删除账本的所有操作日志
  Future<void> deleteAllOperations(int ledgerId) async {
    await (delete(crdtOperations)..where((o) => o.ledgerId.equals(ledgerId))).go();
  }

  Operation _rowToOperation(CrdtOperation row) {
    return Operation(
      opId: row.opId,
      type: OperationType.values.byName(row.type),
      targetId: row.targetId,
      timestamp: row.timestamp,
      deviceId: row.deviceId,
      data: row.data != null ? jsonDecode(row.data!) as Map<String, dynamic>? : null,
      createdAt: row.createdAt,
    );
  }
}
