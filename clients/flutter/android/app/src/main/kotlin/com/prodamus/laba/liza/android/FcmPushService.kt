package com.prodamus.laba.liza.android

import com.famedly.fcm_shared_isolate.FcmSharedIsolateService
import com.google.firebase.messaging.RemoteMessage

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import android.content.Context

class FcmPushService : FcmSharedIsolateService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val eventId = message.data["event_id"]
        NativePushDiagnostics.received(
            applicationContext, eventId, NativePushDiagnostics.sentMs(message.data["liza_sent_ms"]))
        // Р5: повтор того же события не будит Dart — второго звука нет.
        if (!PushEventDedup.firstDelivery(applicationContext, eventId)) {
            NativePushDiagnostics.duplicate(applicationContext, eventId)
            return
        }
        super.onMessageReceived(message)
    }

    override fun onNewToken(token: String) {
        NativePushDiagnostics.token(applicationContext, token)
        super.onNewToken(token)
    }

    override fun getEngine(): FlutterEngine {
        return provideEngine(getApplicationContext())
    }

    companion object {
        fun provideEngine(context: Context): FlutterEngine {
            var engine = MainActivity.engine
            if (engine == null) {
                engine = MainActivity.provideEngine(context)
                engine.getLocalizationPlugin().sendLocalesToFlutter(
                    context.getResources().getConfiguration())
                engine.getDartExecutor().executeDartEntrypoint(
                    DartEntrypoint.createDefault())
            }
            return engine
        }
    }
}
