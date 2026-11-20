"""Исполнимый host guard production C++ geometry/HKCU/user gate.

WinAPI doubles проверяют алгоритм и вызовы; реальный Windows runtime, DPI
notifications, HKCU ACL и жесты мышью остаются native manual-проверкой.
ledger:RL-miniapp-detached-window
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[5]
WINDOWS = ROOT / 'clients/flutter/windows/runner/mini_app_window_channel.cpp'


def extract(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    while ';' in source[start:opening]:
        start = source.index(signature, start + len(signature))
        opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + (';' if signature.startswith('struct ') else '')


PREFIX = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <cstdint>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include <iterator>
using LONG=int; using UINT=unsigned; using DWORD=unsigned; using BYTE=unsigned char;
using HWND=int; using HMONITOR=void*; using LONG_PTR=intptr_t; using LSTATUS=int;
using HKEY=const std::wstring*;
constexpr HKEY HKEY_CURRENT_USER=nullptr;
constexpr DWORD KEY_QUERY_VALUE=1, KEY_SET_VALUE=2, REG_BINARY=3;
constexpr int ERROR_SUCCESS=0;
struct RECT { LONG left,top,right,bottom; };
struct SIZE { LONG cx,cy; };
struct MONITORINFO { UINT cbSize; RECT rcMonitor,rcWork; };
struct MONITORINFOEXW : MONITORINFO { wchar_t szDevice[32]{}; };
struct DISPLAY_DEVICEW { DWORD cb; wchar_t DeviceID[128]{}; };
using BOOL=int; using HDC=void*; using LPRECT=RECT*; using LPARAM=intptr_t;
#define CALLBACK
constexpr int TRUE=1, EDD_GET_DEVICE_INTERFACE_NAME=1;
struct WINDOWPLACEMENT { UINT length; RECT rcNormalPosition; };
constexpr int GWL_EXSTYLE=1, WS_EX_TOOLWINDOW=2;
constexpr int SM_CXSIZEFRAME=1, SM_CXPADDEDBORDER=2;
constexpr UINT MONITOR_DEFAULTTOPRIMARY=1, MONITOR_DEFAULTTONEAREST=2, SWP_NOZORDER=1, SWP_NOACTIVATE=2, SWP_NOSIZE=4;
struct RegistryValue { DWORD type; std::vector<BYTE> bytes; };
std::map<std::wstring,std::map<std::wstring,RegistryValue>> registry;
int reads=0,writes=0,closed=0;
std::map<std::wstring,int> value_writes;
bool registry_error=false;
LSTATUS RegOpenKeyExW(HKEY,const wchar_t* key,DWORD,DWORD,HKEY* result) {
  ++reads;
  auto found=registry.find(key);
  if(registry_error || found==registry.end()) return 1;
  *result=&found->first; return ERROR_SUCCESS;
}
LSTATUS RegCreateKeyExW(HKEY,const wchar_t* key,DWORD,void*,DWORD,DWORD,void*,HKEY* result,void*) {
  if(registry_error) return 1;
  auto found=registry.try_emplace(key).first;
  *result=&found->first; return ERROR_SUCCESS;
}
LSTATUS RegQueryValueExW(HKEY key,const wchar_t* name,void*,DWORD* type,BYTE* data,DWORD* length) {
  auto found=registry.at(*key).find(name);
  if(found==registry.at(*key).end()) return 1;
  auto value=found->second;
  *type=value.type;
  DWORD old=*length;
  *length=static_cast<DWORD>(value.bytes.size());
  if(old < *length) return 1;
  std::memcpy(data,value.bytes.data(),value.bytes.size());
  return ERROR_SUCCESS;
}
LSTATUS RegSetValueExW(HKEY key,const wchar_t* name,DWORD,DWORD type,const BYTE* data,DWORD length) {
  registry[*key][name]={type,std::vector<BYTE>(data,data+length)};
  ++value_writes[name];
  ++writes; return ERROR_SUCCESS;
}
LSTATUS RegCloseKey(HKEY) { ++closed; return ERROR_SUCCESS; }
RECT main_area{0,0,1920,1040}, child_area{0,0,800,600};
RECT main_monitor{0,0,1920,1080}, main_frame{100,120,1100,820}, normal_frame{};
RECT child_frame{};
UINT main_dpi=96, child_dpi=96;
HWND main_window=1;
bool iconic=false, toolwindow=false, zoomed=false;
std::vector<UINT> placements;
HWND MiniAppMainWindow() { return main_window; }
std::optional<RECT> MainWindowFrame();
bool monitor_mode=false, external_connected=true, duplicate_identity=false, fail_external_area=false;
RECT external_area{-2560,-400,0,1040};
UINT external_dpi=144;
int child_monitor=2;
HMONITOR MonitorFromWindow(HWND window,UINT) {
  return reinterpret_cast<HMONITOR>(window==1 ? 1 : monitor_mode ? child_monitor : 2);
}
HMONITOR MonitorFromWindow(std::nullptr_t,UINT) { return reinterpret_cast<HMONITOR>(1); }
bool GetMonitorInfo(HMONITOR monitor,MONITORINFO* info) {
  if(fail_external_area && monitor==reinterpret_cast<HMONITOR>(2)) return false;
  info->rcWork=monitor==reinterpret_cast<HMONITOR>(1) ? main_area : monitor_mode ? external_area : child_area;
  info->rcMonitor=monitor==reinterpret_cast<HMONITOR>(1) ? main_monitor : child_area;
  return true;
}
HMONITOR MonitorFromRect(const RECT* rect,UINT) {
  return reinterpret_cast<HMONITOR>(monitor_mode && rect->left < 0 ? 2 : 1);
}
bool GetMonitorInfoW(HMONITOR monitor,MONITORINFO* base) {
  auto* info=reinterpret_cast<MONITORINFOEXW*>(base);
  GetMonitorInfo(monitor,info);
  if(monitor_mode && monitor==reinterpret_cast<HMONITOR>(2)) info->rcWork=external_area;
  std::wcscpy(info->szDevice,monitor==reinterpret_cast<HMONITOR>(1) ? L"DISPLAY1" : L"DISPLAY2");
  return true;
}
bool EnumDisplayDevicesW(const wchar_t* name,DWORD,DISPLAY_DEVICEW* device,DWORD) {
  std::wcscpy(device->DeviceID,std::wstring(name)==L"DISPLAY1" || duplicate_identity ? L"stable-main" : L"stable-external");
  return true;
}
bool EnumDisplayMonitors(void*,void*,BOOL (*callback)(HMONITOR,HDC,LPRECT,LPARAM),LPARAM data) {
  callback(reinterpret_cast<HMONITOR>(1),nullptr,nullptr,data);
  if(external_connected) callback(reinterpret_cast<HMONITOR>(2),nullptr,nullptr,data);
  return true;
}
bool IsIconic(HWND window) { return window==1 && iconic; }
bool IsZoomed(HWND) { return zoomed; }
bool GetWindowPlacement(HWND,WINDOWPLACEMENT* placement) {
  placement->rcNormalPosition=normal_frame; return true;
}
LONG_PTR GetWindowLongPtr(HWND,int) { return toolwindow ? WS_EX_TOOLWINDOW : 0; }
bool GetWindowRect(HWND window,RECT* rect) { *rect=window==1 ? main_frame : child_frame; return true; }
bool OffsetRect(RECT* r,LONG x,LONG y) { r->left+=x;r->right+=x;r->top+=y;r->bottom+=y;return true; }
UINT GetDpiForWindow(HWND window) { return window==1 ? main_dpi : child_dpi; }
int MulDiv(int value,UINT numerator,int denominator) {
  return static_cast<int>(std::lround(value*double(numerator)/denominator));
}
LONG GetSystemMetricsForDpi(int metric,UINT dpi) { return MulDiv(metric==1 ? 8 : 4,dpi,96); }
bool SetWindowPos(HWND,std::nullptr_t,LONG x,LONG y,LONG w,LONG h,UINT flags) {
  placements.push_back(flags);
  if (flags & SWP_NOSIZE) { w=child_frame.right-child_frame.left; h=child_frame.bottom-child_frame.top; }
  child_frame={x,y,x+w,y+h};
  const auto overlap=[&](const RECT& area) {
    return double(std::max(0,std::min(child_frame.right,area.right)-std::max(x,area.left))) *
        std::max(0,std::min(child_frame.bottom,area.bottom)-std::max(y,area.top));
  };
  if (monitor_mode && external_connected && overlap(external_area)>overlap(main_area)) {
    child_monitor=2; child_dpi=external_dpi; child_area=external_area;
  } else { child_monitor=1; child_dpi=main_dpi; child_area=main_area; }
  return true;
}
'''

SUFFIX = r'''
GeometryBinding Account(const std::string& name) { return {name,true,1}; }
void SizeIs(const std::optional<PreferredSize>& size,double w,double h) {
  assert(size && size->width==w && size->height==h);
}
void PositionIs(const GeometryBinding& binding,double x,double y) {
  const auto position=ReadPreferredPosition(binding);
  assert(position && std::abs(position->x-x)<1e-9 && std::abs(position->y-y)<1e-9);
}
void FrameIs(const RECT& r,int w,int h) { assert(r.right-r.left==w && r.bottom-r.top==h); }
void Drag(GeometryState& state,int w,int h,UINT dpi=96) {
  BeginManualResize(state,child_frame,true);
  CaptureManualResize(state,{0,0,w,h},dpi,true);
  child_frame={0,0,w,h};
  CompleteManualResize(state,child_frame,true);
}
void PositionCases() {
  // AC:RL-miniapp-detached-window/64 — production move + snapshot + monitor restore.
  monitor_mode=true; child_area=external_area; child_dpi=144; main_dpi=96;
  main_area={0,0,1920,1040}; main_frame={100,100,580,620};
  const auto a=Account("@monitor:test"), b=Account("@other-monitor:test");
  GeometryState state; BindGeometry(state,a); state.presented=true;
  child_frame={-2000,-100,-800,800}; // 800x600dp before first move
  BeginManualResize(state,child_frame,true,144);
  child_frame={-1900,0,-700,900};
  CaptureManualResize(state,child_frame,144,true);
  CompleteManualResize(state,child_frame,true);
  auto placement=ReadMonitorPlacement(a);
  assert(placement && std::wstring(placement->monitor)==L"path:stable-external");
  assert(placement->size.width==800 && placement->size.height==600);
  assert(!ReadMonitorPlacement(b));
  auto restored=MiniAppDefaultFrame(2,a);
  assert(SameFrame(restored,child_frame));
  // Moving/resizing Liza does not influence the saved geometry.
  main_frame={800,600,1000,800};
  assert(SameFrame(MiniAppDefaultFrame(2,a),restored));
  g_visibility[2].geometry.binding=a;
  auto minimum=MinimumWindowSize(2); assert(minimum.cx==590 && minimum.cy==780);
  // AC:RL-miniapp-detached-window/65 — missing monitor fallback never rewrites tuple.
  const auto saved=registry[PreferenceKey(a)][L"MonitorPlacementV2"].bytes;
  const auto count=writes;
  external_connected=false; child_dpi=96;
  auto fallback=MiniAppDefaultFrame(2,a);
  assert(fallback.left>=0 && fallback.right<=1920);
  FrameIs(fallback,800,600);
  assert(writes==count && registry[PreferenceKey(a)][L"MonitorPlacementV2"].bytes==saved);
  external_connected=true; child_dpi=144;
  assert(SameFrame(MiniAppDefaultFrame(2,a),restored));
  fail_external_area=true; // identity lookup succeeds, workarea handle becomes stale
  const auto hotplug=MiniAppDefaultFrame(2,a);
  assert(hotplug.left>=0 && hotplug.right<=main_area.right && hotplug.bottom<=main_area.bottom);
  assert(hotplug.right>hotplug.left && hotplug.bottom>hotplug.top && writes==count);
  fail_external_area=false;
  // Changed workarea uses normalized anchor; logical size unchanged, no write.
  const auto old_external=external_area; external_area={-1280,0,0,800};
  const auto clamped=MiniAppDefaultFrame(2,a);
  assert(clamped.left>=-1280 && clamped.right<=0 && clamped.bottom<=800);
  assert(writes==count);
  // AC:RL-miniapp-detached-window/66 — move under temporary clamp preserves preferred.
  child_frame=clamped; BeginManualResize(state,child_frame,true,144);
  child_frame.left-=1; child_frame.right-=1;
  CaptureManualResize(state,child_frame,144,true); CompleteManualResize(state,child_frame,true);
  placement=ReadMonitorPlacement(a); assert(placement->size.width==800 && placement->size.height==600);
  external_area=old_external; child_area=external_area;
  // AC:RL-miniapp-detached-window/67 — malformed snapshot ignored as a whole.
  auto bad=*placement; bad.version=3;
  const int before_bad=writes; WriteMonitorPlacement(a,bad); assert(writes==before_bad);
  bad=*placement; bad.position.x=std::numeric_limits<double>::quiet_NaN();
  WriteMonitorPlacement(a,bad); assert(writes==before_bad);
  registry[PreferenceKey(b)][L"MonitorPlacementV2"]={REG_BINARY,{1,2,3}};
  assert(!ReadMonitorPlacement(b));
  duplicate_identity=true; assert(!FindMonitor(L"path:stable-main")); duplicate_identity=false;
  // DPI second pass stays on selected monitor, independent from Liza.
  child_dpi=96; child_monitor=1; child_frame={0,0,3840,2160};
  placements.clear(); PlaceDefault(2);
  assert(placements.size()==2 && !(placements[0]&SWP_NOSIZE) && child_dpi==144 && child_frame.left<0);
  FrameIs(child_frame,1200,900);
  // AC:RL-miniapp-detached-window/69 — target left/above/right × DPI96/144/192.
  const int before_matrix=writes;
  const RECT targets[]{{-2560,-400,0,1040},{0,-1440,2560,0},{1920,0,4480,1440}};
  for (const auto& area : targets) {
    for (UINT dpi : {96u,144u,192u}) {
      external_area=area; external_dpi=dpi;
      child_dpi=96; child_monitor=1; child_frame={0,0,3840,2160};
      PlaceDefault(2);
      assert(child_monitor==2 && child_dpi==dpi);
      FrameIs(child_frame,MulDiv(800,dpi,96),MulDiv(600,dpi,96));
      assert(child_frame.left>=area.left && child_frame.right<=area.right &&
             child_frame.top>=area.top && child_frame.bottom<=area.bottom);
      const auto normalized=ReadMonitorPlacement(a)->position;
      assert(child_frame.left==area.left+static_cast<LONG>(std::lround((area.right-area.left-(child_frame.right-child_frame.left))*normalized.x)));
      assert(child_frame.top==area.top+static_cast<LONG>(std::lround((area.bottom-area.top-(child_frame.bottom-child_frame.top))*normalized.y)));
    }
  }
  assert(writes==before_matrix);
  assert(value_writes[L"MonitorPlacementV2"]>0);
  monitor_mode=false; main_area={0,0,1920,1040}; child_area=main_area;
}
void MessageDpiCases() {
  // AC:RL-miniapp-detached-window/61 — исполняются реальные ветки WndProc:
  // ручной move через mixed-DPI сохраняет позицию, но не авторазмер от ОС.
  const auto binding=Account("@mixed-dpi:test");
  auto& state=g_visibility[2].geometry;
  BindGeometry(state,binding); state.presented=true;
  WritePreferredSize(binding,{600,600});
  main_frame={0,0,1600,1400}; child_frame={100,100,700,700}; child_dpi=96;
  const int size_writes_before=value_writes[L"FrameSizeDp"];
  for (const bool post_dpi_moving : {false,true}) {
    child_frame={100,100,700,700}; child_dpi=96;
    const int position_writes_before=value_writes[L"FramePositionNormalized"];
    DispatchGeometry(WM_ENTERSIZEMOVE);
    RECT moving{500,200,1100,800};
    DispatchGeometry(WM_MOVING,0,reinterpret_cast<intptr_t>(&moving));
    DispatchGeometry(WM_DPICHANGED);
    child_dpi=144; child_frame={700,350,1600,1250};
    if (post_dpi_moving) DispatchGeometry(WM_MOVING,0,reinterpret_cast<intptr_t>(&child_frame));
    DispatchGeometry(WM_EXITSIZEMOVE);
    PositionIs(binding,1,0.7);
    SizeIs(ReadPreferredSize(binding),600,600);
    assert(value_writes[L"FrameSizeDp"]==size_writes_before);
    assert(value_writes[L"FramePositionNormalized"]==position_writes_before+1);
  }
  // DPI сам по себе и отмена ручного жеста не разрешают запись позиции.
  for (int rejected=0;rejected<4;++rejected) {
    child_frame={100,100,700,700};
    const int writes_before=writes;
    DispatchGeometry(WM_ENTERSIZEMOVE);
    RECT moving=rejected==1 ? child_frame : RECT{500,200,1100,800};
    if (rejected!=0) DispatchGeometry(WM_MOVING,0,reinterpret_cast<intptr_t>(&moving));
    DispatchGeometry(WM_DPICHANGED);
    if (rejected==2) DispatchGeometry(WM_CANCELMODE);
    if (rejected==3) { auto next=binding; ++next.generation; BindGeometry(state,next); }
    child_frame={700,350,1600,1250};
    DispatchGeometry(WM_EXITSIZEMOVE);
    assert(writes==writes_before);
  }
}
int main() {
  const auto a=Account("@a:one"), b=Account("@b:one");
  auto html=a; html.mini_app=false;
  auto unknown=a; unknown.account="";
  // AC:RL-miniapp-detached-window/56 — distinct account keys and escaped separators.
  assert(PreferenceKey(a)!=PreferenceKey(b));
  assert(PreferenceKey(Account("a\\b"))!=PreferenceKey(Account("ab")));
  const auto long_account=Account(std::string(255,'x'));
  const auto long_key=PreferenceKey(long_account);
  size_t segment=0;
  for(wchar_t character:long_key) {
    if(character==L'\\') segment=0;
    else { ++segment; assert(segment<=255); }
  }
  WritePreferredSize(long_account,{801,602});
  SizeIs(ReadPreferredSize(long_account),801,602);
  // AC:RL-miniapp-detached-window/54 — HKCU API double stores both dimensions
  // without process-local preference cache (actual Windows restart is manual).
  WritePreferredSize(a,{850.5,620.25});
  SizeIs(ReadPreferredSize(a),850.5,620.25);
  // AC:RL-miniapp-detached-window/56 — account B cannot read A preference.
  assert(!ReadPreferredSize(b));
  int old_reads=reads, old_writes=writes;
  // AC:RL-miniapp-detached-window/56 — HTML/unknown perform no registry I/O.
  WritePreferredSize(html,{900,600}); WritePreferredSize(unknown,{900,600});
  assert(!ReadPreferredSize(html) && !ReadPreferredSize(unknown));
  assert(reads==old_reads && writes==old_writes);
  // AC:RL-miniapp-detached-window/54 — fresh window context reloads persisted dimensions.
  GeometryState fresh; BindGeometry(fresh,a);
  SizeIs(ReadPreferredSize(fresh.binding),850.5,620.25);
  for (auto invalid : {PreferredSize{0,600},PreferredSize{-1,600},
      PreferredSize{800,std::numeric_limits<double>::infinity()},
      PreferredSize{std::numeric_limits<double>::quiet_NaN(),600},
      PreferredSize{100001,600}}) {
    WritePreferredSize(b,invalid); assert(!ReadPreferredSize(b));
    double dimensions[2]{invalid.width,invalid.height};
    auto* data=reinterpret_cast<BYTE*>(dimensions);
    registry[PreferenceKey(b)][L"FrameSizeDp"]={REG_BINARY,std::vector<BYTE>(data,data+sizeof(dimensions))};
    assert(!ReadPreferredSize(b)); registry.erase(PreferenceKey(b));
  }
  registry[PreferenceKey(b)][L"FrameSizeDp"]={REG_BINARY,{1,2,3}}; assert(!ReadPreferredSize(b));
  registry[PreferenceKey(b)][L"FrameSizeDp"]={REG_BINARY,std::vector<BYTE>(32)}; assert(!ReadPreferredSize(b));
  registry[PreferenceKey(b)][L"FrameSizeDp"]={999,std::vector<BYTE>(16)}; assert(!ReadPreferredSize(b));
  registry.erase(PreferenceKey(b));
  registry_error=true; assert(!ReadPreferredSize(a)); WritePreferredSize(b,{800,600});
  registry_error=false; assert(!ReadPreferredSize(b));
  // AC:RL-miniapp-detached-window/53 — actual main frame caps fresh and restored frames.
  registry.erase(PreferenceKey(a));
  g_visibility[2].geometry.binding=a;
  FrameIs(PresentationFrame(2),1000,700);
  WritePreferredSize(a,{900,650});
  FrameIs(PresentationFrame(2),900,650);
  main_frame={100,100,600,500};
  FrameIs(PresentationFrame(2),500,400);
  // AC:RL-miniapp-detached-window/59 — shrinking main only changes applied frame.
  SizeIs(ReadPreferredSize(a),900,650);
  // AC:RL-miniapp-detached-window/58 — outer minimum capped by smaller main.
  auto minimum=MinimumWindowSize(2); assert(minimum.cx==393 && minimum.cy==400);
  // AC:RL-miniapp-detached-window/59 — enlarging main restores original preference.
  main_frame={0,0,4000,3000};
  FrameIs(PresentationFrame(2),900,650);
  main_area={-3000,-1000,-2700,-800};
  FrameIs(PresentationFrame(2),300,200);
  child_area=main_area; minimum=MinimumWindowSize(2);
  assert(minimum.cx==300 && minimum.cy==200);
  main_area={0,0,1920,1040}; child_area=main_area; main_frame={100,120,1100,820};
  g_visibility[2].geometry.binding=html;
  FrameIs(PresentationFrame(2),1728,936);
  minimum=MinimumWindowSize(2); assert(minimum.cx==824 && minimum.cy==612);
  g_visibility[2].geometry.binding=a;
  // Two-step placement must apply target DPI before second preference fit.
  child_dpi=192; main_dpi=144; placements.clear(); PlaceDefault(2);
  assert(placements.size()==2 && (placements[0]&SWP_NOSIZE) && !(placements[1]&SWP_NOSIZE));
  FrameIs(child_frame,1000,700); // saved1350x975px capped by main1000x700px
  SizeIs(ReadPreferredSize(a),900,650);
  registry.erase(PreferenceKey(a)); main_window=0; child_dpi=96;
  FrameIs(PresentationFrame(2),960,700); main_window=1;
  // Minimized main rcNormalPosition workspace -> screen; taskbar left/top,
  // negative-origin monitor; toolwindow coordinates already screen.
  main_monitor={-1920,-1080,0,0}; main_area={-1880,-1040,0,0};
  normal_frame={-1800,-1000,-800,-300}; iconic=true;
  auto normal=MainWindowFrame(); assert(normal && normal->left==-1760 && normal->top==-960);
  toolwindow=true; normal=MainWindowFrame(); assert(normal->left==-1800 && normal->top==-1000);
  toolwindow=false; iconic=false;
  main_monitor={0,0,1920,1080};main_area={0,0,1920,1040};child_area=main_area;child_dpi=96;
  // AC:RL-miniapp-detached-window/57 — скрытые события без изменения frame не пишут;
  // automatic fit after a completed manual request cannot overwrite it.
  GeometryState first,second;
  BindGeometry(first,a); BindGeometry(second,a);
  old_writes=writes; Drag(first,900,650); assert(writes==old_writes); // hidden creation
  first.presented=true; second.presented=true;
  BeginManualResize(first,child_frame,true); CompleteManualResize(first,child_frame,true); assert(writes==old_writes); // без движения
  BeginManualResize(first,child_frame,true); CaptureManualResize(first,{0,0,1350,975},144,true);
  child_frame={0,0,1350,975};
  CompleteManualResize(first,child_frame,true);
  child_frame={0,0,480,520}; GrowToMinimum(2); // auto-fit after completion cannot overwrite
  SizeIs(ReadPreferredSize(a),900,650);
  // AC:RL-miniapp-detached-window/55 — latest completion wins across two window states.
  BeginManualResize(first,child_frame,true); CaptureManualResize(first,{0,0,850,630},96,true);
  Drag(second,800,600); SizeIs(ReadPreferredSize(a),800,600);
  child_frame={0,0,850,630};
  CompleteManualResize(first,child_frame,true); SizeIs(ReadPreferredSize(a),850,630);
  // AC:RL-miniapp-detached-window/56 — account/generation rebind cancels pending ownership.
  // AC:RL-miniapp-detached-window/57 — canceled/hidden/abnormal completion never writes.
  for(int event=0;event<6;++event) {
    child_frame={0,0,850,630};
    const int writes_before_rejected=writes;
    BeginManualResize(first,child_frame,true); CaptureManualResize(first,{100,120,1090,810},96,true);
    child_frame={100,120,1090,810};
    if(event==0) BindGeometry(first,b); // account change
    if(event==1) { auto next=a; ++next.generation; BindGeometry(first,next); }
    if(event==2) CancelManualResize(first); // hide / close / maximize
    if(event==3) first.presented=false;
    if(event==4) CompleteManualResize(first,child_frame,false); // minimized/hidden
    if(event==5) CaptureManualResize(first,{0,0,1,1},96,false);
    CompleteManualResize(first,child_frame,true);
    assert(writes==writes_before_rejected); assert(!ReadPreferredPosition(b));
    SizeIs(ReadPreferredSize(a),850,630); assert(!ReadPreferredSize(b));
    BindGeometry(first,a); first.presented=true;
  }
  BindGeometry(first,html); Drag(first,1000,800);
  BindGeometry(first,unknown); Drag(first,1000,800);
  SizeIs(ReadPreferredSize(a),850,630);
  // AC:RL-miniapp-detached-window/57 — cancel/Escape returns actual frame to
  // begin frame, with or without final WM_SIZING(initial): never save either.
  BindGeometry(first,a); first.presented=true;
  for (bool sizing_initial : {false,true}) {
    child_frame={0,0,800,600};
    const int before_cancel=writes;
    BeginManualResize(first,child_frame,true);
    CaptureManualResize(first,{0,0,990,690},96,true);
    if (sizing_initial) CaptureManualResize(first,child_frame,96,true);
    CompleteManualResize(first,child_frame,true);
    assert(writes==before_cancel);
    SizeIs(ReadPreferredSize(a),850,630);
  }
  // WM_CANCELMODE can leave the enlarged frame in place: pending state,
  // rather than frame restoration alone, must prevent persistence.
  child_frame={0,0,800,600};
  const int before_mode_cancel=writes;
  BeginManualResize(first,child_frame,true);
  CaptureManualResize(first,{0,0,990,690},96,true);
  child_frame={0,0,990,690};
  CancelManualResize(first);
  CompleteManualResize(first,child_frame,true);
  assert(writes==before_mode_cancel); SizeIs(ReadPreferredSize(a),850,630);
  // A completed frame changed by OS/programmatic fit is ambiguous: skip,
  // preserving the prior preference rather than writing either size.
  child_frame={0,0,800,600};
  const int before_fit=writes;
  BeginManualResize(first,child_frame,true);
  CaptureManualResize(first,{0,0,990,690},96,true);
  child_frame={0,0,900,650};
  CompleteManualResize(first,child_frame,true);
  assert(writes==before_fit); SizeIs(ReadPreferredSize(a),850,630);
  // Programmatic frame changes and present/focus cannot create a candidate.
  BindGeometry(first,a); PlaceDefault(2); CompleteManualResize(first,child_frame,true);
  SizeIs(ReadPreferredSize(a),850,630);
  // AC:RL-miniapp-detached-window/53 — full mini App production matrix:
  // DPI100/150/200% ×6ordinary/shifted/negative/small workareas ×3main sizes
  // ×3preference states =162 combinations; HTML DefaultFrame is not stubbed
  // into the mini App path. Assertions express cap/min/persistence contracts.
  int matrix_cases=0;
  const RECT areas[]{
      {0,0,1920,1040}, {-2560,40,0,1440}, {100,-1200,3940,960},
      {0,0,640,480}, {5,9,1371,737}, {-800,-600,-480,-360}};
  const SIZE main_sizes_dp[]{{480,520},{960,700},{4000,3000}};
  const PreferredSize manual_smaller{550,580}, huge_preference{50000,50000};
  main_window=1; iconic=false; toolwindow=false;
  g_visibility[2].geometry.binding=a;
  for (const UINT dpi : {96u,144u,192u}) {
    for (const RECT& area : areas) {
      for (const SIZE& main_size : main_sizes_dp) {
        for (int preference=0;preference<3;++preference) {
          main_area=area; child_area=area; main_monitor=area;
          main_dpi=dpi; child_dpi=dpi;
          main_frame={area.left+37,area.top+29,
              area.left+37+MulDiv(main_size.cx,dpi,96),
              area.top+29+MulDiv(main_size.cy,dpi,96)};
          registry.erase(PreferenceKey(a));
          if (preference==1) WritePreferredSize(a,manual_smaller);
          if (preference==2) WritePreferredSize(a,huge_preference);
          const int writes_before_geometry=writes;
          const LONG cap_width=std::min(area.right,main_frame.right)-std::max(area.left,main_frame.left);
          const LONG cap_height=std::min(area.bottom,main_frame.bottom)-std::max(area.top,main_frame.top);
          // AC:RL-miniapp-detached-window/58 — per-axis outer393x520dp minimum, capped.
          const SIZE minimum=MinimumWindowSize(2);
          assert(minimum.cx==std::min(MulDiv(393,dpi,96),cap_width));
          assert(minimum.cy==std::min(MulDiv(520,dpi,96),cap_height));
          const RECT direct=MiniAppDefaultFrame(2,a);
          const RECT dispatched=PresentationFrame(2);
          assert(SameFrameSize(direct,dispatched));
          assert(direct.left==dispatched.left && direct.top==dispatched.top);
          const LONG width=dispatched.right-dispatched.left;
          const LONG height=dispatched.bottom-dispatched.top;
          // AC:RL-miniapp-detached-window/53 — default/restored frame fits main and workarea.
          assert(width>0 && height>0);
          assert(width<=cap_width && height<=cap_height);
          assert(width>=minimum.cx && height>=minimum.cy);
          assert(dispatched.left>=area.left && dispatched.top>=area.top);
          assert(dispatched.right<=area.right && dispatched.bottom<=area.bottom);
          assert(dispatched.left>=main_frame.left && dispatched.top>=main_frame.top);
          assert(dispatched.right<=main_frame.right && dispatched.bottom<=main_frame.bottom);
          if (preference==0 || preference==2) FrameIs(dispatched,cap_width,cap_height);
          if (preference==1 && cap_width>=MulDiv(550,dpi,96) &&
              cap_height>=MulDiv(580,dpi,96)) {
            FrameIs(dispatched,MulDiv(550,dpi,96),MulDiv(580,dpi,96));
          }
          placements.clear(); PlaceDefault(2);
          assert(placements.size()==2 && (placements[0]&SWP_NOSIZE) &&
                 !(placements[1]&SWP_NOSIZE));
          FrameIs(child_frame,width,height);
          assert(child_frame.left==dispatched.left && child_frame.top==dispatched.top);
          GrowToMinimum(2); // automatic minimum cannot exceed initial main/workarea cap
          FrameIs(child_frame,width,height);
          // AC:RL-miniapp-detached-window/59 — default/place/minimum clamp do not mutate
          // persisted preferred dimensions, including the deliberately oversized value.
          assert(writes==writes_before_geometry);
          if (preference==0) assert(!ReadPreferredSize(a));
          if (preference==1) SizeIs(ReadPreferredSize(a),550,580);
          if (preference==2) SizeIs(ReadPreferredSize(a),50000,50000);
          ++matrix_cases;
        }
      }
    }
  }
  assert(matrix_cases==162);
  PositionCases();
  MessageDpiCases();
}
'''


class WindowsPreferencesTest(unittest.TestCase):
    def test_extracted_production_geometry_registry_and_gesture_gate(self):
        source = WINDOWS.read_text()
        structs = '\n'.join(extract(source, f'struct {name} {{') for name in [
            'GeometryBinding', 'PreferredSize', 'PreferredPosition', 'MonitorPlacement', 'MonitorSearch', 'GeometryState'])
        preference_functions = '\n'.join(extract(source, signature) for signature in [
            'bool ValidPreferredSize(', 'std::wstring PreferenceKey(',
            'std::optional<PreferredSize> ReadPreferredSize(', 'void WritePreferredSize(',
            'bool ValidPreferredPosition(', 'std::optional<PreferredPosition> ReadPreferredPosition(',
            'void WritePreferredPosition(', 'double NormalizedPosition(',
            'bool ValidMonitorPlacement(', 'std::optional<MonitorPlacement> ReadMonitorPlacement(',
            'void WriteMonitorPlacement(', 'std::wstring MonitorIdentity(',
            'BOOL CALLBACK MatchMonitor(', 'HMONITOR FindMonitor(',
            'void SaveMonitorPlacement(', 'bool SameFrame(',
            'void CancelManualResize(', 'void DpiChangedManualResize(', 'void BindGeometry(', 'bool SameBinding(',
            'bool SameFrameSize(', 'void BeginManualResize(', 'void CaptureManualResize(', 'void CompleteManualResize('])
        observer = '\nstruct Observer { GeometryState geometry; bool in_size_move=false; }; std::map<HWND,Observer> g_visibility;\n'
        constants = '\n'.join(re.findall(r'constexpr int k\w+ = \d+;', source))
        geometry_functions = '\n'.join(extract(source, signature) for signature in [
            'LONG FrameInset(', 'RECT WorkArea(', 'SIZE FitWindowSize(',
            'std::optional<RECT> MainWindowFrame(', 'RECT MiniAppVisibleArea(', 'SIZE MiniAppAvailableSize(',
            'SIZE MinimumWindowSize(', 'void GrowToMinimum(', 'RECT DefaultFrame(',
            'RECT MiniAppDefaultFrame(', 'RECT PresentationFrame(', 'bool HasMonitorPlacement(', 'void PlaceDefault('])
        proc = extract(source, 'LRESULT CALLBACK MiniAppVisibilityProc(')
        gate_start = proc.index('  auto& geometry = found->second.geometry;')
        gate_end = proc.index('  const auto observer = found->second;', gate_start)
        completion = extract(proc, 'if (alive != g_visibility.end() && message == WM_EXITSIZEMOVE)')
        message_gate = r'''
constexpr UINT WM_ENTERSIZEMOVE=1, WM_SIZING=2, WM_MOVING=3, WM_DPICHANGED=4,
    WM_CANCELMODE=5, WM_CLOSE=6, WM_SHOWWINDOW=7, WM_SIZE=8, WM_EXITSIZEMOVE=9;
constexpr UINT SIZE_MINIMIZED=1, SIZE_MAXIMIZED=2;
constexpr int FALSE=0;
bool IsWindowVisible(HWND) { return true; }
void DispatchGeometry(UINT message, uintptr_t wparam=0, intptr_t lparam=0) {
  const HWND window=2;
  const auto found=g_visibility.find(window);
''' + proc[gate_start:gate_end] + '\nconst auto alive=g_visibility.find(window);\n' + completion + '\n}\n'
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'Нужен host C++ compiler')
        with tempfile.TemporaryDirectory() as directory:
            cpp, binary = Path(directory) / 'guard.cpp', Path(directory) / 'guard'
            cpp.write_text(PREFIX + '\nRECT WorkArea(HMONITOR);\n' + structs + preference_functions + observer + constants + geometry_functions + message_gate + SUFFIX)
            compiled = subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_window_messages_wire_only_manual_candidate_before_auto_growth(self):
        source = WINDOWS.read_text()
        proc = extract(source, 'LRESULT CALLBACK MiniAppVisibilityProc(')
        self.assertIn('message == WM_ENTERSIZEMOVE', proc)
        self.assertIn('message == WM_SIZING', proc)
        self.assertIn('message == WM_MOVING', proc)
        self.assertIn('message == WM_DPICHANGED', proc)
        self.assertIn('message == WM_CANCELMODE', proc)
        self.assertIn('message == WM_SHOWWINDOW && !wparam', proc)
        self.assertIn('wparam == SIZE_MAXIMIZED', proc)
        self.assertLess(proc.index('CompleteManualResize('), proc.index('GrowToMinimum(window)'))
        set_title = source[source.index('method == "setTitle"'):source.index('method == "focus"')]
        self.assertIn('BindGeometry(', set_title)
        self.assertNotIn('PlaceDefault(', set_title)
        self.assertNotIn('WritePreferredSize(', set_title)


if __name__ == '__main__':
    unittest.main()
