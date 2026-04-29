# Pane / Window / Tab (GUI side)

The three objects you receive in event callbacks, key bindings, and `wezterm.action_callback`. They're the GUI-facing handles to the same underlying mux state covered in [05-mux-and-workspaces.md](05-mux-and-workspaces.md). When wezterm hands you `(window, pane)` from a key binding or an `InputSelector` action, you've got GUI handles; when you reach into `wezterm.mux.*` you get mux handles. Most methods named the same way exist on both, but the shape and identity rules differ — see *Gotchas*.

## Overview

- **Pane** — a single terminal grid: scrollback, cursor, foreground process, OSC state. The GUI Pane and the MuxPane represent the same underlying object; you can convert via `pane:tab():window():gui_window()` (mux → gui) and there is no public reverse path — GUI Pane methods just *are* the wider surface.
- **Window** — a top-level OS window holding tabs. The GUI Window is the rendering surface and event source; the MuxWindow holds the tab/pane tree. Cross with `window:mux_window()` and `mux_window:gui_window()`.
- **Tab** — wezterm has no separate "GUI Tab"; tabs are mux-only. `window:active_tab()` returns a MuxTab. The "tab bar" is a render concept, not a Lua object.

In practice, the only true GUI-only object is `Window`. `Pane` and `Tab` come from `wezterm.mux.*` and from event arguments interchangeably.

## Pane

### Identity
- `pane:pane_id()` — unique integer, stable for the pane's lifetime.
- `pane:tab()` — owning MuxTab, or `nil` if the pane has been closed.
- `pane:window()` — owning MuxWindow, or `nil` if closed. Note: this is the *mux* window. To reach the GUI window from a pane, use `pane:window():gui_window()`.

### Content
- `pane:get_lines_as_text(n)` — last `n` lines of the visible viewport joined with `\n`. No ANSI/SGR.
- `pane:get_logical_lines_as_text(n)` — same but unwraps soft-wraps into single logical lines.
- `pane:get_text_from_region(x0, y0, x1, y1)` — rectangular region; coords are stable-row-index based.
- `pane:get_semantic_zones(zone_type)` — list of `{start_x, start_y, end_x, end_y, semantic_type}`. `zone_type` is one of `'Prompt'`, `'Input'`, `'Output'`, or omitted for all. Requires the shell to emit OSC 133 (zsh/bash with shell-integration; pwsh with the wezterm module).
- `pane:get_dimensions()` — `{ cols, viewport_rows, scrollback_rows, scrollback_top, physical_top, dpi, pixel_width, pixel_height }`.

### CWD / process
- `pane:get_current_working_dir()` — Url userdata in modern wezterm, string in older (see *Gotchas*). Set via OSC 7 from the shell.
- `pane:get_foreground_process_info()` — table of `{ pid, name, executable, status, cwd, argv, ... }` for the active foreground process. Returns `nil` if procinfo is unavailable on this OS for this process.
- `pane:get_foreground_process_name()` — just the executable path string. Cheaper than the full info table.
- `pane:get_user_vars()` — table of user-set variables (OSC 1337 `SetUserVar` from the shell).
- `pane:get_title()` — string set via OSC 0/2 or wezterm's title rules.

### Spawning
- `pane:split { ... }` — split this pane and spawn into the new half. See [07-splits.md](07-splits.md) for direction-name quirks (it uses `Top`/`Bottom` while `SplitPane` uses `Up`/`Down`).
- `pane:move_to_new_tab()` / `pane:move_to_new_window()` — detach.

### Messaging
- `pane:send_text(text)` — feed text into the pane's pty as if typed. Newlines are `\r`, not `\n`.
- `pane:paste(text)` — same but routed through bracketed-paste if the program has it enabled. Prefer this for multi-line commands you want as a single unit.
- `pane:inject_output(text)` — write directly to the terminal, bypassing the program. Cosmetic only; the shell doesn't see it.

### State / control
- `pane:activate()` — focus this pane within its tab. Doesn't switch tabs — pair with `pane:tab():activate()`.
- `pane:is_alt_screen_active()` — true while a full-screen TUI (vim, less, htop) holds the alt screen. Use to skip work that depends on prompt/output structure.
- `pane:has_unseen_output()` — boolean, cleared on activation.
- `pane:get_progress()` — OSC 9;4 progress info.

## Window

### Identity
- `window:window_id()` — integer GUI window id. Pair with `wezterm.mux.get_window(id)` to cross over to the mux side.
- `window:gui_window()` — only on MuxWindow; on a GUI Window it's the same object. Returns `nil` if the mux window has no GUI counterpart (e.g. a tls-attached headless mux).
- `window:mux_window()` — the MuxWindow for this GUI Window. Always non-nil for a GUI Window you got from an event.

### Structure
- `window:active_pane()` — current focused pane in the active tab. Use to capture "the pane the user was looking at" when you open a modal — see *Gotchas*.
- `window:active_tab()` — current active MuxTab.
- `window:tabs()` (alias `window:mux_window():tabs()`) — list of MuxTabs in window order.
- `window:active_workspace()` — workspace name string.

