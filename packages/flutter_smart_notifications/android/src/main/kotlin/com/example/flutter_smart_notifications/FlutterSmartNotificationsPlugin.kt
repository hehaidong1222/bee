package com.example.flutter_smart_notifications

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterSmartNotificationsPlugin */
class FlutterSmartNotificationsPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_smart_notifications")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "scheduleNotification" -> {
        val title = call.argument<String>("title") ?: "记账提醒"
        val body = call.argument<String>("body") ?: "别忘了记录今天的收支哦 💰"
        val scheduledTimeMillis = call.argument<Long>("scheduledTimeMillis") ?: 0
        val notificationId = call.argument<Int>("notificationId") ?: 1001

        scheduleNotification(title, body, scheduledTimeMillis, notificationId)
        result.success(true)
      }
      "cancelNotification" -> {
        val notificationId = call.argument<Int>("notificationId") ?: 1001
        cancelNotification(notificationId)
        result.success(true)
      }
      "isIgnoringBatteryOptimizations" -> {
        result.success(isIgnoringBatteryOptimizations())
      }
      "requestIgnoreBatteryOptimizations" -> {
        requestIgnoreBatteryOptimizations()
        result.success(true)
      }
      "openAppSettings" -> {
        openAppSettings()
        result.success(true)
      }
      "getBatteryOptimizationInfo" -> {
        result.success(getBatteryOptimizationInfo())
      }
      "openNotificationChannelSettings" -> {
        openNotificationChannelSettings()
        result.success(true)
      }
      "getNotificationChannelInfo" -> {
        result.success(getNotificationChannelInfo())
      }
      "testDirectNotification" -> {
        val title = call.argument<String>("title") ?: "直接测试通知"
        val body = call.argument<String>("body") ?: "这是直接调用NotificationReceiver的测试"
        val notificationId = call.argument<Int>("notificationId") ?: 7777

        testDirectNotification(title, body, notificationId)
        result.success(true)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  private fun scheduleNotification(title: String, body: String, scheduledTimeMillis: Long, notificationId: Int) {
    try {
      android.util.Log.d("FlutterSmartNotifications", "开始调度通知: ID=$notificationId, 时间=$scheduledTimeMillis")
      android.util.Log.d("FlutterSmartNotifications", "标题: $title")
      android.util.Log.d("FlutterSmartNotifications", "内容: $body")

      val intent = Intent(context, NotificationReceiver::class.java).apply {
        putExtra("title", title)
        putExtra("body", body)
        putExtra("notificationId", notificationId)
        // 使用动态包名构建action
        action = "${context.packageName}.NOTIFICATION_ALARM"
      }

      val pendingIntent = PendingIntent.getBroadcast(
        context,
        notificationId,
        intent,
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
          PendingIntent.FLAG_UPDATE_CURRENT
        }
      )

      val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

      // 检查是否有精确闹钟权限
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (!alarmManager.canScheduleExactAlarms()) {
          android.util.Log.w("FlutterSmartNotifications", "⚠️ 没有精确闹钟权限")
          return
        }
      }

      // 计算时间差用于调试
      val currentTime = System.currentTimeMillis()
      val timeDiff = scheduledTimeMillis - currentTime
      android.util.Log.d("FlutterSmartNotifications", "当前时间: $currentTime")
      android.util.Log.d("FlutterSmartNotifications", "调度时间: $scheduledTimeMillis")
      android.util.Log.d("FlutterSmartNotifications", "时间差: ${timeDiff / 1000}秒")

      if (timeDiff <= 0) {
        android.util.Log.w("FlutterSmartNotifications", "⚠️ 调度时间已过期，立即发送通知")
        // 如果时间已过，立即发送通知
        val receiver = NotificationReceiver()
        receiver.onReceive(context, intent)
        return
      }

      // 使用setExactAndAllowWhileIdle确保在休眠模式下也能触发
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        android.util.Log.d("FlutterSmartNotifications", "使用 setExactAndAllowWhileIdle 调度通知")
        alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, scheduledTimeMillis, pendingIntent)
      } else {
        android.util.Log.d("FlutterSmartNotifications", "使用 setExact 调度通知")
        alarmManager.setExact(AlarmManager.RTC_WAKEUP, scheduledTimeMillis, pendingIntent)
      }

      android.util.Log.d("FlutterSmartNotifications", "✅ AlarmManager 通知调度成功")
    } catch (e: Exception) {
      android.util.Log.e("FlutterSmartNotifications", "❌ AlarmManager 通知调度失败: $e")
    }
  }

  private fun cancelNotification(notificationId: Int) {
    android.util.Log.d("FlutterSmartNotifications", "取消通知: ID=$notificationId")
    val intent = Intent(context, NotificationReceiver::class.java).apply {
      action = "${context.packageName}.NOTIFICATION_ALARM"
    }
    val pendingIntent = PendingIntent.getBroadcast(
      context,
      notificationId,
      intent,
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
      } else {
        PendingIntent.FLAG_UPDATE_CURRENT
      }
    )

    val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    alarmManager.cancel(pendingIntent)
  }

  private fun isIgnoringBatteryOptimizations(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
      powerManager.isIgnoringBatteryOptimizations(context.packageName)
    } else {
      true
    }
  }

  private fun requestIgnoreBatteryOptimizations() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
      if (!powerManager.isIgnoringBatteryOptimizations(context.packageName)) {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
          data = Uri.parse("package:${context.packageName}")
          flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        try {
          context.startActivity(intent)
        } catch (e: Exception) {
          // 如果无法打开请求页面，则打开应用设置
          openAppSettings()
        }
      }
    }
  }

  private fun openAppSettings() {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
      data = Uri.parse("package:${context.packageName}")
      flags = Intent.FLAG_ACTIVITY_NEW_TASK
    }
    context.startActivity(intent)
  }

  private fun getBatteryOptimizationInfo(): Map<String, Any> {
    val isIgnoring = isIgnoringBatteryOptimizations()
    val canRequest = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
    val manufacturer = Build.MANUFACTURER

    return mapOf(
      "isIgnoring" to isIgnoring,
      "canRequest" to canRequest,
      "manufacturer" to manufacturer,
      "model" to Build.MODEL,
      "androidVersion" to Build.VERSION.RELEASE
    )
  }

  private fun openNotificationChannelSettings() {
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
          putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
          putExtra(Settings.EXTRA_CHANNEL_ID, "accounting_reminder")
          flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
        android.util.Log.d("FlutterSmartNotifications", "打开通知渠道设置页面")
      } else {
        // Android 8.0以下版本打开应用通知设置
        openAppSettings()
      }
    } catch (e: Exception) {
      android.util.Log.e("FlutterSmartNotifications", "打开通知渠道设置失败: $e")
      // fallback到应用设置
      openAppSettings()
    }
  }

  private fun getNotificationChannelInfo(): Map<String, Any> {
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = notificationManager.getNotificationChannel("accounting_reminder")

        if (channel != null) {
          val importanceLevel = when (channel.importance) {
            NotificationManager.IMPORTANCE_NONE -> "none"
            NotificationManager.IMPORTANCE_MIN -> "min"
            NotificationManager.IMPORTANCE_LOW -> "low"
            NotificationManager.IMPORTANCE_DEFAULT -> "default"
            NotificationManager.IMPORTANCE_HIGH -> "high"
            NotificationManager.IMPORTANCE_MAX -> "max"
            else -> "unknown"
          }

          return mapOf(
            "isEnabled" to (channel.importance != NotificationManager.IMPORTANCE_NONE),
            "importance" to importanceLevel,
            "sound" to (channel.sound != null),
            "vibration" to channel.shouldVibrate(),
            "bypassDnd" to channel.canBypassDnd(),
            "showBadge" to channel.canShowBadge(),
            "lightColor" to channel.lightColor,
            "lockscreenVisibility" to channel.lockscreenVisibility
          )
        } else {
          android.util.Log.w("FlutterSmartNotifications", "通知渠道 'accounting_reminder' 不存在")
          return mapOf(
            "isEnabled" to false,
            "importance" to "none",
            "sound" to false,
            "vibration" to false,
            "channelExists" to false
          )
        }
      } else {
        // Android 8.0以下版本的通知设置
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
          notificationManager.areNotificationsEnabled()
        } else {
          true // 假设旧版本通知是开启的
        }

        return mapOf(
          "isEnabled" to notificationsEnabled,
          "importance" to "default",
          "sound" to true,
          "vibration" to true,
          "legacyVersion" to true
        )
      }
    } catch (e: Exception) {
      android.util.Log.e("FlutterSmartNotifications", "获取通知渠道信息失败: $e")
      return mapOf(
        "isEnabled" to false,
        "importance" to "unknown",
        "sound" to false,
        "vibration" to false,
        "error" to (e.message ?: "Unknown error")
      )
    }
  }

  private fun testDirectNotification(title: String, body: String, notificationId: Int) {
    android.util.Log.d("FlutterSmartNotifications", "🔨 开始直接测试NotificationReceiver")
    android.util.Log.d("FlutterSmartNotifications", "标题: $title")
    android.util.Log.d("FlutterSmartNotifications", "内容: $body")
    android.util.Log.d("FlutterSmartNotifications", "ID: $notificationId")

    try {
      val receiver = NotificationReceiver()
      val intent = Intent().apply {
        putExtra("title", title)
        putExtra("body", body)
        putExtra("notificationId", notificationId)
      }

      receiver.onReceive(context, intent)
      android.util.Log.d("FlutterSmartNotifications", "✅ NotificationReceiver调用完成")
    } catch (e: Exception) {
      android.util.Log.e("FlutterSmartNotifications", "❌ 直接测试NotificationReceiver失败: $e")
    }
  }
}
