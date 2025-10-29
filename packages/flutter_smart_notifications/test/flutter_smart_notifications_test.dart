import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_notifications/flutter_smart_notifications.dart';
import 'package:flutter_smart_notifications/flutter_smart_notifications_platform_interface.dart';
import 'package:flutter_smart_notifications/flutter_smart_notifications_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterSmartNotificationsPlatform
    with MockPlatformInterfaceMixin
    implements FlutterSmartNotificationsPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterSmartNotificationsPlatform initialPlatform = FlutterSmartNotificationsPlatform.instance;

  test('$MethodChannelFlutterSmartNotifications is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterSmartNotifications>());
  });

  test('getPlatformVersion', () async {
    FlutterSmartNotifications flutterSmartNotificationsPlugin = FlutterSmartNotifications();
    MockFlutterSmartNotificationsPlatform fakePlatform = MockFlutterSmartNotificationsPlatform();
    FlutterSmartNotificationsPlatform.instance = fakePlatform;

    expect(await flutterSmartNotificationsPlugin.getPlatformVersion(), '42');
  });
}