### Display / events
- `window:get_dimensions()` — `{ pixel_width, pixel_height, dpi, is_full_screen }`.
- `window:current_event()` — for use inside `format-tab-title` / mouse callbacks; the event being processed.
- `window:get_appearance()` — `'Light'` / `'Dark'` / `'LightHighContrast'` / `'DarkHighContrast'`.
- `window:effective_config()` — the resolved config table (post-overrides).
- `window:set_config_overrides(t)` — merge `t` over the running config for *this window only*. Triggers a re-render.

### User-facing
- `window:toast_notification(title, message, url_or_nil, timeout_ms)` — transient banner. termtools uses this for "no selection", "project unavailable", etc.
- `window:set_left_status(formatted)` — left side of the tab bar, accepts a `wezterm.format`'d string.
- `window:set_right_status(formatted)` — right side, same.
- `window:copy_to_clipboard(text, target?)` — `target` is `'Clipboard'` (default) or `'PrimarySelection'`.

### Dispatch
- `window:perform_action(action, pane)` — fire any `wezterm.action.*`. The `pane` argument is *required* and acts as the target — actions like `SplitPane` and `SpawnCommandInNewTab` use it to know where to spawn.
- `window:composition_status()` — IME state string; non-nil while composing.

### Selection
- `window:get_selection_text_for_pane(pane)` — current selection in the given pane, or `''` if nothing selected.
- `window:get_selection_escapes_for_pane(pane)` — same, but with ANSI escapes preserved.

## Tab (MuxTab)

- `tab:tab_id()` — integer.
- `tab:panes()` — list of panes in this tab, in tile order.
- `tab:panes_with_info()` — same but each entry is `{ index, is_active, is_zoomed, left, top, width, height, pixel_width, pixel_height, pane }`. Use when you need geometry; otherwise `panes()` is cheaper.
- `tab:active_pane()` — currently focused pane in the tab.
- `tab:set_zoomed(bool)` — toggle the zoomed/maximised pane state.
- `tab:get_title()` — string, set via `wezterm.action.SetTabTitle` or by wezterm's auto-title.
- `tab:set_title(s)` — programmatic title. Wins over auto-title.
- `tab:activate()` — switch to this tab. Does not focus the window itself if the OS focus is elsewhere.
- `tab:window()` — owning MuxWindow.

## Examples

### Resolve a pane's CWD: procinfo first, OSC 7 fallback

`util.pane_cwd` (lua/util.lua:166) reads `get_foreground_process_info().cwd` first because the OS-reported CWD is always live. It falls back to `get_current_working_dir()` (handling both the modern Url-userdata return type and the old string type) only when procinfo isn't available — that path covers wezterm builds without procinfo on the platform. PowerShell and cmd don't emit OSC 7 on every `cd`, so an OSC-7-first ordering would lag behind manual chdirs.

```lua
function M.pane_cwd(pane)
  if not pane then return nil end
  local ok_pi, info = pcall(pane.get_foreground_process_info, pane)
  if ok_pi and info and type(info.cwd) == 'string' and info.cwd ~= '' then
    return info.cwd
  end
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if ok and cwd then
    if type(cwd) == 'table' and cwd.file_path then return cwd.file_path end
    if type(cwd) == 'string' and cwd ~= '' then return cwd end
  end
  return nil
end
```

### Walk every pane in every mux window

`util.foreach_pane` (lua/util.lua:180) is the standard "find a pane matching X" iterator. The callback may return a non-nil value to short-circuit; that value is returned from `foreach_pane`.

```lua
function M.foreach_pane(fn, opts)
  opts = opts or {}
  local windows = opts.window and { opts.window } or wezterm.mux.all_windows()
  for _, win in ipairs(windows) do
    for _, tab in ipairs(win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        local result = fn(pane, tab, win)
        if result ~= nil then return result end
      end
    end
  end
end
```

Used by `pickers/project.lua:80` to count how many tabs a project root has open, and by `claude.lua:108` to scan every claude pane for its working/idle classification.

### Capture the active pane when a modal opens

The pane handed to a picker's callback is the pane that was active *when the modal opened*. By the time the user confirms, that pane may have closed (e.g. user closed a terminal, then hit a key chord that opens the picker over a different one). The pickers re-fetch:

```lua
-- lua/pickers/project.lua:221
local target_pane = w:active_pane() or p
w:perform_action(
  wezterm.action.SpawnCommandInNewTab { cwd = entry.path, args = cmd },
  target_pane
)
```

`w:active_pane()` queries the *current* focus; `p` is the closure-captured pane from when the modal opened. The `or` chain means: prefer current focus, fall back to the original pane.

### Toast a transient notification

```lua
-- lua/pickers/action.lua:88
window:toast_notification('termtools',
  'Could not determine current directory; action picker unavailable.',
  nil, 3000)
```

Args are `(title, body, url_or_nil, timeout_ms)`. The URL field, if non-nil, makes the toast clickable. termtools always passes `nil` for it.

### Cross from mux pane to GUI window (focus)

When activating a pane from a non-current window — `claude.lua:181` after `focus_next_waiting()` — you need to also focus the OS window, which is a *GUI* operation:

