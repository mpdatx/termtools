# 05 — Mux and Workspaces

`wezterm.mux` is the API into the multiplexer process — the thing that actually owns panes, tabs, and windows. The GUI is a *view* of the mux. Reach for this surface when you need to enumerate or create mux objects without going through the GUI's keymap, when you need to script workspaces, or when you want code that works headless.

## Overview

A WezTerm process has two cooperating halves (see [01-architecture.md](01-architecture.md)):

- The **GUI** renders, takes keyboard input, runs your event handlers.
- The **mux** owns PTYs and the object tree of windows → tabs → panes. It can run inside the GUI process (the default) or as a separate `wezterm-mux-server` daemon that the GUI connects to.

Splitting GUI from mux is what makes a few things possible:

- **Persistence across GUI restarts** — when the mux is daemonised, you can kill the GUI window, reopen it, and your panes are still there with their scrollback intact.
- **Multiple GUI clients** — two GUIs attached to one mux see the same tabs.
- **Headless mux servers** — `wezterm-mux-server` runs without any GUI; clients attach via TLS, Unix-domain socket, or SSH.

In termtools' default setup we run with the in-process mux. The TODO.md wishlist item to wire up `wezterm-mux-server` is what would unlock reload-vs-restart without losing long-running Claude sessions.

The `wezterm.mux.*` calls work the same in either mode: the API is to the mux, regardless of whether that mux is in your GUI process or across a socket.

## Key APIs

### `wezterm.mux` module

| Call | Returns | Notes |
| --- | --- | --- |
| `wezterm.mux.all_windows()` | array of `MuxWindow` | every live window across every workspace |
| `wezterm.mux.get_window(id)` | `MuxWindow` or nil | look up by integer id (the same id `GuiWindow:window_id()` returns) |
| `wezterm.mux.get_tab(id)` / `get_pane(id)` | `MuxTab` / `MuxPane` | by integer id |
| `wezterm.mux.spawn_window(cmd)` | `tab, pane, window` | creates window+tab+pane in one call. `cmd` is a `SpawnCommand` table — see [06-spawning.md](06-spawning.md) |
| `wezterm.mux.get_active_workspace()` | string | name of the workspace currently shown |
| `wezterm.mux.set_active_workspace(name)` | — | switches workspace; same effect as `act.SwitchToWorkspace` |
| `wezterm.mux.get_workspace_names()` | array of strings | every workspace that has at least one window |
| `wezterm.mux.rename_workspace(old, new)` | — | renames in place |
| `wezterm.mux.all_domains()` / `get_domain(id_or_name)` | `Domain` objects | mux/ssh/exec/local domains; see [16-domains.md](16-domains.md) |
| `wezterm.mux.set_default_domain(domain)` | — | what new spawns target by default |

Upstream rule of thumb: don't call any of the spawning functions at file scope. The config chunk re-runs on reload, so a top-level `mux.spawn_window` would produce a new window every reload. Use `gui-startup` or `mux-startup` events instead — see [10-events.md](10-events.md).

### `MuxWindow`

| Method | Returns |
| --- | --- |
| `:tabs()` | array of `MuxTab` |
| `:tabs_with_info()` | array of `{tab=MuxTab, is_active=bool, index=int}` |
| `:active_tab()` | `MuxTab` |
| `:active_pane()` | `MuxPane` |
| `:spawn_tab(cmd)` | `tab, pane, window` — adds a tab to *this* window |
| `:get_workspace()` / `:set_workspace(name)` | workspace is per-window |
| `:get_title()` / `:set_title(s)` | window title |
| `:gui_window()` | `GuiWindow` or **nil** if no GUI is attached |
| `:window_id()` | integer id |

### `MuxTab`

