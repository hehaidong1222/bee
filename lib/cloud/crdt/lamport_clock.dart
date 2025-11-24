import 'dart:math';

/// Lamport 逻辑时钟
///
/// 用于保证分布式系统中操作的全局有序性。
/// Lamport 时钟的核心规则：
/// 1. 本地事件发生时，时钟 +1
/// 2. 发送消息时，附带当前时钟值
/// 3. 接收消息时，取 max(本地时钟, 消息时钟) + 1
///
/// 这保证了：如果事件 A 因果先于事件 B，则 clock(A) < clock(B)
class LamportClock {
  int _value;

  LamportClock([int initial = 0]) : _value = initial;

  /// 当前时间戳
  int get value => _value;

  /// 本地事件：时间戳 +1
  ///
  /// 每次产生本地操作时调用
  int tick() {
    _value++;
    return _value;
  }

  /// 接收远程操作：取最大值 +1
  ///
  /// 收到远程操作时调用，确保本地时钟总是大于已知的最大时钟
  int receive(int remoteTimestamp) {
    _value = max(_value, remoteTimestamp) + 1;
    return _value;
  }

  /// 更新到某个值（用于初始化/恢复）
  ///
  /// 只有当新值大于当前值时才更新
  void update(int newValue) {
    if (newValue > _value) {
      _value = newValue;
    }
  }

  /// 批量接收远程时间戳，更新到最大值
  void receiveAll(Iterable<int> timestamps) {
    for (final ts in timestamps) {
      if (ts > _value) {
        _value = ts;
      }
    }
    _value++; // 确保本地时钟大于所有已知时钟
  }

  @override
  String toString() => 'LamportClock($_value)';
}
