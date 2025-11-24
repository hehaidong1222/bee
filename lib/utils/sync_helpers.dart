import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers.dart';
import '../cloud/transactions_sync_manager.dart';
import '../services/logger_service.dart';

/// 统一处理本地变更后的同步逻辑：
/// - 始终先标记本地变更（使缓存失效）
/// - 若开启多设备同步：只同步操作日志（CRDT模式）
/// - 若开启自动同步但未开启多设备同步：上传快照
/// - 若未开启自动同步：立即刷新同步状态（应显示"本地较新"）
Future<void> handleLocalChange(WidgetRef ref,
    {required int ledgerId, bool background = true}) async {
  logger.debug('SyncHelper', '开始处理账本变更: ledgerId=$ledgerId, background=$background');

  // 失效缓存
  final sync = ref.read(syncServiceProvider);
  try {
    sync.markLocalChanged(ledgerId: ledgerId);
  } catch (_) {}

  // 检查同步设置
  bool autoSync = false;
  bool multiDeviceSync = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    autoSync = prefs.getBool('auto_sync') ?? false;
    multiDeviceSync = prefs.getBool('multi_device_sync_enabled') ?? false;
  } catch (_) {}

  // 始终立即刷新一次状态，确保UI及时反映本地变更
  ref.read(syncStatusRefreshProvider.notifier).state++;

  // 刷新账本列表数据（笔数、余额、时间）
  ref.read(ledgerListRefreshProvider.notifier).state++;

  // 根据同步模式选择不同的同步方式
  if (multiDeviceSync) {
    // 多设备同步模式：只同步操作日志
    logger.info('SyncHelper', '多设备同步模式：同步操作日志');
    if (background) {
      final refresh = ref.read(syncStatusRefreshProvider.notifier);
      Future(() async {
        try {
          if (sync is TransactionsSyncManager) {
            await sync.syncOperationLogOnly(ledgerId: ledgerId);
          }
          refresh.state++;
        } catch (e) {
          logger.warning('SyncHelper', '操作日志同步失败: $e');
        }
      });
    } else {
      try {
        if (sync is TransactionsSyncManager) {
          await sync.syncOperationLogOnly(ledgerId: ledgerId);
        }
        ref.read(syncStatusRefreshProvider.notifier).state++;
      } catch (e) {
        logger.warning('SyncHelper', '操作日志同步失败: $e');
      }
    }
  } else if (autoSync) {
    // 传统模式：上传快照
    logger.info('SyncHelper', '传统同步模式：上传快照');
    if (background) {
      final refresh = ref.read(syncStatusRefreshProvider.notifier);
      Future(() async {
        try {
          await sync.uploadCurrentLedger(ledgerId: ledgerId);
          refresh.state++;
        } catch (_) {}
      });
    } else {
      try {
        await sync.uploadCurrentLedger(ledgerId: ledgerId);
        ref.read(syncStatusRefreshProvider.notifier).state++;
      } catch (_) {}
    }
  }
}
