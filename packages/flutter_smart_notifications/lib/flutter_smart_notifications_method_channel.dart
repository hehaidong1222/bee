import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_smart_notifications_platform_interface.dart';

/// An implementation of [FlutterSmartNotificationsPlatform] that uses method channels.
class MethodChannelFlutterSmartNotifications extends FlutterSmartNotificationsPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_smart_notifications');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
