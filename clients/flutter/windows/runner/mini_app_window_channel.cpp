#include "mini_app_window_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <memory>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Каналы живут, пока жив процесс: обработчик держит мессенджер движка, а
// движок окна уходит вместе с окном.
std::vector<std::unique_ptr<flutter::MethodChannel<EncodableValue>>> g_channels;

// Привязка обновляется целиком до событий нового документа. Незавершённый
// жест хранит исходную привязку, поэтому размер не переезжает между аккаунтами.
struct GeometryBinding {
  std::string account;
  bool mini_app = true;
  int64_t generation = 0;
};
struct PreferredSize {
  double width;
  double height;
};
struct PreferredPosition {
  double x;
  double y;
};
struct GeometryState {
  GeometryBinding binding;
  bool presented = false;
  bool resizing = false;
  bool manual_candidate = false;
  bool dpi_changed = false;
  GeometryBinding resize_binding;
  std::optional<PreferredSize> candidate;
  RECT initial_frame{};
  RECT candidate_frame{};
};

std::optional<RECT> MainWindowFrame();

bool ValidPreferredSize(const PreferredSize& size) {
  return std::isfinite(size.width) && std::isfinite(size.height) &&
         size.width > 0 && size.height > 0 &&
         size.width <= 100000 && size.height <= 100000;
}

// Hex полного UTF-8 ID исключает разделители registry path и коллизии
// аккаунтов. appId не входит в ключ: последнее предпочтение общее для аккаунта.
std::wstring PreferenceKey(const GeometryBinding& binding) {
  if (!binding.mini_app || binding.account.empty()) return {};
  const wchar_t* digits = L"0123456789abcdef";
  std::wstring key = L"Software\\Liza\\MiniAppWindowSize\\";
  size_t index = 0;
  for (unsigned char byte : binding.account) {
    // Один компонент registry key ограничен255 символами; Matrix ID
    // до255 байт разбиваем на безопасные сегменты по240 hex-символов.
    if (index && index % 120 == 0) key += L'\\';
    ++index;
    key += digits[byte >> 4];
    key += digits[byte & 15];
  }
  return key;
}

std::optional<PreferredSize> ReadPreferredSize(const GeometryBinding& binding) {
  const auto key = PreferenceKey(binding);
  if (key.empty()) return std::nullopt;
  HKEY handle = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, KEY_QUERY_VALUE,
                      &handle) != ERROR_SUCCESS) return std::nullopt;
  double dimensions[2]{};
  DWORD type = 0;
  DWORD bytes = sizeof(dimensions);
  const LSTATUS status = ::RegQueryValueExW(handle, L"FrameSizeDp", nullptr,
      &type, reinterpret_cast<BYTE*>(dimensions), &bytes);
  ::RegCloseKey(handle);
  const PreferredSize size{dimensions[0], dimensions[1]};
  if (status != ERROR_SUCCESS || type != REG_BINARY ||
      bytes != sizeof(dimensions) || !ValidPreferredSize(size)) {
    return std::nullopt;
  }
  return size;
}

void WritePreferredSize(const GeometryBinding& binding, const PreferredSize& size) {
  const auto key = PreferenceKey(binding);
  if (key.empty() || !ValidPreferredSize(size)) return;
  HKEY handle = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &handle, nullptr) != ERROR_SUCCESS) return;
  const double dimensions[2]{size.width, size.height};
  ::RegSetValueExW(handle, L"FrameSizeDp", 0, REG_BINARY,
      reinterpret_cast<const BYTE*>(dimensions), sizeof(dimensions));
  ::RegCloseKey(handle);
}

bool ValidPreferredPosition(const PreferredPosition& position) {
  return std::isfinite(position.x) && std::isfinite(position.y) &&
         position.x >= 0 && position.x <= 1 &&
         position.y >= 0 && position.y <= 1;
}

