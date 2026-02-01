import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../cloud/sync_backend.dart';
import '../../../cloud/sync_notifier.dart';
import '../recurring_transaction_repository.dart';

/// 本地周期记账Repository实现
/// 基于 Drift 数据库实现
class LocalRecurringTransactionRepository implements RecurringTransactionRepository {
  final BeeDatabase db;
  final SyncNotifier? syncNotifier;
  static const _uuid = Uuid();

  LocalRecurringTransactionRepository(this.db, {this.syncNotifier});

  @override
  Future<List<RecurringTransaction>> getAllRecurringTransactions() async {
    return await (db.select(db.recurringTransactions)).get();
  }

  @override
  Future<List<RecurringTransaction>> getRecurringTransactionsByLedger(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
  }

  @override
  Future<List<RecurringTransaction>> getEnabledRecurringTransactions(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId) & t.enabled.equals(true)))
        .get();
  }

  @override
  Future<int> addRecurringTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool enabled = true,
  }) async {
    final syncId = _uuid.v4();
    final id = await db.into(db.recurringTransactions).insert(
      RecurringTransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: type,
        amount: amount,
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: frequency,
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: startDate,
        endDate: d.Value(endDate),
        enabled: d.Value(enabled),
        syncId: d.Value(syncId),
      ),
    );
    syncNotifier?.onRecordChanged('recurring_transactions', syncId, SyncOperation.upsert, {
      'ledgerId': ledgerId,
      'type': type,
      'amount': amount,
      'categoryId': categoryId,
      'accountId': accountId,
      'toAccountId': toAccountId,
      'note': note,
      'frequency': frequency,
      'interval': interval,
      'dayOfMonth': dayOfMonth,
      'dayOfWeek': dayOfWeek,
      'monthOfYear': monthOfYear,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate?.toIso8601String(),
      'enabled': enabled,
    });
    return id;
  }

  @override
  Future<void> updateRecurringTransaction({
    required int id,
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool? enabled,
    DateTime? lastGeneratedDate,
  }) async {
    final now = DateTime.now();
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(
      RecurringTransactionsCompanion(
        ledgerId: d.Value(ledgerId),
        type: d.Value(type),
        amount: d.Value(amount),
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: d.Value(frequency),
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: d.Value(startDate),
        endDate: d.Value(endDate),
        enabled: enabled != null ? d.Value(enabled) : const d.Value.absent(),
        lastGeneratedDate: d.Value(lastGeneratedDate),
        updatedAt: d.Value(now),
      ),
    );
    if (syncNotifier != null) {
      final record = await (db.select(db.recurringTransactions)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (record?.syncId != null) {
        syncNotifier!.onRecordChanged('recurring_transactions', record!.syncId!, SyncOperation.upsert, {
          'ledgerId': record.ledgerId,
          'type': record.type,
          'amount': record.amount,
          'categoryId': record.categoryId,
          'accountId': record.accountId,
          'toAccountId': record.toAccountId,
          'note': record.note,
          'frequency': record.frequency,
          'interval': record.interval,
          'startDate': record.startDate.toIso8601String(),
          'endDate': record.endDate?.toIso8601String(),
          'enabled': record.enabled,
          'updatedAt': now.toIso8601String(),
        });
      }
    }
  }

  @override
  Future<void> deleteRecurringTransaction(int id) async {
    String? syncId;
    if (syncNotifier != null) {
      final record = await (db.select(db.recurringTransactions)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      syncId = record?.syncId;
    }
    await (db.delete(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .go();
    if (syncId != null) {
      syncNotifier!.onRecordChanged('recurring_transactions', syncId, SyncOperation.delete, null);
    }
  }

  @override
  Future<void> toggleRecurringTransaction(int id, bool enabled) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      enabled: d.Value(enabled),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Future<void> updateLastGeneratedDate(int id, DateTime date) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      lastGeneratedDate: d.Value(date),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Stream<List<RecurringTransaction>> watchAllRecurringTransactions() {
    return (db.select(db.recurringTransactions)).watch();
  }

  @override
  Stream<List<RecurringTransaction>> watchRecurringTransactionsByLedger(int ledgerId) {
    return (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .watch();
  }

  @override
  Future<void> batchInsertRecurringTransactions(
      List<RecurringTransactionsCompanion> items) async {
    await db.batch((batch) {
      batch.insertAll(db.recurringTransactions, items);
    });
  }
}