| Method | Returns |
| --- | --- |
| `:panes()` | array of `MuxPane` |
| `:panes_with_info()` | array of `{pane, is_active, is_zoomed, index, left, top, width, height, pixel_width, pixel_height}` — use this when you need pane geometry without doing math |
| `:active_pane()` | `MuxPane` |
| `:window()` | `MuxWindow` |
| `:get_title()` / `:set_title(s)` | tab title |
| `:tab_id()` | integer id |
| `:activate()` | makes this the active tab in its window |
| `:get_pane_direction(dir)` | `MuxPane` adjacent in `'Up' / 'Down' / 'Left' / 'Right'` |
| `:rotate_clockwise()` / `:rotate_counter_clockwise()` | reshuffle pane positions |
| `:set_zoomed(bool)` | toggle zoom |

### `MuxPane`

`MuxPane` and the GUI-side `Pane` share most of their methods — `get_current_working_dir`, `get_foreground_process_info`, `get_lines_as_text`, `inject_output`, `send_text`, `pane_id`, etc. Treat them as the same object for read/inspect purposes. See [04-pane-window-tab.md](04-pane-window-tab.md) for that whole surface.

The mux-only navigation methods are:

- `pane:tab()` → `MuxTab` containing this pane
- `pane:window()` → `MuxWindow` containing this pane

These let you walk *up* the tree from a pane handed to you by an event. Useful in `foreach_pane`-style loops where you only have the pane and need its tab id.

## Workspaces

A workspace is just a string label attached to a window. Every window belongs to exactly one workspace; the active workspace is the one the GUI is currently showing. Switching workspaces hides every window not in the new workspace.

Properties:

- **Per-window, not per-pane.** Moving a tab from one workspace to another moves the *window* the tab lives in (or you split the tab onto a window in the other workspace).
- **Created lazily.** A workspace exists as soon as a window is set to it; it disappears when the last window leaves. There's no separate "create workspace" call.
- **Default workspace** is the literal string `default` unless overridden in config.
- **Spawn-time selection.** `mux.spawn_window { workspace = 'foo', ... }` puts the new window straight into `foo` — and switches to `foo` if the spawn happened from a key binding.

Two ways to switch:

```lua
-- From a key binding (preferred):
{ key = 'p', mods = 'LEADER', action = wezterm.action.SwitchToWorkspace { name = 'claude' } },

-- From Lua at runtime:
wezterm.mux.set_active_workspace('claude')
```

`SwitchToWorkspace` with no `name` opens a picker prompting the user. With `name` set but no matching window, it creates the workspace and spawns into it.

## Examples

### Walk every pane in every window — `util.foreach_pane`

`lua/util.lua:180`:

```lua
function M.foreach_pane(fn, opts)
  opts = opts or {}
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if not ok_wt then return nil end

  local windows
  if opts.window then
    windows = { opts.window }
  else
    local ok, all = pcall(wezterm.mux.all_windows)
    if not ok then return nil end
    windows = all
  end

  for _, win in ipairs(windows) do
    for _, tab in ipairs(win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        local result = fn(pane, tab, win)
        if result ~= nil then return result end
      end
    end
  end
  return nil
end
```

The `pcall` around `mux.all_windows` is defensive — there are early-startup contexts (notably `gui-startup`) where `wezterm.mux` calls have raised. Returning a non-nil value from `fn` short-circuits the walk.

### Find a project's existing tab — `pickers/project.lua`

`lua/pickers/project.lua:66`:

```lua
local function find_existing_pane_in_window(window, root)
  if not window or not root then return nil, nil end
  local ok, mux_window = pcall(wezterm.mux.get_window, window:window_id())
  if not ok or not mux_window then return nil, nil end
  local found = util.foreach_pane(function(pane)
    local path = util.pane_cwd(pane)
    if path and util.is_inside(path, root) then return pane end
  end, { window = mux_window })
  if found then return found:tab(), found end
  return nil, nil
end
```

Note `pane:tab()` to walk back up. The GUI window's `:window_id()` is the same id `mux.get_window` takes — that's how you cross from GUI-side handlers into mux territory.

### Spawn a window in a specific workspace

