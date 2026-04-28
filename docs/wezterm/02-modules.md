# 02 — `wezterm.*` module catalogue

A skim-friendly index of the `wezterm` Lua surface. Each submodule has a one-line purpose, then its top functions one-per-line. Full signatures live upstream — the headings link to the canonical index for each module.

## Overview

The Lua API ships as the global `wezterm` table plus a handful of submodules. Roughly:

| Submodule | Purpose | When to reach for it |
| --------- | ------- | -------------------- |
| `wezterm` | Top-level utilities, actions, events, logging, child processes | Anywhere — almost every config touches this |
| `wezterm.mux` | Multiplexer state: windows, tabs, panes, workspaces, domains | Workspace switching, headless tab spawning, MuxWindow access |
| `wezterm.gui` | GUI-only queries: open windows, screens, system appearance, default keys | UI logic that needs the front-end (light/dark, multi-monitor) |
| `wezterm.color` | Color parsing, scheme loading, and Color-object math | Tab-bar tinting, scheme synthesis, contrast checks |
| `wezterm.time` | Current time, scheduled callbacks, RFC3339 parsing | Polling, debounce, anything time-stamped |
| `wezterm.serde` | JSON / TOML / YAML encode + decode | Reading sidecar configs, talking to CLIs that emit JSON |
| `wezterm.procinfo` | Process tree introspection by PID | "What is this pane actually running?" without OSC 7 |
| `wezterm.url` | URL parser | Hyperlink rules, OSC 8 handling |
| `wezterm.plugin` | Plugin discovery / install / update | Vendoring third-party Lua via wezterm's plugin loader |

Two things are worth flagging before the per-module breakdown:

- **GUI vs mux split.** `wezterm.gui` only works in a real GUI process; `wezterm.mux` works in both GUI and headless `wezterm-mux-server`. See [01-architecture.md](01-architecture.md).
- **`wezterm` vs `wezterm.serde` overlap.** Both expose `json_encode` / `json_parse`-style helpers. The `serde` versions are newer, support TOML and YAML too, and are the ones to prefer in new code. termtools' `lua/wt.lua` already does the fallback dance.

---

## Key APIs

### `wezterm` (top-level) — [docs](https://wezterm.org/config/lua/wezterm/index.html)

The everything-else module: utilities, the action constructor, event registration, logging, child-process helpers, the `GLOBAL` state bag, the config builder, and font helpers.

- `wezterm.home_dir` — string field, the user's home directory (cross-platform).
- `wezterm.config_dir` — string field, the directory `wezterm.lua` was loaded from.
- `wezterm.target_triple` — string field, e.g. `x86_64-pc-windows-msvc` or `aarch64-apple-darwin`.
- `wezterm.hostname()` — system hostname, useful for per-host config branches.
- `wezterm.format(elements)` — render a list of `{ Foreground=..., Text=... }` entries to a styled string for tab bars, status, and `InputSelector` labels.
- `wezterm.action.<Name> { ... }` — construct a `KeyAssignment`. See [08-actions-and-keys.md](08-actions-and-keys.md).
- `wezterm.action_callback(fn)` — wrap a Lua function as a key/mouse action; receives `(window, pane, ...)`.
- `wezterm.on(event, handler)` — register a handler for built-in or custom events; multiple handlers stack.
- `wezterm.emit(event, ...)` — fire a custom event synchronously.
- `wezterm.has_action(name)` — reflective check for whether an action constructor exists.
- `wezterm.GLOBAL` — process-wide table that survives config reload; the only sanctioned place to keep runtime state. See [12-state-and-timing.md](12-state-and-timing.md).
- `wezterm.log_info / log_warn / log_error(msg)` — write to wezterm's debug log; see [19-io-and-logging.md](19-io-and-logging.md) for log location.
- `wezterm.read_dir(path)` — list directory entries as full paths (returns a Lua array). WezTerm-only; not in standalone Lua.
- `wezterm.glob(pattern, [cwd])` — expand a glob to a list of paths.
- `wezterm.run_child_process(argv)` — synchronous spawn; returns `(success, stdout, stderr)`. **Blocks the GUI thread** — see Gotchas.
- `wezterm.background_child_process(argv)` — fire-and-forget spawn, no output capture.
- `wezterm.config_builder()` — returns a config table proxy that errors on misspelled keys. Always prefer this over a bare table.
- `wezterm.font(family, [attrs])` — single-family font spec.
- `wezterm.font_with_fallback(list)` — ordered fallback list for glyph coverage.
- `wezterm.json_encode(value)` / `wezterm.json_parse(s)` — legacy JSON helpers; prefer `wezterm.serde.*` in new code.
- `wezterm.strftime(fmt)` — local-time strftime wrapper.
- `wezterm.sleep_ms(ms)` — synchronous sleep; like `run_child_process`, blocks the GUI.

