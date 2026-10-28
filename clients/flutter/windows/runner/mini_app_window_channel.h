#ifndef RUNNER_MINI_APP_WINDOW_CHANNEL_H_
#define RUNNER_MINI_APP_WINDOW_CHANNEL_H_

#include <flutter/flutter_view_controller.h>

// Канал `liza/miniapp_window` движка окна mini App (desktop_multi_window):
// заголовок, размер, фокус, закрытие своего окна ОС (см. mini_app_window.dart).
// Свой канал, а не window_manager: тот перехватывает WndProc окна и умеет
// destroy() = PostQuitMessage, то есть завершить всю Лизу.
void RegisterMiniAppWindowChannel(flutter::FlutterViewController* controller);

#endif  // RUNNER_MINI_APP_WINDOW_CHANNEL_H_
