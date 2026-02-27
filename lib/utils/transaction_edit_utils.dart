import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudBackendType;
import '../data/db.dart';
import '../cloud/transactions_sync_manager.dart';
import '../pages/transaction/transaction_editor_page.dart';
import '../providers/database_providers.dart';
import '../providers/sync_providers.dart';
import '../l10n/app_localizations.dart';
import '../widgets/ui/ui.dart';

class TransactionEditUtils {
  static DateTime? _lastExperimentalHintAt;

  static Future<void> _maybeShowExperimentalHint(
    BuildContext context,
    WidgetRef ref, {
    required int ledgerId,
  }) async {
    if (!context.mounted) return;
    final cloudConfig = ref.read(activeCloudConfigProvider).valueOrNull;
    if (cloudConfig == null ||
        cloudConfig.type != CloudBackendType.beecountCloud) {
      return;
    }
    final repo = ref.read(repositoryProvider);
    final ledger = await repo.getLedgerById(ledgerId);
    if (ledger == null || ledger.type.trim().toLowerCase() != 'shared') {
      return;
    }
    final now = DateTime.now();
    final lastAt = _lastExperimentalHintAt;
    if (lastAt != null && now.difference(lastAt).inSeconds < 3) {
      return;
    }
    _lastExperimentalHintAt = now;
    if (!context.mounted) return;
    showToast(
      context,
      AppLocalizations.of(context).cloudCollabExperimentalWriteHint,
    );
  }

  static Future<bool> canWriteLedger(
    BuildContext context,
    WidgetRef ref, {
    int? ledgerId,
    bool showDeniedMessage = true,
  }) async {
    final int resolvedLedgerId = ledgerId ?? ref.read(currentLedgerIdProvider);
    final sync = ref.read(syncServiceProvider);
    if (sync is! TransactionsSyncManager) {
      return true;
    }
    final allowed = await sync.canWriteLedger(ledgerId: resolvedLedgerId);
    if (!allowed && showDeniedMessage && context.mounted) {
      showToast(
        context,
        AppLocalizations.of(context).cloudCollabWriteDeniedMessage,
      );
    } else if (allowed) {
      await _maybeShowExperimentalHint(
        context,
        ref,
        ledgerId: resolvedLedgerId,
      );
    }
    return allowed;
  }

  static Future<bool> canModifyTransaction(
    BuildContext context,
    WidgetRef ref,
    Transaction transaction, {
    int? ledgerId,
    bool showDeniedMessage = true,
  }) async {
    return canModifyTransactionById(
      context,
      ref,
      transactionId: transaction.id,
      ledgerId: ledgerId,
      showDeniedMessage: showDeniedMessage,
    );
  }

  static Future<bool> canModifyTransactionById(
    BuildContext context,
    WidgetRef ref, {
    required int transactionId,
    int? ledgerId,
    bool showDeniedMessage = true,
  }) async {
    final int resolvedLedgerId = ledgerId ?? ref.read(currentLedgerIdProvider);
    final sync = ref.read(syncServiceProvider);
    if (sync is! TransactionsSyncManager) {
      return true;
    }
    final allowed = await sync.canModifyTransaction(
      ledgerId: resolvedLedgerId,
      transactionId: transactionId,
    );
    if (!allowed && showDeniedMessage && context.mounted) {
      showToast(
        context,
        AppLocalizations.of(context).cloudCollabEditDeniedMessage,
      );
    } else if (allowed) {
      await _maybeShowExperimentalHint(
        context,
        ref,
        ledgerId: resolvedLedgerId,
      );
    }
    return allowed;
  }

  static Future<bool> canManageLedger(
    BuildContext context,
    WidgetRef ref, {
    int? ledgerId,
    bool showDeniedMessage = true,
  }) async {
    final int resolvedLedgerId = ledgerId ?? ref.read(currentLedgerIdProvider);
    final sync = ref.read(syncServiceProvider);
    if (sync is! TransactionsSyncManager) {
      return true;
    }
    final allowed = await sync.canManageLedger(ledgerId: resolvedLedgerId);
    if (!allowed && showDeniedMessage && context.mounted) {
      showToast(
        context,
        AppLocalizations.of(context).cloudCollabManageDeniedMessage,
      );
    } else if (allowed) {
      await _maybeShowExperimentalHint(
        context,
        ref,
        ledgerId: resolvedLedgerId,
      );
    }
    return allowed;
  }

  static Future<void> editTransaction(
    BuildContext context,
    WidgetRef ref,
    Transaction transaction,
    Category? category,
  ) async {
    final allowed = await canModifyTransaction(context, ref, transaction);
    if (!allowed) {
      return;
    }

    // 获取交易关联的标签ID
    final repo = ref.read(repositoryProvider);
    final tags = await repo.getTagsForTransaction(transaction.id);
    final tagIds = tags.map((t) => t.id).toList();

    if (!context.mounted) return;

    // 所有类型（收入/支出/转账）都使用交易编辑器页面
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: transaction.type, // 'expense', 'income', 或 'transfer'
          quickAdd: true,
          initialCategoryId: transaction.categoryId,
          initialAmount: transaction.amount,
          initialDate: transaction.happenedAt,
          initialNote: transaction.note,
          editingTransactionId: transaction.id,
          initialAccountId: transaction.accountId,
          // 转账特有的参数
          initialToAccountId: transaction.toAccountId,
          // 标签
          initialTagIds: tagIds,
        ),
      ),
    );
  }
}
