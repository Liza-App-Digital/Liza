#include "mini_app_window_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windows.h>
#include <dwmapi.h>

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
  bool frameless = false;
  bool in_size_move = false;
};
std::map<HWND, VisibilityObserver> g_visibility;

// Геометрия окна mini App в dp (заявка 13.11: «должен открываться большим»,
// минимум — «как у тебя сейчас … хороший размер», ~800×600). Синхронно с
// MiniAppWindowPlugin в macos/Runner/MainFlutterWindow.swift.
constexpr int kDefaultWidth = 1100;
constexpr int kDefaultHeight = 820;
constexpr int kMinWidth = 800;
constexpr int kMinHeight = 600;

// Невидимая рамка DWM слева/справа/снизу входит в размер окна, но не в
// контент: добавляем её, чтобы контент был ровно заявленного размера.
LONG FrameInset(UINT dpi) {
  return ::GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

RECT WorkArea(HMONITOR monitor) {
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  ::GetMonitorInfo(monitor, &info);
  return info.rcWork;
}

// Размер окна под контент dp_w×dp_h, но не больше 90% рабочей области:
// на 1366×768@125% минимум 800×600 иначе не влезает и окно не сдвинуть.
SIZE FitWindowSize(int dp_w, int dp_h, UINT dpi, const RECT& area) {
  const LONG inset = FrameInset(dpi);
  const LONG max_w = (area.right - area.left) * 9 / 10;
  const LONG max_h = (area.bottom - area.top) * 9 / 10;
  return {std::min<LONG>(::MulDiv(dp_w, dpi, 96) + 2 * inset, max_w),
          std::min<LONG>(::MulDiv(dp_h, dpi, 96) + inset, max_h)};
}

SIZE MinimumWindowSize(HWND window) {
  UINT dpi = ::GetDpiForWindow(window);
  if (!dpi) dpi = 96;
  return FitWindowSize(kMinWidth, kMinHeight, dpi,
      WorkArea(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)));
}