### `wezterm.mux` — [docs](https://wezterm.org/config/lua/wezterm.mux/index.html)

Multiplexer-side handles for windows, tabs, panes, workspaces, and domains. Works headlessly. See [05-mux-and-workspaces.md](05-mux-and-workspaces.md) for object shapes.

- `wezterm.mux.all_windows()` — list of every `MuxWindow`.
- `wezterm.mux.get_window(id)` — fetch a `MuxWindow` by ID (the same ID `Window:window_id()` returns).
- `wezterm.mux.get_tab(id)` — fetch a `MuxTab` by ID.
- `wezterm.mux.get_pane(id)` — fetch a `MuxPane` (or `Pane`) by ID.
- `wezterm.mux.spawn_window(opts)` — open a new window/tab/pane in a chosen domain + workspace. Returns `(tab, pane, window)`.
- `wezterm.mux.get_active_workspace()` — current workspace name.
- `wezterm.mux.set_active_workspace(name)` — switch workspaces (creates implicitly if needed).
- `wezterm.mux.get_workspace_names()` — array of all known workspace names.
- `wezterm.mux.rename_workspace(old, new)` — rename in place.
- `wezterm.mux.all_domains()` — every registered `MuxDomain`.
- `wezterm.mux.get_domain([name_or_id])` — specific domain; nil arg returns the default.
- `wezterm.mux.set_default_domain(domain)` — change which domain new spawns use by default.

### `wezterm.gui` — [docs](https://wezterm.org/config/lua/wezterm.gui/index.html)

GUI-only queries. Calling these from `wezterm-mux-server` or before the GUI has started will fail.

- `wezterm.gui.gui_windows()` — every open `Window` object.
- `wezterm.gui.gui_window_for_mux_window(mux_window)` — bridge from mux to GUI side.
- `wezterm.gui.screens()` — connected monitors with bounds, scale, and DPI.
- `wezterm.gui.get_appearance()` — `"Light"` / `"Dark"` / `"LightHighContrast"` / `"DarkHighContrast"`.
- `wezterm.gui.default_keys()` — the built-in key table; useful as a base when overriding.
- `wezterm.gui.default_key_tables()` — the built-in named key tables (e.g. `copy_mode`, `search_mode`).
- `wezterm.gui.enumerate_gpus()` — available GPU adapters; pair with `webgpu_preferred_adapter`.

### `wezterm.color` — [docs](https://wezterm.org/config/lua/wezterm.color/index.html)

Color parsing and the `Color` object's math operators. See [13-format-and-colors.md](13-format-and-colors.md) for usage.

- `wezterm.color.parse(s)` — accept any CSS-ish color string and return a `Color`.
- `wezterm.color.from_hsla(h, s, l, a)` — build a `Color` from HSLA components.
- `wezterm.color.gradient(spec, n)` — interpolate `n` colors along a gradient.
- `wezterm.color.get_default_colors()` — the active scheme's color table.
- `wezterm.color.get_builtin_schemes()` — name → scheme map for everything bundled.
- `wezterm.color.load_scheme(path)` / `load_base16_scheme(path)` / `load_terminal_sexy_scheme(path)` — import external schemes.
- `wezterm.color.save_scheme(scheme, name, path)` — write a scheme out to disk.
- `wezterm.color.extract_colors_from_image(path)` — sample dominant colors from an image.

`Color` object methods (chainable, all return new `Color`s):

- `:lighten(f)` / `:darken(f)` / `:lighten_fixed(f)` / `:darken_fixed(f)` — luminance shifts.
- `:saturate(f)` / `:desaturate(f)` / `:saturate_fixed(f)` / `:desaturate_fixed(f)` — saturation shifts.
- `:adjust_hue_fixed(deg)` / `:adjust_hue_fixed_ryb(deg)` — hue rotation.
- `:complement()` / `:complement_ryb()` / `:triad()` / `:square()` — harmony helpers.
- `:contrast_ratio(other)` / `:delta_e(other)` — perceptual comparisons.
- `:hsla()` / `:laba()` / `:linear_rgba()` / `:srgb_u8()` — export to component tuples.

### `wezterm.time` — [docs](https://wezterm.org/config/lua/wezterm.time/index.html)

Time + scheduled callbacks. The async `call_after` is the only sanctioned way to "do X later" without blocking.

