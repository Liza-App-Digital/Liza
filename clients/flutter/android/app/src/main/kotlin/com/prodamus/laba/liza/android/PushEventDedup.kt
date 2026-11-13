package com.prodamus.laba.liza.android

import android.content.Context

/** Р5 (спека 2026-11-12-push-sync-industry-alignment): повтор того же события
 * (ретрай Synapse после 504, повторная доставка FCM) не должен звучать второй
 * раз. Храним последние [CAPACITY] event_id; повтор не передаём в Dart, где
 * рисуется уведомление со звуком. Пуш без event_id (счётчик/снятие баннера)
 * не дедупим — он ничего не показывает.
 *
 * Лежит в SharedPreferences, а не в памяти: между двумя доставками процесс
 * обычно уже убит. Сами event_id не секрет, но храним sha-хэш — в файл
 * приложения не попадает ничего, что совпадало бы с серверными id.
 */
object PushEventDedup {
    const val CAPACITY = 200
    private const val PREFS = "liza_push_dedup"
    private const val KEY = "seen"

    /** Чистая логика: (впервые ли, новое окно). Самое свежее — в конце. */
    fun admit(seen: List<String>, key: String): Pair<Boolean, List<String>> {
        if (seen.contains(key)) return Pair(false, seen)
        val next = (seen + key).takeLast(CAPACITY)
        return Pair(true, next)
    }

    @Synchronized
    fun firstDelivery(context: Context, eventId: String?): Boolean {
        if (eventId.isNullOrEmpty()) return true
        return try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val seen = prefs.getString(KEY, "")!!.split('\n').filter { it.isNotEmpty() }
            val (first, next) = admit(seen, NativePushDiagnostics.eventHash(eventId))
            if (first) prefs.edit().putString(KEY, next.joinToString("\n")).apply()
            first
        } catch (_: Exception) {
            // Сбой хранилища не должен терять уведомление: лучше лишний звук.
            true
        }
    }
}
