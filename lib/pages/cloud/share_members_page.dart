import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../cloud/transactions_sync_manager.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

class ShareMembersPage extends ConsumerStatefulWidget {
  const ShareMembersPage({
    super.key,
    required this.ledgerId,
  });

  final int ledgerId;

  @override
  ConsumerState<ShareMembersPage> createState() => _ShareMembersPageState();
}

class _ShareMembersPageState extends ConsumerState<ShareMembersPage> {
  bool _loading = true;
  String? _error;
  List<BeeCountCloudShareMember> _members = const [];

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '-';
    }
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(value.toLocal());
  }

  String _memberName(AppLocalizations l10n, BeeCountCloudShareMember member) {
    return resolveCollabMemberName(
      userId: member.userId,
      displayName: member.userDisplayName,
      email: member.userEmail,
      fallbackUnknown: l10n.cloudCollabUnknownMember,
    );
  }

  String _statusLabel(AppLocalizations l10n, String? status) {
    final normalized = (status ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'active':
        return l10n.cloudCollabMemberStatusActive;
      case 'left':
        return l10n.cloudCollabMemberStatusLeft;
      default:
        return normalized.isEmpty ? l10n.cloudCollabRoleUnknown : normalized;
    }
  }

  String _roleLabel(AppLocalizations l10n, String? role) {
    switch ((role ?? '').trim().toLowerCase()) {
      case 'owner':
        return l10n.cloudCollabRoleOwner;
      case 'editor':
        return l10n.cloudCollabRoleEditor;
      case 'viewer':
        return l10n.cloudCollabRoleViewerLegacy;
      default:
        return l10n.cloudCollabRoleUnknown;
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sync = ref.read(syncServiceProvider);
      if (sync is! TransactionsSyncManager) {
        throw StateError(
          AppLocalizations.of(context).cloudCollabUnavailableMessage,
        );
      }
      final members = await sync.listShareMembers(ledgerId: widget.ledgerId);
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final capabilityAsync =
        ref.watch(ledgerCollabCapabilityProvider(widget.ledgerId));
    final capability = capabilityAsync.asData?.value;
    final scopeDenied = capability?.scopeDenied ?? false;

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.cloudCollabMembersPageTitle,
            subtitle: l10n.cloudCollabMembersPageSubtitle,
            showBack: true,
            actions: [
              IconButton(
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Expanded(
            child: capabilityAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('${l10n.commonError}: $e'),
              ),
              data: (_) {
                if (scopeDenied) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '${l10n.cloudCollabScopeDeniedHint}\n\n${l10n.cloudCollabScopeDeniedAction}',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: BeeTokens.textSecondary(context)),
                      ),
                    ),
                  );
                }
                if (_loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_error != null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('${l10n.commonError}: $_error'),
                    ),
                  );
                }
                if (_members.isEmpty) {
                  return Center(
                    child: Text(
                      l10n.cloudCollabNoMembers,
                      style: TextStyle(color: BeeTokens.textSecondary(context)),
                    ),
                  );
                }
                final hasLegacyViewer = _members.any(
                    (member) => normalizeCollabRole(member.role) == 'viewer');
                return Column(
                  children: [
                    if (hasLegacyViewer)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Text(
                          l10n.cloudCollabLegacyViewerHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: BeeTokens.textSecondary(context),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _members.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final member = _members[index];
                          return SectionCard(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              leading: CollabMemberAvatar(
                                userId: member.userId,
                                label: _memberName(l10n, member),
                                avatarUrl: member.userAvatarUrl,
                                size: 36,
                              ),
                              title: Text(
                                _memberName(l10n, member),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                shortCollabUserId(member.userId),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: BeeTokens.textTertiary(context),
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if ((member.userEmail ?? '')
                                        .trim()
                                        .isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 6),
                                        child: Text(
                                          member.userEmail!,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: BeeTokens.textSecondary(
                                                context),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        InfoTag(_roleLabel(l10n, member.role)),
                                        InfoTag(
                                            _statusLabel(l10n, member.status)),
                                        InfoTag(
                                          l10n.cloudCollabJoinedAt(
                                              _formatDateTime(member.joinedAt)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