- `wezterm.time.now()` — current `Time` object.
- `wezterm.time.parse(s, fmt)` — parse with a strftime-style format.
- `wezterm.time.parse_rfc3339(s)` — parse RFC3339 (ISO-8601 subset).
- `wezterm.time.call_after(seconds, fn)` — fire `fn` after a delay; non-blocking; supports sub-second floats.

`Time` object methods:

- `:format(fmt)` — strftime-style format in local TZ.
- `:format_utc(fmt)` — same, but UTC.
- `:sun_times(lat, lon)` — sunrise/sunset for a location.

### `wezterm.serde` — [docs](https://wezterm.org/config/lua/wezterm.serde/index.html)

Structured-data codec set. Prefer this over the legacy `wezterm.json_*` aliases.

- `wezterm.serde.json_encode(v)` / `json_encode_pretty(v)` — Lua → JSON string.
- `wezterm.serde.json_decode(s)` — JSON string → Lua.
- `wezterm.serde.toml_encode(v)` / `toml_encode_pretty(v)` — Lua → TOML.
- `wezterm.serde.toml_decode(s)` — TOML → Lua.
- `wezterm.serde.yaml_encode(v)` — Lua → YAML.
- `wezterm.serde.yaml_decode(s)` — YAML → Lua.

### `wezterm.procinfo` — [docs](https://wezterm.org/config/lua/wezterm.procinfo/index.html)

Process introspection by PID. The deeper alternative to `pane:get_foreground_process_name()` when you need the whole process tree (parent, children, env, argv). See [18-procinfo-and-platform.md](18-procinfo-and-platform.md).

- `wezterm.procinfo.pid()` — PID of the wezterm process itself.
- `wezterm.procinfo.current_working_dir_for_pid(pid)` — best-effort CWD for any PID.
- `wezterm.procinfo.executable_path_for_pid(pid)` — absolute path to the binary.
- `wezterm.procinfo.get_info_for_pid(pid)` — full `LocalProcessInfo` (name, argv, executable, CWD, children, parent).

### `wezterm.url` — [docs](https://wezterm.org/config/lua/wezterm.url/index.html)

Tiny module — one constructor, then a `Url` object with the usual URL fields.

- `wezterm.url.parse(s)` — return a `Url` with `scheme` / `host` / `path` / `query` / `fragment` / `username` / `password` / `port`.

### `wezterm.plugin` — [docs](https://wezterm.org/config/lua/wezterm.plugin/index.html)

Lightweight plugin loader. Clones git repos into wezterm's runtime dir and `require`s them.

- `wezterm.plugin.require(url)` — install (if missing) and load a plugin from a git URL; returns its module table.
- `wezterm.plugin.list()` — currently installed plugins.
- `wezterm.plugin.update_all()` — `git pull` everything.

---

## Examples

```lua
-- Top-level: actions, callbacks, events, GLOBAL.
-- lua/actions.lua:147 builds an InputSelector with action_callback and persists the
-- choice in wezterm.GLOBAL so it survives config reload.
wezterm.action.InputSelector {
  title = title,
  choices = choices,
  action = wezterm.action_callback(function(w, _p, id, _label)
    wezterm.GLOBAL = wezterm.GLOBAL or {}
    wezterm.GLOBAL[global_key] = chosen_name
  end),
}
```

```lua
-- Top-level: log_warn for diagnostics that should reach the wezterm log
-- without disturbing the GUI. lua/claude.lua:82 logs pane-read failures.
wezterm.log_warn('termtools.claude: get_lines_as_text failed for pane ' .. id)
```

```lua
-- Top-level: read_dir is the cross-platform way to enumerate a directory
-- without shelling out. lua/projects.lua:30 uses it to walk scan_roots.
local ok, entries = pcall(wezterm.read_dir, dir)
for _, full in ipairs(entries) do
  local name = full:match('([^/\\]+)$') or full
  -- ...
end
```

```lua
-- Top-level: target_triple for OS dispatch. lua/platform.lua:9.
local triple = wezterm.target_triple or ''
if triple:find('windows') then ... end
```

```lua
-- Top-level: background_child_process for fire-and-forget GUI launches.
-- lua/actions.lua:52 — spawning an external editor without blocking.
local ok, err = pcall(wezterm.background_child_process, args)
```

```lua
-- Top-level: run_child_process when you need stdout. Use sparingly — synchronous.
-- lua/platform/darwin.lua:58 resolves a program name via the login shell's PATH.
local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
```

```lua
-- mux: bridge from a GUI Window to a MuxWindow for workspace ops.
-- lua/pickers/project.lua:68.
local ok, mux_window = pcall(wezterm.mux.get_window, window:window_id())
```

