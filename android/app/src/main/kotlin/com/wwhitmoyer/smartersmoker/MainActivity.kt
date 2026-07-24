package com.wwhitmoyer.smartersmoker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.wwhitmoyer.smartersmoker/system_sounds"
    private val notificationChannelId = "grill_temperature_alerts"
    private val notificationPermissionRequest = 4102
    private val handler = Handler(Looper.getMainLooper())
    private var notificationRingtone: Ringtone? = null
    private var alarmRingtone: Ringtone? = null
    private var alarmRepeat: Runnable? = null
    private val notificationPlays = mutableListOf<Runnable>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequest,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playPreAlarm" -> {
                    val probe = call.argument<Int>("probe") ?: 0
                    showProbeNotification(
                        probe = probe,
                        current = call.argument<Int>("current"),
                        target = call.argument<Int>("target"),
                        targetReached = false,
                    )
                    playPreAlarm()
                    result.success(null)
                }
                "startTargetAlarm" -> {
                    val probe = call.argument<Int>("probe") ?: 0
                    showProbeNotification(
                        probe = probe,
                        current = call.argument<Int>("current"),
                        target = call.argument<Int>("target"),
                        targetReached = true,
                    )
                    startTargetAlarm()
                    result.success(null)
                }
                "cancelProbeAlert" -> {
                    val probe = call.argument<Int>("probe") ?: 0
                    notificationManager().cancel(notificationId(probe))
                    result.success(null)
                }
                "notifySmokerReady" -> {
                    showSmokerReadyNotification(
                        current = call.argument<Int>("current"),
                        target = call.argument<Int>("target"),
                    )
                    playNotificationOnce()
                    result.success(null)
                }
                "cancelSmokerReady" -> {
                    notificationManager().cancel(smokerReadyNotificationId)
                    result.success(null)
                }
                "stopAlarm" -> {
                    stopAllSounds()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            notificationChannelId,
            "Grill temperature alerts",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Probe pre-alarms and target temperature alerts"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null)
            enableVibration(true)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun showProbeNotification(
        probe: Int,
        current: Int?,
        target: Int?,
        targetReached: Boolean,
    ) {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            probe,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (targetReached) {
            "Probe $probe reached its target"
        } else {
            "Probe $probe is near its target"
        }
        val detail = listOfNotNull(
            current?.let { "Current: $it°" },
            target?.let { "Target: $it°" },
            if (targetReached) "Tap to open the app and acknowledge" else null,
        ).joinToString("  •  ")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(detail)
            .setStyle(Notification.BigTextStyle().bigText(detail))
            .setContentIntent(pendingIntent)
            .setAutoCancel(!targetReached)
            .setOngoing(targetReached)
            .setCategory(
                if (targetReached) Notification.CATEGORY_ALARM
                else Notification.CATEGORY_REMINDER,
            )
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
        notificationManager().notify(notificationId(probe), notification)
    }

    private fun notificationManager() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private val smokerReadyNotificationId = 7100
    private fun notificationId(probe: Int) = 7200 + probe

    private fun showSmokerReadyNotification(current: Int?, target: Int?) {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            smokerReadyNotificationId,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val detail = listOfNotNull(
            current?.let { "Current: $it°" },
            target?.let { "Target: $it°" },
        ).joinToString("  •  ")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Smarter Smoker is ready")
            .setContentText(detail)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
        notificationManager().notify(smokerReadyNotificationId, notification)
    }

    private fun playNotificationOnce() {
        if (alarmRingtone?.isPlaying == true) return
        notificationRingtone?.stop()
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        notificationRingtone = RingtoneManager.getRingtone(applicationContext, uri)?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            play()
        }
    }

    private fun playPreAlarm() {
        stopAllSounds()
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        notificationRingtone = RingtoneManager.getRingtone(applicationContext, uri)?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        }
        repeat(3) { index ->
            val play = Runnable {
                notificationRingtone?.stop()
                notificationRingtone?.play()
            }
            notificationPlays.add(play)
            handler.postDelayed(play, index * 1200L)
        }
    }

    private fun startTargetAlarm() {
        stopAllSounds()
        val alarmUri =
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        alarmRingtone = RingtoneManager.getRingtone(applicationContext, alarmUri)?.apply {
            audioAttributes =
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            alarmRingtone?.isLooping = true
            alarmRingtone?.play()
        } else {
            alarmRepeat = object : Runnable {
                override fun run() {
                    alarmRingtone?.stop()
                    alarmRingtone?.play()
                    handler.postDelayed(this, 2500L)
                }
            }
            handler.post(alarmRepeat!!)
        }
    }

    private fun stopAllSounds() {
        notificationPlays.forEach(handler::removeCallbacks)
        notificationPlays.clear()
        notificationRingtone?.stop()
        notificationRingtone = null
        alarmRepeat?.let(handler::removeCallbacks)
        alarmRepeat = null
        alarmRingtone?.stop()
        alarmRingtone = null
    }

    override fun onDestroy() {
        stopAllSounds()
        notificationManager().cancelAll()
        super.onDestroy()
    }
}
