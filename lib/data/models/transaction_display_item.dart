import '../db.dart';

/// 交易列表展示项
/// 聚合了交易、分类、标签和附件数量信息
/// 用于首页等交易列表的一次性数据加载
class TransactionDisplayItem {
  /// 交易数据
  final Transaction transaction;

  /// 分类数据（可为空，如转账交易）
  final Category? category;

  /// 标签列表
  final List<Tag> tags;

  /// 附件数量
  final int attachmentCount;

  /// 是否正在加载标签/附件数据
  /// true: 标签和附件区域显示占位符
  /// false: 显示真实数据
  final bool isDetailLoading;

  const TransactionDisplayItem({
    required this.transaction,
    this.category,
    this.tags = const [],
    this.attachmentCount = 0,
    this.isDetailLoading = false,
  });

  /// 创建副本，支持更新部分字段
  TransactionDisplayItem copyWith({
    Transaction? transaction,
    Category? category,
    List<Tag>? tags,
    int? attachmentCount,
    bool? isDetailLoading,
  }) {
    return TransactionDisplayItem(
      transaction: transaction ?? this.transaction,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      attachmentCount: attachmentCount ?? this.attachmentCount,
      isDetailLoading: isDetailLoading ?? this.isDetailLoading,
    );
  }

  /// 快捷访问交易 ID
  int get id => transaction.id;

  /// 快捷访问交易类型
  String get type => transaction.type;

  /// 快捷访问交易金额
  double get amount => transaction.amount;

  /// 快捷访问交易时间
  DateTime get happenedAt => transaction.happenedAt;

  /// 快捷访问备注
  String? get note => transaction.note;

  /// 快捷访问账户 ID
  int? get accountId => transaction.accountId;

  /// 快捷访问目标账户 ID（转账）
  int? get toAccountId => transaction.toAccountId;

  /// 是否有标签
  bool get hasTags => tags.isNotEmpty;

  /// 是否有附件
  bool get hasAttachments => attachmentCount > 0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TransactionDisplayItem) return false;
    return transaction.id == other.transaction.id &&
        category?.id == other.category?.id &&
        tags.length == other.tags.length &&
        attachmentCount == other.attachmentCount &&
        isDetailLoading == other.isDetailLoading;
  }

  @override
  int get hashCode => Object.hash(
        transaction.id,
        category?.id,
        tags.length,
        attachmentCount,
        isDetailLoading,
      );
}
