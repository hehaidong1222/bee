import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_smart_notifications_method_channel.dart';

abstract class FlutterSmartNotificationsPlatform extends PlatformInterface {
  /// Constructs a FlutterSmartNotificationsPlatform.
  FlutterSmartNotificationsPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterSmartNotificationsPlatform _instance = MethodChannelFlutterSmartNotifications();

  /// The default instance of [FlutterSmartNotificationsPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterSmartNotifications].
  static FlutterSmartNotificationsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterSmartNotificationsPlatform] when
  /// they register themselves.
  static set instance(FlutterSmartNotificationsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
