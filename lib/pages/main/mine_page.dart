import 'dart:async';
import 'dart:io' show Platform, File;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:beecount/widgets/biz/bee_icon.dart';
import 'package:intl/intl.dart';

import '../data/import_page.dart';
import '../data/export_page.dart';
import '../settings/personalize_page.dart';
import '../../providers.dart';
import '../../providers/theme_providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../../cloud/sync_service.dart';
import '../../cloud/transactions_sync_manager.dart';
import '../cloud/cloud_service_page.dart';
import '../../services/system/logger_service.dart';
import '../../services/ui/avatar_service.dart';
import '../../services/export/share_poster_service.dart';
import '../../l10n/app_localizations.dart';
import '../category/category_manage_page.dart';
import '../category/category_migration_page.dart';
import '../transaction/recurring_transaction_page.dart';
import '../settings/reminder_settings_page.dart';
import '../settings/language_settings_page.dart';
import '../account/accounts_page.dart';
import '../settings/widget_management_page.dart';
import '../automation/auto_billing_settings_page.dart';
import '../ai/ai_settings_page.dart';
import '../cloud/cloud_sync_page.dart';
import '../../utils/website_urls.dart';
import '../../providers/github_star_provider.dart';
import '../settings/data_management_page.dart';
import '../settings/appearance_settings_page.dart';
import '../settings/smart_billing_page.dart';
import '../settings/automation_page.dart';
import '../settings/about_page.dart';
import '../report/annual_report_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:in_app_review/in_app_review.dart';
import '../../services/system/update_service.dart';
import '../../utils/ui_scale_extensions.dart';
import '../donation/donation_page.dart';

