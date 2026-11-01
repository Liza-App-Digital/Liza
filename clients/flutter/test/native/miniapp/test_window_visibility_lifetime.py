"""Host-страж настоящего Windows WndProc с моделью lifetime messenger.

Не Windows runtime/build: WinAPI заменён, исполняется функция из production .cpp.
ledger:RL-miniapp-contact
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[5]
SOURCE = ROOT / 'clients/flutter/windows/runner/mini_app_window_channel.cpp'


class WindowLifetimeTest(unittest.TestCase):
    def test_destroy_and_reentrant_destroy_detach_before_engine(self):
        # AC:RL-miniapp-contact/6
        source = SOURCE.read_text()
        proc = source[source.index('LRESULT CALLBACK MiniAppVisibilityProc('):
                      source.index('// Позиция и размер последнего закрытого окна')]
        prefix = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <map>
#include <memory>
#include <vector>
using HWND=void*;
const HWND kWindow=reinterpret_cast<HWND>(1);
const HWND kMain=reinterpret_cast<HWND>(2);
HWND MiniAppMainWindow() { return kMain; }
using UINT=unsigned;
using WPARAM=uintptr_t;
using LPARAM=intptr_t;
using LRESULT=intptr_t;
using LONG_PTR=intptr_t;
using WNDPROC=LRESULT (*)(HWND,UINT,WPARAM,LPARAM);
#define CALLBACK
#define LOWORD(x) ((x)&0xffff)
constexpr UINT WM_SIZE=1, WM_SHOWWINDOW=2, WM_CLOSE=3, WM_DESTROY=4,
  WM_NCDESTROY=5, WM_ACTIVATE=6, WM_ACTIVATEAPP=7, WM_WINDOWPOSCHANGED=8;
constexpr int SIZE_MINIMIZED=1, WA_INACTIVE=0, GWLP_WNDPROC=0;
using EncodableValue=int;
bool alive=true, detached=false, restored=false, unhooked=false, reenter=false;
int calls=0, destroyed_channels=0;
namespace flutter {
template<typename T> struct MethodChannel {
  ~MethodChannel() { assert(alive); ++destroyed_channels; }
  void InvokeMethod(const char*,std::unique_ptr<T>) { assert(alive); ++calls; }
  void SetMethodCallHandler(std::nullptr_t) { assert(alive); detached=true; }
};
}
std::vector<std::unique_ptr<flutter::MethodChannel<EncodableValue>>> g_channels;
struct VisibilityObserver {
  WNDPROC original;
  flutter::MethodChannel<EncodableValue>* channel;
  int64_t visibility_epoch=0, snapshot_sequence=0, focus_epoch=0;
  int64_t direct_main_focus_epoch=-1;
};
std::map<HWND,VisibilityObserver> g_visibility;
void* g_foreground_hook=reinterpret_cast<void*>(1);
int Visibility(HWND,bool=false) { return 1; }
LRESULT MiniAppVisibilityProc(HWND,UINT,WPARAM,LPARAM);
LRESULT DefWindowProc(HWND,UINT,WPARAM,LPARAM) { return 0; }
LONG_PTR SetWindowLongPtr(HWND,int,LONG_PTR) { restored=true; return 1; }
bool UnhookWinEvent(void*) { unhooked=true; return true; }
LRESULT CallWindowProc(WNDPROC p,HWND w,UINT m,WPARAM a,LPARAM b) { return p(w,m,a,b); }
LRESULT Original(HWND w,UINT message,WPARAM,LPARAM) {
  if(message==WM_DESTROY) {
    // desktop_multi_window удаляет engine здесь. Все raw messenger owners
    // обязаны исчезнуть раньше; иначе следующий NCDESTROY вызовет UAF.
    assert(detached && restored && unhooked);
    assert(g_visibility.empty() && g_channels.empty());
    alive=false;
  }
  if(message==WM_SIZE && reenter) MiniAppVisibilityProc(w,WM_DESTROY,0,0);
  return 42;
}
void Setup() {
  alive=true; detached=restored=unhooked=false;
  reenter=false; calls=0; destroyed_channels=0; g_foreground_hook=reinterpret_cast<void*>(1);
  g_channels.push_back(std::make_unique<flutter::MethodChannel<EncodableValue>>());
  g_visibility.emplace(kWindow, VisibilityObserver{Original,g_channels.back().get()});
}
'''
        suffix = r'''
int main() {
  Setup();
  assert(MiniAppVisibilityProc(kWindow,WM_DESTROY,0,0)==42);
  assert(!alive && calls==1 && destroyed_channels==1);
  // После снятия subclass NCDESTROY идёт прямо original, не к messenger.
  Original(kWindow,WM_NCDESTROY,0,0);
  assert(calls==1);
  Setup(); reenter=true;
  assert(MiniAppVisibilityProc(kWindow,WM_SIZE,0,0)==42);
  assert(!alive && calls==1 && destroyed_channels==1);
  Setup();
  MiniAppVisibilityProc(kWindow,WM_ACTIVATE,WA_INACTIVE,reinterpret_cast<LPARAM>(kMain));
  assert(g_visibility.at(kWindow).focus_epoch==1 && calls==1);
  assert(g_visibility.at(kWindow).direct_main_focus_epoch==1);
  // A→другое окно: поздний main snapshot не получает proof прямого transfer.
  MiniAppVisibilityProc(kWindow,WM_ACTIVATE,WA_INACTIVE,3);
  assert(g_visibility.at(kWindow).direct_main_focus_epoch==-1);
  MiniAppVisibilityProc(kWindow,WM_DESTROY,0,0);
  assert(calls==3 && destroyed_channels==1);
}
'''
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'Нужен host C++ compiler для lifetime-стража')
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / 'guard.cpp'
            binary = Path(directory) / 'guard'
            cpp.write_text(prefix + proc + suffix)
            compiled = subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                       str(cpp), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
