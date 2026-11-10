#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Walkthrough aid: `SHUNBO_WINDOW=WxH` overrides the initial window size so the
  // narrow/portrait layout branch can be inspected on desktop (e.g. 404x860 to
  // mimic a phone in portrait). Unset means "use the default and start maximized".
  {
    wchar_t env[32];
    const DWORD n = ::GetEnvironmentVariableW(L"SHUNBO_WINDOW", env, 32);
    if (n > 0 && n < 32) {
      int w = 0;
      int h = 0;
      if (::swscanf_s(env, L"%dx%d", &w, &h) == 2 && w >= 240 && h >= 240) {
        size = Win32Window::Size(w, h);
      }
    }
  }
  // Window title is written as escape sequences instead of literal CJK text.
  // MSVC parses this file using the local code page (936 here), so a UTF-8
  // Chinese literal would be garbled (and trip C4819) unless /utf-8 is set.
  // \u987A\u64AD spells the product name "shunbo" in Chinese.
  if (!window.Create(L"\u987A\u64AD shunbo", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Start maximized: done in FlutterWindow::OnCreate (after the first frame).
  // Win32Window::Show() calls ShowWindow(SW_SHOWNORMAL) once the first frame is
  // ready, which would cancel a maximize requested here.

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
