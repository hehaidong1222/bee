import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/db.dart';
import '../system/logger_service.dart';

class CollabSyncMigrationService {
  CollabSyncMigrationService._();

  static const _backupTable = 'collab_sync_migration_backups';

  static Future<void> migrateSchemaV15(
    BeeDatabase db, {
    required int fromSchema,
    required int toSchema,
  }) async {
    await createPreMigrationBackup(
      db,
      fromSchema: fromSchema,
      toSchema: toSchema,
    );
    await _ensureSyncColumns(db);
    await _ensureSyncTables(db);
    await _backfillSyncId(db);
  }

  static Future<void> initializeFreshSchemaV15(BeeDatabase db) async {
    await _ensureSyncColumns(db);
    await _ensureSyncTables(db);
    await _backfillSyncId(db);
  }

  static Future<void> createPreMigrationBackup(
    BeeDatabase db, {
    required int fromSchema,
    required int toSchema,
  }) async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS $_backupTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_schema INTEGER NOT NULL,
        to_schema INTEGER NOT NULL,
        backup_path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'ready'
      )
    ''');

    final existing = await db.customSelect(
      '''
      SELECT id FROM $_backupTable
      WHERE from_schema = $fromSchema AND to_schema = $toSchema
      ORDER BY id DESC
      LIMIT 1
      ''',
    ).getSingleOrNull();
    if (existing != null) {
      logger.info(
        'CollabMigration',
        'Skip backup, existing backup metadata found for $fromSchema->$toSchema',
      );
      return;
    }

    final documentsDir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(documentsDir.path, 'migration_backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    final backupPath = p.join(
      backupDir.path,
      'beecount_sync_v${fromSchema}_to_v${toSchema}_$ts.sqlite',
    );

    final escaped = backupPath.replaceAll("'", "''");
    try {
      await db.customStatement("VACUUM INTO '$escaped'");
    } catch (e) {
      logger.warning(
        'CollabMigration',
        'VACUUM INTO failed, fallback to file copy: $e',
      );
      final dbPath = p.join(documentsDir.path, 'beecount.sqlite');
      final source = File(dbPath);
      if (!await source.exists()) {
        rethrow;
      }
      await source.copy(backupPath);
    }

    await db.customStatement(
      '''
      INSERT INTO $_backupTable (from_schema, to_schema, backup_path, created_at, status)
      VALUES (?, ?, ?, ?, 'ready')
      ''',
      [fromSchema, toSchema, backupPath, ts ~/ 1000],
    );

    logger.info('CollabMigration', 'Pre-migration backup created: $backupPath');
  }

  static Future<List<CollabSyncBackupMeta>> listBackups(BeeDatabase db) async {
    final rows = await db.customSelect(
      '''
      SELECT id, from_schema, to_schema, backup_path, created_at, status
      FROM $_backupTable
      ORDER BY id DESC
      ''',
    ).get();

    return rows
        .map(
          (row) => CollabSyncBackupMeta(
            id: (row.data['id'] as num).toInt(),
            fromSchema: (row.data['from_schema'] as num).toInt(),
            toSchema: (row.data['to_schema'] as num).toInt(),
            backupPath: row.data['backup_path']?.toString() ?? '',
            createdAtEpochSeconds:
                (row.data['created_at'] as num?)?.toInt() ?? 0,
            status: row.data['status']?.toString() ?? 'unknown',
          ),
        )
        .toList(growable: false);
  }

  static Future<CollabSyncRollbackInfo?> latestRollbackInfo(
      BeeDatabase db) async {
    final backups = await listBackups(db);
    if (backups.isEmpty) {
      return null;
    }
    final latest = backups.first;
    return CollabSyncRollbackInfo(
      backupPath: latest.backupPath,
      fromSchema: latest.fromSchema,
      toSchema: latest.toSchema,
      note:
          'Close app, replace beecount.sqlite with backup file, then relaunch.',
    );
  }

  static Future<void> _ensureSyncColumns(BeeDatabase db) async {
    await _ensureColumn(
      db,
      table: 'ledgers',
      column: 'sync_id',
      sql: "ALTER TABLE ledgers ADD COLUMN sync_id TEXT",
    );
    await _ensureColumn(
      db,
      table: 'ledgers',
      column: 'last_change_id',
      sql:
          "ALTER TABLE ledgers ADD COLUMN last_change_id INTEGER NOT NULL DEFAULT 0",
    );
    await _ensureColumn(
      db,
      table: 'ledgers',
      column: 'created_by_user_id',
      sql: "ALTER TABLE ledgers ADD COLUMN created_by_user_id TEXT",
    );

    await _ensureColumn(
      db,
      table: 'transactions',
      column: 'sync_id',
      sql: "ALTER TABLE transactions ADD COLUMN sync_id TEXT",
    );
    await _ensureColumn(
      db,
      table: 'transactions',
      column: 'last_change_id',
      sql:
          "ALTER TABLE transactions ADD COLUMN last_change_id INTEGER NOT NULL DEFAULT 0",
    );
    await _ensureColumn(
      db,
      table: 'transactions',
      column: 'created_by_user_id',
      sql: "ALTER TABLE transactions ADD COLUMN created_by_user_id TEXT",
    );

    await _ensureColumn(
      db,
      table: 'accounts',
      column: 'sync_id',
      sql: "ALTER TABLE accounts ADD COLUMN sync_id TEXT",
    );
    await _ensureColumn(
      db,
      table: 'accounts',
      column: 'last_change_id',
      sql:
          "ALTER TABLE accounts ADD COLUMN last_change_id INTEGER NOT NULL DEFAULT 0",
    );
    await _ensureColumn(
      db,
      table: 'accounts',
      column: 'created_by_user_id',
      sql: "ALTER TABLE accounts ADD COLUMN created_by_user_id TEXT",
    );

    await _ensureColumn(
      db,
      table: 'categories',
      column: 'sync_id',
      sql: "ALTER TABLE categories ADD COLUMN sync_id TEXT",
    );
    await _ensureColumn(
      db,
      table: 'categories',
      column: 'last_change_id',
      sql:
          "ALTER TABLE categories ADD COLUMN last_change_id INTEGER NOT NULL DEFAULT 0",
    );
    await _ensureColumn(
      db,
      table: 'categories',
      column: 'created_by_user_id',
      sql: "ALTER TABLE categories ADD COLUMN created_by_user_id TEXT",
    );

    await _ensureColumn(
      db,
      table: 'tags',
      column: 'sync_id',
      sql: "ALTER TABLE tags ADD COLUMN sync_id TEXT",
    );
    await _ensureColumn(
      db,
      table: 'tags',
      column: 'last_change_id',
      sql:
          "ALTER TABLE tags ADD COLUMN last_change_id INTEGER NOT NULL DEFAULT 0",
    );
    await _ensureColumn(
      db,
      table: 'tags',
      column: 'created_by_user_id',
      sql: "ALTER TABLE tags ADD COLUMN created_by_user_id TEXT",
    );

    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_ledgers_sync_id ON ledgers(sync_id)',
    );
    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_sync_id ON transactions(sync_id)',
    );
    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_sync_id ON accounts(sync_id)',
    );
    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_sync_id ON categories(sync_id)',
    );
    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_sync_id ON tags(sync_id)',
    );
  }

  static Future<void> _ensureSyncTables(BeeDatabase db) async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_state (
        ledger_sync_id TEXT PRIMARY KEY,
        server_cursor INTEGER NOT NULL DEFAULT 0,
        last_change_id INTEGER NOT NULL DEFAULT 0,
        last_pull_at INTEGER,
        last_push_at INTEGER,
        last_error TEXT,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    ''');

    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ledger_sync_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_sync_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload_json TEXT,
        base_change_id INTEGER,
        request_id TEXT,
        idempotency_key TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        source TEXT NOT NULL DEFAULT 'local',
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    ''');

    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status, id)',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_ledger_status ON sync_queue(ledger_sync_id, status, id)',
    );
    await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_idempotency ON sync_queue(idempotency_key) WHERE idempotency_key IS NOT NULL',
    );
  }

  static Future<void> _backfillSyncId(BeeDatabase db) async {
    await db.customStatement("""
      UPDATE ledgers
      SET sync_id = 'ledger_' || id || '.json'
      WHERE sync_id IS NULL OR TRIM(sync_id) = ''
    """);

    await db.customStatement("""
      UPDATE transactions
      SET sync_id = 'tx_' || COALESCE(ledger_id, 0) || '_' || id
      WHERE sync_id IS NULL OR TRIM(sync_id) = ''
    """);

    await db.customStatement("""
      UPDATE accounts
      SET sync_id = 'account_' || COALESCE(ledger_id, 0) || '_' || id
      WHERE sync_id IS NULL OR TRIM(sync_id) = ''
    """);

    await db.customStatement("""
      UPDATE categories
      SET sync_id = 'category_' || id
      WHERE sync_id IS NULL OR TRIM(sync_id) = ''
    """);

    await db.customStatement("""
      UPDATE tags
      SET sync_id = 'tag_' || id
      WHERE sync_id IS NULL OR TRIM(sync_id) = ''
    """);
  }

  static Future<void> _ensureColumn(
    BeeDatabase db, {
    required String table,
    required String column,
    required String sql,
  }) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    final exists = rows.any((row) => row.data['name'] == column);
    if (!exists) {
      await db.customStatement(sql);
    }
  }
}

class CollabSyncBackupMeta {
  const CollabSyncBackupMeta({
    required this.id,
    required this.fromSchema,
    required this.toSchema,
    required this.backupPath,
    required this.createdAtEpochSeconds,
    required this.status,
  });

  final int id;
  final int fromSchema;
  final int toSchema;
  final String backupPath;
  final int createdAtEpochSeconds;
  final String status;
}

class CollabSyncRollbackInfo {
  const CollabSyncRollbackInfo({
    required this.backupPath,
    required this.fromSchema,
    required this.toSchema,
    required this.note,
  });

  final String backupPath;
  final int fromSchema;
  final int toSchema;
  final String note;
}
