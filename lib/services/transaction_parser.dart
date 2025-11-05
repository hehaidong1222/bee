/// 交易类型枚举
enum TransactionType {
  expense, // 支出
  income, // 收入
}

/// 交易记录解析结果
class ParsedTransaction {
  final double? amount;
  final String? categoryName;
  final String? note;
  final TransactionType? type;
  final String originalText;

  ParsedTransaction({
    this.amount,
    this.categoryName,
    this.note,
    this.type,
    required this.originalText,
  });

  bool get isValid => amount != null;
}

/// 语音文本解析器
/// 支持的格式：
/// - "午饭50" / "午饭花了50"
/// - "午餐50块" / "午餐50元"
/// - "今天吃饭花了50" / "今天吃饭花了50块钱"
/// - "收入工资5000" / "工资5000"
class TransactionParser {
  // 金额相关关键词
  static const _amountKeywords = ['花了', '花', '支出', '买', '付', '付了'];
  static const _incomeKeywords = ['收入', '赚了', '赚', '收到', '入账'];

  // 货币单位
  static const _currencyUnits = ['元', '块', '块钱', '元钱', '刀'];

  // 常见分类关键词映射
  static final _categoryKeywords = {
    '餐饮': ['吃', '饭', '餐', '午饭', '晚饭', '早饭', '午餐', '晚餐', '早餐', '夜宵', '宵夜', '零食', '水果', '饮料', '咖啡', '奶茶'],
    '交通': ['打车', '出租车', '滴滴', '地铁', '公交', '油费', '加油', '停车', '过路费'],
    '购物': ['买', '购', '衣服', '鞋', '包', '化妆品', '日用品', '超市'],
    '娱乐': ['电影', '游戏', '唱歌', 'KTV', '旅游', '景点', '门票'],
    '医疗': ['医院', '看病', '药', '体检', '挂号'],
    '住房': ['房租', '水费', '电费', '燃气费', '物业费', '房贷'],
    '工资': ['工资', '薪水', '薪资'],
    '奖金': ['奖金', '红包', '年终奖'],
    '其他收入': ['兼职', '外快'],
  };

  /// 解析语音文本为交易记录
  static ParsedTransaction parse(String text) {
    if (text.trim().isEmpty) {
      return ParsedTransaction(originalText: text);
    }

    final cleanText = text.trim();

    // 1. 提取金额
    final amount = _extractAmount(cleanText);

    // 2. 判断交易类型（支出/收入）
    final type = _extractType(cleanText);

    // 3. 提取分类
    final categoryName = _extractCategory(cleanText);

    // 4. 提取备注（去掉金额和分类后的剩余文本）
    final note = _extractNote(cleanText, amount, categoryName);

    return ParsedTransaction(
      amount: amount,
      categoryName: categoryName,
      note: note?.isNotEmpty == true ? note : null,
      type: type,
      originalText: text,
    );
  }

  /// 提取金额
  static double? _extractAmount(String text) {
    // 移除货币单位
    String processedText = text;
    for (final unit in _currencyUnits) {
      processedText = processedText.replaceAll(unit, ' ');
    }

    // 使用正则提取数字（支持小数）
    final numberPattern = RegExp(r'(\d+\.?\d*)');
    final matches = numberPattern.allMatches(processedText);

    if (matches.isEmpty) return null;

    // 找最大的数字（通常是金额）
    double? maxAmount;
    for (final match in matches) {
      final numStr = match.group(1);
      if (numStr != null) {
        final num = double.tryParse(numStr);
        if (num != null && (maxAmount == null || num > maxAmount)) {
          maxAmount = num;
        }
      }
    }

    return maxAmount;
  }

  /// 判断交易类型
  static TransactionType _extractType(String text) {
    // 检查是否包含收入关键词
    for (final keyword in _incomeKeywords) {
      if (text.contains(keyword)) {
        return TransactionType.income;
      }
    }

    // 默认为支出
    return TransactionType.expense;
  }

  /// 提取分类名称
  static String? _extractCategory(String text) {
    // 遍历分类关键词映射
    for (final entry in _categoryKeywords.entries) {
      for (final keyword in entry.value) {
        if (text.contains(keyword)) {
          return entry.key;
        }
      }
    }

    return null;
  }

  /// 提取备注
  static String? _extractNote(String text, double? amount, String? category) {
    String note = text;

    // 移除金额相关文本
    if (amount != null) {
      note = note.replaceAll(RegExp(r'\d+\.?\d*'), '');
      for (final unit in _currencyUnits) {
        note = note.replaceAll(unit, '');
      }
    }

    // 移除金额关键词
    for (final keyword in [..._amountKeywords, ..._incomeKeywords]) {
      note = note.replaceAll(keyword, '');
    }

    // 移除分类关键词
    if (category != null) {
      final categoryKeywords = _categoryKeywords[category] ?? [];
      for (final keyword in categoryKeywords) {
        note = note.replaceAll(keyword, '');
      }
    }

    // 清理空格
    note = note.trim();

    return note.isEmpty ? null : note;
  }
}
