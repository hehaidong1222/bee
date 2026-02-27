import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudBackendType;

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/sync_providers.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';
import 'share_members_page.dart';

class LedgerCollabPage extends ConsumerStatefulWidget {
  const LedgerCollabPage({
    super.key,
    required this.ledgerId,
    this.ledgerName,
  });

  final int ledgerId;
  final String? ledgerName;

  @override
  ConsumerState<LedgerCollabPage> createState() => _LedgerCollabPageState();
}

class _LedgerCollabPageState extends ConsumerState<LedgerCollabPage> {
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
        return l10n.cloudCollabRoleNotReady;
    }
  }

  String _statusLabel(LedgerCollabCapability? capability) {
    switch (capability?.status) {
      case LedgerCollabCapabilityStatus.resolved:
        return 'resolved';
      case LedgerCollabCapabilityStatus.notApplicable:
        return 'not_applicable';
      case LedgerCollabCapabilityStatus.scopeDenied:
        return 'scopeDenied';
      case LedgerCollabCapabilityStatus.unavailable:
      case null:
        return 'unavailable';
    }
  }

  Future<void> _copyDiagnostics(
    BuildContext context, {
    required LedgerCollabCapability? capability,
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      final auth = await ref.read(authServiceProvider.future);
      final user = await auth.currentUser;
      final deviceId = user?.metadata?['deviceId']?.toString().trim();
      final role = normalizeCollabRole(capability?.role);
      final lines = <String>[
        'ledgerId=${widget.ledgerId}',
        'role_resolve_status=${_statusLabel(capability)}',
        'role=${role.isEmpty ? 'not_ready' : role}',
        'detail=${(capability?.detail ?? '').trim().isEmpty ? '-' : capability!.detail!}',
        'scope_hint=${capability?.scopeDenied == true ? 'ALLOW_APP_RW_SCOPES=true' : '-'}',
        'deviceId=${(deviceId ?? '').isEmpty ? '-' : deviceId}',
      ];
      await Clipboard.setData(ClipboardData(text: lines.join('\n')));
      if (!context.mounted) return;
      showToast(context, l10n.cloudCollabDiagnosticsCopied);
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '${l10n.commonFailed}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cloudConfig = ref.watch(activeCloudConfigProvider);
    final isBeeCountCloudMode = cloudConfig.hasValue &&
        cloudConfig.value!.type == CloudBackendType.beecountCloud;
    final capabilityAsync =
        ref.watch(ledgerCollabCapabilityProvider(widget.ledgerId));
    final capability = capabilityAsync.asData?.value;
    final scopeDenied = capability?.scopeDenied ?? false;

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.cloudCollabManagePageTitle,
            subtitle: widget.ledgerName?.isNotEmpty == true
                ? widget.ledgerName!
                : l10n.cloudCollabManagePageSubtitle,
            showBack: true,
          ),
          Expanded(
            child: !isBeeCountCloudMode
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        l10n.cloudCollabUnavailableMessage,
                        style: TextStyle(
                          color: BeeTokens.textSecondary(context),
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SectionCard(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: const Icon(Icons.science_outlined),
                          title: Text(l10n.cloudCollabExperimentalBetaTitle),
                          subtitle:
                              Text(l10n.cloudCollabExperimentalBetaSubtitle),
                        ),
                      ),
                      if (scopeDenied)
                        SectionCard(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            leading: const Icon(Icons.warning_amber_outlined),
                            title: Text(l10n.cloudCollabScopeDeniedTitle),
                            subtitle: Text(
                              '${l10n.cloudCollabScopeDeniedHint}\n${l10n.cloudCollabScopeDeniedAction}',
                            ),
                          ),
                        ),
                      SectionCard(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: [
                            AppListTile(
                              leading: Icons.shield_outlined,
                              title: l10n.cloudCollabCurrentRoleTitle,
                              subtitle: normalizeCollabRole(capability?.role) ==
                                      'viewer'
                                  ? l10n.cloudCollabLegacyViewerHint
                                  : l10n.cloudCollabCurrentRoleSubtitle,
                              trailing: InfoTag(capabilityAsync.isLoading
                                  ? l10n.cloudCollabRoleLoading
                                  : _roleLabel(
                                      l10n,
                                      capability ??
                                          const LedgerCollabCapability(
                                            status: LedgerCollabCapabilityStatus
                                                .unavailable,
                                            role: null,
                                          ),
                                    )),
                              onTap: null,
                            ),
                            BeeTokens.cardDivider(context),
                            AppListTile(
                              leading: Icons.group_outlined,
                              title: l10n.cloudCollabMembersEntryTitle,
                              subtitle: l10n.cloudCollabMembersEntrySubtitle,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ShareMembersPage(
                                      ledgerId: widget.ledgerId),
                                ),
                              ),
                            ),
                            BeeTokens.cardDivider(context),
                            AppListTile(
                              leading: Icons.admin_panel_settings_outlined,
                              title: l10n.cloudCollabManagedInBackendTitle,
                              subtitle: scopeDenied
                                  ? l10n.cloudCollabRoleNotReady
                                  : l10n.cloudCollabManagedInBackendHint,
                              onTap: null,
                            ),
                            BeeTokens.cardDivider(context),
                            AppListTile(
                              leading: Icons.medical_information_outlined,
                              title: l10n.cloudCollabDiagnosticsTitle,
                              subtitle: l10n.cloudCollabDiagnosticsSubtitle,
                              onTap: () => _copyDiagnostics(
                                context,
                                capability: capability,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
