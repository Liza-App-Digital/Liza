#include "mini_app_window_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <memory>
#include <map>
#include <string>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Каналы живут, пока жив процесс: обработчик держит мессенджер движка, а
// движок окна уходит вместе с окном.
std::vector<std::unique_ptr<flutter::MethodChannel<EncodableValue>>> g_channels;

// Снимок ОС и уведомления относятся только к окнам MiniApp. Не подменяем
// делегат главного окна и всегда продолжаем исходную цепочку WndProc.
struct VisibilityObserver {
  WNDPROC original;
  flutter::MethodChannel<EncodableValue>* channel;
  int64_t visibility_epoch = 0;
  int64_t snapshot_sequence = 0;
  int64_t focus_epoch = 0;
  int64_t direct_main_focus_epoch = -1;
};
std::map<HWND, VisibilityObserver> g_visibility;

HWINEVENTHOOK g_foreground_hook = nullptr;
HWND g_previous_foreground = nullptr;
int64_t g_main_focus_epoch = 0;

HWND MiniAppMainWindow() {
  HWND window = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  DWORD process = 0;
  if (window) ::GetWindowThreadProcessId(window, &process);
  return process == ::GetCurrentProcessId() ? window : nullptr;
}

void CALLBACK ForegroundChanged(HWINEVENTHOOK, DWORD, HWND window,
                                LONG, LONG, DWORD, DWORD) {
  const HWND main = MiniAppMainWindow();
  if (g_previous_foreground == main && window != main) ++g_main_focus_epoch;
  g_previous_foreground = window;
}

EncodableMap Visibility(HWND window, bool closed = false) {
  const HWND foreground = ::GetForegroundWindow();
  const HWND main = MiniAppMainWindow();
  const auto observer = g_visibility.find(window);
  const int64_t epoch = observer == g_visibility.end() ? 0 : observer->second.visibility_epoch;
  const int64_t sequence = observer == g_visibility.end() ? 0 : ++observer->second.snapshot_sequence;
  return {
      {EncodableValue("sequence"), EncodableValue(sequence)},
      {EncodableValue("focus_epoch"), EncodableValue(observer == g_visibility.end() ? int64_t{0} : observer->second.focus_epoch)},
      {EncodableValue("main_focus_epoch"), EncodableValue(g_main_focus_epoch)},
      {EncodableValue("direct_main_focus_epoch"), EncodableValue(observer == g_visibility.end() ? int64_t{-1} : observer->second.direct_main_focus_epoch)},
      {EncodableValue("visibility_epoch"), EncodableValue(epoch)},
      {EncodableValue("closed"), EncodableValue(closed || !::IsWindow(window) || observer == g_visibility.end())},
      {EncodableValue("visible"), EncodableValue(::IsWindowVisible(window) != FALSE)},
      {EncodableValue("minimized"), EncodableValue(::IsIconic(window) != FALSE)},
      {EncodableValue("focused"), EncodableValue(foreground == window)},
      {EncodableValue("main_focused"), EncodableValue(g_foreground_hook && main && foreground == main)},
  };
}

LRESULT CALLBACK MiniAppVisibilityProc(HWND window, UINT message,
                                      WPARAM wparam, LPARAM lparam) {
  const auto found = g_visibility.find(window);
  if (found == g_visibility.end()) return ::DefWindowProc(window, message, wparam, lparam);
  if ((message == WM_SIZE && wparam == SIZE_MINIMIZED) ||
      (message == WM_SHOWWINDOW && !wparam) || message == WM_CLOSE ||
      (message == WM_ACTIVATEAPP && !wparam)) {
    found->second.visibility_epoch++;
  }
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    found->second.focus_epoch++;
    // При WA_INACTIVE lParam содержит HWND фактического получателя фокуса.
    // Сохраняем destination до любой очереди callbacks / позднего snapshot.
    const HWND destination = reinterpret_cast<HWND>(lparam);
    found->second.direct_main_focus_epoch =
        destination && destination == MiniAppMainWindow()
          ? found->second.focus_epoch : -1;
  }
  const auto observer = found->second;
  if (message == WM_DESTROY) {
    // desktop_multi_window уничтожает FlutterViewController внутри original
    // WM_DESTROY. Всё, что обращается к messenger, снимаем ДО этой границы.
    observer.channel->InvokeMethod("visibilityChanged",
        std::make_unique<EncodableValue>(Visibility(window, true)));
    observer.channel->SetMethodCallHandler(nullptr);
    ::SetWindowLongPtr(window, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(observer.original));
    g_visibility.erase(window);
    g_channels.erase(std::remove_if(g_channels.begin(), g_channels.end(),
        [observer](const auto& channel) { return channel.get() == observer.channel; }),
        g_channels.end());
    if (g_visibility.empty() && g_foreground_hook) {
      ::UnhookWinEvent(g_foreground_hook);
      g_foreground_hook = nullptr;
    }
    return ::CallWindowProc(observer.original, window, message, wparam, lparam);
  }
  if (message == WM_CLOSE) {
    observer.channel->InvokeMethod("visibilityChanged",
        std::make_unique<EncodableValue>(Visibility(window, true)));
  }
  const auto result = ::CallWindowProc(observer.original, window, message, wparam, lparam);
  // Original proc мог синхронно вызвать DestroyWindow. Raw channel из старого
  // observer после этой точки использовать нельзя.
  const auto alive = g_visibility.find(window);
  if (alive != g_visibility.end() &&
      (message == WM_SHOWWINDOW || message == WM_SIZE ||
       message == WM_ACTIVATE || message == WM_ACTIVATEAPP || message == WM_WINDOWPOSCHANGED)) {
    alive->second.channel->InvokeMethod("visibilityChanged",
        std::make_unique<EncodableValue>(Visibility(window)));
  }
  return result;
}