// Предел WM_GETMINMAXINFO Windows применяет только к смене размера, не к
// переезду: окно, ужатое на маленьком мониторе (минимум там — 90% экрана),
// на большом осталось бы меньше 800×600 (проба MOVE 13.11). Дорастить до
// минимума нового монитора, не выходя за его рабочую область.
void GrowToMinimum(HWND window) {
  if (::IsZoomed(window) || ::IsIconic(window)) return;
  RECT rect{};
  ::GetWindowRect(window, &rect);
  const SIZE min = MinimumWindowSize(window);
  const LONG width = std::max<LONG>(rect.right - rect.left, min.cx);
  const LONG height = std::max<LONG>(rect.bottom - rect.top, min.cy);
  if (width == rect.right - rect.left && height == rect.bottom - rect.top) {
    return;
  }
  const RECT area =
      WorkArea(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
  const LONG left = std::max(area.left, std::min(rect.left, area.right - width));
  const LONG top = std::max(area.top, std::min(rect.top, area.bottom - height));
  ::SetWindowPos(window, nullptr, left, top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

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
      {EncodableValue("maximized"), EncodableValue(::IsZoomed(window) != FALSE)},
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
  // Безрамочное окно: снимаем только заголовок. Рамки слева/справа/снизу
  // остаются невидимыми рамками DWM — за них окно тянется снаружи контента,
  // работают Snap и maximize. Если снять все рамки (return 0), их целиком
  // накрывает вид Flutter, и курсор ресайза ловится лишь в самом углу.
  if (found->second.frameless && message == WM_NCCALCSIZE && wparam == TRUE) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    const LONG top = params->rgrc[0].top;
    const LONG left = params->rgrc[0].left;
    ::CallWindowProc(found->second.original, window, message, wparam, lparam);
    // Развёрнутое окно выходит за монитор на толщину рамки — сверху тоже.
    params->rgrc[0].top =
        top + (::IsZoomed(window) ? params->rgrc[0].left - left : 0);
    return 0;
  }
  // Без перерисовки неклиентской части: при WS_CAPTION её отрисовка при смене
  // активности даёт полосу системного заголовка поверх нашей шапки.
  if (found->second.frameless && message == WM_NCACTIVATE) {
    return ::CallWindowProc(found->second.original, window, message, wparam, -1);
  }
  if (message == WM_GETMINMAXINFO) {
    const auto result = ::CallWindowProc(found->second.original, window,
                                         message, wparam, lparam);
    const SIZE min = MinimumWindowSize(window);
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    info->ptMinTrackSize.x = min.cx;
    info->ptMinTrackSize.y = min.cy;
    return result;
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
  if (message == WM_ENTERSIZEMOVE) found->second.in_size_move = true;
  if (message == WM_EXITSIZEMOVE) found->second.in_size_move = false;
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
  // Переезд без перетаскивания (Win+Shift+стрелка, программный перенос) —
  // сразу; перетаскивание — один раз по WM_EXITSIZEMOVE, чтобы не дёргать
  // окно под курсором.
  if (alive != g_visibility.end() && ::IsWindowVisible(window) &&
      (message == WM_EXITSIZEMOVE ||
       (message == WM_WINDOWPOSCHANGED && !alive->second.in_size_move &&
        !(reinterpret_cast<const WINDOWPOS*>(lparam)->flags & SWP_NOMOVE)))) {
    GrowToMinimum(window);
  }
  if (alive != g_visibility.end() &&
      (message == WM_SHOWWINDOW || message == WM_SIZE ||
       message == WM_ACTIVATE || message == WM_ACTIVATEAPP || message == WM_WINDOWPOSCHANGED)) {
    alive->second.channel->InvokeMethod("visibilityChanged",
        std::make_unique<EncodableValue>(Visibility(window)));
  }
  return result;
}

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

bool FramelessArg(const EncodableValue* arguments) {
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) return false;
  auto it = map->find(EncodableValue("frameless"));
  if (it == map->end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value && *value;
}

// Большое окно по центру монитора, на котором стоит окно Лизы. Размер не
// запоминается: прежний g_last_frame тащил в каждое следующее окно размер
// закрытого — в том числе 800×600 плагина у окна, закрытого до present.
RECT DefaultFrame(HWND window) {
  HMONITOR monitor = ::MonitorFromWindow(
      MiniAppMainWindow() ? MiniAppMainWindow() : window,
      MONITOR_DEFAULTTONEAREST);
  const RECT area = WorkArea(monitor);
  const SIZE size = FitWindowSize(kDefaultWidth, kDefaultHeight,
                                  FlutterDesktopGetDpiForMonitor(monitor), area);
  const LONG left = area.left + (area.right - area.left - size.cx) / 2;
  const LONG top = area.top + (area.bottom - area.top - size.cy) / 2;
  return RECT{left, top, left + size.cx, top + size.cy};
}

// Сначала перенос на монитор Лизы, потом размер: при переносе между
// мониторами с разным DPI плагин в WM_DPICHANGED применяет предложенный
// системой rect и перебил бы размер, заданный одним вызовом.
void PlaceDefault(HWND window) {
  const UINT flags = SWP_NOZORDER | SWP_NOACTIVATE;
  RECT frame = DefaultFrame(window);
  ::SetWindowPos(window, nullptr, frame.left, frame.top, 0, 0,
                 flags | SWP_NOSIZE);
  frame = DefaultFrame(window);
  ::SetWindowPos(window, nullptr, frame.left, frame.top,
                 frame.right - frame.left, frame.bottom - frame.top, flags);
}

std::string EdgeArg(const EncodableValue* arguments) {
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) return std::string();
  auto it = map->find(EncodableValue("edge"));
  if (it == map->end()) return std::string();
  const auto* edge = std::get_if<std::string>(&it->second);
  return edge ? *edge : std::string();
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
          const bool frameless = FramelessArg(call.arguments());
          const auto observer = g_visibility.find(window);
          if (frameless && observer != g_visibility.end() &&
              !observer->second.frameless) {
            // Стиль окна не урезаем (WS_CAPTION, WS_MAXIMIZEBOX, WS_THICKFRAME
            // нужны для ресайза за рамки, Snap и maximize) — заголовок снимает
            // WM_NCCALCSIZE. FRAMECHANGED — пересчитать рамку до показа.
            observer->second.frameless = true;
            const LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
            ::SetWindowLongPtr(window, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
            const MARGINS margins{0, 0, 1, 0};
            ::DwmExtendFrameIntoClientArea(window, &margins);
            ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                           SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                               SWP_NOACTIVATE | SWP_FRAMECHANGED);
          }
          PlaceDefault(window);
          Focus(window);
          result->Success();
        } else if (method == "startDrag") {
          ::ReleaseCapture();
          ::SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else if (method == "startResize") {
          // Верхний край: рамки сверху нет (снята вместе с заголовком), его
          // ловит полоса в шапке Flutter. Остальные края — рамки DWM.
          const std::string edge = EdgeArg(call.arguments());
          const WPARAM hit = edge == "topLeft"    ? HTTOPLEFT
                             : edge == "topRight" ? HTTOPRIGHT
                                                  : HTTOP;
          if (!::IsZoomed(window)) {
            POINT cursor{};
            ::GetCursorPos(&cursor);
            ::ReleaseCapture();
            ::SendMessage(window, WM_NCLBUTTONDOWN, hit,
                          MAKELPARAM(cursor.x, cursor.y));
          }
          result->Success();
        } else if (method == "toggleMaximize") {
          ::ShowWindow(window, ::IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success(EncodableValue(::IsZoomed(window) != FALSE));
        } else if (method == "geometry") {
          // Контент, минимум и рабочая область в dp — для нативного стража.
          UINT dpi = ::GetDpiForWindow(window);
          if (!dpi) dpi = 96;
          const double scale = dpi / 96.0;
          RECT client{};
          ::GetClientRect(window, &client);
          const SIZE min = MinimumWindowSize(window);
          const LONG inset = FrameInset(dpi);
          const RECT area = WorkArea(
              ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
          auto dp = [scale](LONG px) { return EncodableValue(px / scale); };
          result->Success(EncodableValue(EncodableMap{
              {EncodableValue("width"), dp(client.right - client.left)},
              {EncodableValue("height"), dp(client.bottom - client.top)},
              {EncodableValue("minWidth"), dp(min.cx - 2 * inset)},
              {EncodableValue("minHeight"), dp(min.cy - inset)},
              {EncodableValue("areaWidth"), dp(area.right - area.left)},
              {EncodableValue("areaHeight"), dp(area.bottom - area.top)},
              {EncodableValue("maximized"),
               EncodableValue(::IsZoomed(window) != FALSE)},
          }));
        } else if (method == "setTitle") {
          ::SetWindowTextW(window,
                           Utf16FromUtf8(TitleArg(call.arguments())).c_str());
          result->Success();
        } else if (method == "focus") {
          Focus(window);
          result->Success();
        } else if (method == "close") {
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
    // Окно ещё скрыто (hiddenAtLaunch): большой размер сразу, чтобы первый
    // кадр Flutter не строился под 800×600 плагина. present повторит.
    PlaceDefault(window);
  }
  g_channels.push_back(std::move(channel));
}
