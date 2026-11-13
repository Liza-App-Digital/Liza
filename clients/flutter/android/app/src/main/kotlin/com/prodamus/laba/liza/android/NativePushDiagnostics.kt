package com.prodamus.laba.liza.android

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.AtomicFile
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Private bounded spool: Firebase callback пишет ДО запуска Dart isolate.
 * Никаких payload/token/room id. Чтение не удаляет записи, id переживает retry.
 */
object NativePushDiagnostics {
    private const val MAX_COUNT = 256
    private const val MAX_BYTES = 128 * 1024
    private const val TTL_MS = 7L * 24 * 60 * 60 * 1000
    private val stages = setOf("fcmReceived", "fcmDuplicate", "token")
    private val reasons = setOf("first", "unchanged", "rotated", "registration_failed")

    private fun hash(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).take(16)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    /** Тот же хэш, что в журнале: им же ключуется дедуп повторов. */
    fun eventHash(value: String): String = hash(value)

    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "push-diagnostics-v2.json"))

    private fun load(context: Context): Pair<MutableList<JSONObject>, Int> {
        val store = file(context)
        if (!store.baseFile.exists() && !File(store.baseFile.path + ".bak").exists()) return Pair(mutableListOf(), 0)
        return try {
            if (store.baseFile.length() > MAX_BYTES + 4096) throw IllegalStateException()
            val json = JSONObject(String(store.readFully(), Charsets.UTF_8))
            val raw = json.optJSONArray("entries") ?: JSONArray()
            var dropped = json.optInt("dropped", 0).coerceIn(0, Int.MAX_VALUE)
            val ids = mutableSetOf<String>()
            val now = System.currentTimeMillis()
            val entries = mutableListOf<JSONObject>()
            for (i in 0 until raw.length()) {
                val item = raw.optJSONObject(i)
                val id = item?.optString("id") ?: ""
                val time = item?.optLong("t", -1) ?: -1
                if (item == null || !id.matches(Regex("[0-9a-fA-F-]{36}")) ||
                    !ids.add(id) || !stages.contains(item.optString("s")) ||
                    time < now - TTL_MS || time > now + 60000) {
                    dropped = (dropped.toLong() + 1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    continue
                }
                // Пересборка по whitelist даже при испорченном файле.
                val clean = JSONObject().put("id", id).put("t", time).put("s", item.getString("s"))
                val reason = item.optString("reason")
                if (reasons.contains(reason)) clean.put("reason", reason)
                val eventHash = item.optString("event_hash")
                if (eventHash.matches(Regex("[a-f0-9]{32}"))) {
                    clean.put("event_hash", eventHash).put("hash_version", "sha256-128")
                }
                val sent = item.optLong("sent", -1)
                if (sent > 0 && sent <= now + TTL_MS) clean.put("sent", sent)
                entries.add(clean)
            }
            Pair(entries, dropped)
        } catch (_: Exception) { Pair(mutableListOf(), 1) }
    }

    private fun persist(context: Context, entries: MutableList<JSONObject>, loss: Int) {
        var dropped = loss
        fun bytes() = JSONObject().put("entries", JSONArray(entries))
            .put("dropped", dropped).toString().toByteArray(Charsets.UTF_8)
        var data = bytes()
        while (entries.isNotEmpty() && (entries.size > MAX_COUNT || data.size > MAX_BYTES)) {
            entries.removeAt(0)
            dropped = (dropped.toLong() + 1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            data = bytes()
        }
        val store = file(context)
        val stream = store.startWrite()
        try {
            stream.write(data)
            store.finishWrite(stream)
        } catch (error: Exception) {
            store.failWrite(stream)
            throw error
        }
    }

    /** M6: `liza_sent_ms` из data пуша (мс эпохи, строкой) — момент отправки Sygnal'ом. */
    fun sentMs(raw: String?): Long? = raw?.toLongOrNull()?.takeIf { it > 0 }

    @Synchronized
    fun received(context: Context, eventId: String?, sentMs: Long? = null) {
        append(context, "fcmReceived", eventId = eventId, sent = sentMs)
    }

    /** Ф1.1: повтор события отброшен LRU — подтверждение исхода duplicate. */
    @Synchronized
    fun duplicate(context: Context, eventId: String?) {
        append(context, "fcmDuplicate", eventId = eventId)
    }

    @Synchronized
    fun token(context: Context, token: String) {
        try {
            val prefs = context.getSharedPreferences("push-diagnostics-v2", Context.MODE_PRIVATE)
            val digest = hash(token)
            val old = prefs.getString("token_digest", null)
            val reason = if (old == null) "first" else if (old == digest) "unchanged" else "rotated"
            append(context, "token", reason = reason)
            prefs.edit().putString("token_digest", digest).apply()
        } catch (_: Exception) { /* Диагностика не меняет Firebase dispatch. */ }
    }

    private fun append(context: Context, stage: String, eventId: String? = null, reason: String? = null,
                       sent: Long? = null) {
        try {
            val (entries, dropped) = load(context)
            val item = JSONObject().put("id", UUID.randomUUID().toString())
                .put("t", System.currentTimeMillis()).put("s", stage)
            if (!eventId.isNullOrEmpty()) item.put("event_hash", hash(eventId)).put("hash_version", "sha256-128")
            if (reason != null) item.put("reason", reason)
            if (sent != null && sent > 0) item.put("sent", sent)
            entries.add(item)
            persist(context, entries, dropped)
        } catch (_: Exception) { /* Нельзя менять доставку при storage failure. */ }
    }

    @Synchronized
    fun read(context: Context): List<Map<String, Any>>? {
        return try {
            val (entries, dropped) = load(context)
            persist(context, entries, dropped)
            val result = entries.map { item ->
                item.keys().asSequence().associateWith { item.get(it) }
            }.toMutableList()
            if (dropped > 0) result.add(mapOf("id" to "native-diagnostic-loss",
                "t" to System.currentTimeMillis(), "s" to "diagnosticLoss",
                "reason" to "dropped", "value" to dropped))
            result
        } catch (_: Exception) { null }
    }

    fun settings(context: Context): Map<String, Int> {
        val importance = if (Build.VERSION.SDK_INT >= 26) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.getNotificationChannel("liza_push")?.importance ?: -2
        } else -1
        val battery = if (Build.VERSION.SDK_INT >= 23) {
            val manager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (manager.isIgnoringBatteryOptimizations(context.packageName)) 0 else 1
        } else -1
        return mapOf("authorization" to if (NotificationManagerCompat.from(context).areNotificationsEnabled()) 2 else 1,
            "channelImportance" to importance, "batteryOptimization" to battery)
    }

    fun settingsIntent(context: Context): Intent = if (Build.VERSION.SDK_INT >= 26) {
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    } else {
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    }
}
