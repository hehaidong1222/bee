import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/db.dart';
import '../pages/transaction/transaction_editor_page.dart';
import '../providers/database_providers.dart';

class TransactionEditUtils {
  static Future<void> editTransaction(
    BuildContext context,
    WidgetRef ref,
    Transaction transaction,
    Category? category,
  ) async {
    final db = ref.read(databaseProvider);
    final repo = ref.read(repositoryProvider);

    // 共享账本 Phase 2:tx 的 categoryId/accountId/tags 在 Editor 共享场景下走
    // override 字段。编辑时需要把 override 的 server syncId 反查回本地
    // SharedXxx 表的 int id,这样 selector 才能 highlight 正确项。
    int? initialCategoryId = transaction.categoryId;
    int? initialAccountId = transaction.accountId;
    int? initialToAccountId = transaction.toAccountId;
    List<int> tagIds;

    final catOverride = transaction.categorySyncIdOverride;
    final accOverride = transaction.accountSyncIdOverride;
    final toAccOverride = transaction.toAccountSyncIdOverride;
    final tagOverride = transaction.tagSyncIdsOverride;

    if (catOverride != null && catOverride.isNotEmpty) {
      final shared = await (db.select(db.sharedCategories)
            ..where((c) => c.syncId.equals(catOverride)))
          .getSingleOrNull();
      initialCategoryId = shared?.id;
    }
    if (accOverride != null && accOverride.isNotEmpty) {
      final shared = await (db.select(db.sharedAccounts)
            ..where((a) => a.syncId.equals(accOverride)))
          .getSingleOrNull();
      initialAccountId = shared?.id;
    }
    if (toAccOverride != null && toAccOverride.isNotEmpty) {
      final shared = await (db.select(db.sharedAccounts)
            ..where((a) => a.syncId.equals(toAccOverride)))
          .getSingleOrNull();
      initialToAccountId = shared?.id;
    }
    if (tagOverride != null && tagOverride.isNotEmpty) {
      // tagSyncIdsOverride 是 JSON array of server syncIds,反查 SharedTags.id
      List<String> syncIds = const [];
      try {
        final decoded = jsonDecode(tagOverride);
        if (decoded is List) {
          syncIds = decoded.whereType<String>().toList();
        }
      } catch (_) {}
      if (syncIds.isEmpty) {
        tagIds = const [];
      } else {
        final rows = await db.customSelect(
          'SELECT id FROM shared_tags WHERE sync_id IN (${List.filled(syncIds.length, '?').join(',')})',
          variables: [for (final s in syncIds) Variable<String>(s)],
          readsFrom: {db.sharedTags},
        ).get();
        tagIds = rows.map((r) => r.read<int>('id')).toList();
      }
    } else {
      final tags = await repo.getTagsForTransaction(transaction.id);
      tagIds = tags.map((t) => t.id).toList();
    }

    if (!context.mounted) return;

    // 所有类型（收入/支出/转账）都使用交易编辑器页面
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: transaction.type, // 'expense', 'income', 或 'transfer'
          quickAdd: true,
          initialCategoryId: initialCategoryId,
          initialAmount: transaction.amount,
          initialDate: transaction.happenedAt,
          initialNote: transaction.note,
          editingTransactionId: transaction.id,
          initialAccountId: initialAccountId,
          // 转账特有的参数
          initialToAccountId: initialToAccountId,
          // 标签
          initialTagIds: tagIds,
        ),
      ),
    );
  }
}