#include "flutter_window.h"

#include <cwchar>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "mini_app_window_channel.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // Движок окна mini App (desktop_multi_window) получает ТОЛЬКО то, что нужно
  // WebView: полный RegisterPlugins там завёл бы второй app_links, sentry,
  // firebase, уведомления и т.д. в одном процессе с главным движком.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    auto* engine = view_controller->engine();
    FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(
        engine->GetRegistrarForPlugin("FlutterInappwebviewWindowsPluginCApi"));
    UrlLauncherWindowsRegisterWithRegistrar(
        engine->GetRegistrarForPlugin("UrlLauncherWindows"));
    RegisterMiniAppWindowChannel(view_controller);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

namespace {

// Окна mini App (desktop_multi_window) создаются без владельца и с окном Лизы
// не умирают; их движок с WebView2 гасится только на WM_DESTROY своего окна.
// Не закрыть их здесь — после PostQuitMessage окно остаётся на экране без
// цикла сообщений, а движок разрушается при выгрузке DLL плагина: процесс
// висит, окно не закрывается и переживает перезапуск Лизы (заявка №61).
void CloseMiniAppWindows() {
  std::vector<HWND> windows;
  ::EnumThreadWindows(
      ::GetCurrentThreadId(),
      [](HWND window, LPARAM param) -> BOOL {
        wchar_t name[64];
        if (::GetClassName(window, name, 64) &&
            wcscmp(name, L"FLUTTER_MULTI_WINDOW_WIN32_WINDOW") == 0) {
          reinterpret_cast<std::vector<HWND>*>(param)->push_back(window);
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&windows));
  for (HWND window : windows) {
    // Тот же путь, что крестик ОС. Если движок окна оставил WM_CLOSE себе
    // (запрос выхода в Dart), закрываем без него.
    ::SendMessage(window, WM_CLOSE, 0, 0);
    if (::IsWindow(window)) {
      ::DestroyWindow(window);
    }
  }
}

}  // namespace

void FlutterWindow::OnDestroy() {
  // Главный движок ещё жив: окна mini App гасим, пока работает цикл сообщений.
  CloseMiniAppWindows();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
