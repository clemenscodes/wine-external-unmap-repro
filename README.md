# winex11: external unmap of a managed window never reaches the Win32 side

When another X client unmaps a managed Wine window (`XUnmapWindow`), winex11
records the new `WM_STATE` as the window's desired host state but never tells
the Win32 side. The application keeps seeing a visible window
(`IsWindowVisible` stays 1, no `WM_SHOWWINDOW`, no `SWP_HIDEWINDOW`). The next
`SetWindowPos` from the application then maps the window again on its own,
undoing the external unmap.

An external iconify, by contrast, is propagated correctly
(`WM_SYSCOMMAND SC_MINIMIZE`, later `SC_RESTORE`), which is the control case
below.

Tested with Wine 11.19 (staging, wow64) from nixpkgs, openbox as the window
manager on Xvfb.

## Run it

```sh
nix develop
./run-repro.sh unmap     # the bug
./run-repro.sh iconify   # the control
```

The first run creates a private Wine prefix in `.wineprefix/`. Each run starts
its own Xvfb (`:99`) and openbox, so nothing touches the desktop. Full logs land
in `out/<mode>/`: `app.log` (Win32 side), `x11.log` (host side, sampled with
`xwininfo`/`xprop` every 250 ms), `wine.log` (`WINEDEBUG=warn+event,warn+x11drv`).

`repro.exe` (built from `repro.c` with MinGW) shows one window, logs what the
Win32 side believes about it every 250 ms plus every `WM_SHOWWINDOW`,
`WM_WINDOWPOSCHANGED` and `WM_SYSCOMMAND`, and calls
`SetWindowPos(100, 100, 800, 600, SWP_NOZORDER | SWP_NOACTIVATE)` itself at
6 s. The script hides the window from outside at 3 s and shows it again at 8 s.

## Result

`unmap` (identical in every run; times in ms, both clocks within about 100 ms):

```
[    5] x11 map=IsViewable WM_STATE=Normal geometry=632x446+54+80
[   14] app window created and shown
[  265] state IsWindowVisible=1 WS_VISIBLE=1 IsIconic=0 rect=(50,50)-(690,530)
[ 3003] host xdotool windowunmap
[ 3096] x11 map=IsUnMapped WM_STATE=none geometry=632x446+54+80
                  <- no message reaches the app, IsWindowVisible stays 1
[ 6015] app SetWindowPos -> 100,100 800x600
[ 6016] msg WM_WINDOWPOSCHANGED flags=0x14 pos=(100,100) size=800x600
[ 6187] x11 map=IsViewable WM_STATE=Normal geometry=792x566+104+130
                  <- Wine maps the window again on its own
[ 8007] host xdotool windowmap   (no effect, already mapped)
```

Wine's warnings for the unmap:

```
warn:event:X11DRV_UnmapNotify window 0x3004e/e00001 unexpectedly unmapped, assuming reparenting
warn:event:X11DRV_FocusOut Ignoring window 0x3004e/e00001 FocusOut serial 167, ... during reparenting
warn:x11drv:handle_state_change window 0x3004e/e00001 unexpected WM_STATE 0/167
```

`iconify` (the control):

```
[ 3002] host xdotool windowminimize
[ 3089] msg WM_SYSCOMMAND 0xf020                                   <- SC_MINIMIZE
[ 3097] x11 map=IsUnMapped WM_STATE=Iconic
[ 3265] state IsWindowVisible=1 WS_VISIBLE=1 IsIconic=1
[ 6015] app SetWindowPos -> 100,100 800x600                         <- stays minimized
[ 8006] host xdotool windowactivate
[ 8092] msg WM_SYSCOMMAND 0xf120                                   <- SC_RESTORE
[ 8249] x11 map=IsViewable WM_STATE=Normal
```

## Where it happens (Wine 11.19)

1. `X11DRV_UnmapNotify` (`dlls/winex11.drv/event.c`) sees no pending
   `WM_STATE` request and only sets `data->reparenting`.
