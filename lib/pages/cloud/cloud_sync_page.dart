import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../services/billing/post_processor.dart';
import '../../cloud/sync_service.dart';
import '../../cloud/transactions_sync_manager.dart';
import '../auth/login_page.dart';
import 'devices_page.dart';

/// 云同步与备份二级页面 - 包含所有同步操作
class CloudSyncPage extends ConsumerStatefulWidget {
  const CloudSyncPage({super.key});

  @override
  ConsumerState<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends ConsumerState<CloudSyncPage> {
  bool uploadBusy = false;
  bool downloadBusy = false;
  int _lastQueueFailedToastCount = -1;
  int? _lastQueueFailedLedgerId;

  void _handleQueueSummaryToast({
    required bool isBeeCountCloudMode,
    required int ledgerId,
    required LocalSyncQueueSummary summary,
  }) {
    if (!isBeeCountCloudMode) {
      _lastQueueFailedToastCount = -1;
      _lastQueueFailedLedgerId = null;
      return;
    }
    if (_lastQueueFailedLedgerId != ledgerId) {
      _lastQueueFailedLedgerId = ledgerId;
      _lastQueueFailedToastCount = -1;
    }
    final failed = summary.failed;
    if (failed <= 0) {
      _lastQueueFailedToastCount = 0;
      return;
    }
    if (failed == _lastQueueFailedToastCount) {
      return;
    }
    _lastQueueFailedToastCount = failed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      showToast(
        context,
        AppLocalizations.of(context).cloudCollabUploadQueueFailedToast(
          '$failed',
        ),
      );
    });
  }

  String? _guessAvatarMimeType(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    return null;
  }

  void _refreshCollabAvatarConsumers() {
    final currentLedgerId = ref.read(currentLedgerIdProvider);
    ref.read(syncStatusRefreshProvider.notifier).state++;
    ref.read(ledgerListRefreshProvider.notifier).state++;
    if (currentLedgerId > 0) {
      ref
          .read(syncStatusRefreshByLedgerProvider(currentLedgerId).notifier)
          .state++;
      ref
          .read(ledgerDataRefreshByLedgerProvider(currentLedgerId).notifier)
          .state++;
    }
  }

  Future<void> _retryPendingAvatarUpload(
    BuildContext context, {
    required TransactionsSyncManager sync,
    required String localPath,
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw StateError('avatar file not found');
      }
      final bytes = await file.readAsBytes();
      await sync.uploadMyAvatar(
        bytes: bytes,
        fileName: localPath.split('/').last,
        mimeType: _guessAvatarMimeType(localPath),
      );
      _refreshCollabAvatarConsumers();
      ref.read(pendingAvatarUploadPathProvider.notifier).state = null;
      ref.read(pendingAvatarUploadErrorProvider.notifier).state = null;
      if (!context.mounted) return;
      showToast(context, l10n.cloudCollabAvatarUploadSuccess);
    } catch (e) {
      ref.read(pendingAvatarUploadErrorProvider.notifier).state = '$e';
      if (!context.mounted) return;
      showToast(context, l10n.cloudCollabAvatarUploadFailed);
    }
  }

  Future<void> _retryMissingMediaDownloads(
    BuildContext context, {
    required TransactionsSyncManager sync,
    required int ledgerId,
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      final result = await sync.retryMissingMediaDownloads(ledgerId: ledgerId);
      if (!context.mounted) return;
      if (result.failed > 0) {
        await AppDialog.warning(
          context,
          title: l10n.cloudCollabMediaRetryPartialTitle,
          message: l10n.cloudCollabMediaRetryPartialMessage(
            '${result.downloaded}',
            '${result.failed}',
          ),
        );
        return;
      }
      if (result.downloaded > 0) {
        showToast(
          context,
          l10n.cloudCollabMediaRetrySuccess('${result.downloaded}'),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      await AppDialog.warning(
        context,
        title: l10n.cloudCollabMediaRetryFailedTitle,
        message: l10n.cloudCollabMediaRetryFailedMessage('$e'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authServiceProvider);
    final sync = ref.watch(syncServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);

    if (ledgerId == 0) {
      return Scaffold(
        backgroundColor: BeeTokens.scaffoldBackground(context),
        body: Column(
          children: [
            PrimaryHeader(
              title: AppLocalizations.of(context).cloudSyncPageTitle,
              subtitle: AppLocalizations.of(context).cloudSyncPageSubtitle,
              showBack: true,
            ),
            Expanded(
              child: Center(
                child: Text(
                  AppLocalizations.of(context).aiOcrNoLedger,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: BeeTokens.textSecondary(context),
                      ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: AppLocalizations.of(context).cloudSyncPageTitle,
            subtitle: AppLocalizations.of(context).cloudSyncPageSubtitle,
            showBack: true,
          ),
          Expanded(
            child: authAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('${AppLocalizations.of(context).commonError}: $e'),
              ),
              data: (auth) => FutureBuilder<CloudUser?>(
                future: auth.currentUser,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final l10n = AppLocalizations.of(context);
                  final user = snap.data;
                  final cloudConfig = ref.watch(activeCloudConfigProvider);
                  final isLocalMode = cloudConfig.hasValue &&
                      cloudConfig.value!.type == CloudBackendType.local;
                  final isSupabaseMode = cloudConfig.hasValue &&
                      cloudConfig.value!.type == CloudBackendType.supabase;
                  final isBeeCountCloudMode = cloudConfig.hasValue &&
                      cloudConfig.value!.type == CloudBackendType.beecountCloud;
                  final txSyncManager =
                      sync is TransactionsSyncManager ? sync : null;
                  final requiresLogin = isSupabaseMode || isBeeCountCloudMode;
                  final canUseCloud =
                      !isLocalMode && (!requiresLogin || user != null);
                  final showBeeCountCloudDeviceEntry = isBeeCountCloudMode &&
                      user != null &&
                      txSyncManager != null;
                  final pendingAvatarPath =
                      ref.watch(pendingAvatarUploadPathProvider);
                  final pendingAvatarError =
                      ref.watch(pendingAvatarUploadErrorProvider);
                  final asyncSt = ref.watch(syncStatusProvider(ledgerId));
                  final cached = ref.watch(lastSyncStatusProvider(ledgerId));
                  final st = asyncSt.asData?.value ?? cached;
                  final queueSummaryAsync =
                      isBeeCountCloudMode && txSyncManager != null
                          ? ref.watch(ledgerSyncQueueSummaryProvider(ledgerId))
                          : const AsyncValue<LocalSyncQueueSummary>.data(
                              LocalSyncQueueSummary.empty(),
                            );
                  final queueSummary = queueSummaryAsync.asData?.value ??
                      const LocalSyncQueueSummary.empty();
                  final queuePending = queueSummary.pending;
                  final queueFailed = queueSummary.failed;
                  _handleQueueSummaryToast(
                    isBeeCountCloudMode: isBeeCountCloudMode,
                    ledgerId: ledgerId,
                    summary: queueSummary,
                  );

                  final isFirstLoad = st == null;
                  final refreshing = asyncSt.isLoading;
                  bool inSync = false;
                  bool notLoggedIn = false;

                  // 计算同步状态显示
                  String subtitle = '';
                  IconData icon = Icons.sync_outlined;

                  if (!isFirstLoad) {
                    switch (st.diff) {
                      case SyncDiff.notLoggedIn:
                        subtitle =
                            AppLocalizations.of(context).mineSyncNotLoggedIn;
                        icon = Icons.lock_outline;
                        notLoggedIn = true;
                        break;
                      case SyncDiff.notConfigured:
                        subtitle =
                            AppLocalizations.of(context).mineSyncNotConfigured;
                        icon = Icons.cloud_off_outlined;
                        break;
                      case SyncDiff.noRemote:
                        subtitle =
                            AppLocalizations.of(context).mineSyncNoRemote;
                        icon = Icons.cloud_queue_outlined;
                        break;
                      case SyncDiff.inSync:
                        subtitle = isBeeCountCloudMode
                            ? (st.cloudExportedAt != null
                                ? AppLocalizations.of(context)
                                    .mineSyncCloudLatest(
                                    DateFormat('yyyy-MM-dd HH:mm:ss')
                                        .format(st.cloudExportedAt!.toLocal()),
                                  )
                                : AppLocalizations.of(context)
                                    .mineSyncInSyncSimple)
                            : AppLocalizations.of(context)
                                .mineSyncInSync(st.localCount);
                        icon = Icons.verified_outlined;
                        inSync = true;
                        break;
                      case SyncDiff.localNewer:
                        subtitle = AppLocalizations.of(context)
                            .mineSyncLocalNewer(st.localCount);
                        icon = Icons.upload_outlined;
                        break;
                      case SyncDiff.cloudNewer:
                        subtitle =
                            AppLocalizations.of(context).mineSyncCloudNewer;
                        icon = Icons.download_outlined;
                        break;
                      case SyncDiff.different:
                        subtitle =
                            AppLocalizations.of(context).mineSyncDifferent;
                        icon = Icons.change_circle_outlined;
                        break;
                      case SyncDiff.error:
                        String? localizedMessage;
                        if (st.message != null) {
                          switch (st.message!) {
                            case '__SYNC_NOT_CONFIGURED__':
                              localizedMessage = AppLocalizations.of(context)
                                  .syncNotConfiguredMessage;
                              break;
                            case '__SYNC_NOT_LOGGED_IN__':
                              localizedMessage = AppLocalizations.of(context)
                                  .syncNotLoggedInMessage;
                              break;
                            case '__SYNC_CLOUD_BACKUP_CORRUPTED__':
                              localizedMessage = AppLocalizations.of(context)
                                  .syncCloudBackupCorruptedMessage;
                              break;
                            case '__SYNC_NO_CLOUD_BACKUP__':
                              localizedMessage = AppLocalizations.of(context)
                                  .syncNoCloudBackupMessage;
                              break;
                            case '__SYNC_ACCESS_DENIED__':
                              localizedMessage = AppLocalizations.of(context)
                                  .syncAccessDeniedMessage;
                              break;
                            default:
                              localizedMessage = st.message;
                          }
                        }
                        subtitle = localizedMessage ??
                            AppLocalizations.of(context).mineSyncError;
                        icon = Icons.error_outline;
                        break;
                    }
                  }
                  final syncedForActionLock = isBeeCountCloudMode
                      ? (inSync && queuePending <= 0 && queueFailed <= 0)
                      : inSync;
                  final canTapUpload = canUseCloud &&
                      !notLoggedIn &&
                      !uploadBusy &&
                      !downloadBusy &&
                      !isFirstLoad &&
                      !refreshing &&
                      !syncedForActionLock;
                  final canTapDownload = canUseCloud &&
                      !notLoggedIn &&
                      !downloadBusy &&
                      !isFirstLoad &&
                      !refreshing &&
                      !uploadBusy &&
                      !syncedForActionLock;
                  final uploadSubtitle = isFirstLoad
                      ? null
                      : !canUseCloud
                          ? l10n.mineUploadNeedCloudService
                          : notLoggedIn
                              ? l10n.mineUploadNeedLogin
                              : uploadBusy
                                  ? l10n.mineUploadInProgress
                                  : (refreshing
                                      ? l10n.mineUploadRefreshing
                                      : (isBeeCountCloudMode
                                          ? (queueFailed > 0
                                              ? l10n
                                                  .cloudCollabUploadQueueFailed(
                                                  '$queueFailed',
                                                )
                                              : (queuePending > 0
                                                  ? l10n
                                                      .cloudCollabUploadQueuePending(
                                                      '$queuePending',
                                                    )
                                                  : (syncedForActionLock
                                                      ? l10n.mineUploadSynced
                                                      : null)))
                                          : (syncedForActionLock
                                              ? l10n.mineUploadSynced
                                              : null)));

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 提示文案
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          AppLocalizations.of(context).cloudSyncHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: BeeTokens.textTertiary(context),
                          ),
                        ),
                      ),
                      if (isBeeCountCloudMode)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '${AppLocalizations.of(context).cloudCollabMediaRetryHint}\n${AppLocalizations.of(context).cloudCollabEntryMovedHint}',
                            style: TextStyle(
                              fontSize: 12,
                              color: BeeTokens.textSecondary(context),
                            ),
                          ),
                        ),
                      if (isBeeCountCloudMode &&
                          txSyncManager != null &&
                          pendingAvatarPath != null &&
                          pendingAvatarPath.trim().isNotEmpty)
                        SectionCard(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: AppListTile(
                            leading: Icons.account_circle_outlined,
                            title: AppLocalizations.of(context)
                                .cloudCollabAvatarRetryTitle,
                            subtitle: pendingAvatarError == null ||
                                    pendingAvatarError.trim().isEmpty
                                ? AppLocalizations.of(context)
                                    .cloudCollabAvatarRetrySubtitle
                                : '${AppLocalizations.of(context).cloudCollabAvatarRetrySubtitle}\n$pendingAvatarError',
                            onTap: () => _retryPendingAvatarUpload(
                              context,
                              sync: txSyncManager,
                              localPath: pendingAvatarPath,
                            ),
                          ),
                        ),
                      // 同步操作 Section
                      SectionCard(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: [
                            // 同步状态
                            AppListTile(
                              leading: icon,
                              title: AppLocalizations.of(context).mineSyncTitle,
                              subtitle: isFirstLoad ? null : subtitle,
                              enabled: canUseCloud &&
                                  !isFirstLoad &&
                                  !refreshing &&
                                  !uploadBusy &&
                                  !downloadBusy,
                              trailing: (canUseCloud &&
                                      (isFirstLoad ||
                                          refreshing ||
                                          uploadBusy ||
                                          downloadBusy))
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : null,
                              onTap: (isFirstLoad ||
                                      !canUseCloud ||
                                      refreshing ||
                                      uploadBusy ||
                                      downloadBusy)
                                  ? null
                                  : () async {
                                      if (!context.mounted) return;
                                      final lines = <String>[
                                        AppLocalizations.of(context)
                                            .mineSyncLocalRecords(
                                                st.localCount),
                                        if (st.cloudCount != null)
                                          AppLocalizations.of(context)
                                              .mineSyncCloudRecords(
                                                  st.cloudCount!),
                                        if (st.cloudExportedAt != null)
                                          AppLocalizations.of(context)
                                              .mineSyncCloudLatest(DateFormat(
                                                      'yyyy-MM-dd HH:mm:ss')
                                                  .format(st.cloudExportedAt!
                                                      .toLocal())),
                                        if (!isBeeCountCloudMode)
                                          AppLocalizations.of(context)
                                              .mineSyncLocalFingerprint(
                                                  st.localFingerprint),
                                        if (!isBeeCountCloudMode &&
                                            st.cloudFingerprint != null)
                                          AppLocalizations.of(context)
                                              .mineSyncCloudFingerprint(
                                                  st.cloudFingerprint!),
                                        if (st.message != null)
                                          () {
                                            String localizedMessage =
                                                st.message!;
                                            switch (st.message!) {
                                              case '__SYNC_NOT_CONFIGURED__':
                                                localizedMessage =
                                                    AppLocalizations.of(context)
                                                        .syncNotConfiguredMessage;
                                                break;
                                              case '__SYNC_NOT_LOGGED_IN__':
                                                localizedMessage =
                                                    AppLocalizations.of(context)
                                                        .syncNotLoggedInMessage;
                                                break;
                                              case '__SYNC_CLOUD_BACKUP_CORRUPTED__':
                                                localizedMessage = AppLocalizations
                                                        .of(context)
                                                    .syncCloudBackupCorruptedMessage;
                                                break;
                                              case '__SYNC_NO_CLOUD_BACKUP__':
                                                localizedMessage =
                                                    AppLocalizations.of(context)
                                                        .syncNoCloudBackupMessage;
                                                break;
                                              case '__SYNC_ACCESS_DENIED__':
                                                localizedMessage =
                                                    AppLocalizations.of(context)
                                                        .syncAccessDeniedMessage;
                                                break;
                                            }
                                            return AppLocalizations.of(context)
                                                .mineSyncMessage(
                                                    localizedMessage);
                                          }(),
                                      ];
                                      await AppDialog.info(context,
                                          title: AppLocalizations.of(context)
                                              .mineSyncDetailTitle,
                                          message: lines.join('\n'));
                                    },
                            ),
                            BeeTokens.cardDivider(context),
                            // 上传
                            AppListTile(
                              leading: Icons.cloud_upload_outlined,
                              title:
                                  AppLocalizations.of(context).mineUploadTitle,
                              subtitle: uploadSubtitle,
                              enabled: canTapUpload,
                              trailing: (uploadBusy ||
                                      refreshing ||
                                      (isFirstLoad && canUseCloud))
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : null,
                              onTap: !canTapUpload
                                  ? null
                                  : () async {
                                      setState(() => uploadBusy = true);
                                      // 标记为上传中
                                      final uploadingIds =
                                          ref.read(uploadingLedgerIdsProvider);
                                      ref
                                          .read(uploadingLedgerIdsProvider
                                              .notifier)
                                          .state = {...uploadingIds, ledgerId};

                                      try {
                                        await sync.uploadCurrentLedger(
                                            ledgerId: ledgerId);
                                        if (!context.mounted) return;

                                        // 刷新账本列表
                                        ref
                                            .read(ledgerListRefreshProvider
                                                .notifier)
                                            .state++;

                                        await AppDialog.info(context,
                                            title: AppLocalizations.of(context)
                                                .mineUploadSuccess,
                                            message:
                                                AppLocalizations.of(context)
                                                    .mineUploadSuccessMessage);
                                        if (!context.mounted) return;
                                        if (sync is TransactionsSyncManager &&
                                            isBeeCountCloudMode) {
                                          await _retryMissingMediaDownloads(
                                            context,
                                            sync: sync,
                                            ledgerId: ledgerId,
                                          );
                                        }
                                        Future(() async {
                                          try {
                                            await sync.refreshCloudFingerprint(
                                                ledgerId: ledgerId);
                                          } catch (_) {}
                                          try {
                                            const maxAttempts = 6;
                                            var delay = const Duration(
                                                milliseconds: 500);
                                            for (var i = 0;
                                                i < maxAttempts;
                                                i++) {
                                              final stNow =
                                                  await sync.getStatus(
                                                      ledgerId: ledgerId);
                                              if (stNow.diff ==
                                                  SyncDiff.inSync) {
                                                ref
                                                    .read(
                                                        lastSyncStatusProvider(
                                                                ledgerId)
                                                            .notifier)
                                                    .state = stNow;
                                                break;
                                              }
                                              if (i < maxAttempts - 1) {
                                                await Future.delayed(delay);
                                                delay *= 2;
                                              }
                                            }
                                            ref
                                                .read(syncStatusRefreshProvider
                                                    .notifier)
                                                .state++;
                                            ref
                                                .read(
                                                    syncStatusRefreshByLedgerProvider(
                                                            ledgerId)
                                                        .notifier)
                                                .state++;
                                            // 再次刷新账本列表确保状态更新
                                            ref
                                                .read(ledgerListRefreshProvider
                                                    .notifier)
                                                .state++;
                                          } catch (_) {}
                                        });
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        await AppDialog.info(context,
                                            title: AppLocalizations.of(context)
                                                .commonFailed,
                                            message: '$e');
                                      } finally {
                                        if (mounted) {
                                          setState(() => uploadBusy = false);
                                        }
                                        // 移除上传中标记
                                        final uploadingIds = ref
                                            .read(uploadingLedgerIdsProvider);
                                        ref
                                                .read(uploadingLedgerIdsProvider
                                                    .notifier)
                                                .state =
                                            uploadingIds
                                                .where((id) => id != ledgerId)
                                                .toSet();
                                      }
                                    },
                            ),
                            BeeTokens.cardDivider(context),
                            // 下载
                            AppListTile(
                              leading: Icons.cloud_download_outlined,
                              title: AppLocalizations.of(context)
                                  .mineDownloadTitle,
                              subtitle: isFirstLoad
                                  ? null
                                  : !canUseCloud
                                      ? AppLocalizations.of(context)
                                          .mineDownloadNeedCloudService
                                      : notLoggedIn
                                          ? AppLocalizations.of(context)
                                              .mineUploadNeedLogin
                                          : (refreshing
                                              ? AppLocalizations.of(context)
                                                  .mineUploadRefreshing
                                              : (syncedForActionLock
                                                  ? AppLocalizations.of(context)
                                                      .mineUploadSynced
                                                  : null)),
                              enabled: canTapDownload,
                              trailing: (downloadBusy ||
                                      refreshing ||
                                      (isFirstLoad && canUseCloud))
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : null,
                              onTap: !canTapDownload
                                  ? null
                                  : () async {
                                      setState(() => downloadBusy = true);
                                      try {
                                        final res = await sync
                                            .downloadAndRestoreToCurrentLedger(
                                                ledgerId: ledgerId);
                                        if (!context.mounted) return;
                                        final msg = res.inserted > 0
                                            ? AppLocalizations.of(context)
                                                .mineDownloadResult(
                                                    res.inserted)
                                            : AppLocalizations.of(context)
                                                .mineDownloadRefreshedNoChanges;
                                        await AppDialog.info(context,
                                            title: AppLocalizations.of(context)
                                                .mineDownloadComplete,
                                            message: msg);
                                        if (!context.mounted) return;
                                        if (sync is TransactionsSyncManager &&
                                            isBeeCountCloudMode) {
                                          await _retryMissingMediaDownloads(
                                            context,
                                            sync: sync,
                                            ledgerId: ledgerId,
                                          );
                                        }

                                        // 下载完成后，刷新统计和UI状态（不触发同步上传）
                                        PostProcessor.runAfterDownload(ref);
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        await AppDialog.error(context,
                                            title: AppLocalizations.of(context)
                                                .commonFailed,
                                            message: '$e');
                                      } finally {
                                        if (mounted) {
                                          setState(() => downloadBusy = false);
                                        }
                                      }
                                    },
                            ),
                            // 登录/登出（Supabase + BeeCount Cloud 需要）
                            if (!isLocalMode &&
                                (cloudConfig.value!.type ==
                                        CloudBackendType.supabase ||
                                    cloudConfig.value!.type ==
                                        CloudBackendType.beecountCloud))
                              Consumer(builder: (ctx, r, _) {
                                final userNow = user;
                                final cloudConfig =
                                    r.watch(activeCloudConfigProvider);

                                // 根据云服务类型显示不同的用户信息
                                String getUserDisplayName() {
                                  if (userNow == null) {
                                    return AppLocalizations.of(context)
                                        .mineLoginTitle;
                                  }

                                  if (cloudConfig.hasValue &&
                                      cloudConfig.value!.type ==
                                          CloudBackendType.webdav) {
                                    // WebDAV: 显示用户名（去掉 @webdav 后缀）
                                    return userNow.id;
                                  } else if (cloudConfig.hasValue &&
                                      cloudConfig.value!.type ==
                                          CloudBackendType.beecountCloud) {
                                    return userNow.email ?? userNow.id;
                                  } else {
                                    // Supabase: 显示邮箱
                                    return userNow.email ??
                                        AppLocalizations.of(context)
                                            .mineLoggedInEmail;
                                  }
                                }

                                return Column(
                                  children: [
                                    BeeTokens.cardDivider(context),
                                    AppListTile(
                                      leading: userNow == null
                                          ? Icons.login
                                          : Icons.verified_user_outlined,
                                      title: getUserDisplayName(),
                                      subtitle: userNow == null
                                          ? AppLocalizations.of(context)
                                              .mineLoginSubtitle
                                          : AppLocalizations.of(context)
                                              .mineLogoutSubtitle,
                                      onTap: () async {
                                        if (userNow == null) {
                                          await Navigator.of(context).push(
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      const LoginPage()));
                                          ref
                                              .read(syncStatusRefreshProvider
                                                  .notifier)
                                              .state++;
                                          ref
                                              .read(
                                                  statsRefreshProvider.notifier)
                                              .state++;
                                        } else {
                                          final confirmed = await AppDialog
                                                  .confirm<bool>(
                                                context,
                                                title:
                                                    AppLocalizations.of(context)
                                                        .mineLogoutConfirmTitle,
                                                message: AppLocalizations.of(
                                                        context)
                                                    .mineLogoutConfirmMessage,
                                                okLabel:
                                                    AppLocalizations.of(context)
                                                        .mineLogoutButton,
                                                cancelLabel:
                                                    AppLocalizations.of(context)
                                                        .commonCancel,
                                              ) ??
                                              false;

                                          if (confirmed) {
                                            final authService = await ref.read(
                                                authServiceProvider.future);
                                            await authService.signOut();

                                            // 刷新认证服务和同步服务以触发状态更新
                                            ref.invalidate(authServiceProvider);
                                            ref.invalidate(syncServiceProvider);

                                            ref
                                                .read(syncStatusRefreshProvider
                                                    .notifier)
                                                .state++;
                                            ref
                                                .read(statsRefreshProvider
                                                    .notifier)
                                                .state++;
                                          }
                                        }
                                      },
                                    ),
                                  ],
                                );
                              }),
                            // 自动同步 (所有云服务模式都支持)
                            if (!isLocalMode)
                              Consumer(builder: (ctx, r, _) {
                                final autoSync = r.watch(autoSyncValueProvider);
                                final setter = r.read(autoSyncSetterProvider);
                                final value = autoSync.asData?.value ?? false;
                                final can = canUseCloud;

                                return Column(
                                  children: [
                                    BeeTokens.cardDivider(context),
                                    SwitchListTile(
                                      title: Text(AppLocalizations.of(context)
                                          .mineAutoSyncTitle),
                                      subtitle: can
                                          ? Text(AppLocalizations.of(context)
                                              .mineAutoSyncSubtitle)
                                          : Text(AppLocalizations.of(context)
                                              .mineAutoSyncNeedLogin),
                                      value: can ? value : false,
                                      onChanged: can
                                          ? (v) async {
                                              await setter.set(v);
                                            }
                                          : null,
                                    ),
                                  ],
                                );
                              }),
                          ],
                        ),
                      ),
                      if (showBeeCountCloudDeviceEntry) ...[
                        const SizedBox(height: 12),
                        SectionCard(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              AppListTile(
                                leading: Icons.devices_outlined,
                                title: AppLocalizations.of(context)
                                    .cloudCollabDevicesEntryTitle,
                                subtitle: AppLocalizations.of(context)
                                    .cloudCollabDevicesEntrySubtitle,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const DevicesPage(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
