import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db.dart';
import '../../services/logger_service.dart';
import 'lamport_clock.dart';
import 'operation.dart';

/// 操作应用结果
class ApplyResult {
  final int applied;
  final int skipped;
  final int conflicts;

  ApplyResult({
    required this.applied,
    required this.skipped,
    this.conflicts = 0,
  });

  @override
  String toString() =>
      'ApplyResult(applied: $applied, skipped: $skipped, conflicts: $conflicts)';
}

/// 操作应用器
///
/// 负责将远程操作应用到本地数据库
class OperationApplier {
  final BeeDatabase _db;
  final LamportClock _clock;

  OperationApplier(this._db, this._clock);

  /// 应用操作日志到本地数据库
  Future<ApplyResult> apply(int ledgerId, List<Operation> operations) async {
    int applied = 0;
    int skipped = 0;
    int conflicts = 0;

    // 获取本地已有的操作 ID
    final localOpIds = await _getLocalOperationIds(ledgerId);

    for (final op in operations) {
      // 更新 Lamport 时钟
      _clock.receive(op.timestamp);

      // 跳过已存在的操作（幂等性）
      if (localOpIds.contains(op.opId)) {
        skipped++;
        continue;
      }

      // 应用操作
      final result = await _applyOperation(ledgerId, op);
      if (result) {
        applied++;
      } else {
        conflicts++;
      }

      // 保存操作到本地（标记为已同步）
      await _saveOperationAsSynced(op, ledgerId);
      localOpIds.add(op.opId);
    }

    logger.info('OperationApplier',
        '应用完成: applied=$applied, skipped=$skipped, conflicts=$conflicts');

    return ApplyResult(applied: applied, skipped: skipped, conflicts: conflicts);
  }

  /// 获取本地已有的操作 ID
  Future<Set<String>> _getLocalOperationIds(int ledgerId) async {
    final rows = await (_db.select(_db.crdtOperations)
          ..where((o) => o.ledgerId.equals(ledgerId)))
        .get();
    return rows.map((r) => r.opId).toSet();
  }

  /// 应用单个操作
  Future<bool> _applyOperation(int ledgerId, Operation op) async {
    try {
      switch (op.type) {
        case OperationType.insert:
          return await _applyInsert(ledgerId, op);
        case OperationType.update:
          return await _applyUpdate(ledgerId, op);
        case OperationType.delete:
          return await _applyDelete(ledgerId, op);
      }
    } catch (e, st) {
      logger.error('OperationApplier', '应用操作失败: ${op.opId}', e, st);
      return false;
    }
  }

  /// 应用插入操作
  Future<bool> _applyInsert(int ledgerId, Operation op) async {
    final data = op.data;
    if (data == null) {
      logger.warning('OperationApplier', 'insert 操作缺少 data: ${op.opId}');
      return false;
    }

    // 检查记录是否已存在
    final existing = await _findTransactionByUuid(op.targetId);
    if (existing != null) {
      // 记录已存在，检查是否需要 LWW
      logger.debug('OperationApplier', '记录已存在，跳过 insert: ${op.targetId}');
      return false;
    }

    // 检查是否有更晚的删除操作
    final hasLaterDelete = await _hasLaterDeleteOperation(op.targetId, op.timestamp);
    if (hasLaterDelete) {
      logger.debug('OperationApplier', '存在更晚的删除操作，跳过 insert: ${op.targetId}');
      return false;
    }

    // 插入记录
    await _db.into(_db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: data['type'] as String? ?? 'expense',
            amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
            categoryId: Value(data['categoryId'] as int?),
            accountId: Value(data['accountId'] as int?),
            toAccountId: Value(data['toAccountId'] as int?),
            happenedAt: Value(_parseDateTime(data['happenedAt']) ?? DateTime.now()),
            note: Value(data['note'] as String?),
            recurringId: Value(data['recurringId'] as int?),
            uuid: Value(op.targetId),
          ),
        );

