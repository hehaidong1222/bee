import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../data/db.dart';
import '../../services/logger_service.dart';
import 'crdt_repository.dart';
import 'lamport_clock.dart';
import 'operation.dart';
import 'operation_applier.dart';

/// 同步结果
class SyncResult {
  final int uploaded;
  final int downloaded;
  final int conflicts;
  final String? error;

  SyncResult({
    required this.uploaded,
    required this.downloaded,
    this.conflicts = 0,
    this.error,
  });

  bool get success => error == null;

  @override
  String toString() =>
      'SyncResult(uploaded: $uploaded, downloaded: $downloaded, conflicts: $conflicts, error: $error)';
}

/// CRDT 同步服务
///
/// 负责与云端同步操作日志，实现多设备数据同步
class CRDTSyncService {
  final BeeDatabase _db;
  final CloudProvider _cloudProvider;
  final OperationApplier _opApplier;
  final LamportClock _clock;
  final String _deviceId;

  CRDTSyncService({
    required BeeDatabase db,
    required CloudProvider cloudProvider,
    required LamportClock clock,
    required String deviceId,
  })  : _db = db,
        _cloudProvider = cloudProvider,
        _opApplier = OperationApplier(db, clock),
        _clock = clock,
        _deviceId = deviceId;

  /// 同步账本
  Future<SyncResult> sync(int ledgerId) async {
    logger.info('CRDTSync', '开始同步: ledgerId=$ledgerId');

    try {
      // 0. 获取用户 ID
      final userId = await _getUserId();

      // 1. 下载云端快照，获取已合并版本号
      final snapshot = await _downloadSnapshot(ledgerId, userId);
      final snapshotVersion = snapshot?['snapshotVersion'] as int? ?? 0;
      logger.debug('CRDTSync', '云端快照版本: $snapshotVersion');

      // 2. 下载云端操作日志
      final remoteOpLog = await _downloadOperationLog(ledgerId, userId);
      final remoteOps = remoteOpLog?.operations ?? [];
      logger.debug('CRDTSync', '云端操作数: ${remoteOps.length}');

      // 3. 筛选需要应用的远程操作（版本 > 本地已同步版本）
      final syncState = await _db.getSyncState(ledgerId);
      final localSyncedVersion = syncState?.syncedSnapshotVersion ?? 0;

      final newRemoteOps = remoteOps.where((op) {
        final opVersion = op.version ?? op.timestamp;
        return opVersion > localSyncedVersion;
      }).toList();

      // 4. 应用远程操作到本地
      final applyResult = await _opApplier.apply(ledgerId, newRemoteOps);
      logger.debug('CRDTSync', '应用操作: ${applyResult.applied}');

      // 5. 收集本地未同步的操作
      final localOps = await _db.getUnsyncedOperations(ledgerId);
      logger.debug('CRDTSync', '本地未同步操作: ${localOps.length}');

      // 6. 上传本地操作到云端
      int uploaded = 0;
      if (localOps.isNotEmpty) {
        // 合并操作日志
        final mergedOpLog = _mergeOperationLogs(remoteOpLog, localOps, ledgerId);

        // 上传合并后的日志
        await _uploadOperationLog(ledgerId, userId, mergedOpLog);

        // 标记本地操作为已同步
        await _db.markOperationsSynced(localOps.map((o) => o.opId).toList());
        uploaded = localOps.length;
        logger.debug('CRDTSync', '上传操作: $uploaded');
      }

      // 7. 更新同步状态
      final newVersion = _calculateLatestVersion(remoteOps, localOps);
      await _db.updateSyncState(
        ledgerId: ledgerId,
        deviceId: _deviceId,
        localClock: _clock.value,
        syncedSnapshotVersion: newVersion,
        lastSyncAt: DateTime.now(),
      );

      logger.info('CRDTSync', '同步完成');

      return SyncResult(
        uploaded: uploaded,
        downloaded: applyResult.applied,
        conflicts: applyResult.conflicts,
      );
    } catch (e, st) {
      logger.error('CRDTSync', '同步失败', e, st);
      return SyncResult(
        uploaded: 0,
        downloaded: 0,
        error: e.toString(),
      );
    }
  }

  /// 下载云端快照
  Future<Map<String, dynamic>?> _downloadSnapshot(int ledgerId, String userId) async {
    try {
      final path = _snapshotPath(ledgerId, userId);
      final content = await _cloudProvider.storage.download(path: path);
      if (content == null || content.isEmpty) return null;
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      logger.debug('CRDTSync', '下载快照失败: $e');
      return null;
    }
  }

  /// 下载云端操作日志
  Future<OperationLog?> _downloadOperationLog(int ledgerId, String userId) async {
    try {
      final path = _operationLogPath(ledgerId, userId);
      final content = await _cloudProvider.storage.download(path: path);
      if (content == null || content.isEmpty) return null;
      final json = jsonDecode(content) as Map<String, dynamic>;
      return OperationLog.fromJson(json);
    } catch (e) {
      logger.debug('CRDTSync', '下载操作日志失败: $e');
      return null;
    }
  }

  /// 上传操作日志
  Future<void> _uploadOperationLog(int ledgerId, String userId, OperationLog opLog) async {
    final path = _operationLogPath(ledgerId, userId);
    final content = opLog.toJsonString();
    await _cloudProvider.storage.upload(data: content, path: path);
  }

  /// 合并操作日志
  OperationLog _mergeOperationLogs(
    OperationLog? remote,
    List<Operation> localOps,
    int ledgerId,
  ) {
    final base = remote ?? OperationLog.empty(ledgerId);

    // 为本地操作分配版本号
    final maxVersion = base.operations.isEmpty
        ? 0
        : base.operations.map((o) => o.version ?? o.timestamp).reduce((a, b) => a > b ? a : b);

    var nextVersion = maxVersion + 1;
    final opsWithVersion = localOps.map((op) {
      return op.copyWith(version: nextVersion++);
    }).toList();

    return base.addOperations(opsWithVersion);
  }

  /// 计算最新版本号
  int _calculateLatestVersion(List<Operation> remoteOps, List<Operation> localOps) {
    final allOps = [...remoteOps, ...localOps];
    if (allOps.isEmpty) return 0;

    return allOps
        .map((o) => o.version ?? o.timestamp)
        .reduce((a, b) => a > b ? a : b);
  }

  Future<String> _getUserId() async {
    final user = await _cloudProvider.auth.currentUser;
    if (user == null) {
      throw Exception('用户未登录');
    }
    return user.id;
  }

  String _snapshotPath(int ledgerId, String userId) {
    return 'users/$userId/ledger_$ledgerId.json';
  }

  String _operationLogPath(int ledgerId, String userId) {
    return 'operations/ledger_${ledgerId}_ops.json';
  }
}
