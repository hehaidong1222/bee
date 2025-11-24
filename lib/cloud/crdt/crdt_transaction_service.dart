import 'package:drift/drift.dart' as d;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart';
import '../../data/repository.dart';
import '../../services/logger_service.dart';
import 'crdt_repository.dart';
import 'lamport_clock.dart';
import 'operation_generator.dart';

/// CRDT 交易服务
///
/// 包装 Repository 的交易操作，自动生成 CRDT 操作日志
class CRDTTransactionService {
  final BeeDatabase _db;
  final BeeRepository _repo;
  final LamportClock _clock;
  final OperationGenerator _opGenerator;
  final String _deviceId;

  bool _multiDeviceSyncEnabled = false;

  CRDTTransactionService._({
    required BeeDatabase db,
    required BeeRepository repo,
    required LamportClock clock,
    required OperationGenerator opGenerator,
    required String deviceId,
  })  : _db = db,
        _repo = repo,
        _clock = clock,
        _opGenerator = opGenerator,
        _deviceId = deviceId;

  /// 创建服务实例
  static Future<CRDTTransactionService> create({
    required BeeDatabase db,
    required BeeRepository repo,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // 获取或创建设备 ID
    var deviceId = prefs.getString('crdt_device_id');
    if (deviceId == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final random = now % 1000000;
      deviceId = 'device_${now}_$random';
      await prefs.setString('crdt_device_id', deviceId);
    }

    // 初始化 Lamport Clock（从数据库恢复）
    final clock = LamportClock();

    // 恢复 clock 值（取所有账本中最大的 localClock）
    final allSyncStates = await db.select(db.crdtSyncState).get();
    for (final state in allSyncStates) {
      clock.update(state.localClock);
    }

    final opGenerator = OperationGenerator(db, clock, deviceId);

    final service = CRDTTransactionService._(
      db: db,
      repo: repo,
      clock: clock,
      opGenerator: opGenerator,
      deviceId: deviceId,
    );

    // 加载多设备同步开关状态
    service._multiDeviceSyncEnabled =
        prefs.getBool('multi_device_sync_enabled') ?? false;

    return service;
  }

  /// 更新多设备同步开关状态
  void setMultiDeviceSyncEnabled(bool enabled) {
    _multiDeviceSyncEnabled = enabled;
    logger.info('CRDTTransaction', '多设备同步: ${enabled ? "开启" : "关闭"}');
  }

  /// 是否启用多设备同步
  bool get isMultiDeviceSyncEnabled => _multiDeviceSyncEnabled;

  /// 设备 ID
  String get deviceId => _deviceId;

  /// Lamport Clock
  LamportClock get clock => _clock;

  /// 添加交易（带 CRDT 操作生成）
  Future<int> addTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
  }) async {
    // 生成 UUID
    final uuid = _opGenerator.generateUuid();

    // 插入交易
    final id = await _db.into(_db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: type,
            amount: amount,
            categoryId: d.Value(categoryId),
            accountId: d.Value(accountId),
            toAccountId: d.Value(toAccountId),
            happenedAt: d.Value(happenedAt),
            note: d.Value(note),
            uuid: d.Value(uuid),
          ),
        );

    // 如果启用了多设备同步，生成操作日志
    if (_multiDeviceSyncEnabled) {
      await _opGenerator.generateInsert(
        ledgerId: ledgerId,
        targetId: uuid,
        data: {
          'type': type,
          'amount': amount,
          'categoryId': categoryId,
          'accountId': accountId,
          'toAccountId': toAccountId,
          'happenedAt': happenedAt,
          'note': note,
        },
      );
    }

    return id;
  }

  /// 更新交易（带 CRDT 操作生成）
  Future<void> updateTransaction({
    required int id,
    required String type,
    required double amount,
    int? categoryId,
    String? note,
    DateTime? happenedAt,
    d.Value<int?>? accountId,
    d.Value<int?>? toAccountId,
  }) async {
    // 先获取原交易记录，拿到 uuid 和 ledgerId
    final tx = await (_db.select(_db.transactions)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    if (tx == null) {
      logger.warning('CRDTTransaction', '更新失败：交易不存在 id=$id');
      return;
    }

    // 如果没有 uuid，先生成一个
    var uuid = tx.uuid;
    if (uuid == null && _multiDeviceSyncEnabled) {
      uuid = _opGenerator.generateUuid();
      await _db.setTransactionUuid(id, uuid);
    }

    // 更新交易
    await _repo.updateTransaction(
      id: id,
      type: type,
      amount: amount,
      categoryId: categoryId,
      note: note,
      happenedAt: happenedAt,
      accountId: accountId,
      toAccountId: toAccountId,
    );

    // 如果启用了多设备同步，生成操作日志
    if (_multiDeviceSyncEnabled && uuid != null) {
      await _opGenerator.generateUpdate(
        ledgerId: tx.ledgerId,
        targetId: uuid,
        data: {
          'type': type,
          'amount': amount,
          'categoryId': categoryId,
          'note': note,
          if (happenedAt != null) 'happenedAt': happenedAt,
          if (accountId != null && accountId.present) 'accountId': accountId.value,
          if (toAccountId != null && toAccountId.present) 'toAccountId': toAccountId.value,
        },
      );
    }
  }

  /// 删除交易（带 CRDT 操作生成）
  Future<void> deleteTransaction(int id) async {
    // 先获取原交易记录，拿到 uuid 和 ledgerId
    final tx = await (_db.select(_db.transactions)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    if (tx == null) {
      logger.warning('CRDTTransaction', '删除失败：交易不存在 id=$id');
      return;
    }

    // 如果没有 uuid，先生成一个（用于记录删除操作）
    var uuid = tx.uuid;
    if (uuid == null && _multiDeviceSyncEnabled) {
      uuid = _opGenerator.generateUuid();
      await _db.setTransactionUuid(id, uuid);
    }

    // 删除交易
    await _repo.deleteTransaction(id);

    // 如果启用了多设备同步，生成操作日志
    if (_multiDeviceSyncEnabled && uuid != null) {
      await _opGenerator.generateDelete(
        ledgerId: tx.ledgerId,
        targetId: uuid,
      );
    }
  }

  /// 为现有交易生成 UUID（迁移用）
  Future<int> migrateTransactionsWithUuid(int ledgerId) async {
    final txs = await _db.getTransactionsWithoutUuid(ledgerId);
    var count = 0;

    for (final tx in txs) {
      final uuid = _opGenerator.generateUuid();
      await _db.setTransactionUuid(tx.id, uuid);
      count++;
    }

    logger.info('CRDTTransaction', '迁移 UUID 完成: ledgerId=$ledgerId, count=$count');
    return count;
  }
}