std::optional<PreferredPosition> ReadPreferredPosition(const GeometryBinding& binding) {
  const auto key = PreferenceKey(binding);
  if (key.empty()) return std::nullopt;
  HKEY handle = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, KEY_QUERY_VALUE,
                      &handle) != ERROR_SUCCESS) return std::nullopt;
  double coordinates[2]{};
  DWORD type = 0;
  DWORD bytes = sizeof(coordinates);
  const LSTATUS status = ::RegQueryValueExW(handle, L"FramePositionNormalized", nullptr,
      &type, reinterpret_cast<BYTE*>(coordinates), &bytes);
  ::RegCloseKey(handle);
  const PreferredPosition position{coordinates[0], coordinates[1]};
  if (status != ERROR_SUCCESS || type != REG_BINARY ||
      bytes != sizeof(coordinates) || !ValidPreferredPosition(position)) {
    return std::nullopt;
  }
  return position;
}

void WritePreferredPosition(const GeometryBinding& binding,
                            const PreferredPosition& position) {
  const auto key = PreferenceKey(binding);
  if (key.empty() || !ValidPreferredPosition(position)) return;
  HKEY handle = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &handle, nullptr) != ERROR_SUCCESS) return;
  const double coordinates[2]{position.x, position.y};
  ::RegSetValueExW(handle, L"FramePositionNormalized", 0, REG_BINARY,
      reinterpret_cast<const BYTE*>(coordinates), sizeof(coordinates));
  ::RegCloseKey(handle);
}

double NormalizedPosition(LONG offset, LONG travel) {
  return travel > 0 ? std::clamp(offset / static_cast<double>(travel), 0.0, 1.0) : 0.5;
}

void CancelManualResize(GeometryState& state) {
  state.resizing = false;
  state.manual_candidate = false;
  state.dpi_changed = false;
  state.candidate.reset();
}

void DpiChangedManualResize(GeometryState& state) {
  if (!state.resizing) return;
  // Переход монитора меняет физический frame автоматически. Ручной жест
  // сохраняет право записать итоговую позицию, но не размер от DPI-подгонки.
  state.dpi_changed = true;
  state.candidate.reset();
}

void BindGeometry(GeometryState& state, GeometryBinding binding) {
  CancelManualResize(state);
  state.binding = std::move(binding);
}

bool SameBinding(const GeometryBinding& left, const GeometryBinding& right) {
  return left.account == right.account && left.mini_app == right.mini_app &&
         left.generation == right.generation;
}

bool SameFrameSize(const RECT& left, const RECT& right) {
  return left.right - left.left == right.right - right.left &&
         left.bottom - left.top == right.bottom - right.top;
}

bool SameFrame(const RECT& left, const RECT& right) {
  return left.left == right.left && left.top == right.top &&
         left.right == right.right && left.bottom == right.bottom;
}

void BeginManualResize(GeometryState& state, const RECT& initial_frame,
                       bool normal_visible) {
  CancelManualResize(state);
  if (!state.presented || !normal_visible ||
      !state.binding.mini_app || state.binding.account.empty()) return;
  state.resizing = true;
  state.resize_binding = state.binding;
  state.initial_frame = initial_frame;
}

void CaptureManualResize(GeometryState& state, const RECT& frame, UINT dpi,
                         bool normal_visible) {
  if (!state.resizing) return;
  if (!normal_visible || !state.presented ||
      !SameBinding(state.binding, state.resize_binding)) {
    CancelManualResize(state);
    return;
  }
  const double scale = (dpi ? dpi : 96) / 96.0;
  const PreferredSize candidate{(frame.right - frame.left) / scale,
                                (frame.bottom - frame.top) / scale};
  if (ValidPreferredSize(candidate)) {
    state.manual_candidate = !SameFrame(frame, state.initial_frame);
    if (!state.dpi_changed) state.candidate = candidate;
    state.candidate_frame = frame;
  } else {
    CancelManualResize(state);
  }
}