// Позиция и размер последнего закрытого окна — следующее откроется там же.
RECT g_last_frame{};
bool g_has_last_frame = false;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                     static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        utf16.data(), length);
  return utf16;
}

std::string TitleArg(const EncodableValue* arguments) {
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) {
    return std::string();
  }
  auto it = map->find(EncodableValue("title"));
  if (it == map->end()) {
    return std::string();
  }
  const auto* title = std::get_if<std::string>(&it->second);
  return title ? *title : std::string();
}

// Большое окно по центру монитора, на котором стоит окно Лизы.
RECT DefaultFrame(HWND window) {
  HWND main = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  HMONITOR monitor =
      ::MonitorFromWindow(main ? main : window, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  ::GetMonitorInfo(monitor, &info);
  const RECT area = info.rcWork;
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const LONG area_width = area.right - area.left;
  const LONG area_height = area.bottom - area.top;
  const LONG width =
      std::min(static_cast<LONG>(1100 * scale), area_width * 9 / 10);
  const LONG height =
      std::min(static_cast<LONG>(820 * scale), area_height * 9 / 10);
  const LONG left = area.left + (area_width - width) / 2;
  const LONG top = area.top + (area_height - height) / 2;
  return RECT{left, top, left + width, top + height};
}

void Focus(HWND window) {
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window);
}

}  // namespace

void RegisterMiniAppWindowChannel(flutter::FlutterViewController* controller) {
  // HWND вида Flutter; окно ОС — его корневой предок (окно desktop_multi_window).
  HWND view = controller->view()->GetNativeWindow();
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      controller->engine()->messenger(), "liza/miniapp_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [view](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HWND window = ::GetAncestor(view, GA_ROOT);
        if (!window) {
          result->Error("no_window");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "visibility") {
          result->Success(EncodableValue(Visibility(window)));
        } else if (method == "present") {
          ::SetWindowTextW(window,
                           Utf16FromUtf8(TitleArg(call.arguments())).c_str());
          const RECT frame =
              g_has_last_frame ? g_last_frame : DefaultFrame(window);
          ::SetWindowPos(window, nullptr, frame.left, frame.top,
                         frame.right - frame.left, frame.bottom - frame.top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
          Focus(window);
          result->Success();
        } else if (method == "setTitle") {
          ::SetWindowTextW(window,
                           Utf16FromUtf8(TitleArg(call.arguments())).c_str());
          result->Success();
        } else if (method == "focus") {
          Focus(window);
          result->Success();
        } else if (method == "close") {
          WINDOWPLACEMENT placement{};
          placement.length = sizeof(placement);
          if (::GetWindowPlacement(window, &placement)) {
            g_last_frame = placement.rcNormalPosition;
            g_has_last_frame = true;
          }
          ::PostMessage(window, WM_CLOSE, 0, 0);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  const HWND window = ::GetAncestor(view, GA_ROOT);
  if (window && g_visibility.find(window) == g_visibility.end()) {
    const auto original = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
        window, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(MiniAppVisibilityProc)));
    if (original) {
      g_visibility.emplace(window, VisibilityObserver{original, channel.get()});
      if (!g_foreground_hook) {
        g_previous_foreground = ::GetForegroundWindow();
        g_foreground_hook = ::SetWinEventHook(EVENT_SYSTEM_FOREGROUND,
            EVENT_SYSTEM_FOREGROUND, nullptr, ForegroundChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
      }
    }
  }
  g_channels.push_back(std::move(channel));
}
