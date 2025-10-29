# Flutter Smart Notifications

一个可靠的跨平台Flutter通知插件，具有7天备份机制、电池优化检测和完整时区支持。

## ✨ 特性

- ✅ **平台分离架构**：Android和iOS独立实现，针对各平台优化
- ✅ **7天备份机制**（Android）：防止系统清理通知任务
- ✅ **AlarmManager备份**（Android）：双重保障通知可靠性
- ✅ **电池优化检测**（Android）：帮助用户配置最佳通知环境
- ✅ **通知渠道管理**（Android）：检查和配置通知渠道设置
- ✅ **时区支持**：自动处理时区转换
- ✅ **后台通知**：支持应用在后台时触发通知
- ✅ **精确定时**：使用`exactAllowWhileIdle`确保休眠时也能触发

## 📦 安装

在`pubspec.yaml`中添加依赖：

```yaml
dependencies:
  flutter_smart_notifications:
    git:
      url: https://github.com/yourusername/flutter_smart_notifications.git
```

或使用本地路径（开发阶段）：

```yaml
dependencies:
  flutter_smart_notifications:
    path: ../flutter_smart_notifications
```

## 🚀 快速开始

### 1. 初始化

```dart
import 'package:flutter_smart_notifications/flutter_smart_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化时区（必须在通知服务之前）
  NotificationFactory.initializeTimeZone();

  // 获取通知实例
  final notifications = NotificationFactory.getInstance();
  await notifications.initialize();

  runApp(MyApp());
}
```

### 2. 调度每日提醒

```dart
final notifications = NotificationFactory.getInstance();

await notifications.scheduleDailyReminder(
  id: 1001,
  title: '每日提醒',
  body: '别忘了完成今天的任务！',
  hour: 21,  // 晚上9点
  minute: 0,
);
```

### 3. 显示即时通知

```dart
await notifications.showNotification(
  id: 9999,
  title: '测试通知',
  body: '这是一条测试通知',
);
```

### 4. 取消通知

```dart
// 取消单个通知（包括所有备份）
await notifications.cancelNotification(1001);

// 取消所有通知
await notifications.cancelAllNotifications();
```

### 5. 检查待处理的通知

```dart
final pending = await notifications.getPendingNotifications();
print('待处理通知数量: ${pending.length}');
```

## 📱 平台配置

### Android

#### 1. 权限配置

在`android/app/src/main/AndroidManifest.xml`中添加：

```xml
<manifest>
    <!-- 通知权限 -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

    <!-- 精确闹钟权限（Android 12+） -->
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>

    <!-- 唤醒设备 -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>

    <!-- 前台服务 -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

    <!-- 电池优化白名单 -->
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

    <!-- 开机自启动 -->
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>

    <application>
        <!-- 通知接收器 -->
        <receiver
            android:name="com.example.flutter_smart_notifications.NotificationReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

#### 2. 电池优化检测（Android特有功能）

```dart
// 检查电池优化状态
if (Platform.isAndroid) {
  final androidUtil = NotificationFactory.getInstance() as AndroidNotificationUtil;

  // 获取详细信息
  final batteryInfo = await androidUtil.getBatteryOptimizationInfo();
  print('制造商: ${batteryInfo['manufacturer']}');
  print('忽略电池优化: ${batteryInfo['isIgnoring']}');

  // 请求忽略电池优化
  if (batteryInfo['isIgnoring'] != true) {
    await androidUtil.requestIgnoreBatteryOptimizations();
  }

  // 打开应用设置
  await androidUtil.openAppSettings();
}
```

#### 3. 通知渠道管理（Android特有功能）

```dart
if (Platform.isAndroid) {
  final androidUtil = NotificationFactory.getInstance() as AndroidNotificationUtil;

  // 获取通知渠道信息
  final channelInfo = await androidUtil.getNotificationChannelInfo();
  print('渠道启用: ${channelInfo['isEnabled']}');
  print('重要性: ${channelInfo['importance']}');
  print('声音: ${channelInfo['sound']}');
  print('震动: ${channelInfo['vibration']}');

  // 打开通知渠道设置页面
  await androidUtil.openNotificationChannelSettings();
}
```

### iOS

#### 1. 权限配置

在`ios/Runner/Info.plist`中添加：

```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>remote-notification</string>
</array>
```

#### 2. 请求权限

iOS会自动在首次使用时请求通知权限，你也可以手动检查：

```dart
final hasPermission = await notifications.checkPermissionStatus();
if (!hasPermission) {
  await notifications.requestPermissions();
}
```

## 🔧 高级用法

### 调度单次提醒

```dart
await notifications.scheduleOnceReminder(
  id: 2001,
  title: '会议提醒',
  body: '30分钟后有会议',
  scheduledDate: DateTime.now().add(Duration(minutes: 30)),
);
```

## 📊 工作原理

### Android通知可靠性保障

本插件采用**三层备份机制**确保Android通知的可靠性：

1. **主要通知**（ID: 1001）
   - 使用`flutter_local_notifications`的`zonedSchedule`
   - 配置`matchDateTimeComponents.time`实现每日重复
   - 使用`AndroidScheduleMode.exactAllowWhileIdle`确保休眠时触发

2. **7天备份通知**（ID: 1002-1008）
   - 为未来7天分别创建独立通知
   - 防止系统清理重复任务
   - 应用恢复到前台时自动重新设置

3. **AlarmManager备份**（ID: 1101）
   - 使用Android原生`AlarmManager.setExactAndAllowWhileIdle`
   - 作为最后的保障措施
   - 通过`BroadcastReceiver`接收并显示通知

### iOS通知机制

iOS通知实现相对简单，依赖于：

- 使用`flutter_local_notifications`的`zonedSchedule`
- 系统会自动保持通知任务
- 支持后台和前台通知

## 🐛 故障排查

### Android通知不显示？

1. **检查通知权限**
   ```dart
   final hasPermission = await notifications.checkPermissionStatus();
   ```

2. **检查电池优化**
   ```dart
   final androidUtil = NotificationFactory.getInstance() as AndroidNotificationUtil;
   final info = await androidUtil.getBatteryOptimizationInfo();
   ```

3. **检查通知渠道**
   ```dart
   final channelInfo = await androidUtil.getNotificationChannelInfo();
   // 确保 importance 是 'high' 或 'max'
   ```

4. **检查精确闹钟权限**（Android 12+）
   - 进入设置 → 应用 → 你的应用 → 闹钟和提醒
   - 确保"允许设置闹钟和提醒"已开启

5. **特定厂商问题**
   - 小米：需要开启"自启动"和"后台弹出界面"
   - 华为：需要在"电池" → "应用启动管理"中设置手动管理
   - OPPO/Vivo：需要在"权限管理"中允许后台运行

### iOS通知不显示？

1. **检查权限**
   ```dart
   final hasPermission = await notifications.checkPermissionStatus();
   ```

2. **检查设备设置**
   - 设置 → 通知 → 你的应用
   - 确保"允许通知"已开启

## 📄 许可证

MIT License

## 🙏 致谢

基于以下优秀的开源项目：

- [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)
- [timezone](https://pub.dev/packages/timezone)