    logger.debug('OperationApplier', '插入记录: ${op.targetId}');
    return true;
  }

  /// 应用更新操作
  Future<bool> _applyUpdate(int ledgerId, Operation op) async {
    final data = op.data;
    if (data == null) {
      logger.warning('OperationApplier', 'update 操作缺少 data: ${op.opId}');
      return false;
    }

    // 查找目标记录
    final existing = await _findTransactionByUuid(op.targetId);
    if (existing == null) {
      // 记录不存在，可能还未收到 insert 操作
      logger.debug('OperationApplier', '记录不存在，跳过 update: ${op.targetId}');
      return false;
    }

    // 检查 LWW：只有更新的时间戳更大才应用
    final lastOpTs = await _getLastOperationTimestamp(op.targetId);
    if (lastOpTs != null && op.timestamp <= lastOpTs) {
      logger.debug('OperationApplier', '存在更新的操作，跳过 update: ${op.targetId}');
      return false;
    }

    // 构建更新
    final companion = TransactionsCompanion(
      type: data.containsKey('type') ? Value(data['type'] as String) : const Value.absent(),
      amount: data.containsKey('amount')
          ? Value((data['amount'] as num).toDouble())
          : const Value.absent(),
      categoryId: data.containsKey('categoryId')
          ? Value(data['categoryId'] as int?)
          : const Value.absent(),
      accountId: data.containsKey('accountId')
          ? Value(data['accountId'] as int?)
          : const Value.absent(),
      toAccountId: data.containsKey('toAccountId')
          ? Value(data['toAccountId'] as int?)
          : const Value.absent(),
      happenedAt: data.containsKey('happenedAt')
          ? Value(_parseDateTime(data['happenedAt']) ?? DateTime.now())
          : const Value.absent(),
      note: data.containsKey('note') ? Value(data['note'] as String?) : const Value.absent(),
    );

    await (_db.update(_db.transactions)..where((t) => t.id.equals(existing.id)))
        .write(companion);

    logger.debug('OperationApplier', '更新记录: ${op.targetId}');
    return true;
  }

  /// 应用删除操作
  Future<bool> _applyDelete(int ledgerId, Operation op) async {
    // 检查 LWW：只有删除的时间戳更大才应用
    final lastOpTs = await _getLastOperationTimestamp(op.targetId);
    if (lastOpTs != null && op.timestamp <= lastOpTs) {
      // 有更新的操作（可能是 update），跳过删除
      logger.debug('OperationApplier', '存在更新的操作，跳过 delete: ${op.targetId}');
      return false;
    }

    // 查找目标记录
    final existing = await _findTransactionByUuid(op.targetId);
    if (existing != null) {
      await (_db.delete(_db.transactions)..where((t) => t.id.equals(existing.id))).go();
      logger.debug('OperationApplier', '删除记录: ${op.targetId}');
    }

    return true;
  }

  /// 根据 UUID 查找交易记录
  Future<Transaction?> _findTransactionByUuid(String uuid) async {
    final rows = await (_db.select(_db.transactions)
          ..where((t) => t.uuid.equals(uuid)))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 获取目标记录的最后操作时间戳
  Future<int?> _getLastOperationTimestamp(String targetId) async {
    final rows = await (_db.select(_db.crdtOperations)
          ..where((o) => o.targetId.equals(targetId))
          ..orderBy([(o) => OrderingTerm.desc(o.timestamp)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first.timestamp;
  }

  /// 检查是否有更晚的删除操作
  Future<bool> _hasLaterDeleteOperation(String targetId, int timestamp) async {
    final rows = await (_db.select(_db.crdtOperations)
          ..where((o) => o.targetId.equals(targetId))
          ..where((o) => o.type.equals('delete'))
          ..where((o) => o.timestamp.isBiggerThanValue(timestamp)))
        .get();
    return rows.isNotEmpty;
  }

  /// 保存操作到本地（标记为已同步）
  Future<void> _saveOperationAsSynced(Operation op, int ledgerId) async {
    await _db.into(_db.crdtOperations).insertOnConflictUpdate(
          CrdtOperationsCompanion.insert(
            opId: op.opId,
            ledgerId: ledgerId,
            type: op.type.name,
            targetId: op.targetId,
            timestamp: op.timestamp,
            deviceId: op.deviceId,
            data: Value(op.data != null ? jsonEncode(op.data) : null),
            createdAt: op.createdAt,
            synced: const Value(true),
          ),
        );
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

/// LWW 冲突解决器
///
/// Last-Writer-Wins: 时间戳大的胜出
class LWWResolver {
  /// 判断操作是否应该被应用
  ///
  /// 规则：时间戳大的胜出；时间戳相同时，opId 字典序大的胜出
  static bool shouldApply(Operation newOp, Operation? existingOp) {
    if (existingOp == null) return true;

    if (newOp.timestamp > existingOp.timestamp) {
      return true;
    }

    if (newOp.timestamp == existingOp.timestamp) {
      // 时间戳相同，比较 opId
      return newOp.opId.compareTo(existingOp.opId) > 0;
    }

    return false;
  }
}
