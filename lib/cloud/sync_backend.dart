/// 记录级同步后端抽象层
///
/// 定义了后端无关的同步接口，任何实现（Supabase、Pocketbase、自部署服务）
/// 都通过此接口与客户端交互。
library;

// ---- 数据模型 ----

/// 单条数据变更记录（用于推送/拉取）
class SyncChangeRecord {
  /// 表名：transactions, categories, accounts, ledgers, tags, etc.
  final String table;

  /// 记录的全局唯一标识（UUID v4）
  final String syncId;

  /// 操作类型
  final SyncOperation operation;

  /// 记录数据（FK 已转换为 syncId 形式）
  /// delete 操作时为 null
  final Map<String, dynamic>? payload;

  /// 变更时间戳（用于 LWW 冲突解决）
  final DateTime updatedAt;

  const SyncChangeRecord({
    required this.table,
    required this.syncId,
    required this.operation,
    this.payload,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'table': table,
        'syncId': syncId,
        'operation': operation.name,
        'payload': payload,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory SyncChangeRecord.fromJson(Map<String, dynamic> json) {
    return SyncChangeRecord(
      table: json['table'] as String,
      syncId: json['syncId'] as String,
      operation: SyncOperation.values.byName(json['operation'] as String),
      payload: json['payload'] as Map<String, dynamic>?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

/// 操作类型
enum SyncOperation {
  upsert, // 新增或更新
  delete, // 删除
}

/// 推送结果
class SyncPushResult {
  /// 成功接受的变更数
  final int accepted;

  /// 被拒绝的变更数（冲突）
  final int rejected;

  /// 冲突详情
  final List<SyncConflict> conflicts;

  const SyncPushResult({
    required this.accepted,
    this.rejected = 0,
    this.conflicts = const [],
  });
}

/// 冲突信息
class SyncConflict {
  final String syncId;
  final String table;

  /// 服务端当前版本数据
  final Map<String, dynamic> serverData;

  /// 服务端版本的 updatedAt
  final DateTime serverUpdatedAt;

  const SyncConflict({
    required this.syncId,
    required this.table,
    required this.serverData,
    required this.serverUpdatedAt,
  });
}

/// 拉取结果
class SyncPullResult {
  /// 变更记录列表
  final List<SyncChangeRecord> changes;

  /// 本次拉取的服务端时间戳（下次拉取用作 since 参数）
  final DateTime serverTimestamp;

  const SyncPullResult({
    required this.changes,
    required this.serverTimestamp,
  });
}

// ---- 连接状态 ----

enum SyncConnectionState {
  connected,
  connecting,
  disconnected,
  error,
}

// ---- 后端接口 ----

/// 记录级同步后端接口（后端无关）
///
/// 实现此接口即可接入任何后端服务：
/// - Supabase (supabase_sync_backend.dart)
/// - Pocketbase (pocketbase_sync_backend.dart)
/// - 自部署 BeeCount Cloud (self_hosted_sync_backend.dart)
abstract class SyncBackend {
  /// 推送本地变更到远端
  ///
  /// [changes] 中的 FK 字段已转换为 syncId 形式。
  /// 服务端使用 LWW 策略处理冲突。
  Future<SyncPushResult> pushChanges(List<SyncChangeRecord> changes);

  /// 增量拉取远端变更
  ///
  /// [since] 上次同步的服务端时间戳，拉取此时间之后的变更。
  /// 首次同步时传 null 表示全量拉取。
  Future<SyncPullResult> pullChanges({DateTime? since});

  /// 订阅远端实时变更（WebSocket / Realtime）
  ///
  /// 返回的 Stream 在连接断开时会自动重连。
  /// 调用 [dispose] 时 Stream 关闭。
  Stream<SyncChangeRecord> subscribe();

  /// 获取当前连接状态
  SyncConnectionState get connectionState;

  /// 连接状态变更流
  Stream<SyncConnectionState> get connectionStateStream;

  /// 认证：使用凭证连接到后端
  Future<void> authenticate({
    required String serverUrl,
    required String email,
    required String password,
  });

  /// 断开连接
  Future<void> disconnect();

  /// 释放资源
  void dispose();
}
