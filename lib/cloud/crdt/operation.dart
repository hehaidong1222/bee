/// CRDT 操作模型
///
/// 用于多设备同步的操作日志记录

import 'dart:convert';

/// 操作类型
enum OperationType {
  insert, // 插入记录
  update, // 更新记录
  delete, // 删除记录
}

/// 单个操作
///
/// 记录对数据的一次修改操作，用于 CRDT 同步
class Operation {
  /// 操作唯一 ID: {timestamp}-{deviceId}-{seq}
  final String opId;

  /// 操作类型
  final OperationType type;

  /// 被操作记录的 UUID
  final String targetId;

  /// Lamport 时间戳（逻辑时钟）
  final int timestamp;

  /// 产生操作的设备 ID
  final String deviceId;

  /// 操作数据（insert/update 时有值）
  final Map<String, dynamic>? data;

  /// 操作的物理时间（用于 UI 展示）
  final DateTime createdAt;

  /// 操作日志版本号（用于压缩判断）
  final int? version;

  Operation({
    required this.opId,
    required this.type,
    required this.targetId,
    required this.timestamp,
    required this.deviceId,
    this.data,
    required this.createdAt,
    this.version,
  });

  /// 从 JSON 反序列化
  factory Operation.fromJson(Map<String, dynamic> json) {
    return Operation(
      opId: json['opId'] as String,
      type: OperationType.values.byName(json['type'] as String),
      targetId: json['targetId'] as String,
      timestamp: json['timestamp'] as int,
      deviceId: json['deviceId'] as String,
      data: json['data'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      version: json['version'] as int?,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'opId': opId,
      'type': type.name,
      'targetId': targetId,
      'timestamp': timestamp,
      'deviceId': deviceId,
      if (data != null) 'data': data,
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (version != null) 'version': version,
    };
  }

  /// 操作排序：先按时间戳，再按 opId
  int compareTo(Operation other) {
    if (timestamp != other.timestamp) {
      return timestamp.compareTo(other.timestamp);
    }
    return opId.compareTo(other.opId);
  }

  /// 复制并修改部分字段
  Operation copyWith({
    String? opId,
    OperationType? type,
    String? targetId,
    int? timestamp,
    String? deviceId,
    Map<String, dynamic>? data,
    DateTime? createdAt,
    int? version,
  }) {
    return Operation(
      opId: opId ?? this.opId,
      type: type ?? this.type,
      targetId: targetId ?? this.targetId,
      timestamp: timestamp ?? this.timestamp,
      deviceId: deviceId ?? this.deviceId,
      data: data ?? this.data,
      createdAt: createdAt ?? this.createdAt,
      version: version ?? this.version,
    );
  }

  @override
  String toString() {
    return 'Operation(opId: $opId, type: ${type.name}, targetId: $targetId, ts: $timestamp)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Operation && other.opId == opId;
  }

  @override
  int get hashCode => opId.hashCode;
}

/// 操作日志
///
/// 包含账本的所有操作记录
class OperationLog {
  /// 日志格式版本
  final int formatVersion;

  /// 账本 ID
  final int ledgerId;

  /// 所有操作（按时间戳排序）
  final List<Operation> operations;

  /// 快照版本号（已压缩到此版本）
  final int? snapshotVersion;

  OperationLog({
    required this.formatVersion,
    required this.ledgerId,
    required this.operations,
    this.snapshotVersion,
  });

  factory OperationLog.empty(int ledgerId) {
    return OperationLog(
      formatVersion: 1,
      ledgerId: ledgerId,
      operations: [],
    );
  }

  factory OperationLog.fromJson(Map<String, dynamic> json) {
    return OperationLog(
      formatVersion: json['formatVersion'] as int? ?? json['version'] as int? ?? 1,
      ledgerId: json['ledgerId'] as int,
      operations: (json['operations'] as List?)
              ?.map((e) => Operation.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      snapshotVersion: json['snapshotVersion'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'formatVersion': formatVersion,
      'ledgerId': ledgerId,
      'operations': operations.map((e) => e.toJson()).toList(),
      if (snapshotVersion != null) 'snapshotVersion': snapshotVersion,
    };
  }

  /// 序列化为 JSON 字符串
  String toJsonString() => jsonEncode(toJson());

  /// 合并两个操作日志
  OperationLog merge(OperationLog other) {
    // 合并操作，去重
    final mergedOps = <String, Operation>{};
    for (final op in operations) {
      mergedOps[op.opId] = op;
    }
    for (final op in other.operations) {
      mergedOps[op.opId] = op;
    }

    // 排序
    final sortedOps = mergedOps.values.toList()
      ..sort((a, b) => a.compareTo(b));

    return OperationLog(
      formatVersion: formatVersion,
      ledgerId: ledgerId,
      operations: sortedOps,
      snapshotVersion: snapshotVersion,
    );
  }

  /// 获取指定版本之后的操作
  List<Operation> getOperationsAfterVersion(int version) {
    return operations.where((op) => (op.version ?? 0) > version).toList();
  }

  /// 添加操作
  OperationLog addOperation(Operation op) {
    final newOps = [...operations, op]..sort((a, b) => a.compareTo(b));
    return OperationLog(
      formatVersion: formatVersion,
      ledgerId: ledgerId,
      operations: newOps,
      snapshotVersion: snapshotVersion,
    );
  }

  /// 添加多个操作
  OperationLog addOperations(List<Operation> ops) {
    final mergedOps = <String, Operation>{};
    for (final op in operations) {
      mergedOps[op.opId] = op;
    }
    for (final op in ops) {
      mergedOps[op.opId] = op;
    }

    final sortedOps = mergedOps.values.toList()
      ..sort((a, b) => a.compareTo(b));

    return OperationLog(
      formatVersion: formatVersion,
      ledgerId: ledgerId,
      operations: sortedOps,
      snapshotVersion: snapshotVersion,
    );
  }
}
