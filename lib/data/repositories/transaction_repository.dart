import '../db.dart';
import '../models/transaction_display_item.dart';

/// 交易Repository接口
/// 定义交易相关的所有数据操作
abstract class TransactionRepository {
  /// 获取最近的交易记录
  Stream<List<Transaction>> watchRecentTransactions({
    required int ledgerId,
    int limit = 20,
  });

  /// 获取指定月份的交易记录
  Stream<List<Transaction>> watchTransactionsInMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取所有交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category})>> watchTransactionsWithCategoryAll({
    required int ledgerId,
  });

  /// 获取所有交易记录（带分类信息）- 非 Stream 版本
  Stream<List<({Transaction t, Category? category})>> transactionsWithCategoryAll({
    required int ledgerId,
  });

  /// 根据ID获取单条交易
  Future<Transaction?> getTransactionById(int id);

  /// 获取指定月份的交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category})>> watchTransactionsWithCategoryInMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定年份的交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category})>> watchTransactionsWithCategoryInYear({
    required int ledgerId,
    required int year,
  });

  /// 获取指定分类和时间范围的交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category})>> watchTransactionsForCategoryInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    int? categoryId,
    required String type,
  });

  /// 添加交易
  Future<int> addTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
  });

  /// 批量新增交易，单事务内插入，返回插入条数
  Future<int> insertTransactionsBatch(List<TransactionsCompanion> items);

  /// 插入单条交易（使用 Companion 对象）
  Future<int> insertTransactionCompanion(TransactionsCompanion item);

  /// 更新交易
  Future<void> updateTransaction({
    required int id,
    required String type,
    required double amount,
    int? categoryId,
    String? note,
    DateTime? happenedAt,
    dynamic accountId,
  });

  /// 删除交易
  Future<void> deleteTransaction(int id);

  /// 获取指定类型和时间范围内的交易数量
  Future<int> countByTypeInRange({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 获取账本的所有交易记录
  Future<List<Transaction>> getTransactionsByLedger(int ledgerId);

  /// 获取账本的最近N条交易记录（带 LIMIT，用于预加载优化）
  Future<List<Transaction>> getRecentTransactionsByLedger(int ledgerId, {int limit = 20});

  /// 获取账本在指定时间范围内的交易记录
  Future<List<Transaction>> getTransactionsByLedgerInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });

  /// 更新交易（通过ID和字段）
  Future<void> updateTransactionFields({
    required int id,
    int? accountId,
    int? toAccountId,
  });

  /// 获取账本的首笔交易（按时间排序）
  Future<Transaction?> getFirstTransactionByLedger(int ledgerId);

  /// 获取账本的末笔交易（按时间排序）
  Future<Transaction?> getLastTransactionByLedger(int ledgerId);

  /// 更新交易的账本
  Future<void> updateTransactionLedger({
    required int id,
    required int ledgerId,
  });

  /// 获取所有交易记录（带完整详情：分类、标签、附件数量）
  /// 采用渐进式加载：
  /// 1. 首次 yield 返回基础数据（isDetailLoading=true）
  /// 2. 异步加载标签和附件后，再次 yield 完整数据（isDetailLoading=false）
  Stream<List<TransactionDisplayItem>> watchTransactionsWithDetails({
    required int ledgerId,
  });

  /// 获取首屏交易数据（带完整详情）
  /// 用于启动预加载，返回当月数据，如果不足 minCount 条则返回最近 minCount 条
  /// 一次性加载完整详情（分类、标签、附件），无需二次刷新
  Future<List<TransactionDisplayItem>> getInitialTransactionsWithDetails({
    required int ledgerId,
    int minCount = 20,
  });
}
