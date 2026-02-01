import '../data/db.dart';
import 'package:drift/drift.dart';

/// 同步时 FK 转换器
///
/// 本地数据库使用 int 自增 ID 作为外键，但同步时需要转换为
/// 目标记录的 syncId（UUID），以保证跨设备引用一致性。
///
/// 转换方向：
/// - toSyncPayload: 本地 int FK → syncId FK（推送前）
/// - toLocalData: syncId FK → 本地 int FK（拉取后）
class SyncForeignKeyResolver {
  final BeeDatabase db;

  SyncForeignKeyResolver(this.db);

  // ---- FK 映射定义 ----

  /// 每个表的 FK 字段映射
  /// key: 表名, value: FK 字段列表
  static const Map<String, List<FkMapping>> _fkMappings = {
    'transactions': [
      FkMapping('ledgerId', 'ledgerSyncId', 'ledgers'),
      FkMapping('categoryId', 'categorySyncId', 'categories'),
      FkMapping('accountId', 'accountSyncId', 'accounts'),
      FkMapping('toAccountId', 'toAccountSyncId', 'accounts'),
      FkMapping('recurringId', 'recurringSyncId', 'recurring_transactions'),
    ],
    'recurring_transactions': [
      FkMapping('ledgerId', 'ledgerSyncId', 'ledgers'),
      FkMapping('categoryId', 'categorySyncId', 'categories'),
      FkMapping('accountId', 'accountSyncId', 'accounts'),
      FkMapping('toAccountId', 'toAccountSyncId', 'accounts'),
    ],
    'categories': [
      FkMapping('parentId', 'parentSyncId', 'categories'),
    ],
    'accounts': [
      FkMapping('ledgerId', 'ledgerSyncId', 'ledgers'),
    ],
    'transaction_attachments': [
      FkMapping('transactionId', 'transactionSyncId', 'transactions'),
    ],
    'budgets': [
      FkMapping('ledgerId', 'ledgerSyncId', 'ledgers'),
      FkMapping('categoryId', 'categorySyncId', 'categories'),
    ],
    // ledgers 和 tags 没有 FK
  };

  /// 获取表的 FK 映射列表
  static List<FkMapping> getMappings(String table) {
    return _fkMappings[table] ?? const [];
  }

  // ---- 转换方法 ----

  /// 本地记录 → 同步 payload（int FK → syncId FK）
  ///
  /// 将本地数据中的 int FK 字段替换为对应记录的 syncId。
  /// 原始的 int FK 字段会从 payload 中移除。
  Future<Map<String, dynamic>> toSyncPayload(
    String table,
    Map<String, dynamic> localData,
  ) async {
    final mappings = getMappings(table);
    if (mappings.isEmpty) return Map.from(localData);

    final result = Map<String, dynamic>.from(localData);

    for (final mapping in mappings) {
      final localFkValue = result[mapping.localField];
      // 移除本地 int FK 字段
      result.remove(mapping.localField);

      if (localFkValue == null) {
        result[mapping.syncField] = null;
        continue;
      }

      // 查询目标记录的 syncId
      final syncId = await _lookupSyncId(mapping.targetTable, localFkValue as int);
      result[mapping.syncField] = syncId;
    }

    // 移除本地 id 字段（同步用 syncId 标识）
    result.remove('id');

    return result;
  }

  /// 同步 payload → 本地记录（syncId FK → int FK）
  ///
  /// 将同步数据中的 syncId FK 字段转换为本地 int FK。
  /// syncId FK 字段会从结果中移除。
  Future<Map<String, dynamic>> toLocalData(
    String table,
    Map<String, dynamic> syncPayload,
  ) async {
    final mappings = getMappings(table);
    if (mappings.isEmpty) return Map.from(syncPayload);

    final result = Map<String, dynamic>.from(syncPayload);

    for (final mapping in mappings) {
      final syncFkValue = result[mapping.syncField];
      // 移除 syncId FK 字段
      result.remove(mapping.syncField);

      if (syncFkValue == null) {
        result[mapping.localField] = null;
        continue;
      }

      // 查询目标记录的本地 id
      final localId = await _lookupLocalId(mapping.targetTable, syncFkValue as String);
      result[mapping.localField] = localId;
    }

    return result;
  }

  // ---- 内部查询方法 ----

  /// 根据本地 id 查询记录的 syncId
  Future<String?> _lookupSyncId(String table, int localId) async {
    final result = await db.customSelect(
      'SELECT sync_id FROM $table WHERE id = ?',
      variables: [Variable.withInt(localId)],
    ).getSingleOrNull();

    return result?.read<String?>('sync_id');
  }

  /// 根据 syncId 查询记录的本地 id
  Future<int?> _lookupLocalId(String table, String syncId) async {
    final result = await db.customSelect(
      'SELECT id FROM $table WHERE sync_id = ?',
      variables: [Variable.withString(syncId)],
    ).getSingleOrNull();

    return result?.read<int?>('id');
  }
}

/// FK 字段映射定义
class FkMapping {
  /// 本地数据库中的 FK 字段名（int 类型）
  final String localField;

  /// 同步 payload 中的 FK 字段名（syncId 类型）
  final String syncField;

  /// FK 指向的目标表名
  final String targetTable;

  const FkMapping(this.localField, this.syncField, this.targetTable);
}
