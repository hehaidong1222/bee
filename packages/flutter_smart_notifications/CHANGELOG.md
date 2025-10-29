# Changelog

## 0.0.1 (2025-01-29)

### 🎉 初始发布

#### ✨ 核心特性
- ✅ 平台分离架构（Android/iOS独立实现）
- ✅ 工厂模式统一API
- ✅ 完整时区支持

#### 🤖 Android特性
- ✅ 三层备份机制确保通知可靠性
  - 主要通知（flutter_local_notifications）
  - 7天备用提醒（1002-1008）
  - AlarmManager原生备份（1101）
- ✅ 电池优化检测和配置
- ✅ 通知渠道管理
- ✅ 精确闹钟权限请求
- ✅ `exactAllowWhileIdle`确保休眠时触发

#### 🍎 iOS特性
- ✅ 标准通知支持
- ✅ 后台模式支持
- ✅ 权限管理

#### 📦 API
- `NotificationFactory.getInstance()` - 获取平台实例
- `initialize()` - 初始化通知服务
- `scheduleDailyReminder()` - 调度每日提醒
- `scheduleOnceReminder()` - 调度单次提醒
- `showNotification()` - 显示即时通知
- `cancelNotification()` - 取消指定通知
- `cancelAllNotifications()` - 取消所有通知
- `getPendingNotifications()` - 获取待处理通知
- `checkPermissionStatus()` - 检查权限状态
- `requestPermissions()` - 请求权限

#### 🤖 Android专属API
- `getBatteryOptimizationInfo()` - 获取电池优化信息
- `requestIgnoreBatteryOptimizations()` - 请求忽略电池优化
- `getNotificationChannelInfo()` - 获取通知渠道信息
- `openNotificationChannelSettings()` - 打开通知渠道设置
- `openAppSettings()` - 打开应用设置

#### 🔧 技术实现
- 使用`flutter_local_notifications` ^17.2.2
- 使用`timezone` ^0.9.4
- Android: Kotlin + AlarmManager + BroadcastReceiver
- iOS: Swift + UNUserNotificationCenter

#### 📚 文档
- ✅ 完整README文档
- ✅ 平台配置指南
- ✅ API使用示例
- ✅ 故障排查指南

#### 🎯 来源
基于BeeCount记账应用的通知系统重构，经过实战验证。
