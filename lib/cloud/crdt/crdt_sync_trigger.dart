import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart';
import '../../services/logger_service.dart';
import 'crdt_repository.dart';
import 'crdt_sync_service.dart';
import 'lamport_clock.dart';

/// CRDT 同步触发器
///
/// 在现有同步流程中触发 CRDT 操作日志的同步
class CRDTSyncTrigger {
  final BeeDatabase _db;
  final CloudProvider _cloudProvider;

  CRDTSyncService? _syncService;
  LamportClock? _clock;
  String? _deviceId;
  bool _isInitialized = false;

  CRDTSyncTrigger({
    required BeeDatabase db,
    required CloudProvider cloudProvider,
  })  : _db = db,
        _cloudProvider = cloudProvider;

  /// 确保已初始化
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();

    // 获取设备 ID
    _deviceId = prefs.getString('crdt_device_id');
    if (_deviceId == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final random = now % 1000000;
      _deviceId = 'device_${now}_$random';
      await prefs.setString('crdt_device_id', _deviceId!);
    }

    // 初始化 Lamport Clock
    _clock = LamportClock();

    // 恢复 clock 值
    final allSyncStates = await _db.select(_db.crdtSyncState).get();
    for (final state in allSyncStates) {
      _clock!.update(state.localClock);
    }

    // 创建同步服务
    _syncService = CRDTSyncService(
      db: _db,
      cloudProvider: _cloudProvider,
      clock: _clock!,
      deviceId: _deviceId!,
    );

    _isInitialized = true;
    logger.info('CRDTSyncTrigger', '初始化完成: deviceId=$_deviceId');
  }

  /// 检查是否启用多设备同步
  Future<bool> isMultiDeviceSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('multi_device_sync_enabled') ?? false;
  }

  /// 同步操作日志
  ///
  /// 在现有同步（上传/下载）之后调用
  Future<SyncResult?> syncOperationLog(int ledgerId) async {
    // 检查是否启用多设备同步
    final enabled = await isMultiDeviceSyncEnabled();
    if (!enabled) {
      logger.debug('CRDTSyncTrigger', '多设备同步未启用，跳过');
      return null;
    }

    await _ensureInitialized();

    logger.info('CRDTSyncTrigger', '开始同步操作日志: ledgerId=$ledgerId');

    final result = await _syncService!.sync(ledgerId);

    logger.info('CRDTSyncTrigger',
        '操作日志同步完成: uploaded=${result.uploaded}, downloaded=${result.downloaded}');

    return result;
  }

  /// 获取未同步的操作数量
  Future<int> getUnsyncedCount(int ledgerId) async {
    return await _db.getUnsyncedOperationsCount(ledgerId);
  }

  /// 获取同步状态
  Future<CrdtSyncStateData?> getSyncState(int ledgerId) async {
    return await _db.getSyncState(ledgerId);
  }
}