```lua
-- mux: enumerate windows from anywhere (e.g. inside an event with no pane handle).
-- lua/util.lua:189.
local ok, all = pcall(wezterm.mux.all_windows)
```

```lua
-- serde: prefer the new module, fall back to the legacy alias for older wezterm.
-- lua/wt.lua:78.
if wezterm.serde and wezterm.serde.json_decode then
  return wezterm.serde.json_decode(s)
end
if wezterm.json_parse then return wezterm.json_parse(s) end
```

```lua
-- procinfo: walk a pane's process tree.
local pid = pane:get_foreground_process_info().pid
local info = wezterm.procinfo.get_info_for_pid(pid)
for _, child in pairs(info.children or {}) do
  print(child.name, child.executable)
end
```

```lua
-- color: synthesize a tinted accent from the active scheme.
local base = wezterm.color.parse(scheme.background)
local accent = base:lighten(0.15):saturate(0.2)
```

```lua
-- time: schedule a non-blocking callback (no GUI freeze).
wezterm.time.call_after(0.5, function() window:perform_action(act, pane) end)
```

---

## Gotchas

- **`wezterm.run_child_process` is synchronous and blocks the GUI thread.** A child that itself launches `wezterm` (think `wezterm cli`, or a font-probe that spawns a helper that re-enters wezterm) can deadlock or recurse. We hit exactly this in commit `890bf16` (a font-fallback probe that locked up the GUI) and reverted in `620a92e`. If you only need to fire a command, use `background_child_process`. If you need stdout, prefer running it once at startup or behind `time.call_after` rather than on every keypress.
- **`background_child_process` discards stdout/stderr and the exit code.** Failures are silent unless the OS itself rejects the spawn. Wrap in `pcall` if you want even the spawn-time error: `lua/actions.lua:52`.
- **`wezterm.read_dir` only exists in WezTerm's Lua runtime.** Standalone `lua` / `luajit` won't have it. Always `pcall(require, 'wezterm')` and feature-gate, the way `lua/projects.lua` and `lua/util.lua` do, if the module needs to be unit-testable outside wezterm.
- **`wezterm.json_parse` / `wezterm.json_encode` are legacy aliases.** They predate the `serde` submodule. New code should call `wezterm.serde.json_decode` directly; only fall back to the legacy names for compatibility with very old wezterm builds (see `lua/wt.lua:78`).
- **`wezterm.gui.*` is unavailable in `wezterm-mux-server`.** If your code might run headlessly (a multiplexer event handler, a daemonized mux), gate GUI calls with `pcall` or check for the module's existence.
- **`wezterm.GLOBAL` is process-wide, not config-wide.** It survives config reload but not a wezterm restart, and it's shared across all configs the process loads. Namespace your keys (e.g. `termtools_editor_default`) — the table is global state in every sense.
- **`wezterm.sleep_ms` blocks like `run_child_process`.** Use `wezterm.time.call_after` for any meaningful delay. `sleep_ms` is fine in startup-only paths where blocking is acceptable.
- **`wezterm.target_triple` strings differ subtly across platforms** — `x86_64-pc-windows-msvc`, `x86_64-apple-darwin`, `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`. Match on substrings (`windows`, `darwin`, `linux`), not equality.

---

## See also

- [01-architecture.md](01-architecture.md) — where each module is allowed to run (GUI vs mux process).
- [03-config.md](03-config.md) — `wezterm.config_builder` and the config object lifecycle.
- [05-mux-and-workspaces.md](05-mux-and-workspaces.md) — deep-dive on `wezterm.mux` and the Mux* object family.
- [06-spawning.md](06-spawning.md) — `SpawnCommand`, `mux.spawn_window`, `background_child_process` vs `run_child_process` head-to-head.
- [08-actions-and-keys.md](08-actions-and-keys.md) — `wezterm.action`, `action_callback`, and the `KeyAssignment` taxonomy.
- [10-events.md](10-events.md) — `wezterm.on` and `wezterm.emit` in depth.
- [12-state-and-timing.md](12-state-and-timing.md) — `wezterm.GLOBAL`, `time.call_after`, sync vs async child processes.
- [13-format-and-colors.md](13-format-and-colors.md) — `wezterm.format` and the `wezterm.color` Color-object math.
- [18-procinfo-and-platform.md](18-procinfo-and-platform.md) — `wezterm.procinfo`, `target_triple`, `home_dir`, OS quirks.
- [19-io-and-logging.md](19-io-and-logging.md) — `read_dir`, `log_*`, `run_child_process` and where the log file lives.
