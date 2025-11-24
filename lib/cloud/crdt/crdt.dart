/// CRDT 多设备同步模块
///
/// 基于 CRDT (Conflict-free Replicated Data Type) 的多设备同步实现
///
/// 核心组件：
/// - [Operation] - 单个操作记录
/// - [OperationLog] - 操作日志
/// - [LamportClock] - 逻辑时钟
/// - [OperationGenerator] - 操作生成器
/// - [OperationApplier] - 操作应用器
/// - [CRDTSyncService] - 同步服务

library crdt;

export 'crdt_repository.dart';
export 'crdt_sync_service.dart';
export 'crdt_sync_trigger.dart';
export 'crdt_transaction_service.dart';
export 'lamport_clock.dart';
export 'operation.dart';
export 'operation_applier.dart';
export 'operation_generator.dart';
