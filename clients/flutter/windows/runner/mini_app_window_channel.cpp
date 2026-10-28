#include "mini_app_window_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Каналы живут, пока жив процесс: обработчик держит мессенджер движка, а
// движок окна уходит вместе с окном.
std::vector<std::unique_ptr<flutter::MethodChannel<EncodableValue>>> g_channels;

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
        if (method == "present") {
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
  g_channels.push_back(std::move(channel));
}
