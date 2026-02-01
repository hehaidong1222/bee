import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../system/logger_service.dart';

/// 存量数据 syncId 回填服务
///
/// 升级到 v15 后，历史记录的 sync_id 为 null。
/// 此服务在应用启动时检查并回填所有缺失的 syncId。
/// 仅在首次升级后执行一次（后续所有新记录在写入时即生成 syncId）。
class SyncIdBackfillService {
  final BeeDatabase db;

  static const _uuid = Uuid();

  /// 需要回填 syncId 的表
  static const _tables = [
    'ledgers',
    'accounts',
    'categories',
    'transactions',
    'tags',
    'recurring_transactions',
    'budgets',
    'transaction_attachments',
  ];

  /// 每批处理的记录数
  static const _batchSize = 200;

  SyncIdBackfillService(this.db);

  /// 执行回填
  ///
  /// 返回回填的总记录数。如果没有需要回填的记录，返回 0。
  /// 此方法是幂等的，可以安全地多次调用。
  Future<int> backfill() async {
    int totalBackfilled = 0;

    for (final table in _tables) {
      final count = await _backfillTable(table);
      totalBackfilled += count;
    }

    if (totalBackfilled > 0) {
      logger.info('SyncIdBackfill', '回填完成，共 $totalBackfilled 条记录');
    }

    return totalBackfilled;
  }

  /// 检查是否需要回填（有任何 sync_id 为 null 的记录）
  Future<bool> needsBackfill() async {
    for (final table in _tables) {
      final result = await db.customSelect(
        'SELECT COUNT(*) as cnt FROM $table WHERE sync_id IS NULL',
      ).getSingle();
      final count = result.read<int>('cnt');
      if (count > 0) return true;
    }
    return false;
  }

  /// 回填单个表的 syncId
  Future<int> _backfillTable(String table) async {
    int backfilled = 0;

    while (true) {
      // 查找 sync_id 为 null 的记录（分批）
      final rows = await db.customSelect(
        'SELECT id FROM $table WHERE sync_id IS NULL LIMIT ?',
        variables: [Variable.withInt(_batchSize)],
      ).get();

      if (rows.isEmpty) break;

      // 批量更新
      await db.transaction(() async {
        for (final row in rows) {
          final id = row.read<int>('id');
          final syncId = _uuid.v4();
          await db.customUpdate(
            'UPDATE $table SET sync_id = ? WHERE id = ?',
            variables: [Variable.withString(syncId), Variable.withInt(id)],
            updates: {},
          );
        }
      });

      backfilled += rows.length;
      logger.debug('SyncIdBackfill', '$table: 已回填 $backfilled 条');

      // 如果本批不足 batchSize，说明已经处理完毕
      if (rows.length < _batchSize) break;
    }

    if (backfilled > 0) {
      logger.info('SyncIdBackfill', '$table: 共回填 $backfilled 条');
    }

    return backfilled;
  }
}