```lua
wezterm.on('open-claude-here', function(window, pane)
  local cwd = util.pane_cwd(pane) or wezterm.home_dir
  wezterm.mux.spawn_window {
    workspace = 'claude',
    cwd = cwd,
    args = { 'claude' },
  }
  -- If you want the GUI to follow:
  wezterm.mux.set_active_workspace('claude')
end)
```

`spawn_window` returns `tab, pane, window` — useful if you want to immediately rename the tab or split additional panes off it.

### Cycle workspaces from a key binding

```lua
{ key = 'Tab', mods = 'LEADER', action = wezterm.action_callback(function(win, _pane)
    local names = wezterm.mux.get_workspace_names()
    table.sort(names)
    local current = wezterm.mux.get_active_workspace()
    for i, n in ipairs(names) do
      if n == current then
        wezterm.mux.set_active_workspace(names[(i % #names) + 1])
        return
      end
    end
  end),
},
```

### Count tabs whose CWD is under a project root

`lua/pickers/project.lua:80` — same `foreach_pane` pattern, accumulating into a set keyed by `tab:tab_id()`:

```lua
util.foreach_pane(function(pane, tab)
  local cwd = util.pane_cwd(pane)
  if not cwd then return end
  for _, root in ipairs(roots_list) do
    if util.is_inside(cwd, root) then
      seen_tabs[root] = seen_tabs[root] or {}
      seen_tabs[root][tab:tab_id()] = true
      break
    end
  end
end)
```

Tab and pane ids are stable for the lifetime of the object, safe to use as table keys.

## Gotchas

- **Mux server vs in-process mux.** Out of the box the mux runs inside the GUI process — `wezterm.mux.*` operates on it but state dies when the GUI exits. To get persistence across GUI restarts you need `wezterm-mux-server` daemonised, plus a unix/tls domain in config, plus spawns routed through that domain. See [16-domains.md](16-domains.md). termtools' TODO.md tracks this as a wishlist item.
- **`MuxWindow:gui_window()` returns nil in headless mux mode.** If your code might run in a `wezterm-mux-server` (or in `mux-startup` before any GUI attaches), guard the result. Anything that needs to call `:perform_action`, `:toast_notification`, etc., is a GUI-only operation.
- **`wezterm.mux` is fragile in `gui-startup`.** During the very early window/workspace bring-up, some mux calls raise. Wrap with `pcall` or move work into a slightly later event (`window-config-reloaded` is reliably late enough).
- **Don't spawn at file scope.** `mux.spawn_window` at the top of your config chunk fires every reload. Use `gui-startup` / `mux-startup` events; those fire once per process.
- **Workspace is per-window.** Moving a *tab* between workspaces means moving its enclosing window, or detaching the tab to a fresh window in the other workspace. There's no `tab:set_workspace`.
- **Workspaces vanish when empty.** Closing the last window in workspace `foo` removes `foo` from `get_workspace_names()`. If you want sticky workspaces, keep at least one window pinned.
- **Mux ids are not GUI ids in every case.** The window id is shared between mux and GUI. Tab id and pane id are mux-side ids that the GUI honours, but `GuiWindow:window_id()` is what you pass to `mux.get_window`. Keep that one mapping straight and the rest follows.
- **`spawn_window` ignores keybinding context.** When you spawn from `action_callback`, the new window doesn't inherit the calling tab's CWD — pass `cwd = ...` explicitly. `util.pane_cwd(pane)` (see [04-pane-window-tab.md](04-pane-window-tab.md)) is the resolver we use.

## See also

- [04-pane-window-tab.md](04-pane-window-tab.md) — the GUI-side trio, plus pane methods shared with `MuxPane`.
- [06-spawning.md](06-spawning.md) — `SpawnCommand` shape, `spawn_tab` / `spawn_window` / `SpawnCommandInNewTab`.
- [10-events.md](10-events.md) — `gui-startup` vs `mux-startup`, when each fires, what to put in which.
- [16-domains.md](16-domains.md) — mux-server, unix/tls/ssh domains, daemonised persistence.
