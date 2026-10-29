#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

// SetCurrentProcessExplicitAppUserModelID живёт в shell32.lib, который
// шаблонный Flutter-runner явно не линкует.
#pragma comment(lib, "shell32.lib")

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

// AUMID приложения. ДОЛЖЕН совпадать с `AppConfig.appId`, который клиент
// передаёт в flutter_local_notifications_windows (см. background_push.dart).
// Без явной регистрации AUMID у процесса WinRT ToastNotificationManager не
// находит приложение и всплывающие уведомления молча не показываются
// (LABA-1891: «на винде уведомлений нет вовсе»). Одной этой строки мало —
// нужен ещё ярлык в меню Пуск с тем же System.AppUserModel.ID (installer.iss).
constexpr wchar_t kAppUserModelId[] = L"com.prodamus.laba.liza";

// Single-instance + deep-link forwarding.
// При запуске второй копии (например, после клика по liza:// в браузере)
// находим работающее окно Liza, передаём ему URL через WM_COPYDATA
// (см. app_links Windows plugin), выводим его на передний план и
// завершаемся. Так deep-link попадает в уже запущенное приложение, а не
// открывает второе окно.
bool SendAppLinkToInstance(const std::wstring& title) {
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());
  if (!hwnd) {
    return false;
  }
  SendAppLink(hwnd);

  WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
  GetWindowPlacement(hwnd, &place);
  switch (place.showCmd) {
    case SW_SHOWMAXIMIZED:
      ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      break;
    case SW_SHOWMINIMIZED:
      ShowWindow(hwnd, SW_RESTORE);
      break;
    default:
      ShowWindow(hwnd, SW_NORMAL);
      break;
  }
  SetWindowPos(0, HWND_TOP, 0, 0, 0, 0,
               SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  SetForegroundWindow(hwnd);
  return true;
}

// Сторож выхода: цикл сообщений кончился, а процесс за 4 с не завершился —
// значит, завис в разборе плагинов. Убиваем сами, иначе остаётся «зомби» с
// окнами, которые не закрыть (заявка №61). ExitProcess не годится: он снова
// запускает выгрузку DLL, где и висим.
DWORD WINAPI ExitWatchdog(LPVOID) {
  ::Sleep(4000);
  ::OutputDebugString(L"liza: exit-watchdog fired\n");
  wchar_t path[MAX_PATH];
  if (::GetEnvironmentVariable(L"LIZA_PILOT_RESULT", path, MAX_PATH)) {
    HANDLE file = ::CreateFile(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                               OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      const char line[] = "exit-watchdog fired\n";
      DWORD written = 0;
      ::WriteFile(file, line, sizeof(line) - 1, &written, nullptr);
      ::CloseHandle(file);
    }
  }
  ::TerminateProcess(::GetCurrentProcess(), 0);
  return 0;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendAppLinkToInstance(L"Liza")) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Регистрируем AUMID процесса до создания окна и первого показа toast —
  // иначе WinRT не сопоставит уведомления с приложением (LABA-1891).
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.CreateAndShow(L"Liza", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Поток создаём здесь, а не из деструкторов: под блокировкой загрузчика
  // новый поток не стартует.
  ::CreateThread(nullptr, 0, ExitWatchdog, nullptr, 0, nullptr);
  // Страж RL-miniapp-detached-window AC-18: имитация зависшего выхода в VM.
  if (::GetEnvironmentVariable(L"LIZA_TEST_HANG_AFTER_LOOP", nullptr, 0)) {
    ::Sleep(INFINITE);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
