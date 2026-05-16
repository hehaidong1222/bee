/// 成员管理页 —— 列出账本成员,Owner 可踢人 / 转让,任意 member 可退出。
import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/sync/sync_engine.dart';
import '../../cloud/sync/sync_providers.dart' as cloud_sync;
import '../../l10n/app_localizations.dart';
import '../../providers/database_providers.dart';
import '../../providers/shared_ledger_providers.dart';
import '../../providers/sync_providers.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';
import 'invite_page.dart';

class MemberListPage extends ConsumerWidget {
  const MemberListPage({
    super.key,
    required this.ledgerExternalId,
    required this.ledgerName,
  });

  final String ledgerExternalId;
  final String ledgerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final membersAsync = ref.watch(ledgerMembersProvider(ledgerExternalId));

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.sharedMembersPageTitle,
            subtitle: ledgerName,
            showBack: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ref.invalidate(ledgerMembersProvider(ledgerExternalId)),
              ),
            ],
          ),
          Expanded(
            child: membersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('${l10n.commonError}: $e',
                      textAlign: TextAlign.center),
                ),
              ),
              data: (members) => _buildList(context, ref, members, l10n),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<BeeCountCloudLedgerMember> members,
    AppLocalizations l10n,
  ) {
    final me = members.where((m) => m.isSelf).firstOrNull;
    final amOwner = me?.role == 'owner';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          child: Column(
            children: [
              for (final m in members) ...[
                _MemberTile(
                  member: m,
                  amOwner: amOwner,
                  onChangeRole: amOwner && !m.isSelf
                      ? () => _confirmTransfer(context, ref, m, l10n)
                      : null,
                  onRemove: amOwner && !m.isSelf
                      ? () => _confirmRemove(context, ref, m, l10n)
                      : null,
                ),
                if (m != members.last) const Divider(height: 1),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (amOwner)
          SectionCard(
            child: ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: Text(l10n.sharedMembersInviteCta),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => InvitePage(
                    ledgerExternalId: ledgerExternalId,
                    ledgerName: ledgerName,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (me != null && !amOwner)
          SectionCard(
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: Text(
                l10n.sharedMembersLeaveCta,
                style: const TextStyle(color: Colors.redAccent),
              ),
              onTap: () => _confirmLeave(context, ref, me, l10n),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    BeeCountCloudLedgerMember target,
    AppLocalizations l10n,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sharedMembersRemoveTitle),
        content: Text(l10n.sharedMembersRemoveConfirm(
            target.displayName ?? target.email)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonRemove),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await removeMemberAndRefresh(
        ref,
        ledgerId: ledgerExternalId,
        userId: target.userId,
      );
      if (context.mounted) showToast(context, l10n.sharedMembersRemoved);
    } catch (e) {
      if (context.mounted) showToast(context, e.toString());
    }
  }

  Future<void> _confirmTransfer(
    BuildContext context,
    WidgetRef ref,
    BeeCountCloudLedgerMember target,
    AppLocalizations l10n,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sharedMembersTransferTitle),
        content: Text(l10n.sharedMembersTransferConfirm(
            target.displayName ?? target.email)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sharedMembersTransferConfirmCta),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await transferOwnershipAndRefresh(
        ref,
        ledgerId: ledgerExternalId,
        newOwnerUserId: target.userId,
      );
      if (context.mounted) showToast(context, l10n.sharedMembersTransferDone);
    } catch (e) {
      if (context.mounted) showToast(context, e.toString());
    }
  }

  Future<void> _confirmLeave(
    BuildContext context,
    WidgetRef ref,
    BeeCountCloudLedgerMember me,
    AppLocalizations l10n,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sharedMembersLeaveTitle),
        content: Text(l10n.sharedMembersLeaveConfirm(ledgerName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sharedMembersLeaveCta),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await removeMemberAndRefresh(
        ref,
        ledgerId: ledgerExternalId,
        userId: me.userId,
      );
      // 主动退出后立即清本地数据,避免依赖 WS member_change.removed 推送
      // (server 端 broadcast 已经做了,但本地 self-trigger 更可靠)
      try {
        final cloud =
            await ref.read(beecountCloudProviderInstance.future);
        if (cloud != null) {
          final engine = ref.read(cloud_sync.syncEngineProvider(cloud));
          // 解析本地 ledger id
          final db = ref.read(databaseProvider);
          final ledger = await (db.select(db.ledgers)
                ..where((l) => l.syncId.equals(ledgerExternalId)))
              .getSingleOrNull();
          if (ledger != null) {
            await engine.purgeSharedLedger(ledger.id);
          }
        }
      } catch (_) {
        // 清理失败不阻塞 UI 反馈,WS 推送会兜底
      }
      if (context.mounted) {
        showToast(context, l10n.sharedMembersLeaveDone);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) showToast(context, e.toString());
    }
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.amOwner,
    this.onChangeRole,
    this.onRemove,
  });

  final BeeCountCloudLedgerMember member;
  final bool amOwner;
  final VoidCallback? onChangeRole;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final displayName = member.displayName?.isNotEmpty == true
        ? member.displayName!
        : member.email.split('@').first;
    final isOwner = member.role == 'owner';
    return ListTile(
      leading: CircleAvatar(
        child: Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : '?'),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (member.isSelf) ...[
            const SizedBox(width: 4),
            Text(
              ' (${l10n.sharedMembersYou})',
              style: TextStyle(
                color: BeeTokens.textTertiary(context),
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        member.email,
        style: TextStyle(color: BeeTokens.textSecondary(context), fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(isOwner ? l10n.sharedRoleOwner : l10n.sharedRoleEditor),
          ),
          if (amOwner && !member.isSelf && !isOwner)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                if (v == 'transfer') onChangeRole?.call();
                if (v == 'remove') onRemove?.call();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'transfer',
                  child: Text(l10n.sharedMembersTransferTo),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(l10n.sharedMembersRemoveCta),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