2. The window manager then sets `WM_STATE` to Withdrawn.
   `window_wm_state_notify` -> `handle_state_change`
   (`dlls/winex11.drv/window.c`) treats it as "unexpected" and copies the value
   into `desired_state` and `pending_state` as well as `current_state`.
3. `window_update_client_state` returns early because
   `desired_state.wm_state == WithdrawnState` ("ignore state changes on
   invisible windows"), so `GetWindowStateUpdates` reports nothing and
   `WM_WINE_WINDOW_STATE_CHANGED` (`dlls/win32u/message.c`) does nothing. The
   Win32 window keeps `WS_VISIBLE`.
4. On the application's next `SetWindowPos`, `X11DRV_WindowPosChanged`
   recomputes the desired state from the Win32 style (`get_desired_wm_state`:
   `WS_VISIBLE` and an on-screen rect give `NormalState`) and maps the window
   again.

The iconify path differs at step 3: an unexpected `IconicState` turns into
`SC_MINIMIZE` in `window_update_client_state`, so host and Win32 state agree.

## Fix

`patches/0001-winex11-sync-win32-visibility-on-external-withdraw-map.patch`
adds `window_update_client_visibility` to `dlls/winex11.drv/window.c`. When no
request of our own is pending and the host and Win32 visibility disagree in the
way only an external change produces, `GetWindowStateUpdates` reports it to the
Win32 side, which applies it through the existing `NtUserSetWindowPos` path:

- host `Withdrawn`, Win32 `WS_VISIBLE`, not minimized, on-screen rect:
  `SWP_HIDEWINDOW`
- host `Normal` (and desired `Normal`), Win32 not `WS_VISIBLE`:
  `SWP_SHOWWINDOW`

Win32-side show / hide requests update the desired state first, so they never
match. Layered windows waiting for their attributes (which `WindowPosChanged`
deliberately keeps unmapped while `WS_VISIBLE`) are skipped. The patch applies
to both plain Wine 11.19 and Wine-staging 11.19.

The flake builds the same Wine with the patch applied:

```sh
nix build .#wine-patched                       # full Wine build, not cached
nix develop .#patched --command ./run-repro.sh unmap
nix develop .#patched --command ./run-repro.sh iconify
```

`run-repro.sh unmap` ends with a verdict. Unpatched (`nix develop`), three
runs each:

```
FAIL the app learns about the external unmap
FAIL the window stays unmapped across the app's own SetWindowPos
FAIL the app learns about the external map
```

Patched (`nix develop .#patched`), three runs each:

```
PASS the app learns about the external unmap
PASS the window stays unmapped across the app's own SetWindowPos
PASS the app learns about the external map
```

```
[ 3005] host xdotool windowunmap
[ 3038] x11 map=IsUnMapped WM_STATE=none
[ 3047] msg WM_WINDOWPOSCHANGED flags=0x1897 HIDE pos=(50,50) size=640x480
[ 3284] state IsWindowVisible=0 WS_VISIBLE=0
[ 6034] app SetWindowPos -> 100,100 800x600
[ 6065] x11 map=IsUnMapped WM_STATE=none geometry=792x566+104+130   <- stays hidden
[ 8014] host xdotool windowmap
[ 8057] msg WM_WINDOWPOSCHANGED flags=0x1857 SHOW pos=(100,100) size=800x600
[ 8234] x11 map=IsViewable WM_STATE=Normal
[ 8284] state IsWindowVisible=1 WS_VISIBLE=1
```

The `iconify` control is unchanged with the patch (`SC_MINIMIZE`, then
`SC_RESTORE`).

## Expected

Either keep the window hidden and in sync (for example, turn an external
withdraw into a Win32 hide, `SWP_HIDEWINDOW`, the way an external iconify turns
into `SC_MINIMIZE`), or at least not let the Win32 and host states disagree.
Today the host says unmapped while the application says visible, and the next
application-side move silently reverses the external change.
