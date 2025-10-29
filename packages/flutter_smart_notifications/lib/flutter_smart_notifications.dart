export 'notification_util.dart';
export 'notification_factory.dart';
export 'notification_android.dart' show AndroidNotificationUtil;
export 'notification_ios.dart' show IOSNotificationUtil;

/// Flutter Smart Notifications
///
/// A reliable cross-platform notification plugin with:
/// - Platform-separated implementation (Android/iOS)
/// - 7-day backup reminder mechanism (Android)
/// - Battery optimization detection (Android)
/// - Notification channel management (Android)
/// - Timezone support
/// - Background notification support
///
/// Example:
/// ```dart
/// // Initialize
/// NotificationFactory.initializeTimeZone();
/// final notifications = NotificationFactory.getInstance();
/// await notifications.initialize();
///
/// // Schedule daily reminder
/// await notifications.scheduleDailyReminder(
///   id: 1,
///   title: 'Daily Reminder',
///   body: 'Don\'t forget!',
///   hour: 21,
///   minute: 0,
/// );
/// ```
