/* Minimal Win32 app for the external unmap/map repro.
 *
 * Shows one top-level window and prints, every 250 ms, what the Win32 side
 * believes about it (IsWindowVisible, WS_VISIBLE, IsIconic, window rect),
 * plus every WM_SHOWWINDOW / WM_WINDOWPOSCHANGED / WM_SYSCOMMAND it receives.
 * At T_SETPOS ms it calls SetWindowPos itself (a resize, like an application
 * changing its window mode), so the log shows how Wine handles an app-side
 * change while the host has the window unmapped. Exits after T_EXIT ms. */
#include <windows.h>
#include <stdio.h>

#define T_SETPOS 6000
#define T_EXIT 12000
#define TIMER_SAMPLE 1
#define TIMER_SETPOS 2
#define TIMER_EXIT 3

static DWORD start_tick;

static void logf_(const char *fmt, ...)
{
    va_list args;
    printf("[%5lu ms] ", GetTickCount() - start_tick);
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    fflush(stdout);
}

static void sample(HWND hwnd)
{
    RECT rect;
    LONG style = GetWindowLongW(hwnd, GWL_STYLE);
    GetWindowRect(hwnd, &rect);
    logf_("state IsWindowVisible=%d WS_VISIBLE=%d IsIconic=%d rect=(%ld,%ld)-(%ld,%ld)",
          IsWindowVisible(hwnd), !!(style & WS_VISIBLE), IsIconic(hwnd),
          rect.left, rect.top, rect.right, rect.bottom);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    switch (msg)
    {
    case WM_SHOWWINDOW:
        logf_("msg WM_SHOWWINDOW show=%d", (int)wparam);
        break;
    case WM_WINDOWPOSCHANGED:
    {
        const WINDOWPOS *pos = (const WINDOWPOS *)lparam;
        logf_("msg WM_WINDOWPOSCHANGED flags=%#x%s%s pos=(%d,%d) size=%dx%d", pos->flags,
              (pos->flags & SWP_SHOWWINDOW) ? " SHOW" : "", (pos->flags & SWP_HIDEWINDOW) ? " HIDE" : "",
              pos->x, pos->y, pos->cx, pos->cy);
        break;
    }
    case WM_SYSCOMMAND:
        logf_("msg WM_SYSCOMMAND %#lx", (unsigned long)(wparam & 0xfff0));
        break;
    case WM_TIMER:
        if (wparam == TIMER_SAMPLE) sample(hwnd);
        else if (wparam == TIMER_SETPOS)
        {
            KillTimer(hwnd, TIMER_SETPOS);
            logf_("app SetWindowPos -> 100,100 800x600");
            SetWindowPos(hwnd, NULL, 100, 100, 800, 600, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        else if (wparam == TIMER_EXIT) PostQuitMessage(0);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE prev, LPSTR cmdline, int show)
{
    WNDCLASSW cls = {0};
    HWND hwnd;
    MSG msg;

    start_tick = GetTickCount();
    cls.lpfnWndProc = wnd_proc;
    cls.hInstance = instance;
    cls.lpszClassName = L"ReproWindow";
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&cls);

    hwnd = CreateWindowW(L"ReproWindow", L"Repro Window", WS_OVERLAPPEDWINDOW,
                         50, 50, 640, 480, NULL, NULL, instance, NULL);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    logf_("app window created and shown");

    SetTimer(hwnd, TIMER_SAMPLE, 250, NULL);
    SetTimer(hwnd, TIMER_SETPOS, T_SETPOS, NULL);
    SetTimer(hwnd, TIMER_EXIT, T_EXIT, NULL);

    while (GetMessageW(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logf_("app exit");
    return 0;
}
