# 01 — Architecture

The 30,000-foot view: where Lua runs in WezTerm, what evaluates when, and why config code has to be idempotent.

## Overview

WezTerm splits into two cooperating components:

- **GUI process** — the window you see. Renders, handles input, runs your Lua. One per WezTerm window-set on a machine, but they can share a mux.
- **Multiplexer (mux)** — owns the panes, tabs, and PTYs. Survives the GUI exiting; can be local, SSH, TLS, or Unix-domain remote.

Your config file (`~/.wezterm.lua` or `~/.config/wezterm/wezterm.lua`) is a Lua chunk that **returns a config table**. WezTerm evaluates it on launch, on every reload, and potentially multiple times per process. Treat it like a pure function: same inputs in, same config table out, no side effects on the way through.

The reason this matters: anything you do at top level — spawning a child process, writing a file, pushing to a list — happens *every reload*. Anything inside a `wezterm.on(...)` handler runs at dispatch time, but the registration itself runs every reload too.

## Key concepts

### Config evaluation lifecycle

- WezTerm watches the config file and reloads on change. `CTRL+SHIFT+R` forces a reload.
- The chunk is evaluated **multiple times per process**: at startup, on reload, and when new windows attach.
- The returned table replaces the live config. Most keys take effect immediately; a few (font system, GPU backend) need a full restart.
- `--config k=v` CLI overrides win over the file even after reload.

### GUI vs mux

| | Lives in | Survives | Examples |
| --- | --- | --- | --- |
| GUI events | GUI process | until window closes | `gui-startup`, `format-tab-title`, key/mouse bindings |
| Mux events | mux process | until mux exits | `mux-startup`, pane spawn/exit |
| Config file | GUI process | re-evaluated on reload | the whole chunk |

Lua callbacks (event handlers, `action_callback`, key tables) execute in the GUI process and reach the mux through `wezterm.mux.*`. See [02-modules.md](02-modules.md) for the module split.

### Where state lives between reloads

| Storage | Survives reload? | Survives WezTerm restart? |
| --- | --- | --- |
| Local Lua values, upvalues | no — chunk re-runs | no |
| Module-level vars (`local foo` at top of a `require`d file) | yes — `package.loaded` is sticky | no |
| `wezterm.GLOBAL` | yes | no |
| Files on disk (`config_dir`, OS temp) | yes | yes |
| Mux process (panes, workspaces) | yes | only if mux daemonised |

Detail in [12-state-and-timing.md](12-state-and-timing.md). The headline: `package.loaded` caches a `require`'d module across reloads, so module-level `local handlers_registered = false` will retain its mutated value across re-evaluations of the parent chunk.

### Event handlers and `wezterm.on`

`wezterm.on('event-name', fn)` **appends** to a list. Calling it twice registers the handler twice. Because the config chunk re-runs on reload, naive registration leads to duplicates that fire 2x, 3x, ... per event.

Guard with a module-level flag (see termtools' pattern below) or accept that idempotency for the specific event you're handling.

### Closures capture state

Handlers registered today close over whatever `opts` was at the time of registration. If `setup()` runs again with new opts, the *closure* still sees the old values unless you read the live opts at dispatch time. termtools sidesteps this by calling `M.opts()` inside each handler body rather than capturing the table.

## Examples

### termtools' module shape — `setup()` then `apply()`

`lua/init.lua:132` and `lua/init.lua:233` — split between configuration (cached in a module-level `opts`) and config-table mutation:

```lua
local opts = nil

function M.setup(user_opts)
  -- merge defaults, resolve platform bits, cache in module
  opts = require('util').merge_defaults(DEFAULTS, flatten(user_opts or {}))
  -- ... platform.resolve_argv, default_editors, etc.
  return M
end

function M.apply(config)
  local o = M.opts()
  if o.default_keys then
    config.keys = config.keys or {}
    table.insert(config.keys, { key = ..., action = M.project_picker() })
  end
  -- register event handlers exactly once (see next example)
  return config
end
```

Calling pattern in user `~/.wezterm.lua`:

```lua
local termtools = require('init')
termtools.setup({ scan_roots = { ... } })
return termtools.apply(wezterm.config_builder())
```

`apply` runs every reload; `setup` runs every reload; the `opts` module-local survives because `package.loaded.init` sticks.

### Guarding `wezterm.on` against re-registration

`lua/init.lua:231` and `lua/init.lua:293`:

```lua
local handlers_registered = false  -- module-level: survives reloads

function M.apply(config)
  -- ... key bindings, etc.

  if not handlers_registered then
    local wezterm = require('wezterm')

    wezterm.on('termtools.project-picker', function(window, pane)
      pickers.run_project_picker(window, pane, M.opts())  -- live opts read
    end)

    wezterm.on('augment-command-palette', function(window, pane)
      return require('palette').entries(window, pane, M.opts())
    end)

    handlers_registered = true
  end
  return config
end
```

Two things to notice:

1. The flag is at module scope, so `package.loaded` keeps it `true` across reloads.
2. Each handler calls `M.opts()` at dispatch time instead of closing over `o`. New `setup({...})` calls take effect without restart.

### A side-effect-free top level

```lua
-- BAD: spawns one tail every reload
local f = io.popen('tail -F ~/.wezterm.log')

-- GOOD: only fires on the explicit event
wezterm.on('gui-startup', function(cmd)
  -- ... mux:spawn_window etc.
end)
```

## Gotchas

- **Re-evaluation**. The whole chunk re-runs on every reload. Anything at top level runs N times. Hoist work into events or guard with module-level flags.
- **Handler doubling**. `wezterm.on` appends. Without a guard, every reload adds another copy. Symptoms: events firing 2x, 3x, etc., usually noticed as duplicate notifications or pickers opening twice.
- **Closure capture**. Handlers registered with `function() use_opts(opts) end` snapshot `opts`. Re-read live state inside the handler unless the snapshot is what you want.
- **`wezterm.GLOBAL` survives reloads, not restarts**. Persist anything you need across restarts to disk under `wezterm.config_dir`. Detail in [12-state-and-timing.md](12-state-and-timing.md).
- **GUI vs mux callbacks fire in different processes**. `gui-startup` only fires when a GUI attaches; `mux-startup` fires once per mux. Don't expect GUI-only objects (window, pane) inside mux events. See [10-events.md](10-events.md).
- **Side effects at top level multiply**. Spawning a process unconditionally at chunk top level creates one per reload. Move to a one-shot event or guard with a `wezterm.GLOBAL` sentinel.
- **`config_builder()` is the recommended starting point**. It surfaces typos as errors instead of silently ignoring them. See [03-config.md](03-config.md).

## See also

- [02-modules.md](02-modules.md) — what's in `wezterm.*` and which module covers which surface.
- [03-config.md](03-config.md) — config table shape, `config_builder()`, validation.
- [10-events.md](10-events.md) — event taxonomy (GUI vs mux vs window) and registration patterns.
- [12-state-and-timing.md](12-state-and-timing.md) — `wezterm.GLOBAL`, persistence, sync vs async work.
