package com.example.flutter_smart_notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class NotificationClickReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("NotificationClickReceiver", "收到通知点击广播: ${intent.action}")

        val notificationId = intent.getIntExtra("notification_id", -1)
        val title = intent.getStringExtra("title") ?: ""

        Log.d("NotificationClickReceiver", "通知ID: $notificationId")
        Log.d("NotificationClickReceiver", "标题: $title")

        try {
            // 使用包管理器获取启动器Intent
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("from_notification_click", true)
                putExtra("notification_id", notificationId)
                putExtra("notification_title", title)
                putExtra("click_timestamp", System.currentTimeMillis())
            }

            if (launchIntent != null) {
                Log.d("NotificationClickReceiver", "启动应用: $launchIntent")
                context.startActivity(launchIntent)
                Log.d("NotificationClickReceiver", "✅ 应用启动成功")
            } else {
                Log.e("NotificationClickReceiver", "❌ 无法获取启动器Intent")
            }

        } catch (e: Exception) {
            Log.e("NotificationClickReceiver", "❌ 启动应用失败: $e")
        }
    }
}