void CompleteManualResize(GeometryState& state, const RECT& final_frame,
                          bool normal_visible) {
  if (state.resizing && state.manual_candidate && state.presented && normal_visible &&
      SameBinding(state.binding, state.resize_binding) &&
      !SameFrame(final_frame, state.initial_frame) &&
      (state.dpi_changed || SameFrame(final_frame, state.candidate_frame))) {
    // Escape может восстановить initial frame без WM_CANCELMODE или прислать
    // WM_SIZING(initial). Автоподгонка тоже делает итог неоднозначным: пропуск
    // безопаснее записи. После DPI-перехода frame от ОС допустим только для
    // позиции уже начатого ручного жеста, а preferred size не записывается.
    // WM_MOVING даёт тот же кандидат frame, но move-only не меняет размер.
    if (state.candidate && !state.dpi_changed &&
        !SameFrameSize(final_frame, state.initial_frame)) {
      WritePreferredSize(state.resize_binding, *state.candidate);
    }
    if (const auto main = MainWindowFrame()) {
      WritePreferredPosition(state.resize_binding, {
          NormalizedPosition(final_frame.left - main->left,
              main->right - main->left - (final_frame.right - final_frame.left)),
          NormalizedPosition(final_frame.top - main->top,
              main->bottom - main->top - (final_frame.bottom - final_frame.top))});
    }
  }
  CancelManualResize(state);
}

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
  GeometryState geometry{};
};
std::map<HWND, VisibilityObserver> g_visibility;

// Прежний минимум HTML остаётся в client dp; mini App — внешний frame.
constexpr int kMinWidth = 800;
constexpr int kMinHeight = 600;
constexpr int kMiniAppMinWidth = 393;
constexpr int kMiniAppMinHeight = 520;

HWND MiniAppMainWindow();

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

// WINDOWPLACEMENT обычного окна использует workspace coordinates. При
// taskbar сверху/слева перевод в screen обязателен; tool window уже в screen.
std::optional<RECT> MainWindowFrame() {
  const HWND main = MiniAppMainWindow();
  if (!main) return std::nullopt;
  RECT frame{};
  if (::IsIconic(main)) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    if (!::GetWindowPlacement(main, &placement)) return std::nullopt;
    frame = placement.rcNormalPosition;
    if (!(::GetWindowLongPtr(main, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) {
      MONITORINFO info{};
      info.cbSize = sizeof(info);
      if (!::GetMonitorInfo(::MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST),
                            &info)) return std::nullopt;
      ::OffsetRect(&frame, info.rcWork.left - info.rcMonitor.left,
                            info.rcWork.top - info.rcMonitor.top);
    }
  } else if (!::GetWindowRect(main, &frame)) {
    return std::nullopt;
  }
  if (frame.right <= frame.left || frame.bottom <= frame.top) return std::nullopt;
  return frame;
}

RECT MiniAppVisibleArea(const RECT& area) {
  const auto main = MainWindowFrame();
  if (main) {
    const RECT visible{std::max(area.left, main->left), std::max(area.top, main->top),
                       std::min(area.right, main->right), std::min(area.bottom, main->bottom)};
    if (visible.right > visible.left && visible.bottom > visible.top) return visible;
  }
  return area;
}

SIZE MiniAppAvailableSize(const RECT& area) {
  const RECT visible = MiniAppVisibleArea(area);
  const auto main = MainWindowFrame();
  return {std::min(visible.right - visible.left,
                   main ? main->right - main->left : area.right - area.left),
          std::min(visible.bottom - visible.top,
                   main ? main->bottom - main->top : area.bottom - area.top)};
}

