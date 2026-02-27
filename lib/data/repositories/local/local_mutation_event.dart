enum LocalMutationEntityType {
  ledger,
  transaction,
  account,
  category,
  tag,
}

enum LocalMutationAction {
  create,
  update,
  delete,
}

class LocalMutationEvent {
  const LocalMutationEvent({
    required this.entityType,
    required this.action,
    required this.entityId,
    this.ledgerId,
    this.entitySyncId,
    this.occurredAt,
  });

  final LocalMutationEntityType entityType;
  final LocalMutationAction action;
  final int entityId;
  final int? ledgerId;
  final String? entitySyncId;
  final DateTime? occurredAt;
}