class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  String _roleLabel(AppLocalizations l10n, LedgerCollabCapability? capability) {
    if (capability == null) {
      return '';
    }
    if (capability.status == LedgerCollabCapabilityStatus.notApplicable) {
      return '';
    }
    final normalized = normalizeCollabRole(capability.role);
    switch (normalized) {
      case 'owner':
        return l10n.cloudCollabRoleOwner;
      case 'editor':
        return l10n.cloudCollabRoleEditor;
      case 'viewer':
        return l10n.cloudCollabRoleViewerLegacy;
      default:
        return l10n.cloudCollabRoleNotReady;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context), // ⭐ 使用 Token
      body: Column(
        children: [
          PrimaryHeader(
            showBack: false,
            title: AppLocalizations.of(context).mineTitle,
            compact: true,
            showTitleSection: false,
            content: _MinePageHeader(),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                BeeTokens.cardDivider(context),
                SizedBox(height: 8.0.scaled(context, ref)),
                // 云同步与备份
                Consumer(builder: (sectionContext, sectionRef, _) {
                  final activeCfg = sectionRef.watch(activeCloudConfigProvider);

                  return SectionCard(
                    margin: EdgeInsets.fromLTRB(
                        12.0.scaled(sectionContext, sectionRef),
                        0,
                        12.0.scaled(sectionContext, sectionRef),
                        0),
                    child: Column(
                      children: [
                        // 云服务
                        AppListTile(
                          leading: Icons.cloud_queue_outlined,
                          title: AppLocalizations.of(sectionContext)
                              .mineCloudService,
                          subtitle: activeCfg.when(
                            loading: () => AppLocalizations.of(sectionContext)
                                .mineCloudServiceLoading,
                            error: (e, _) =>
                                '${AppLocalizations.of(sectionContext).commonError}: $e',
                            data: (cfg) {
                              switch (cfg.type) {
                                case CloudBackendType.local:
                                  return AppLocalizations.of(sectionContext)
                                      .mineCloudServiceOffline;
                                case CloudBackendType.beecountCloud:
                                  return 'BeeCount Cloud';
                                case CloudBackendType.webdav:
                                  return AppLocalizations.of(sectionContext)
                                      .mineCloudServiceWebDAV;
                                case CloudBackendType.icloud:
                                  return 'iCloud';
                                case CloudBackendType.supabase:
                                  return AppLocalizations.of(sectionContext)
                                      .mineCloudServiceCustom;
                                case CloudBackendType.s3:
                                  return 'S3';
                              }
                            },
                          ),
                          onTap: () async {
                            await Navigator.of(sectionContext).push(
                              MaterialPageRoute(
                                  builder: (_) => const CloudServicePage()),
                            );
                          },
                        ),
                        // 同步状态
                        Builder(
                          builder: (ctx) {
                            return authAsync.when(
                              loading: () => const Padding(
                                padding: EdgeInsets.all(16.0),
                                child:
                                    Center(child: CircularProgressIndicator()),
                              ),
                              error: (e, _) => Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  '${AppLocalizations.of(sectionContext).commonError}: $e',
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ),
                              data: (auth) => FutureBuilder<CloudUser?>(
                                future: auth.currentUser,
                                builder: (ctx, snap) {
                                  if (snap.hasError) {
                                    return Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Text(
                                        '${AppLocalizations.of(sectionContext).commonError}: ${snap.error}',
                                        style:
                                            const TextStyle(color: Colors.red),
                                      ),
                                    );
                                  }

                                  final user = snap.data;
                                  final cloudConfig = sectionRef
                                      .watch(activeCloudConfigProvider);
                                  final isLocalMode = cloudConfig.hasValue &&
                                      cloudConfig.value!.type ==
                                          CloudBackendType.local;
                                  final isSupabaseMode = cloudConfig.hasValue &&
                                      cloudConfig.value!.type ==
                                          CloudBackendType.supabase;
                                  final isBeeCountCloudMode =
                                      cloudConfig.hasValue &&
                                          cloudConfig.value!.type ==
                                              CloudBackendType.beecountCloud;
                                  final requiresLogin =
                                      isSupabaseMode || isBeeCountCloudMode;
                                  // iCloud/WebDAV/S3 使用配置认证；BeeCount Cloud 需要账号登录。
                                  final canUseCloud = !isLocalMode &&
                                      (!requiresLogin || user != null);
                                  final collabCapability = sectionRef
                                      .watch(ledgerCollabCapabilityProvider(
                                          ledgerId))
                                      .asData
                                      ?.value;
                                  final asyncSt = sectionRef
                                      .watch(syncStatusProvider(ledgerId));
                                  final cached = sectionRef
                                      .watch(lastSyncStatusProvider(ledgerId));
                                  final st = asyncSt.asData?.value ?? cached;

                                  // 计算简化的同步状态显示
                                  String subtitle = '';
                                  bool showCheckIcon = false;
                                  final isFirstLoad = st == null;
                                  final refreshing = asyncSt.isLoading;

                                  if (!isFirstLoad) {
                                    if (isBeeCountCloudMode) {
                                      switch (st.diff) {
                                        case SyncDiff.notLoggedIn:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncNotLoggedIn;
                                          break;
                                        case SyncDiff.notConfigured:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncNotConfigured;
                                          break;
                                        case SyncDiff.error:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncError;
                                          break;
                                        default:
                                          if (st.cloudExportedAt != null) {
                                            subtitle = AppLocalizations.of(
                                                    sectionContext)
                                                .mineSyncCloudLatest(DateFormat(
                                                        'yyyy-MM-dd HH:mm:ss')
                                                    .format(st.cloudExportedAt!
                                                        .toLocal()));
                                          } else {
                                            subtitle = AppLocalizations.of(
                                                    sectionContext)
                                                .mineSyncInSyncSimple;
                                          }
                                          showCheckIcon = true;
                                          break;
                                      }
                                    } else {
                                      switch (st.diff) {
                                        case SyncDiff.notLoggedIn:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncNotLoggedIn;
                                          break;
                                        case SyncDiff.notConfigured:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncNotConfigured;
                                          break;
                                        case SyncDiff.noRemote:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncNoRemote;
                                          break;
                                        case SyncDiff.inSync:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncInSyncSimple;
                                          showCheckIcon = true;
                                          break;
                                        case SyncDiff.localNewer:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncLocalNewerSimple;
                                          break;
                                        case SyncDiff.cloudNewer:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncCloudNewerSimple;
                                          break;
                                        case SyncDiff.different:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncDifferent;
                                          break;
                                        case SyncDiff.error:
                                          subtitle = AppLocalizations.of(
                                                  sectionContext)
                                              .mineSyncError;
                                          break;
                                      }
                                    }
                                  }

                                  if (!isFirstLoad &&
                                      isBeeCountCloudMode &&
                                      user != null) {
                                    final roleLabel = _roleLabel(
                                      AppLocalizations.of(sectionContext),
                                      collabCapability,
                                    );
                                    if (roleLabel.isNotEmpty) {
                                      subtitle = subtitle.isEmpty
                                          ? roleLabel
                                          : '$subtitle · $roleLabel';
                                    }
                                  }

                                  return Column(
                                    children: [
                                      BeeTokens.cardDivider(sectionContext),
                                      AppListTile(
                                        leading: Icons.cloud_sync_outlined,
                                        title:
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncTitle,
                                        subtitle: isFirstLoad ? null : subtitle,
                                        enabled: !isLocalMode,
                                        trailing: (canUseCloud &&
                                                (isFirstLoad || refreshing))
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : showCheckIcon
                                                ? Icon(Icons.check_circle,
                                                    color: sectionRef.watch(
                                                        primaryColorProvider),
                                                    size: 20)
                                                : Icon(Icons.chevron_right,
                                                    color: BeeTokens.iconTertiary(
                                                        context), // ⭐ 使用 Token
                                                    size: 20),
                                        onTap: () async {
                                          await Navigator.of(sectionContext)
                                              .push(
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    const CloudSyncPage()),
                                          );
                                        },
                                      ),
                                    ],
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }),
                // 功能管理
                SizedBox(height: 8.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.fromLTRB(12.0.scaled(context, ref), 0,
                      12.0.scaled(context, ref), 0),
                  child: Column(
                    children: [
                      // 智能记账
                      AppListTile(
                        leading: Icons.auto_awesome_outlined,
                        title: AppLocalizations.of(context).smartBilling,
                        subtitle: AppLocalizations.of(context).smartBillingDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20), // ⭐ 使用 Token
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const SmartBillingPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 数据管理
                      AppListTile(
                        leading: Icons.storage_outlined,
                        title: AppLocalizations.of(context).dataManagement,
                        subtitle:
                            AppLocalizations.of(context).dataManagementDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20), // ⭐ 使用 Token
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const DataManagementPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 账户管理
                      AppListTile(
                        leading: Icons.account_balance_wallet_outlined,
                        title: AppLocalizations.of(context).accountsTitle,
                        subtitle:
                            AppLocalizations.of(context).accountsManageDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20), // ⭐ 使用 Token
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AccountsPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 自动化功能
                      AppListTile(
                        leading: Icons.schedule_outlined,
                        title: AppLocalizations.of(context).automation,
                        subtitle: AppLocalizations.of(context).automationDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20), // ⭐ 使用 Token
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AutomationPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 外观设置
                      AppListTile(
                        leading: Icons.palette_outlined,
                        title: AppLocalizations.of(context).appearanceSettings,
                        subtitle:
                            AppLocalizations.of(context).appearanceSettingsDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20), // ⭐ 使用 Token
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AppearanceSettingsPage()),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                // 帮助与信息
                SizedBox(height: 8.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.fromLTRB(12.0.scaled(context, ref), 0,
                      12.0.scaled(context, ref), 0),
                  child: Column(
                    children: [
                      AppListTile(
                        leading: Icons.info_outline,
                        title: AppLocalizations.of(context).about,
                        subtitle: AppLocalizations.of(context).aboutDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AboutPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 使用帮助
                      AppListTile(
                        leading: Icons.help_outline,
                        title: AppLocalizations.of(context).mineHelp,
                        subtitle: AppLocalizations.of(context).mineHelpSubtitle,
                        onTap: () async {
                          final locale = Localizations.localeOf(context);
                          final url = Uri.parse(WebsiteUrls.docs(locale));
                          await _tryOpenUrl(url);
                        },
                      ),
                    ],
                  ),
                ),
                // 支持我们
                SizedBox(height: 8.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.fromLTRB(12.0.scaled(context, ref), 0,
                      12.0.scaled(context, ref), 0),
                  child: Column(
                    children: [
                      // 仅在iOS显示打赏入口
                      if (Platform.isIOS) ...[
                        Consumer(
                          builder: (context, ref, _) {
                            final primaryColor =
                                ref.watch(primaryColorProvider);
                            return AppListTile(
                              leading: Icons.favorite,
                              leadingWidget: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: primaryColor.withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.favorite_border,
                                  color: primaryColor,
                                ),
                              ),
                              title: AppLocalizations.of(context).donationTitle,
                              subtitle: AppLocalizations.of(context)
                                  .donationEntrySubtitle,
                              trailing: Icon(Icons.chevron_right,
                                  color: BeeTokens.iconTertiary(context),
                                  size: 20),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => const DonationPage()),
                                );
                              },
                            );
                          },
                        ),
                        BeeTokens.cardDivider(context),
                      ],
                      // GitHub Star
                      Consumer(
                        builder: (context, ref, _) {
                          final starCountAsync =
                              ref.watch(githubStarCountProvider);
                          final starCount = starCountAsync.valueOrNull ?? 999;
                          return AppListTile(
                            leading: Icons.star_outline,
                            title:
                                AppLocalizations.of(context).mineSupportAuthor,
                            subtitle: AppLocalizations.of(context)
                                .mineSupportAuthorSubtitle(
                                    starCount.toString()),
                            onTap: () => _showGitHubStarGuide(context),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 年度账单
                      AppListTile(
                        leading: Icons.auto_graph_rounded,
                        title: AppLocalizations.of(context).annualReportTitle,
                        subtitle: AppLocalizations.of(context)
                            .annualReportEntrySubtitle,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AnnualReportPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 分享海报
                      AppListTile(
                        leading: Icons.ios_share_rounded,
                        title: AppLocalizations.of(context).mineShareApp,
                        subtitle:
                            AppLocalizations.of(context).mineShareWithFriends,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () {
                          // 打开海报轮播预览对话框（支持年度、月度、总览3种海报）
                          SharePosterService.showPosterCarouselPreview(context);
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 复制推广文案
                      AppListTile(
                        leading: Icons.content_copy_rounded,
                        title: AppLocalizations.of(context).mineCopyPromoText,
                        subtitle:
                            AppLocalizations.of(context).mineCopyPromoSubtitle,
                        onTap: () async {
                          final l10n = AppLocalizations.of(context);
                          await Clipboard.setData(
                            ClipboardData(text: l10n.shareGuidanceCopyText),
                          );
                          if (context.mounted) {
                            showToast(context, l10n.shareGuidanceCopied);
                          }
                        },
                      ),
                      // 只在iOS上显示评分入口（Android还未上架）
                      if (Platform.isIOS) ...[
                        BeeTokens.cardDivider(context),
                        AppListTile(
                          leading: Icons.star_border_rounded,
                          title: AppLocalizations.of(context).mineRateApp,
                          subtitle:
                              AppLocalizations.of(context).mineRateAppSubtitle,
                          onTap: () => _rateApp(context),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: BeeDimens.p16.scaled(context, ref)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCell extends ConsumerWidget {
  final String label;
  final dynamic value; // 可以是 String 或 double
  final TextStyle? labelStyle;
  final TextStyle? numStyle;
  final bool isAmount; // 是否为金额类型
  final String? currencyCode; // 币种代码
  final bool centered; // 是否居中对齐

  const _StatCell({
    required this.label,
    required this.value,
    this.labelStyle,
    this.numStyle,
    this.isAmount = false,
    this.currencyCode,
    this.centered = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget valueWidget;
    if (isAmount && value is double) {
      // 金额类型,使用 AmountText
      valueWidget = AmountText(
        value: value as double,
        signed: false,
        showCurrency: true,
        useCompactFormat: ref.watch(compactAmountProvider),
        currencyCode: currencyCode,
        style: numStyle,
      );
    } else {
      // 其他类型,直接显示字符串
      valueWidget = Text(value.toString(), style: numStyle);
    }

    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        valueWidget,
        SizedBox(height: 4.0.scaled(context, ref)), // 数字与标签间距增大
        Text(label,
            style: labelStyle,
            textAlign: centered ? TextAlign.center : TextAlign.start),
      ],
    );
  }
}

// 导入完成后的短暂动画提示：线性进度条从 0 -> 100%
class _ImportSuccessTile extends StatelessWidget {
  const _ImportSuccessTile();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) {
        return AppListTile(
          leading: Icons.check_circle_outline,
          title: AppLocalizations.of(ctx).mineImportCompleteTitle,
          subtitle: AppLocalizations.of(ctx).mineImportCompleteAllSuccess,
          trailing: SizedBox(
            width: 72,
            child: LinearProgressIndicator(
              value: v,
              valueColor: AlwaysStoppedAnimation(primary),
            ),
          ),
        );
      },
    );
  }
}

/// 尝试使用多种方式打开URL，提供更好的兼容性
Future<bool> _tryOpenUrl(Uri url) async {
  try {
    // 方式1: 默认外部应用打开
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return true;
    }

    // 方式2: 浏览器内打开
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalNonBrowserApplication);
      return true;
    }

    // 方式3: 平台默认方式
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.platformDefault);
      return true;
    }

    logger.error('MinePage', '无法打开URL: $url');
    return false;
  } catch (e) {
    logger.error('MinePage', '打开URL失败: $url', e);
    return false;
  }
}

/// 显示 GitHub Star 引导弹窗
void _showGitHubStarGuide(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final screenHeight = MediaQuery.of(context).size.height;

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.githubStarGuideTitle),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: screenHeight * 0.5,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.githubStarGuideContent,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              // 引导图片
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/images/github_star_guide.png',
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            _tryOpenUrl(Uri.parse('https://github.com/TNT-Likely/BeeCount'));
          },
          child: Text(l10n.githubStarGuideButton),
        ),
      ],
    ),
  );
}

/// 请求应用评分
///
/// iOS系统对原生评分弹窗有限制：
/// 1. 每365天最多弹出3次
/// 2. 模拟器上不显示
/// 3. 用户可在系统设置中禁用
///
/// 因此直接打开App Store评分页面更可靠
Future<void> _rateApp(BuildContext context) async {
  try {
    final InAppReview inAppReview = InAppReview.instance;

    // 直接打开应用商店评分页面（更可靠，不受系统限制）
    if (Platform.isIOS) {
      await inAppReview.openStoreListing(
        appStoreId: '6754611670', // BeeCount的App Store ID
      );
      logger.info('MinePage', '已打开App Store评分页面');
    } else {
      // Android会自动打开Google Play（如果已上架）
      await inAppReview.openStoreListing();
      logger.info('MinePage', '已打开Google Play评分页面');
    }
  } catch (e) {
    logger.error('MinePage', '打开评分失败', e);
    // 失败时不显示错误提示，静默失败
  }
}

/// 我的页面头部
class _MinePageHeader extends ConsumerStatefulWidget {
  const _MinePageHeader();

  @override
  ConsumerState<_MinePageHeader> createState() => _MinePageHeaderState();
}

class _MinePageHeaderState extends ConsumerState<_MinePageHeader> {
  String? _avatarPath;
  bool _isLoadingAvatar = true;
  bool _avatarUploadBusy = false;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final path = await AvatarService.getAvatarPath();
    if (mounted) {
      setState(() {
        _avatarPath = path;
        _isLoadingAvatar = false;
      });
      if (path != null && path.trim().isNotEmpty) {
        unawaited(_maybeBootstrapAvatarUpload(path));
      }
    }
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

  Future<void> _maybeBootstrapAvatarUpload(String localPath) async {
    if (_avatarUploadBusy) {
      return;
    }
    final normalizedLocalPath = localPath.trim();
    if (normalizedLocalPath.isEmpty) {
      return;
    }
    final pendingAvatarPath = ref.read(pendingAvatarUploadPathProvider);
    if (pendingAvatarPath != null &&
        pendingAvatarPath.trim().isNotEmpty &&
        pendingAvatarPath.trim() == normalizedLocalPath) {
      unawaited(_uploadAvatarToCloud(normalizedLocalPath));
      return;
    }
    final cloudConfig = await ref.read(activeCloudConfigProvider.future);
    if (!mounted) return;
    if (!cloudConfig.valid ||
        cloudConfig.type != CloudBackendType.beecountCloud) {
      return;
    }
    final authService = await ref.read(authServiceProvider.future);
    final currentUser = await authService.currentUser;
    if (!mounted) return;
    if (currentUser == null || currentUser.id.trim().isEmpty) {
      return;
    }
    final sync = ref.read(syncServiceProvider);
    if (sync is! TransactionsSyncManager) {
      return;
    }
    try {
      final profile = await sync.getMyProfile();
      if (!mounted) return;
      final hasCloudAvatar = (profile.avatarUrl ?? '').trim().isNotEmpty;
      if (!hasCloudAvatar) {
        unawaited(_uploadAvatarToCloud(normalizedLocalPath));
      }
    } catch (e, stackTrace) {
      logger.warning('MinePage', '检查云端头像状态失败: $e');
      logger.debug('MinePage', '检查云端头像状态堆栈: $stackTrace');
    }
  }

  Future<void> _showAvatarOptions() async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mineAvatarTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l10n.mineAvatarFromGallery),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(l10n.mineAvatarFromCamera),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            if (_avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(l10n.mineAvatarDelete,
                    style: const TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;

    try {
      if (result == 'gallery') {
        final path = await AvatarService.pickAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          unawaited(_uploadAvatarToCloud(path));
        }
      } else if (result == 'camera') {
        final path = await AvatarService.takePhotoAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          unawaited(_uploadAvatarToCloud(path));
        }
      } else if (result == 'delete') {
        await AvatarService.deleteAvatar();
        if (mounted) {
          setState(() => _avatarPath = null);
        }
        ref.read(pendingAvatarUploadPathProvider.notifier).state = null;
        ref.read(pendingAvatarUploadErrorProvider.notifier).state = null;
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${AppLocalizations.of(context).commonError}: $e');
    }
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

  Future<void> _uploadAvatarToCloud(String localPath) async {
    final cloudConfig = await ref.read(activeCloudConfigProvider.future);
    if (!mounted) return;
    if (!cloudConfig.valid ||
        cloudConfig.type != CloudBackendType.beecountCloud) {
      return;
    }
    final sync = ref.read(syncServiceProvider);
    if (sync is! TransactionsSyncManager) {
      return;
    }
    setState(() {
      _avatarUploadBusy = true;
    });
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
      if (mounted) {
        showToast(context,
            AppLocalizations.of(context).cloudCollabAvatarUploadSuccess);
      }
    } catch (e) {
      ref.read(pendingAvatarUploadPathProvider.notifier).state = localPath;
      ref.read(pendingAvatarUploadErrorProvider.notifier).state = '$e';
      if (mounted) {
        showToast(
          context,
          AppLocalizations.of(context).cloudCollabAvatarUploadFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _avatarUploadBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 获取当前账本信息
    final currentLedgerId = ref.watch(currentLedgerIdProvider);
    final countsAsync = ref.watch(countsForLedgerProvider(currentLedgerId));
    final balanceAsync = ref.watch(currentBalanceProvider(currentLedgerId));
    final currentLedgerAsync = ref.watch(currentLedgerProvider);
    final hide = ref.watch(hideAmountsProvider);

    final day = countsAsync.asData?.value.dayCount ?? 0;
    final tx = countsAsync.asData?.value.txCount ?? 0;
    final balance = balanceAsync.asData?.value ?? 0.0;
    final currencyCode = currentLedgerAsync.asData?.value?.currency ?? 'CNY';

    // 统计信息文字颜色
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: BeeTokens.textSecondary(context));
    final numStyle = BeeTextTokens.strongTitle(context)
        .copyWith(fontSize: 20, color: BeeTokens.textPrimary(context));

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12.0.scaled(context, ref),
        12.0.scaled(context, ref),
        12.0.scaled(context, ref),
        10.0.scaled(context, ref),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              // 头像/Logo
              GestureDetector(
                onTap: _showAvatarOptions,
                child: Stack(
                  children: [
                    Container(
                      width: 80.0.scaled(context, ref),
                      height: 80.0.scaled(context, ref),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.1),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child: _isLoadingAvatar
                            ? Center(
                                child: SizedBox(
                                  width: 20.0.scaled(context, ref),
                                  height: 20.0.scaled(context, ref),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              )
                            : (_avatarPath != null
                                ? Image.file(
                                    File(_avatarPath!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return BeeIcon(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        size: 40.0.scaled(context, ref),
                                      );
                                    },
                                  )
                                : BeeIcon(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    size: 40.0.scaled(context, ref),
                                  )),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 24.0.scaled(context, ref),
                        height: 24.0.scaled(context, ref),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Icon(
                          Icons.camera_alt,
                          size: 12.0.scaled(context, ref),
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (_avatarUploadBusy)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.3),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 20.0.scaled(context, ref),
                              height: 20.0.scaled(context, ref),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: 12.0.scaled(context, ref)),
              // Slogan with eye icon - 手动偏移让文字视觉居中
              Padding(
                padding: EdgeInsets.only(
                    left: 26.0.scaled(context, ref)), // 偏移量 = 图标(18) + 间距(8)
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center, // 垂直居中对齐
                  children: [
                    Text(
                      AppLocalizations.of(context).mineSlogan,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: BeeTokens.textPrimary(context), // ⭐ 使用 Token
                            fontWeight: FontWeight.w600,
                          ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(width: 8.0.scaled(context, ref)),
                    GestureDetector(
                      onTap: () {
                        final cur = ref.read(hideAmountsProvider);
                        ref.read(hideAmountsProvider.notifier).state = !cur;
                      },
                      child: Padding(
                        padding: EdgeInsets.only(top: 2.0.scaled(context, ref)),
                        child: Icon(
                          hide
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                          color: BeeTokens.textPrimary(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16.0.scaled(context, ref)),
              // 统计数据
              Row(
                children: [
                  Expanded(
                    child: _StatCell(
                      label: AppLocalizations.of(context).mineDaysCount,
                      value: day.toString(),
                      labelStyle: labelStyle,
                      numStyle: numStyle,
                      centered: true,
                    ),
                  ),
                  Expanded(
                    child: _StatCell(
                      label: AppLocalizations.of(context).mineTotalRecords,
                      value: tx.toString(),
                      labelStyle: labelStyle,
                      numStyle: numStyle,
                      centered: true,
                    ),
                  ),
                  Expanded(
                    child: _StatCell(
                      label: AppLocalizations.of(context).mineCurrentBalance,
                      value: balance,
                      isAmount: true,
                      currencyCode: currencyCode,
                      labelStyle: labelStyle,
                      numStyle: numStyle.copyWith(
                        color: balance >= 0
                            ? BeeTokens.textPrimary(context)
                            : BeeTokens.error(context),
                      ),
                      centered: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
