# Global hotkey to focus WezTerm — design

## Goal

A global hotkey that brings the running WezTerm window to the foreground. No
launch-if-missing, no toggle, no resize. Just "make WezTerm the foreground
app".

## Scope

This spec covers the macOS recipe only. Windows is deferred to a follow-up
spec; a pure-PowerShell implementation needs a long-running message pump
(WinForms hidden window + `RegisterHotKey` via `Add-Type`), and the user
asked to defer it.

## Non-goals

- Launching WezTerm if it isn't running.
- Quake-style hide/toggle.
- Resizing or full-screening the window.
- Multi-window selection logic — if the user has multiple WezTerm windows,
  the script picks one (the focused or main window) and doesn't try to be
  clever about which.
- Automated tests — this manipulates real OS window managers; smoke-tested
  by hand.

## Deliverable

A single file:

```
examples/macos/wezterm-focus.lua
```

The file is a Hammerspoon script. When loaded (via `dofile` from
`~/.hammerspoon/init.lua`), it registers a global hotkey that focuses
WezTerm. The hotkey is configurable at the top of the file.

### Default hotkey

`ctrl+alt+cmd+space`. Picked for low conflict risk; configurable.

### File contents (target)

```lua
-- Hammerspoon recipe: global hotkey to focus WezTerm.
-- Install: in ~/.hammerspoon/init.lua, add
--   dofile(os.getenv('HOME')..'/path/to/termtools/examples/macos/wezterm-focus.lua')
-- then reload Hammerspoon.

local HOTKEY = { mods = { 'ctrl', 'alt', 'cmd' }, key = 'space' }
local BUNDLE_ID = 'com.github.wez.wezterm'

local function focus()
  local app = hs.application.applicationsForBundleID(BUNDLE_ID)[1]
  if not app then return end
  app:activate(true)
  local win = app:focusedWindow() or app:mainWindow()
  if win then win:focus() end
end

hs.hotkey.bind(HOTKEY.mods, HOTKEY.key, focus)
```

### Behavior

1. Look up the running WezTerm app by its bundle ID
   (`com.github.wez.wezterm`). If `applicationsForBundleID` returns no
   instances, return silently — do not launch.
2. Call `app:activate(true)` to bring it to the foreground (the `true`
   un-hides if hidden and brings windows forward).
3. Pick the app's focused window if any, else its main window. Call
   `win:focus()` to ensure that window is keyed.

Edge cases:

- **WezTerm running but all windows minimized**: `focusedWindow()` and
  `mainWindow()` may be nil. `app:activate(true)` will still surface the
  app from the dock; if no window is restored, the user clicks the dock
  icon — acceptable for v1.
- **Multiple WezTerm windows**: we activate the app and focus whichever
  window Hammerspoon reports as focused/main. Per the brainstorming
  decision, no smarter selection.
- **WezTerm hidden via `app:hide()` or Cmd-H**: `app:activate(true)`
  un-hides it.

## Documentation

Update the existing "No global hotkeys" caveat in `README.md` (currently
around line 254) to point at the new recipe. One short paragraph, two
lines of install snippet. Note that Windows is not yet covered.

The script's top-of-file comment is the install instructions; users
shouldn't need to read README to wire it up.

## Testing

Manual smoke test on macOS:

1. WezTerm running and frontmost → press hotkey → no observable change
   (already focused).
2. WezTerm running but another app frontmost → press hotkey → WezTerm
   becomes frontmost.
3. WezTerm running but minimized to dock → press hotkey → WezTerm
   un-minimizes / is brought forward.
4. WezTerm not running → press hotkey → nothing happens, no error in
   Hammerspoon console.
5. WezTerm hidden via Cmd-H → press hotkey → WezTerm unhides.

## Risks / known limitations

- The `Cmd-H`-hidden case relies on `app:activate(true)` un-hiding; if
  Hammerspoon's behavior changes here we'd need an explicit
  `app:unhide()` call.
- macOS doesn't have a real "maximized" state, so we don't try to detect
  it. If the user wants Quake-style toggle later (hide on second press
  when fullscreen), it's an additive change.
- Uses `hs.application.applicationsForBundleID` rather than the
  `hs.application.find('WezTerm')` name lookup, because the bundle ID is
  unambiguous and survives WezTerm rename / multiple installs.

## Deferred follow-ups

- **Windows**: PowerShell long-running script with WinForms hidden form
  for `RegisterHotKey` + `WM_HOTKEY`. Roughly 50 lines plus a Task
  Scheduler install snippet. Separate spec when picked up.
- **Toggle / hide**: if the user later wants a "hide if frontmost"
  toggle, add a check for `app:isFrontmost()` and call `app:hide()`.
- **Launch-if-missing**: add an `hs.application.launchOrFocusByBundleID`
  fallback when the app isn't running.
