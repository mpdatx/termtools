# 12 — State and timing

How to keep state across config reloads, where on disk WezTerm reads from, and how to "do work later" without freezing the GUI. Three small surfaces with a few sharp edges — the most-used is `wezterm.GLOBAL`, the most-misused is `wezterm.run_child_process`.

## Overview

The config chunk re-runs on every reload (see [01-architecture.md](01-architecture.md)). Anything you computed last time is gone unless you stashed it somewhere that survives. WezTerm gives you three tiers:

- **`wezterm.GLOBAL`** — a process-wide Lua table. Survives config reload; lost on WezTerm restart. The sanctioned place for "user toggled this at runtime, remember it until they quit".
- **`package.loaded.<module>` upvalues** — module-level locals retain their values across reloads because `require` caches the module. Same lifetime as `GLOBAL` in practice (tied to the process), but scoped to one Lua module rather than process-wide.
- **Files on disk** — under `wezterm.config_dir`, `wezterm.home_dir`, or wherever you want. The only tier that survives a restart.

Timing is constrained by WezTerm being **single-threaded for Lua**: the GUI thread runs your handlers, and anything that blocks it freezes the window. The two "do work later" primitives are `wezterm.time.call_after(seconds, fn)` (non-blocking, fires on the GUI thread) and `wezterm.background_child_process(argv)` (fire-and-forget OS subprocess, doesn't block). Sleeping (`wezterm.sleep_ms`) and synchronous child-process spawn (`wezterm.run_child_process`) both block the GUI and should almost never appear in an event handler.

## Key APIs

### State persistence

- `wezterm.GLOBAL` — a regular Lua table that the runtime preserves across config reloads. Keys are arbitrary; idiomatic style is to namespace them (`termtools_editor_default`, not `editor_default`) because every config in the process sees the same table.
- `wezterm.config_dir` — string, the directory the config file was loaded from. Typically `~/.config/wezterm` on Unix or `%USERPROFILE%/.config/wezterm` on Windows. Read-only.
- `wezterm.config_file` — string, full path to the resolved config file (post-`--config-file` override). Read-only.
- `wezterm.home_dir` — string, the user's home directory. Cross-platform — gives `C:\Users\name` on Windows, `/Users/name` on macOS, `/home/name` on Linux. Prefer this over `os.getenv('HOME')` (Windows doesn't set `HOME` reliably).

Sidecar persistence to disk is unsupported as a built-in: write your own with `wezterm.serde.json_encode` (or TOML/YAML) plus `io.open(path, 'w')`. There's no atomic-write helper — use a write-temp-then-rename pattern if simultaneous edits matter.

### Timing

- `wezterm.time.now()` — returns a `Time` userdata for "now". Methods: `:format(fmt)` (local-TZ strftime), `:format_utc(fmt)` (UTC strftime), `:sun_times(lat, lon)` (sunrise/sunset for a coordinate). For raw epoch seconds, `os.time()` (standard Lua) is simpler.
- `wezterm.time.call_after(seconds, fn)` — fires `fn` after `seconds` (float, sub-second OK). Non-blocking, fires on the GUI thread, returns nothing — there is no cancellation handle. The only sanctioned way to defer work.
- `wezterm.sleep_ms(ms)` — synchronous sleep. **Blocks the GUI thread.** Documented as "use only at config-eval time", and even there it's discouraged. Almost never the right answer.

### Child processes

- `wezterm.run_child_process(argv)` — synchronous spawn. Returns `(success, stdout, stderr)`. **Blocks the GUI thread for the full duration.** Safe at config-eval time only if the child cannot itself launch wezterm (see the lockup story under Gotchas). Avoid in event handlers.
- `wezterm.background_child_process(argv)` — fire-and-forget. Returns immediately. No stdout, stderr, or exit code is exposed — failures are silent unless the OS rejects the spawn synchronously. Right answer for "open this GUI editor".

Both are covered in more depth in [06-spawning.md](06-spawning.md), which has the lockup story.

## Examples

### `wezterm.GLOBAL` — runtime editor switching

`lua/actions.lua:155` — the `pick_editor_modal` callback writes the user's choice into `GLOBAL` so the next call to `editor_spec` sees it. Note the namespacing (`termtools_editor_*`) and the explicit-`false` sentinel for "disabled" (distinct from `nil` meaning "fall back to config"):

```lua
action = wezterm.action_callback(function(w, _p, id, _label)
  if not id then return end
  local entry = entries[tonumber(id)]
  if not entry then return end
  wezterm.GLOBAL = wezterm.GLOBAL or {}        -- defensive init
  if allow_disable and entry.name == nil then
    wezterm.GLOBAL[global_key] = false         -- explicit disable
  else
    wezterm.GLOBAL[global_key] = entry.name    -- chosen registry name
  end
end),
```