SIZE MinimumWindowSize(HWND window) {
  UINT dpi = ::GetDpiForWindow(window);
  if (!dpi) dpi = 96;
  const RECT area = WorkArea(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
  const auto observer = g_visibility.find(window);
  if (observer != g_visibility.end() && !observer->second.geometry.binding.mini_app) {
    return FitWindowSize(kMinWidth, kMinHeight, dpi, area);
  }
  const SIZE available = MiniAppAvailableSize(area);
  return {std::min<LONG>(::MulDiv(kMiniAppMinWidth, dpi, 96), available.cx),
          std::min<LONG>(::MulDiv(kMiniAppMinHeight, dpi, 96), available.cy)};
}

// Предел WM_GETMINMAXINFO Windows применяет только к смене размера, не к
// переезду: окно, ужатое на маленьком мониторе (минимум там — 90% экрана),
// на большом осталось бы меньше минимума. Дорастить до
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
  auto& geometry = found->second.geometry;
  const bool normal_visible = ::IsWindowVisible(window) &&
      !::IsIconic(window) && !::IsZoomed(window);
  if (message == WM_ENTERSIZEMOVE) {
    found->second.in_size_move = true;
    RECT initial_frame{};
    const bool measured = ::GetWindowRect(window, &initial_frame) != FALSE;
    BeginManualResize(geometry, initial_frame, normal_visible && measured);
  }
  if (message == WM_SIZING || message == WM_MOVING) {
    // Запрос пользователя до любой программной GrowToMinimum / monitor-fit.
    CaptureManualResize(geometry, *reinterpret_cast<const RECT*>(lparam),
                        ::GetDpiForWindow(window), normal_visible);
  }
  if (message == WM_DPICHANGED) DpiChangedManualResize(geometry);
  if (message == WM_CANCELMODE || message == WM_CLOSE ||
      (message == WM_SHOWWINDOW && !wparam) ||
      (message == WM_SIZE && (wparam == SIZE_MINIMIZED || wparam == SIZE_MAXIMIZED))) {
    CancelManualResize(geometry);
  }
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
  if (alive != g_visibility.end() && message == WM_EXITSIZEMOVE) {
    RECT final_frame{};
    const bool measured = ::GetWindowRect(window, &final_frame) != FALSE;
    CompleteManualResize(alive->second.geometry, final_frame,
        measured && ::IsWindowVisible(window) &&
        !::IsIconic(window) && !::IsZoomed(window));
  }
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

GeometryBinding GeometryBindingArg(const EncodableValue* arguments) {
  GeometryBinding binding;
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) { binding.mini_app = false; return binding; }
  auto account = map->find(EncodableValue("accountUserId"));
  if (account != map->end()) {
    if (const auto* value = std::get_if<std::string>(&account->second)) {
      binding.account = *value;
    }
  }
  auto kind = map->find(EncodableValue("kind"));
  const auto* kind_value = kind == map->end() ? nullptr :
      std::get_if<std::string>(&kind->second);
  binding.mini_app = kind_value && *kind_value == "miniApp";
  auto generation = map->find(EncodableValue("geometryGeneration"));
  if (generation != map->end()) {
    if (const auto* value = std::get_if<int64_t>(&generation->second)) {
      binding.generation = *value;
    } else if (const auto* int32_value = std::get_if<int32_t>(&generation->second)) {
      binding.generation = *int32_value;
    }
  }
  return binding;
}

// HTML сохраняет прежнюю геометрию90% рабочей области без preferences.
RECT DefaultFrame(HWND window) {
  HMONITOR monitor = ::MonitorFromWindow(
      MiniAppMainWindow() ? MiniAppMainWindow() : window,
      MONITOR_DEFAULTTONEAREST);
  const RECT area = WorkArea(monitor);
  // 90% именно внешней рамки, а не client: рамки DWM уже внутри размера.
  const SIZE size{(area.right - area.left) * 9 / 10,
                  (area.bottom - area.top) * 9 / 10};
  const LONG left = area.left + (area.right - area.left - size.cx) / 2;
  const LONG top = area.top + (area.bottom - area.top - size.cy) / 2;
  return RECT{left, top, left + size.cx, top + size.cy};
}

RECT MiniAppDefaultFrame(HWND window, const GeometryBinding& binding) {
  const HWND main_window = MiniAppMainWindow();
  const RECT area = WorkArea(::MonitorFromWindow(
      main_window ? main_window : window, MONITOR_DEFAULTTONEAREST));
  const auto main = MainWindowFrame();
  UINT dpi = ::GetDpiForWindow(window);
  if (!dpi) dpi = 96;
  const double scale = dpi / 96.0;
  const SIZE available = MiniAppAvailableSize(area);
  const auto preferred = ReadPreferredSize(binding);
  const double desired_width = preferred ? preferred->width * scale :
      main ? main->right - main->left : 960 * scale;
  const double desired_height = preferred ? preferred->height * scale :
      main ? main->bottom - main->top : 700 * scale;
  const LONG width = std::min<LONG>(available.cx,
      static_cast<LONG>(std::lround(std::max(desired_width, kMiniAppMinWidth * scale))));
  const LONG height = std::min<LONG>(available.cy,
      static_cast<LONG>(std::lround(std::max(desired_height, kMiniAppMinHeight * scale))));
  const RECT anchor = main.value_or(area);
  const auto position = ReadPreferredPosition(binding).value_or(PreferredPosition{0.5, 0.5});
  const RECT visible = MiniAppVisibleArea(area);
  const LONG left = std::clamp(anchor.left + static_cast<LONG>(std::lround(
      (anchor.right - anchor.left - width) * position.x)),
      visible.left, visible.right - width);
  const LONG top = std::clamp(anchor.top + static_cast<LONG>(std::lround(
      (anchor.bottom - anchor.top - height) * position.y)),
      visible.top, visible.bottom - height);
  return {left, top, left + width, top + height};
}

