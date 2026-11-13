#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Name of the window channel. Must match `WindowChannel` on the Dart side
// character for character; a typo here fails silently (the Dart call just
// returns false and fullscreen degrades to "content gets a bit bigger").
constexpr char kWindowChannelName[] = "shunbo/window";

// Tells the shell that |hwnd| is a fullscreen window so the taskbar keeps
// itself behind it instead of covering the bottom of the video.
//
// Deliberately NOT using SHAppBarMessage(ABM_SETSTATE, ABS_AUTOHIDE): that
// rewrites the user's global taskbar auto-hide preference, and a crash or a
// forced kill would leave the taskbar permanently auto-hidden. MarkFullscreenWindow
// only affects this window's lifetime, which is exactly the scope we want.
void MarkTaskbarFullscreen(HWND hwnd, bool fullscreen) {
  ITaskbarList2* taskbar = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&taskbar));
  if (FAILED(hr) || taskbar == nullptr) {
    return;
  }
  taskbar->HrInit();
  taskbar->MarkFullscreenWindow(hwnd, fullscreen ? TRUE : FALSE);
  taskbar->Release();
}

}  // namespace

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
  RegisterWindowChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // Maximize only after Show(): Win32Window::Show() uses SW_SHOWNORMAL, so a
    // maximize requested before the first frame would be cancelled by it.
    // A TV-style layout keeps a permanent channel rail on the right, and at
    // 200% DPI the 1280x720 default window left that rail outside the screen.
    // Skip maximizing when SHUNBO_WINDOW pinned an explicit size (walkthrough:
    // a maximized window would hide the very portrait layout being inspected).
    if (::GetEnvironmentVariableW(L"SHUNBO_WINDOW", nullptr, 0) == 0) {
      ::ShowWindow(this->GetHandle(), SW_SHOWMAXIMIZED);
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // The channel holds a raw messenger pointer owned by the engine, so it must
  // be destroyed before the controller.
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setFullscreen") {
          result->NotImplemented();
          return;
        }
        bool enabled = false;
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args != nullptr) {
          auto it = args->find(flutter::EncodableValue("enabled"));
          if (it != args->end()) {
            const auto* flag = std::get_if<bool>(&it->second);
            enabled = flag != nullptr && *flag;
          }
        }
        SetFullscreen(enabled);
        result->Success(flutter::EncodableValue(true));
      });
}

void FlutterWindow::SetFullscreen(bool enabled) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (enabled == is_fullscreen_) {
    return;
  }

  if (enabled) {
    // Remember everything needed to put the window back exactly as it was:
    // a maximized window must return maximized, not merely "some size".
    saved_style_ = ::GetWindowLong(hwnd, GWL_STYLE);
    saved_placement_.length = sizeof(saved_placement_);
    if (!::GetWindowPlacement(hwnd, &saved_placement_)) {
      saved_placement_ = {};
    }

    HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    if (monitor == nullptr || !::GetMonitorInfo(monitor, &info)) {
      // Without a monitor rect we cannot cover the screen; leave the window
      // untouched rather than shrinking it into something unrecognizable.
      return;
    }
    const RECT& target = info.rcMonitor;

    // Drop WS_OVERLAPPEDWINDOW (caption, thick frame, system menu) but keep
    // WS_VISIBLE: a borderless window without it would vanish.
    ::SetWindowLong(hwnd, GWL_STYLE,
                    (saved_style_ & ~WS_OVERLAPPEDWINDOW) | WS_VISIBLE);
    ::SetWindowPos(hwnd, HWND_TOP, target.left, target.top,
                   target.right - target.left, target.bottom - target.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
  } else {
    if (saved_style_ != 0) {
      ::SetWindowLong(hwnd, GWL_STYLE, saved_style_);
    }
    if (saved_placement_.length != 0) {
      ::SetWindowPlacement(hwnd, &saved_placement_);
    }
    // SWP_FRAMECHANGED is required for the restored non-client area to be laid
    // out immediately; without it the title bar only reappears after the next
    // resize, which looks like a stuck fullscreen.
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                       SWP_NOZORDER | SWP_NOOWNERZORDER);
  }

  MarkTaskbarFullscreen(hwnd, enabled);
  is_fullscreen_ = enabled;
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
    case WM_SYSCOMMAND:
      // Alt+Enter is the Windows-wide fullscreen toggle and would otherwise be
      // swallowed by DefWindowProc as a system menu command. Report it to Dart
      // through the same channel so there is exactly one source of truth for
      // the fullscreen state.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam == VK_RETURN) {
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "toggleFullscreen",
              std::make_unique<flutter::EncodableValue>(
                  flutter::EncodableValue()));
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