```lua
local tab = pane:tab()
if tab then tab:activate() end
pane:activate()
if tab then
  local mw = tab:window()                -- mux window
  if mw and mw.gui_window then           -- guard: not all mux windows are gui
    local gui = mw:gui_window()
    if gui then pcall(gui.focus, gui) end
  end
end
```

Three steps: activate tab in mux, activate pane in tab, then bring the OS window forward.

### Read the current selection

`open_selection.lua:25`:

```lua
local raw = window:get_selection_text_for_pane(pane)
if not raw or raw == '' then
  window:toast_notification('termtools',
    'No selection — highlight a file path first.', nil, 1500)
  return
end
```

### Send text to a pane

`send_text` is a literal pty write. To "press Enter", append `\r` (carriage return), not `\n`:

```lua
pane:send_text('rs\r')                          -- one line, runs immediately
pane:send_text('git status\r')
pane:paste('git log\n--oneline\n--graph\r')    -- multi-line via bracketed paste
```

## Gotchas

### `get_current_working_dir` return type changed
Older wezterm versions returned a `string`. Modern versions return a `Url` userdata with `.file_path`, `.host`, `.scheme` fields. Always handle both:

```lua
local cwd = pane:get_current_working_dir()
if type(cwd) == 'table' then cwd = cwd.file_path end
```

`util.pane_cwd` does this for you. Don't rely on `tostring(cwd)` — it returns the full URL form (`file://host/path`), which is rarely what you want.

### `pane:tab()` / `pane:window()` can be `nil`
A pane that's been closed (or is in a transient state during a teardown) returns `nil` from these. Always guard:

```lua
local tab = pane:tab()
if tab then tab:activate() end
```

### Method calls on stale panes raise
Once a pane is closed, calling methods on the captured Lua handle typically raises an error rather than returning `nil`. The action-callback pattern (re-fetch via `w:active_pane()`) is the safe shape. When you must use a stored pane, wrap with `pcall`:

```lua
local ok, text = pcall(pane.get_lines_as_text, pane, 50)
if not ok then return end
```

(See `claude.lua:79` — same pattern for `get_lines_as_text` since the pane may have closed between scans.)

### `window:active_pane()` races with focus changes
Inside an `InputSelector` action callback, the user may have switched panes between opening the modal and confirming a choice. The callback's `pane` argument is the *original* pane (closure-captured); `window:active_pane()` is *now*. They can disagree. termtools picks `active_pane() or p` to prefer current focus but survive a closed-original case — see `pickers/project.lua:221`.

### `window:gui_window()` returns `nil` from a mux-only context
A `wezterm.mux-startup` event runs before any GUI windows exist, and a tls-attached headless mux may have mux windows with no GUI counterpart. Guard before chaining:

```lua
local mw = tab:window()
if mw and mw.gui_window then
  local gui = mw:gui_window()
  if gui then ... end
end
```

The `mw.gui_window` test catches both "method exists" (a GUI Window has it as identity) and "not nil". Calling `gui_window()` on a GUI window is safe and returns itself, so this same guard works in either direction.

### `pane:split` direction vocabulary differs from `SplitPane`
`pane:split { direction = 'Top' }` — uses `Top`/`Bottom`/`Left`/`Right`.
`wezterm.action.SplitPane { direction = 'Up' }` — uses `Up`/`Down`/`Left`/`Right`.

`actions.lua` has a `split_direction` helper that translates. See [07-splits.md](07-splits.md).

### `send_text` newline semantics
A bare `\n` will be echoed as a literal newline by most shells (continuation), not executed. Use `\r` to submit a command. `pane:paste` handles bracketed paste so multi-line text works as expected.

### `tab_id` and `pane_id` are GUI-session-scoped
They reset on wezterm restart. Don't persist them to disk. Use them as keys in `wezterm.GLOBAL` (process-lifetime) but not in saved state files.

### `set_left_status` / `set_right_status` need formatted input
They expect a `wezterm.format { ... }` result, not a raw `wezterm.format` table. If you pass a table, you get a Lua error. termtools' `claude.lua:316` builds the format list, then the `update-right-status` event handler renders it once and calls `set_*_status` with the rendered string.

### `panes_with_info` index is 1-based, but `(left, top)` are 0-based pixel-cell coords
Mixing these up will silently give you an off-by-one in geometry math. The `index` is the 1-based table key into `tab:panes()`; `left`/`top` are cell offsets from the top-left of the tab.

## See also
- [05-mux-and-workspaces.md](05-mux-and-workspaces.md) — MuxWindow / MuxTab / MuxPane and `wezterm.mux.*` traversal.
- [07-splits.md](07-splits.md) — `pane:split` vs `SplitPane`, direction names.
- [11-pickers.md](11-pickers.md) — `InputSelector` callback shape, modal-time-vs-confirm-time pane races.
- [15-osc-and-clipboard.md](15-osc-and-clipboard.md) — OSC 7 (cwd reporting), OSC 133 (semantic zones), OSC 1337 (user vars).
- [18-procinfo-and-platform.md](18-procinfo-and-platform.md) — what `get_foreground_process_info` returns per OS, and where it returns nothing.
