package com.prodamus.laba.liza.android

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.view.WindowManager
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    /** Канал защиты экрана: Flutter просит включить/снять FLAG_SECURE. */
    private var secureScreenChannel: MethodChannel? = null

    /** Канал буфера обмена: материализация `content://`-URI в байты. */
    private var clipboardChannel: MethodChannel? = null
    private var pushHealthChannel: MethodChannel? = null

    /** Чтение содержимого URI — блокирующий I/O, уводим с главного потока. */
    private val clipboardExecutor = Executors.newSingleThreadExecutor()

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Движок настроен в provideEngine, но канал защиты экрана привязан к
        // ОКНУ конкретной Activity, а не к движку: регистрируем его здесь и
        // снимаем в onDestroy, иначе переживший Activity движок будет держать
        // ссылку на убитое окно.
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_SCREEN_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setSecure") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val enabled = call.argument<Boolean>("enabled") ?: false
            // Работа с окном допустима только из главного потока.
            runOnUiThread {
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
            }
            result.success(null)
        }
        secureScreenChannel = channel

        // Канал буфера обмена. Материализация читает `contentResolver`, который
        // берём из applicationContext (переживает kill/restore Activity —
        // движок синглтон), а не из Activity-контекста. I/O — в фоновом
        // executor'е, результат отдаём на главном потоке (контракт MethodChannel).
        val clipboard = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIPBOARD_CHANNEL,
        )
        clipboard.setMethodCallHandler { call, result ->
            if (call.method != "resolveContentUris") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val uris = call.argument<List<String>>("uris") ?: emptyList()
            val resolver = applicationContext.contentResolver
            clipboardExecutor.execute {
                val out = ArrayList<Map<String, Any?>>()
                for (uriStr in uris) {
                    try {
                        val uri = Uri.parse(uriStr)
                        val mime = resolver.getType(uri) ?: continue
                        // Материализуем только изображения — вставка альбома
                        // касается картинок; прочие типы вставки идут своим
                        // путём (файл-документ через реальный path на desktop).
                        if (!mime.startsWith("image")) continue
                        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                            ?: continue
                        out.add(
                            mapOf(
                                "name" to displayName(resolver, uri),
                                "mime" to mime,
                                "bytes" to bytes,
                            ),
                        )
                    } catch (_: Exception) {
                        // Битый/недоступный URI пропускаем — остальные доедут.
                    }
                }
                runOnUiThread { result.success(out) }
            }
        }
        clipboardChannel = clipboard
        pushHealthChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.prodamus.laba.liza/push_health").also { health ->
            health.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNotificationSettings" -> {
                        try { result.success(NativePushDiagnostics.settings(applicationContext)) }
                        catch (_: Exception) { result.error("settings_unavailable", null, null) }
                    }
                    "readDiagnosticJournal" -> clipboardExecutor.execute {
                        val entries = NativePushDiagnostics.read(applicationContext)
                        runOnUiThread { result.success(entries) }
                    }
                    "openNotificationSettings" -> {
                        try {
                            startActivity(NativePushDiagnostics.settingsIntent(this))
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Имя файла из `OpenableColumns.DISPLAY_NAME`; null → Dart-fallback. */
    private fun displayName(
        resolver: android.content.ContentResolver,
        uri: Uri,
    ): String? {
        return try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && cursor.columnCount > 0) {
                        cursor.getString(0)
                    } else {
                        null
                    }
                }
        } catch (_: Exception) {
            null
        }
    }

    override fun onDestroy() {
        secureScreenChannel?.setMethodCallHandler(null)
        secureScreenChannel = null
        clipboardChannel?.setMethodCallHandler(null)
        clipboardChannel = null
        pushHealthChannel?.setMethodCallHandler(null)
        pushHealthChannel = null
        // Страховка от «залипшего» флага: android:configChanges в манифесте
        // покрывает поворот/смену темы/плотности — ЭТА Activity из-за них не
        // пересоздаётся. Но она умирает при возврате из фона после kill
        // процесса системой (или в системном "Force stop"), а движок —
        // синглтон в companion object и переживает смерть Activity. Новая
        // Activity получит чистое окно без FLAG_SECURE, а Dart-состояние
        // (счётчик стражей) само повторный setSecure(true) не пришлёт до
        // ближайшего resumed. Снимаем явно, чтобы окно умирающей Activity не
        // осталось с флагом «в наследство» при повторном использовании
        // движка.
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onDestroy()
    }

    companion object {
        /** Совпадает с `MethodChannel` в `lib/utils/secure_screen.dart`. */
        const val SECURE_SCREEN_CHANNEL = "ru.liza/secure_screen"

        /** Совпадает с `MethodChannel('liza/clipboard')` в `lib/utils/clipboard_paste.dart`. */
        const val CLIPBOARD_CHANNEL = "liza/clipboard"

        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false)
            engine = eng
            return eng
        }
    }
}