`lua/util.lua:141` — the read side, in `editor_spec`. Live-reads `GLOBAL` at every dispatch (not at handler-registration time) so the override takes effect immediately:

```lua
function M.editor_spec(role, opts)
  -- ...
  local ok_wt, wezterm = pcall(require, 'wezterm')
  local global = (ok_wt and wezterm.GLOBAL) or {}
  local override = global['termtools_editor_' .. role]

  if override == false then return nil end           -- explicit disable
  local name = override or editors[role]
  if name and registry[name] then return registry[name] end
  return nil
end
```

The pattern is: **defensive init on write** (`GLOBAL = GLOBAL or {}`), **defensive read on read** (`(GLOBAL or {})[key]`). Don't assume the table exists — until *some* code path writes to it, it's the literal value `nil`.

### `wezterm.GLOBAL` — MRU and sort cycling

`lua/pickers/project.lua:24` — same pattern, scoped to a small helper so the rest of the module reads/writes ordinary Lua tables:

```lua
local function global_table()
  wezterm.GLOBAL = wezterm.GLOBAL or {}
  return wezterm.GLOBAL
end

local function mru_get()
  return global_table().termtools_project_mru or {}
end

local function mru_push(path)
  if not path or path == '' then return end
  local mru = mru_get()
  local out = { path }
  for _, p in ipairs(mru) do
    if p ~= path and #out < MRU_CAP then out[#out + 1] = p end
  end
  global_table().termtools_project_mru = out
end
```

Two project-relevant runtime states live here: `termtools_project_mru` (recently-opened-project list) and `termtools_project_sort` (cycle through smart/alphabetical/mru). Both survive reload; both reset on full restart. The header comment at `lua/pickers/project.lua:18` flags disk persistence as a TODO.

### `time.call_after` — schedule a deferred dispatch

The non-blocking deferral primitive. Example shape (not currently used in termtools — we route through `pane:split` for the InputSelector→split race per [07-splits.md](07-splits.md), but `call_after` is the alternative):

```lua
-- Dispatch SplitPane after the current InputSelector has fully closed,
-- so the action queue is empty by the time SplitPane runs.
wezterm.time.call_after(0.05, function()
  -- Capture window/pane in the enclosing closure.
  -- pcall because the pane may have been closed in the meantime.
  pcall(function()
    window:perform_action(act.SplitPane { ... }, pane)
  end)
end)
```

Two things to know:

1. **No cancellation handle.** If you need to cancel, set a guard variable and have the callback bail out:
   ```lua
   local stale_token = false
   wezterm.time.call_after(2.0, function()
     if stale_token then return end
     -- ... real work
   end)
   -- elsewhere: stale_token = true to cancel
   ```
2. **`window` and `pane` may be invalid by the time the callback fires.** The user might have closed the pane or the window during the delay. Always wrap method calls on captured handles in `pcall`.

### `run_child_process` — probing at startup, not on every event

`lua/platform/darwin.lua:58` — the macOS PATH-resolution shim. Synchronous child spawn, but called **once at `setup()` time** so the cost is bounded:

```lua
function M.resolve_argv(args)
  if not args or #args == 0 then return args end
  local prog = args[1]
  if prog:sub(1, 1) == '/' then return args end
  local wezterm = require('wezterm')
  local shell = os.getenv('SHELL') or '/bin/zsh'
  local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
  if not ok or not stdout then return args end
  -- ...
end
```

The header comment at `lua/platform/darwin.lua:48` explicitly flags this: "Doing the lookup once at setup time keeps spawns direct (no shell middleman per pane)". The result is cached in module state. Never call `run_child_process` from a per-keypress handler — see Gotchas.

A "is `gh` installed" probe would look the same:

```lua
-- At setup time, not in an event handler.
local has_gh = (function()
  local ok, stdout = wezterm.run_child_process({ 'gh', '--version' })
  return ok and stdout and stdout:match('^gh version')
end)()
```

### Sidecar JSON — read at config-eval, merge over user opts

Sketched in `TODO.md:5` for a future settings UI; the file isn't written yet, but the shape is straightforward:

```lua
-- In setup() or apply()
local function read_sidecar()
  local path = wezterm.home_dir .. '/.config/termtools/settings.json'
  local f = io.open(path, 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  local ok, decoded = pcall(wezterm.serde.json_decode, content)
  return ok and decoded or {}
end

-- Sidecar wins over inline opts (it's the "live edited" surface).
local merged = util.merge_defaults(user_opts, read_sidecar())
```

