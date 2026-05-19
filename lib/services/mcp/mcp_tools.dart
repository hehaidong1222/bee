import 'dart:convert';
import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';

Map<String, dynamic> getToolDefinitions() {
  return {
    "tools": [
      {
        "name": "get_daily_expenses",
        "description": "鑾峰彇鎸囧畾鏃ユ湡鐨勬墍鏈夋敹鏀褰?,
        "inputSchema": {
          "type": "object",
          "properties": {
            "date": {
              "type": "string",
              "description": "鏃ユ湡锛屾牸寮?YYYY-MM-DD锛屽 2026-05-19锛屾垨浼犲叆 today 琛ㄧず浠婂ぉ"
            }
          },
          "required": ["date"]
        }
      },
      {
        "name": "get_monthly_summary",
        "description": "鑾峰彇鎸囧畾鏈堜唤鐨勬敹鏀眹鎬?,
        "inputSchema": {
          "type": "object",
          "properties": {
            "year": {
              "type": "integer",
              "description": "骞翠唤锛屽 2026"
            },
            "month": {
              "type": "integer",
              "description": "鏈堜唤 1-12"
            }
          },
          "required": ["year", "month"]
        }
      },
      {
        "name": "get_transactions_by_date_range",
        "description": "鑾峰彇鎸囧畾鏃ユ湡鑼冨洿鍐呯殑鎵€鏈夋敹鏀褰?,
        "inputSchema": {
          "type": "object",
          "properties": {
            "start_date": {
              "type": "string",
              "description": "寮€濮嬫棩鏈燂紝鏍煎紡 YYYY-MM-DD"
            },
            "end_date": {
              "type": "string",
              "description": "缁撴潫鏃ユ湡锛屾牸寮?YYYY-MM-DD"
            }
          },
          "required": ["start_date", "end_date"]
        }
      },
      {
        "name": "get_category_totals",
        "description": "鑾峰彇鎸囧畾鏈堜唤鐨勫垎绫绘敮鍑虹粺璁?,
        "inputSchema": {
          "type": "object",
          "properties": {
            "year": {
              "type": "integer",
              "description": "骞翠唤锛屽 2026"
            },
            "month": {
              "type": "integer",
              "description": "鏈堜唤 1-12"
            }
          },
          "required": ["year", "month"]
        }
      }
    ]
  };
}

Future<dynamic> handleToolCall(
  String toolName,
  Map<String, dynamic> arguments,
  BaseRepository repo,
) async {
  switch (toolName) {
    case 'get_daily_expenses':
      return _handleDailyExpenses(arguments, repo);
    case 'get_monthly_summary':
      return _handleMonthlySummary(arguments, repo);
    case 'get_transactions_by_date_range':
      return _handleDateRange(arguments, repo);
    case 'get_category_totals':
      return _handleCategoryTotals(arguments, repo);
    default:
      throw Exception('鏈煡宸ュ叿: $toolName');
  }
}

Future<Map<String, dynamic>> _handleDailyExpenses(
  Map<String, dynamic> args,
  BaseRepository repo,
) async {
  final dateStr = args['date'] as String;
  final date = dateStr == 'today'
      ? DateTime.now()
      : DateTime.tryParse(dateStr);
  if (date == null) {
    return {"error": "鏃犳晥鏃ユ湡鏍煎紡: $dateStr"};
  }

  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = dayStart.add(const Duration(hours: 23, minutes: 59, seconds: 59));

  final txWithCats = await repo.getTransactionsByDateRange(
    ledgerId: await _getDefaultLedgerId(repo),
    startDate: dayStart,
    endDate: dayEnd,
  );

  final items = txWithCats.map((t) => {
    "id": t.t.id,
    "type": t.t.type,
    "amount": t.t.amount,
    "category": t.category?.name,
    "note": t.t.note ?? '',
    "time": t.t.happenedAt.toIso8601String(),
    "account": t.account?.name,
  }).toList();

  final totalIncome = items
      .where((i) => i['type'] == 'income')
      .fold<double>(0, (s, i) => s + (i['amount'] as double));
  final totalExpense = items
      .where((i) => i['type'] == 'expense')
      .fold<double>(0, (s, i) => s + (i['amount'] as double));

  return {
    "date": dateStr,
    "total_income": totalIncome,
    "total_expense": totalExpense,
    "transaction_count": items.length,
    "transactions": items,
  };
}

Future<Map<String, dynamic>> _handleMonthlySummary(
  Map<String, dynamic> args,
  BaseRepository repo,
) async {
  final year = args['year'] as int;
  final month = args['month'] as int;
  final monthDate = DateTime(year, month);

  final txWithCats = await repo.getTransactionsByDateRange(
    ledgerId: await _getDefaultLedgerId(repo),
    startDate: DateTime(year, month, 1),
    endDate: DateTime(year, month + 1, 0, 23, 59, 59),
  );

  double totalIncome = 0;
  double totalExpense = 0;
  for (final t in txWithCats) {
    if (t.t.type == 'income') totalIncome += t.t.amount;
    if (t.t.type == 'expense') totalExpense += t.t.amount;
  }

  return {
    "year": year,
    "month": month,
    "total_income": totalIncome,
    "total_expense": totalExpense,
    "net": totalIncome - totalExpense,
    "transaction_count": txWithCats.length,
  };
}

Future<Map<String, dynamic>> _handleDateRange(
  Map<String, dynamic> args,
  BaseRepository repo,
) async {
  final startDate = DateTime.tryParse(args['start_date'] as String);
  final endDate = DateTime.tryParse(args['end_date'] as String);
  if (startDate == null || endDate == null) {
    return {"error": "鏃犳晥鏃ユ湡鏍煎紡"};
  }

  final endOfDay = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);

  final txWithCats = await repo.getTransactionsByDateRange(
    ledgerId: await _getDefaultLedgerId(repo),
    startDate: startDate,
    endDate: endOfDay,
  );

  final items = txWithCats.map((t) => {
    "id": t.t.id,
    "type": t.t.type,
    "amount": t.t.amount,
    "category": t.category?.name,
    "note": t.t.note ?? '',
    "time": t.t.happenedAt.toIso8601String(),
  }).toList();

  return {
    "start_date": args['start_date'],
    "end_date": args['end_date'],
    "transaction_count": items.length,
    "transactions": items,
  };
}

Future<Map<String, dynamic>> _handleCategoryTotals(
  Map<String, dynamic> args,
  BaseRepository repo,
) async {
  final year = args['year'] as int;
  final month = args['month'] as int;

  final txWithCats = await repo.getTransactionsByDateRange(
    ledgerId: await _getDefaultLedgerId(repo),
    startDate: DateTime(year, month, 1),
    endDate: DateTime(year, month + 1, 0, 23, 59, 59),
  );

  final expenseByCategory = <String, double>{};
  for (final t in txWithCats) {
    if (t.t.type == 'expense') {
      final catName = t.category?.name ?? '鏈垎绫?;
      expenseByCategory[catName] =
          (expenseByCategory[catName] ?? 0) + t.t.amount;
    }
  }

  final sorted = expenseByCategory.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return {
    "year": year,
    "month": month,
    "categories": sorted.map((e) => {
      "category": e.key,
      "amount": e.value,
    }).toList(),
  };
}

Future<int> _getDefaultLedgerId(BaseRepository repo) async {
  final ledgers = await repo.getAllLedgers();
  if (ledgers.isEmpty) throw Exception('娌℃湁璐︽湰');
  return ledgers.first.id;
}
