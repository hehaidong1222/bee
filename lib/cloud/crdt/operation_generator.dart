import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../../services/logger_service.dart';
import 'lamport_clock.dart';
import 'operation.dart';

/// 操作生成器
///
/// 负责在本地数据变更时生成对应的 CRDT 操作
class OperationGenerator {
  final BeeDatabase _db;
  final LamportClock _clock;
  final String _deviceId;
  final _uuid = const Uuid();

  int _seq = 0;

  OperationGenerator(this._db, this._clock, this._deviceId);

  /// 生成操作 ID
  ///
  /// 格式: {timestamp}-{deviceId}-{seq}
  /// 确保全局唯一且可排序
  String _generateOpId() {
    final ts = _clock.tick();
    final opId = '$ts-$_deviceId-${_seq++}';
    return opId;
  }

  /// 生成新的 UUID
  String generateUuid() => _uuid.v4();

  /// 生成插入操作
  Future<Operation> generateInsert({
    required int ledgerId,
    required String targetId,
    required Map<String, dynamic> data,
  }) async {
    final opId = _generateOpId();
    final op = Operation(
      opId: opId,
      type: OperationType.insert,
      targetId: targetId,
      timestamp: _clock.value,
      deviceId: _deviceId,
      data: data,
      createdAt: DateTime.now(),
    );

    // 保存到本地数据库
    await _saveOperation(op, ledgerId);
    logger.debug('OperationGenerator', '生成 insert 操作: $opId');

    return op;
  }

  /// 生成更新操作
  Future<Operation> generateUpdate({
    required int ledgerId,
    required String targetId,
    required Map<String, dynamic> data,
  }) async {
    final opId = _generateOpId();
    final op = Operation(
      opId: opId,
      type: OperationType.update,
      targetId: targetId,
      timestamp: _clock.value,
      deviceId: _deviceId,
      data: data,
      createdAt: DateTime.now(),
    );

    await _saveOperation(op, ledgerId);
    logger.debug('OperationGenerator', '生成 update 操作: $opId');

    return op;
  }

  /// 生成删除操作
  Future<Operation> generateDelete({
    required int ledgerId,
    required String targetId,
  }) async {
    final opId = _generateOpId();
    final op = Operation(
      opId: opId,
      type: OperationType.delete,
      targetId: targetId,
      timestamp: _clock.value,
      deviceId: _deviceId,
      data: null,
      createdAt: DateTime.now(),
    );

    await _saveOperation(op, ledgerId);
    logger.debug('OperationGenerator', '生成 delete 操作: $opId');

    return op;
  }

  /// 保存操作到本地数据库
  Future<void> _saveOperation(Operation op, int ledgerId) async {
    await _db.into(_db.crdtOperations).insert(
          CrdtOperationsCompanion.insert(
            opId: op.opId,
            ledgerId: ledgerId,
            type: op.type.name,
            targetId: op.targetId,
            timestamp: op.timestamp,
            deviceId: op.deviceId,
            data: Value(op.data != null ? _encodeData(op.data!) : null),
            createdAt: op.createdAt,
            synced: const Value(false),
          ),
        );
  }

  String _encodeData(Map<String, dynamic> data) {
    // 处理 DateTime 类型
    final encoded = <String, dynamic>{};
    for (final entry in data.entries) {
      if (entry.value is DateTime) {
        encoded[entry.key] = (entry.value as DateTime).toIso8601String();
      } else {
        encoded[entry.key] = entry.value;
      }
    }
    return jsonEncode(encoded);
  }
}
