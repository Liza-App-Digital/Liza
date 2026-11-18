"""Исполнимый host-страж production-функций геометрии C++ и Swift.

WinAPI/screenArea заменены моделями; это НЕ native ОС/Flutter runtime.
Legacy HTML geometry: mini App с17.11 имеет отдельную policy.
ledger:RL-miniapp-detached-window
ledger:RL-liza-liquid-page
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[5]
WINDOWS = ROOT / 'clients/flutter/windows/runner/mini_app_window_channel.cpp'
MACOS = ROOT / 'clients/flutter/macos/Runner/MainFlutterWindow.swift'


def function(source, signature):
    """Извлекаем именно тело production-функции, без копии алгоритма."""
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class DefaultGeometryTest(unittest.TestCase):
    def compile_and_run(self, compiler, source, extension, flags):
        self.assertIsNotNone(compiler, f'Нужен host compiler {extension}')
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / ('guard.' + extension)
            binary = Path(directory) / 'guard'
            file.write_text(source)
            compiled = subprocess.run([compiler, *flags, str(file), '-o', str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_windows_html_frame_90_percent_centered_on_main_monitor_each_present(self):
        source = WINDOWS.read_text()
        constants = '\n'.join(re.findall(r'constexpr int kMin(?:Width|Height) = \d+;', source))
        functions = '\n'.join(function(source, signature) for signature in [
            'LONG FrameInset(', 'RECT WorkArea(', 'SIZE FitWindowSize(',
            'RECT DefaultFrame(', 'RECT PresentationFrame(', 'void PlaceDefault(',
        ])
        prefix = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <vector>
#include <map>
using LONG=int; using UINT=unsigned; using HWND=int; using HMONITOR=int;
struct RECT { LONG left,top,right,bottom; };
struct SIZE { LONG cx,cy; };
struct MONITORINFO { UINT cbSize; RECT rcWork; };
constexpr int SM_CXSIZEFRAME=1, SM_CXPADDEDBORDER=2;
constexpr UINT MONITOR_DEFAULTTONEAREST=2, SWP_NOZORDER=1, SWP_NOACTIVATE=2, SWP_NOSIZE=4;
RECT main_area{}, child_area{}, frame{};
UINT main_dpi=96, child_dpi=144;
HWND main_window=1;
struct GeometryBinding { bool mini_app=false; };
struct GeometryState { GeometryBinding binding{}; };
struct Observer { GeometryState geometry{}; };
std::map<HWND,Observer> g_visibility{{1,{}},{2,{}}};
RECT MiniAppDefaultFrame(HWND,const GeometryBinding&) { assert(false); return {}; }
std::vector<UINT> placements;
HWND MiniAppMainWindow() { return main_window; }
HMONITOR MonitorFromWindow(HWND window,UINT) { return window==1 ? 1 : 2; }
bool GetMonitorInfo(HMONITOR monitor,MONITORINFO* info) {
  info->rcWork=monitor==1 ? main_area : child_area; return true;
}
UINT FlutterDesktopGetDpiForMonitor(HMONITOR monitor) { return monitor==1 ? main_dpi : child_dpi; }
UINT GetDpiForWindow(HWND window) { return window==1 ? main_dpi : child_dpi; }
int MulDiv(int value,UINT numerator,int denominator) {
  return static_cast<int>(std::lround(value*double(numerator)/denominator));
}
LONG GetSystemMetricsForDpi(int metric,UINT dpi) { return MulDiv(metric==1 ? 8 : 4,dpi,96); }
bool SetWindowPos(HWND,std::nullptr_t,LONG x,LONG y,LONG w,LONG h,UINT flags) {
  placements.push_back(flags);
  if (!(flags & SWP_NOSIZE)) frame={x,y,x+w,y+h};
  // Перенос меняет DPI окна прежде второго прохода PlaceDefault.
  child_dpi=main_dpi;
  return true;
}
'''
        suffix = r'''
void Check(const RECT& actual,const RECT& area) {
  const double w=area.right-area.left, h=area.bottom-area.top;
  // Legacy HTML: обе стороны допуска90% frame, не client.
  assert(std::abs((actual.right-actual.left)-w*0.9)<=1);
  assert(std::abs((actual.bottom-actual.top)-h*0.9)<=1);
  assert(std::abs((actual.left+actual.right)-(area.left+area.right))<=1);
  assert(std::abs((actual.top+actual.bottom)-(area.top+area.bottom))<=1);
}
int main() {
  for (auto area : {RECT{0,0,1920,1040}, RECT{-2560,40,0,1440},
                    RECT{100,-1200,3940,960}, RECT{0,0,640,480}, RECT{5,9,1371,737}}) {
    for (UINT dpi : {96u,144u,192u}) {
      main_window=1; main_area=area; main_dpi=dpi;
      child_area={0,0,800,600}; child_dpi=96;
      Check(DefaultFrame(2),main_area);
      placements.clear(); PlaceDefault(2); Check(frame,main_area);
      assert(placements.size()==2 && (placements[0]&SWP_NOSIZE) && !(placements[1]&SWP_NOSIZE));
      frame={0,0,450,400}; // Предыдущее ручное уменьшение не влияет на новое окно.
      PlaceDefault(2); Check(frame,main_area);
      // Legacy HTML: прежний минимум client dp + рамка, clamp.
      const SIZE min=FitWindowSize(kMinWidth,kMinHeight,dpi,main_area);
      const LONG inset=FrameInset(dpi);
      assert(min.cx==std::min(MulDiv(800,dpi,96)+2*inset,(area.right-area.left)*9/10));
      assert(min.cy==std::min(MulDiv(600,dpi,96)+inset,(area.bottom-area.top)*9/10));
      main_window=0; Check(DefaultFrame(2),child_area); // fallback без Лизы.
    }
  }
}
'''
        self.compile_and_run(shutil.which('clang++') or shutil.which('g++'),
                             prefix + constants + functions + suffix, 'cpp',
                             ['-std=c++17', '-Wall', '-Wextra', '-Werror'])

    def test_macos_html_frame_90_percent_centered_each_present_and_minimum_clamp(self):
        source = MACOS.read_text()
        constants = '\n'.join(re.findall(r'  private static let (?:defaultSize|minimumSize) = NSSize[^\n]+', source))
        functions = '\n'.join(function(source, signature) for signature in [
            'private static func fit(', 'private static func defaultFrame(',
        ])
        harness = '''
import Cocoa
class MiniAppWindowPlugin {
  static var area = NSRect.zero
  private static func screenArea() -> NSRect { return area }
''' + constants + '\n' + functions + '''
  static func check() {
    let f = defaultFrame()
    // Legacy HTML: внешний frame ровно90% каждой оси.
    precondition(abs(f.width - area.width * 0.9) < 0.001, "frame width must be 90%")
    precondition(abs(f.height - area.height * 0.9) < 0.001, "frame height must be 90%")
    precondition(abs(f.midX - area.midX) < 0.001)
    precondition(abs(f.midY - area.midY) < 0.001)
    // Legacy HTML: прежний minimum800×600 с fit.
    let minimum = fit(minimumSize)
    precondition(minimum.width == min(800, area.width * 0.9))
    precondition(minimum.height == min(600, area.height * 0.9))
    precondition(defaultFrame() == f) // Нет памяти о прошлой геометрии.
  }
}
for rect in [NSRect(x: 0,y: 25,width: 1440,height: 875),
             NSRect(x: -2560,y: 40,width: 2560,height: 1400),
             NSRect(x: 100,y: -1200,width: 3840,height: 2160),
             NSRect(x: 0,y: 0,width: 640,height: 480)] {
  MiniAppWindowPlugin.area = rect
  MiniAppWindowPlugin.check()
}
'''
        self.compile_and_run(shutil.which('swiftc'), harness, 'swift', [])


if __name__ == '__main__':
    unittest.main()