RECT PresentationFrame(HWND window) {
  const auto observer = g_visibility.find(window);
  const GeometryBinding binding = observer == g_visibility.end() ?
      GeometryBinding{} : observer->second.geometry.binding;
  return binding.mini_app ? MiniAppDefaultFrame(window, binding) : DefaultFrame(window);
}

// Сначала перенос на монитор Лизы, потом размер: при переносе между
// мониторами с разным DPI плагин в WM_DPICHANGED применяет предложенный
// системой rect и перебил бы размер, заданный одним вызовом.
void PlaceDefault(HWND window) {
  const UINT flags = SWP_NOZORDER | SWP_NOACTIVATE;
  RECT frame = PresentationFrame(window);
  ::SetWindowPos(window, nullptr, frame.left, frame.top, 0, 0,
                 flags | SWP_NOSIZE);
  frame = PresentationFrame(window);
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
          const auto bound = g_visibility.find(window);
          if (bound != g_visibility.end()) {
            BindGeometry(bound->second.geometry, GeometryBindingArg(call.arguments()));
            bound->second.geometry.presented = false;
          }
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
          const auto presented = g_visibility.find(window);
          if (presented != g_visibility.end()) {
            presented->second.geometry.presented = ::IsWindowVisible(window) != FALSE;
          }
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
          // width/height остаются client; frame* отдельно измеряет рамку. Всё в dp.
          UINT dpi = ::GetDpiForWindow(window);
          if (!dpi) dpi = 96;
          const double scale = dpi / 96.0;
          RECT client{};
          ::GetClientRect(window, &client);
          RECT frame{};
          ::GetWindowRect(window, &frame);
          const SIZE min = MinimumWindowSize(window);
          const LONG inset = FrameInset(dpi);
          const RECT area = WorkArea(
              ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
          const auto main = MainWindowFrame();
          auto dp = [scale](LONG px) { return EncodableValue(px / scale); };
          result->Success(EncodableValue(EncodableMap{
              {EncodableValue("width"), dp(client.right - client.left)},
              {EncodableValue("height"), dp(client.bottom - client.top)},
              {EncodableValue("frameWidth"), dp(frame.right - frame.left)},
              {EncodableValue("frameHeight"), dp(frame.bottom - frame.top)},
              {EncodableValue("mainFrameWidth"), main ? dp(main->right - main->left) : EncodableValue()},
              {EncodableValue("mainFrameHeight"), main ? dp(main->bottom - main->top) : EncodableValue()},
              {EncodableValue("minFrameWidth"), dp(min.cx)},
              {EncodableValue("minFrameHeight"), dp(min.cy)},
              {EncodableValue("minWidth"), dp(min.cx - 2 * inset)},
              {EncodableValue("minHeight"), dp(min.cy - inset)},
              {EncodableValue("areaWidth"), dp(area.right - area.left)},
              {EncodableValue("areaHeight"), dp(area.bottom - area.top)},
              {EncodableValue("maximized"),
               EncodableValue(::IsZoomed(window) != FALSE)},
          }));
        } else if (method == "setTitle") {
          const auto observer = g_visibility.find(window);
          if (observer != g_visibility.end()) {
            BindGeometry(observer->second.geometry, GeometryBindingArg(call.arguments()));
          }
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
    // Окно ещё скрыто (hiddenAtLaunch): размер Лизы сразу, чтобы первый
    // кадр Flutter не строился под 800×600 плагина. present повторит.
    PlaceDefault(window);
  }
  g_channels.push_back(std::move(channel));
}
