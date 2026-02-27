/// 账本卡片组件
///
/// 展示账本基本信息，同步状态通过 syncStatusProvider 单独获取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudBackendType;

import '../../models/ledger_display_item.dart';
import '../../cloud/sync_service.dart';
import '../../providers/theme_providers.dart';
import '../../providers/sync_providers.dart';
import '../../utils/format_utils.dart';
import '../../utils/currencies.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import 'collab_member_avatar.dart';

/// 账本卡片
class LedgerCard extends ConsumerWidget {
  final LedgerDisplayItem ledger;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  const LedgerCard({
    super.key,
    required this.ledger,
    this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  String _roleLabel(AppLocalizations l10n, LedgerCollabCapability capability) {
    final normalized = normalizeCollabRole(capability.role);
    switch (normalized) {
      case 'owner':
        return l10n.cloudCollabRoleOwner;
      case 'editor':
        return l10n.cloudCollabRoleEditor;
      case 'viewer':
        return l10n.cloudCollabRoleViewerLegacy;
      default:
        return l10n.cloudCollabRoleLoading;
    }
  }

  List<LedgerCollabMemberSummary> _activeMembers(
      List<LedgerCollabMemberSummary> members) {
    return members
        .where((member) => (member.status ?? '').trim().toLowerCase() != 'left')
        .toList(growable: false);
  }

  Widget _buildMemberStack(
    BuildContext context,
    List<LedgerCollabMemberSummary> members,
  ) {
    final active = _activeMembers(members);
    if (active.isEmpty) return const SizedBox.shrink();
    final visible = active.take(3).toList(growable: false);
    final hiddenCount = active.length - visible.length;
    final stackWidth =
        20 + (visible.length <= 1 ? 0 : (visible.length - 1) * 14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: stackWidth.toDouble(),
          height: 20,
          child: Stack(
            children: [
              for (var i = 0; i < visible.length; i++)
                Positioned(
                  left: i * 14,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: BeeTokens.surface(context),
                        width: 1.2,
                      ),
                    ),
                    child: CollabMemberAvatar(
                      userId: visible[i].userId,
                      label: visible[i].resolvedDisplayName,
                      avatarUrl: visible[i].avatarUrl,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (hiddenCount > 0) ...[
          const SizedBox(width: 6),
          Container(
            height: 20,
            constraints: const BoxConstraints(minWidth: 20),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: BeeTokens.surfaceElevated(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BeeTokens.border(context)),
            ),
            alignment: Alignment.center,
            child: Text(
              '+$hiddenCount',
              style: TextStyle(
                fontSize: 11,
                color: BeeTokens.textSecondary(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPillTag(
    BuildContext context, {
    required String text,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primaryColor = ref.watch(primaryColorProvider);
    final l10n = AppLocalizations.of(context);
    final cloudConfig = ref.watch(activeCloudConfigProvider);
    final isBeeCountCloudMode = cloudConfig.hasValue &&
        cloudConfig.value!.type == CloudBackendType.beecountCloud;

    // 获取同步状态
    final syncStatusAsync = ref.watch(syncStatusProvider(ledger.id));
    final syncStatus = syncStatusAsync.valueOrNull;

    // 检查是否正在上传
    final uploadingIds = ref.watch(uploadingLedgerIdsProvider);
    final isUploading =
        !ledger.isRemoteOnly && uploadingIds.contains(ledger.id);

    // 判断同步状态
    final isRemote = ledger.isRemoteOnly;
    final isSynced = syncStatus?.diff == SyncDiff.inSync;
    final collabCapability = (!isRemote && ledger.ledgerType == 'shared')
        ? (isBeeCountCloudMode
            ? ref.watch(ledgerCollabCapabilityProvider(ledger.id)).asData?.value
            : null)
        : null;
    final collabMembers =
        (!isRemote && ledger.ledgerType == 'shared' && isBeeCountCloudMode)
            ? ref.watch(ledgerCollabMembersProvider(ledger.id)).asData?.value ??
                const <LedgerCollabMemberSummary>[]
            : const <LedgerCollabMemberSummary>[];
    final activeMemberCount = _activeMembers(collabMembers).length;
    final showMemberStack = !isRemote &&
        ledger.ledgerType == 'shared' &&
        isBeeCountCloudMode &&
        activeMemberCount > 0;

    // 非同步状态：除了inSync和noRemote之外的所有状态
    final isNotSynced = syncStatus != null &&
        syncStatus.diff != SyncDiff.inSync &&
        syncStatus.diff != SyncDiff.noRemote &&
        syncStatus.diff != SyncDiff.notConfigured;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: BeeTokens.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: BeeTokens.isDark(context)
              ? Border.all(color: BeeTokens.border(context), width: 1)
              : null,
          boxShadow: BeeTokens.isDark(context)
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              // 左侧色条：仅选中时显示
              if (selected)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                      ),
                    ),
                  ),
                ),

              // 底层：账本信息（始终显示）
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 顶部：名称 + 状态图标
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 账本名称 + 标签
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                translateLedgerName(context, ledger.name),
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: BeeTokens.textPrimary(context),
                                ),
                              ),
                              if (ledger.ledgerType == 'shared')
                                _buildPillTag(
                                  context,
                                  text: l10n.cloudCollabSharedTag,
                                  background:
                                      Colors.blue.withValues(alpha: 0.16),
                                  foreground: Colors.blue.shade700,
                                ),
                              if (isBeeCountCloudMode &&
                                  (collabCapability?.roleResolved ?? false))
                                _buildPillTag(
                                  context,
                                  text: _roleLabel(l10n, collabCapability!),
                                  background:
                                      primaryColor.withValues(alpha: 0.16),
                                  foreground: primaryColor,
                                ),
                            ],
                          ),
                        ),
                        if (!isRemote) ...[
                          const SizedBox(width: 6),
                          Text(
                            '(ID:${ledger.id})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: primaryColor.withValues(alpha: 0.8),
                            ),
                          ),
                        ],

                        const SizedBox(width: 8),

                        // 状态图标
                        _buildStatusIcon(
                          context,
                          ref,
                          primaryColor,
                          isSynced,
                          isNotSynced,
                          isRemote,
                          isUploading,
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // 统计数据（本地和远程都显示）
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 币种
                        Text(
                          '${l10n.ledgersCurrency}：${getCurrencyName(ledger.currency, context)}（${ledger.currency}）',
                          style: TextStyle(
                            fontSize: 14,
                            color: BeeTokens.textSecondary(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 记账笔数
                        Text(
                          l10n.ledgersRecords('${ledger.transactionCount}'),
                          style: TextStyle(
                            fontSize: 14,
                            color: BeeTokens.textSecondary(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 余额（根据设置使用简洁或完整格式）
                        Text(
                          l10n.ledgersBalance(
                            ref.watch(compactAmountProvider)
                                ? formatBalance(
                                    ledger.balance,
                                    ledger.currency,
                                    isChineseLocale:
                                        Localizations.localeOf(context)
                                                .languageCode ==
                                            'zh',
                                  )
                                : formatBalanceFull(
                                    ledger.balance, ledger.currency),
                          ),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: ledger.balance >= 0
                                ? BeeTokens.success(context)
                                : BeeTokens.error(context),
                          ),
                        ),
                      ],
                    ),
                    if (showMemberStack) const SizedBox(height: 24),
                  ],
                ),
              ),

              if (showMemberStack)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _buildMemberStack(
                    context,
                    collabMembers,
                  ),
                ),

              // 蒙层：仅远程账本显示
              if (isRemote)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: BeeTokens.surface(context).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.cloud_download,
                          size: 48,
                          color: primaryColor,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.ledgerCardDownloadCloud,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态图标
  Widget _buildStatusIcon(
    BuildContext context,
    WidgetRef ref,
    Color primaryColor,
    bool isSynced,
    bool isNotSynced,
    bool isRemote,
    bool isUploading,
  ) {
    // 优先显示上传中状态
    if (isUploading) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.0,
        ),
      );
    }

    if (isRemote) {
      // 远程账本：云下载图标
      return Icon(
        Icons.cloud_download,
        color: primaryColor,
        size: 20,
      );
    } else if (isSynced) {
      // 已同步：绿色云勾选图标
      return const Icon(
        Icons.cloud_done,
        color: Colors.green,
        size: 20,
      );
    } else if (isNotSynced) {
      // 未同步（包括：localNewer、cloudNewer、different、error、notLoggedIn）：红色云图标
      return const Icon(
        Icons.cloud_off,
        color: Colors.red,
        size: 20,
      );
    } else {
      // 纯本地账本（离线模式/未配置）：灰色云关闭图标
      return const Icon(
        Icons.cloud_off,
        color: Colors.grey,
        size: 20,
      );
    }
  }
}