Writing back is plain `io.open(path, 'w')` plus `wezterm.serde.json_encode_pretty(table)`. For safety against simultaneous edits, write to `path .. '.tmp'` first then `os.rename` over the original — there is no built-in atomic-write helper.

## Gotchas

- **`wezterm.GLOBAL` survives reload, not restart.** It's process-memory, period. Anything you can't reconstruct from disk must be re-derivable, or you'll lose it the first time the user closes WezTerm. The header comment in `lua/pickers/project.lua:18` makes this explicit and flags disk persistence as TODO.
- **`wezterm.GLOBAL` is per-mux-process, not per-window.** Every config the process loads sees the same table. Namespace your keys (`termtools_editor_default`, not `editor_default`) so you don't collide with an unrelated config or plugin. A fresh GUI attaching to an already-running mux server inherits the mux's `GLOBAL`; a brand-new mux start does not.
- **No cancellation handle for `call_after`.** Once scheduled, the callback will fire. Use a guard variable that the callback checks at fire time — there is no `cancel(token)` API.
- **`call_after` doesn't carry window/pane.** You must capture them in the closure. By the time the callback fires, the captured pane may have closed and the window may have been destroyed. Always `pcall` the handle methods inside the callback; never crash a deferred handler.
- **`call_after` fires on the GUI thread.** Long work in the callback freezes the UI exactly like a synchronous handler. Same constraint as event handlers ([10-events.md](10-events.md)) — keep the body small, use `background_child_process` for slow work.
- **`run_child_process` blocks the GUI thread for the entire duration of the child.** Lockup story: commit `890bf16` shelled out to `wezterm ls-fonts --list-system` from inside config eval to filter out unavailable font families. Two failure modes compounded: the synchronous spawn froze the GUI, and the child wezterm process re-evaluated the user's `wezterm.lua` on launch — which itself called `run_child_process` again. Fork bomb on the GUI thread, locked up Windows and macOS instances. Reverted in `620a92e`. `TODO.md:3` documents the rule: never call `run_child_process` from a path that runs on every config reload, and never let the child re-enter wezterm without `--skip-config`. See [06-spawning.md](06-spawning.md) for the longer write-up.
- **`background_child_process` discards everything.** No stdout, no stderr, no exit code. Spawn-time errors *may* throw on some platforms; `pcall` around it as `lua/actions.lua:52` does if you want even the spawn-time signal.
- **`sleep_ms` is almost never the answer.** It blocks the GUI thread. If you want a delay, use `call_after`. If you want slow work, use `background_child_process`. The only legitimate use is at config-eval time where blocking is acceptable, and even there it's a code smell.
- **`config_dir` may not exist as a directory** on a fresh install. WezTerm creates it on first use, but if you write a sidecar there at config-eval time on a brand-new system, `io.open(path, 'w')` may fail because the parent directory doesn't exist yet. Either `mkdir -p` it first (via `wezterm.background_child_process` at startup) or fall back gracefully on write failure.
- **No atomic-write helper.** `io.open(path, 'w')` truncates immediately, so a crash mid-write leaves an empty or half-written file. Write to `path .. '.tmp'`, close, then `os.rename` — `rename` is atomic on the same filesystem on every platform WezTerm runs on.
- **`Time` userdata vs raw epoch seconds.** `wezterm.time.now()` returns a `Time` object that has `:format()` but doesn't compare with `<` to an integer. For "current epoch seconds for arithmetic", use `os.time()` (plain Lua) or `tonumber(wezterm.time.now():format('%s'))`. For human-readable timestamps, the `Time` API's `:format('%Y-%m-%d %H:%M:%S')` is the right call.
- **Module-level upvalues survive reload but not restart**, same as `GLOBAL`. The mechanism is different — `package.loaded.<module>` is sticky, so re-`require`ing the module returns the same table — but the lifetime is the same. Use upvalues for module-private state, `GLOBAL` for cross-module or cross-config-reload state.

## See also

- [01-architecture.md](01-architecture.md) — config evaluation lifecycle, why state has to opt into surviving reloads, the `package.loaded` mechanism.
- [02-modules.md](02-modules.md) — the `wezterm.*` surface where `GLOBAL`, `time.*`, and the child-process helpers live.
- [06-spawning.md](06-spawning.md) — `run_child_process` vs `background_child_process` head-to-head, the `890bf16` lockup story in full.
- [10-events.md](10-events.md) — handler doubling on reload (the same "module-level guard flag" pattern as `GLOBAL` namespacing).
- [11-pickers.md](11-pickers.md) — where `GLOBAL` is read on each picker open (the project picker reads its sort mode and MRU live).
- [17-palette.md](17-palette.md) — `augment-command-palette` callbacks read live `GLOBAL` state when building entry descriptions.
