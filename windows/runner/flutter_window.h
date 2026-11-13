#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Registers the `shunbo/window` method channel on the engine's messenger.
  void RegisterWindowChannel();

  // Enters / leaves real (borderless, monitor-covering, taskbar-hidden)
  // fullscreen. See the comment block in flutter_window.cpp for why this
  // cannot be done from Dart.
  void SetFullscreen(bool enabled);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // `shunbo/window` channel (only `setFullscreen` today).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Whether the window is currently in real fullscreen.
  bool is_fullscreen_ = false;

  // Style and placement captured on entering fullscreen, restored on exit.
  LONG saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
