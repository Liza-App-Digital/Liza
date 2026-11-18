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
#include <cstdint>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>
using LONG=int; using UINT=unsigned; using DWORD=unsigned; using BYTE=unsigned char;
using HWND=int; using HMONITOR=int; using LONG_PTR=intptr_t; using LSTATUS=int;
using HKEY=const std::wstring*;
constexpr HKEY HKEY_CURRENT_USER=nullptr;
constexpr DWORD KEY_QUERY_VALUE=1, KEY_SET_VALUE=2, REG_BINARY=3;
constexpr int ERROR_SUCCESS=0;
struct RECT { LONG left,top,right,bottom; };
struct SIZE { LONG cx,cy; };
struct MONITORINFO { UINT cbSize; RECT rcMonitor,rcWork; };
struct WINDOWPLACEMENT { UINT length; RECT rcNormalPosition; };
constexpr int GWL_EXSTYLE=1, WS_EX_TOOLWINDOW=2;
constexpr int SM_CXSIZEFRAME=1, SM_CXPADDEDBORDER=2;
constexpr UINT MONITOR_DEFAULTTONEAREST=2, SWP_NOZORDER=1, SWP_NOACTIVATE=2, SWP_NOSIZE=4;
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
HMONITOR MonitorFromWindow(HWND window,UINT) { return window==1 ? 1 : 2; }
bool GetMonitorInfo(HMONITOR monitor,MONITORINFO* info) {
  info->rcWork=monitor==1 ? main_area : child_area;
  info->rcMonitor=monitor==1 ? main_monitor : child_area;
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
  if (!(flags & SWP_NOSIZE)) child_frame={x,y,x+w,y+h};
  child_dpi=main_dpi; child_area=main_area;
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
  // AC:RL-miniapp-detached-window/61 — завершённый move-only восстанавливает
  // позицию справа; отдельное предпочтение размера не перезаписывается.
  const auto a=Account("@position:one"), b=Account("@position:two");
  auto html=a; html.mini_app=false;
  auto unknown=a; unknown.account="";
  main_frame={100,100,1500,1100}; main_area={0,0,1920,1200};
  main_window=1; child_dpi=96; main_dpi=96;
  WritePreferredSize(a,{600,600});
  assert(!ReadPreferredPosition(a));
  auto reopened=MiniAppDefaultFrame(2,a);
  assert(reopened.left==500 && reopened.top==300); // без позиции — центр
  GeometryState state; BindGeometry(state,a); state.presented=true;
  child_frame=reopened;
  const int size_writes_before=value_writes[L"FrameSizeDp"];
  BeginManualResize(state,child_frame,true);
  child_frame={900,400,1500,1000};
  CaptureManualResize(state,child_frame,96,true);
  CompleteManualResize(state,child_frame,true);
  assert(value_writes[L"FrameSizeDp"]==size_writes_before);
  PositionIs(a,1,0.75); SizeIs(ReadPreferredSize(a),600,600);
  reopened=MiniAppDefaultFrame(2,a);
  assert(reopened.left==900 && reopened.top==400);
  GeometryState second; BindGeometry(second,a); second.presented=true;
  BeginManualResize(state,{100,100,700,700},true);
  CaptureManualResize(state,{900,400,1500,1000},96,true);
  BeginManualResize(second,{100,100,700,700},true);
  CaptureManualResize(second,{500,200,1100,800},96,true);
  CompleteManualResize(second,{500,200,1100,800},true);
  PositionIs(a,0.5,0.25);
  CompleteManualResize(state,{900,400,1500,1000},true);
  PositionIs(a,1,0.75); // последнее завершение побеждает между окнами аккаунта
  // Новый контекст, другой main/DPI и отрицательные координаты монитора.
  GeometryState fresh; BindGeometry(fresh,a);
  main_frame={-1800,-1000,-200,400}; main_area={-1920,-1080,0,480}; child_dpi=144;
  reopened=MiniAppDefaultFrame(2,fresh.binding);
  assert(reopened.left==-1100 && reopened.top==-625);
  FrameIs(reopened,900,900); PositionIs(a,1,0.75);
  const int writes_before_rejected=writes;
  WritePreferredPosition(html,{0,1}); WritePreferredPosition(unknown,{0,1});
  assert(!ReadPreferredPosition(html) && !ReadPreferredPosition(unknown));
  assert(!ReadPreferredPosition(b));
  assert(writes==writes_before_rejected);
  for (auto invalid : {PreferredPosition{-0.1,0.5}, PreferredPosition{0.5,1.1},
      PreferredPosition{std::numeric_limits<double>::infinity(),0.5},
      PreferredPosition{0.5,std::numeric_limits<double>::quiet_NaN()}}) {
    WritePreferredPosition(b,invalid); assert(!ReadPreferredPosition(b));
    const double coordinates[2]{invalid.x,invalid.y};
    const auto* bytes=reinterpret_cast<const BYTE*>(coordinates);
    registry[PreferenceKey(b)][L"FramePositionNormalized"]={
        REG_BINARY,std::vector<BYTE>(bytes,bytes+sizeof(coordinates))};
    assert(!ReadPreferredPosition(b)); registry.erase(PreferenceKey(b));
  }
  for (const RegistryValue& invalid : {RegistryValue{REG_BINARY,{1,2,3}},
      RegistryValue{REG_BINARY,std::vector<BYTE>(32)}, RegistryValue{999,std::vector<BYTE>(16)}}) {
    registry[PreferenceKey(b)][L"FramePositionNormalized"]=invalid;
    assert(!ReadPreferredPosition(b));
  }
  registry_error=true; WritePreferredPosition(b,{0,0}); assert(!ReadPreferredPosition(a));
  registry_error=false; registry.erase(PreferenceKey(b));
  // Полноразмерное окно без travel сохраняет центр по обеим осям.
  main_frame={0,0,800,600}; main_area={0,0,1920,1200}; child_dpi=96;
  child_frame={0,0,700,550};
  BeginManualResize(state,child_frame,true);
  child_frame={0,0,800,600}; CaptureManualResize(state,child_frame,96,true);
  CompleteManualResize(state,child_frame,true);
  PositionIs(a,0.5,0.5);
  // Программная смена позиции после кандидата неоднозначна даже при том же
  // размере: не записываем ни размер, ни позицию.
  const int writes_before_fit=writes;
  BeginManualResize(state,child_frame,true);
  CaptureManualResize(state,{10,10,810,610},96,true);
  CompleteManualResize(state,{20,20,820,620},true);
  assert(writes==writes_before_fit);
  // Частично невидимый main: frame внутри фактического пересечения с workarea,
  // даже ниже обычного минимума. Автоподгонка не меняет предпочтения.
  WritePreferredSize(a,{600,600}); WritePreferredPosition(a,{1,0});
  const int writes_before_clamp=writes;
  for (const RECT frame : {RECT{-400,-300,1000,700}, RECT{900,500,1800,1200}}) {
    main_frame=frame; main_area={0,0,1200,800};
    reopened=MiniAppDefaultFrame(2,a);
    assert(reopened.left>=std::max(frame.left,main_area.left));
    assert(reopened.top>=std::max(frame.top,main_area.top));
    assert(reopened.right<=std::min(frame.right,main_area.right));
    assert(reopened.bottom<=std::min(frame.bottom,main_area.bottom));
  }
  FrameIs(reopened,300,300);
  assert(writes==writes_before_clamp); SizeIs(ReadPreferredSize(a),600,600); PositionIs(a,1,0);
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
            'GeometryBinding', 'PreferredSize', 'PreferredPosition', 'GeometryState'])
        preference_functions = '\n'.join(extract(source, signature) for signature in [
            'bool ValidPreferredSize(', 'std::wstring PreferenceKey(',
            'std::optional<PreferredSize> ReadPreferredSize(', 'void WritePreferredSize(',
            'bool ValidPreferredPosition(', 'std::optional<PreferredPosition> ReadPreferredPosition(',
            'void WritePreferredPosition(', 'double NormalizedPosition(', 'bool SameFrame(',
            'void CancelManualResize(', 'void DpiChangedManualResize(', 'void BindGeometry(', 'bool SameBinding(',
            'bool SameFrameSize(', 'void BeginManualResize(', 'void CaptureManualResize(', 'void CompleteManualResize('])
        observer = '\nstruct Observer { GeometryState geometry; bool in_size_move=false; }; std::map<HWND,Observer> g_visibility;\n'
        constants = '\n'.join(re.findall(r'constexpr int k\w+ = \d+;', source))
        geometry_functions = '\n'.join(extract(source, signature) for signature in [
            'LONG FrameInset(', 'RECT WorkArea(', 'SIZE FitWindowSize(',
            'std::optional<RECT> MainWindowFrame(', 'RECT MiniAppVisibleArea(', 'SIZE MiniAppAvailableSize(',
            'SIZE MinimumWindowSize(', 'void GrowToMinimum(', 'RECT DefaultFrame(',
            'RECT MiniAppDefaultFrame(', 'RECT PresentationFrame(', 'void PlaceDefault('])
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
            cpp.write_text(PREFIX + structs + preference_functions + observer + constants + geometry_functions + message_gate + SUFFIX)
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
