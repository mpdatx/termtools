# 10 — Events and `wezterm.on`

WezTerm's event bus is how Lua hooks into the terminal's lifecycle, and how key bindings reach behaviour that's too complex to fit inline. Events are also the canonical way to share one body of code between multiple bindings: a key emits an event, one handler runs.

## Overview

`wezterm.on(name, fn)` registers a handler. WezTerm fires events at well-defined points (window resize, tab title formatting, GUI startup, command-palette augmentation) and also lets you define your own event names. Your code dispatches a custom event by either calling `wezterm.emit('name', ...)` from Lua or by binding `wezterm.action.EmitEvent 'name'` to a key or mouse gesture; both end up calling every registered handler.

There are three mental shapes for events:

| Shape | Examples | Handler shape |
| ----- | -------- | ------------- |
| **Lifecycle** — fired once at process boundaries | `gui-startup`, `mux-startup`, `gui-attached` | callback receives a `SpawnCommand` (or nothing) |
| **Window-scoped notifications** — fired on the GUI thread for a specific window | `format-tab-title`, `update-status`, `bell`, `window-focus-changed` | callback receives `(window, pane, ...)` |
| **Custom** — names your code defines and dispatches | `termtools.project-picker`, `termtools.run-action` | callback receives whatever the emitter passed |

The pairing between [08-actions-and-keys.md](08-actions-and-keys.md)'s `EmitEvent` and `wezterm.on` is the same bridge used everywhere in termtools: `pickers.M.project_picker()` returns an `EmitEvent` action; `init.apply()` registers the matching handler. The two sides of the bridge live in different files but use the same name string as their contract.

## Key APIs

### `wezterm.on(event_name, handler)` — [docs](https://wezterm.org/config/lua/wezterm/on.html)

Append a handler to the per-event list. Calling `wezterm.on` twice for the same event registers two handlers; both run, in registration order. There is no unregister API — see Gotchas.

For most window-scoped events the handler signature is `function(window, pane, ...extra)`. The "extra" varies by event (`format-tab-title` gets a `tab` plus all-tabs/all-panes/config/hover/max_width; `user-var-changed` gets a name+value; `open-uri` gets the URI string; etc.). Always check the per-event docs before binding — argument order matters.

Return values matter for some events:

- **`format-tab-title` / `format-window-title`** — must return a string (or a `wezterm.format`-style FormatItem array). Returning nothing falls back to the default.
- **`augment-command-palette`** — must return an array of `PaletteEntry` tables.
- **`open-uri`, `new-tab-button-click`** — return `false` to swallow the default action; anything else lets it proceed.
- **Most notification events** (`bell`, `update-status`, `window-focus-changed`, `window-resized`, `window-config-reloaded`, custom events) — no return value is interpreted; returning `false` from any handler short-circuits subsequent handlers in the chain (`wezterm.emit` semantics).

### `wezterm.emit(event_name, ...)` — [docs](https://wezterm.org/config/lua/wezterm/emit.html)

Programmatic dispatch. `wezterm.emit('foo', a, b)` runs every `wezterm.on('foo', ...)` handler with `(a, b)`. Returns a boolean: `false` if any handler returned `false` (i.e. "default action suppressed"), otherwise `true`.

`emit` does **not** carry an implicit `window` / `pane`. If your handler expects them, you have to pass them yourself. This is the main difference from `EmitEvent`.

### `wezterm.action.EmitEvent 'name'` — [docs](https://wezterm.org/config/lua/keyassignment/EmitEvent.html)

A `KeyAssignment` value: drop it into `config.keys`, `config.mouse_bindings`, or a `PaletteEntry.action` field. When dispatched, it's equivalent to `wezterm.emit('name', window, pane)` — the calling window and pane are passed automatically.

The action constructor also accepts extra arguments after the name: `wezterm.action.EmitEvent('name', arg1, arg2)` ends up as `emit('name', window, pane, arg1, arg2)`. termtools uses this for the palette → run-action bridge (see Examples).

## Built-in event catalogue

### Lifecycle events

| Event | Signature | Notes |
| ----- | --------- | ----- |
| `gui-startup` | `function(cmd)` | Fires once when the GUI process starts via `wezterm start`. `cmd` is an optional `SpawnCommand` reflecting CLI args (or nil). Runs **before any windows exist** — use `wezterm.mux.spawn_window` to create initial layouts. |
| `gui-attached` | `function(domain)` | Fires when a GUI attaches to a mux (including remote mux). After `gui-startup`. |
| `mux-startup` | `function()` | Fires once on the mux side as it starts up; receives no args. Use this for layouts that should exist regardless of whether a GUI is attached. |
| `window-config-reloaded` | `function(window, pane)` | Fires after every config reload — file change, `ReloadConfiguration`, or `window:set_config_overrides`. Useful for invalidating caches. Beware: calling `set_config_overrides` from inside this handler re-fires it; guard against loops. |

### Window events (GUI thread)

| Event | Signature | Return |
| ----- | --------- | ------ |
| `format-tab-title` | `function(tab, all_tabs, all_panes, config, hover, max_width)` | string \| FormatItem[] (default if nil/error) |
| `format-window-title` | `function(tab, pane, all_tabs, all_panes, config)` | string (default if nil/error). **Only the first registered handler runs** — unlike most events. |
| `update-status` | `function(window, pane)` | nothing. Fires every `status_update_interval` ms. Coalesced — never overlaps itself. |
| `update-right-status` | `function(window, pane)` | Older alias for `update-status` scoped to the right side; prefer `update-status` plus `window:set_right_status` in new code. |
| `window-focus-changed` | `function(window, pane)` | nothing. Use `window:is_focused()` inside. |
| `window-resized` | `function(window, pane)` | nothing. Coalesced during live resize. |
| `bell` | `function(window, pane)` | nothing. The pane that bell'd may not be the active one. Handler **supplements** the configured bell, doesn't replace it. |
| `new-tab-button-click` | `function(window, pane, button, default_action)` | `false` swallows the default. `default_action` may be nil. |
| `user-var-changed` | `function(window, pane, name, value)` | nothing. Fires on `OSC 1337;SetUserVar` from a shell. |
| `open-uri` | `function(window, pane, uri)` | `false` swallows the default browser open. |
| `augment-command-palette` | `function(window, pane)` | array of `PaletteEntry`. Covered in [17-palette.md](17-palette.md). |

### Mux events

When wezterm runs as a multiplexer (`wezterm-mux-server`, or the in-process mux in a normal GUI session), a separate set of events fires there. The catalogue is small; `mux-startup` is the one most configs care about. `pane-output` and friends exist for advanced scripting and aren't currently used by termtools.

### Custom events

Any name your code defines via `wezterm.on('myname', fn)` and dispatches via `EmitEvent 'myname'` (or `wezterm.emit`). Convention: prefix with your project name so plugins don't collide. termtools uses `termtools.*` (`termtools.project-picker`, `termtools.action-picker`, `termtools.run-action`, `termtools.open-selection`, `termtools.claude-next-waiting`, `termtools.claude-session-picker`).

## Examples

### The termtools EmitEvent → handler bridge

`lua/pickers.lua:43` returns the action that key bindings use:

```lua
function M.project_picker(_opts)
  return wezterm.action.EmitEvent 'termtools.project-picker'
end
```

`lua/init.lua:296` registers the matching handler inside `apply()`:

```lua
wezterm.on('termtools.project-picker', function(window, pane)
  pickers.run_project_picker(window, pane, M.opts())
end)
```

The handler reads `M.opts()` at dispatch time rather than capturing the table — so `setup({...})` calls between the registration and the dispatch take effect without a restart. Same shape for `termtools.action-picker` (init.lua:300), `termtools.run-action` (init.lua:304), `termtools.open-selection` (init.lua:308).

The palette uses the carry-extra-args form: `lua/palette.lua:48` builds an `EmitEvent('termtools.run-action', root, action.label)` so the handler at `init.lua:304` receives `(window, pane, root, label)` and can dispatch the chosen action without re-querying the palette state.

### Guarding registration against handler doubling

`lua/init.lua:231` and `lua/init.lua:293`:

```lua
local handlers_registered = false  -- module-scope, survives reloads

function M.apply(config)
  -- ... key bindings ...

  if not handlers_registered then
    local wezterm = require('wezterm')

    wezterm.on('termtools.project-picker', function(window, pane)
      pickers.run_project_picker(window, pane, M.opts())
    end)
    -- ... more wezterm.on calls ...

    handlers_registered = true
  end
  return config
end
```

Without the flag, every config reload appends another handler copy, so the picker would open 2x, 3x, ... after each reload. `package.loaded.init` keeps the module-scope `handlers_registered = true` across reloads. See [01-architecture.md](01-architecture.md) for the lifecycle context.

### Custom tab title with claude indicator

`lua/style.lua:80`:

```lua
wezterm.on('format-tab-title', function(tab, _tabs, _panes, _conf, _hover, max_width)
  local termtools = package.loaded['init']
  local glyph_of = termtools and termtools.claude_glyph_for_pane

  local representative = tab.active_pane
  if glyph_of and tab.panes then
    for _, p in ipairs(tab.panes) do
      if glyph_of(p.pane_id) then representative = p; break end
    end
  end

  local idx = tab.tab_index + 1
  local title = (representative.title or ''):gsub('^Administrator: ', '')
  -- ... build label, truncate to max_width ...
  return label
end)
```

Synchronous — must return fast. `wezterm.run_child_process` from inside this handler errors out with "attempt to yield from outside a coroutine".

### Status bar updates on a poll

`lua/claude.lua:310`:

```lua
config.status_update_interval = opts.poll_interval_ms

wezterm.on('update-status', function(window, _pane)
  M.scan()
  local fmt = opts.show_status_bar and summary_format() or nil
  local rendered = fmt and wezterm.format(fmt) or ''
  window:set_left_status(rendered)
end)
```

`update-status` is the preferred surface for any "tick" work — `window-focus-changed` only fires on focus changes, and a top-level `time.call_after` recursion is a worse pattern than letting wezterm coalesce calls for you.

### Initial layout via `gui-startup`

```lua
local mux = require('wezterm').mux

wezterm.on('gui-startup', function(cmd)
  local tab, pane, window = mux.spawn_window(cmd or {})
  pane:split { direction = 'Right', size = 0.4 }
  window:gui_window():maximize()
end)
```

`cmd` reflects any args passed to `wezterm start` — passing it through to `spawn_window` lets `wezterm start -- htop` still work as expected; the rest of the layout is your additions.

### Cache invalidation on config reload

```lua
local cached_scheme = nil

wezterm.on('window-config-reloaded', function(window, _pane)
  cached_scheme = nil
end)
```

Anything you derived from config and memoised should be cleared here — colour-scheme objects, parsed paths, etc.

### Custom URI handling

```lua
wezterm.on('open-uri', function(window, pane, uri)
  if uri:find('^jira://') then
    window:perform_action(
      wezterm.action.SpawnCommandInNewWindow {
        args = { 'open-jira', uri:sub(8) },
      }, pane)
    return false  -- swallow the default browser open
  end
  -- nil/no return: let the default fire
end)
```

## Gotchas

- **Handler doubling on reload.** `wezterm.on` *appends*. Every config reload re-runs the chunk, which re-registers the handler. Without a guard, you'll have N copies after N reloads and the event fires N times. The fix is a module-scope `handlers_registered` flag (termtools' pattern at `lua/init.lua:231`) that `package.loaded` keeps alive across reloads. See [01-architecture.md](01-architecture.md).
- **`format-window-title` is special-cased: only the first handler runs.** Most events run all handlers in registration order; `format-window-title` does not. If two modules both try to set it, the second silently loses.
- **Synchronous handlers.** `format-tab-title`, `format-window-title`, `update-status` and the focus/resize/bell events run on the GUI thread. Anything slow there freezes the UI. Calling `wezterm.run_child_process` errors out with "attempt to yield outside a coroutine"; `wezterm.sleep_ms` blocks the whole frame. Use `wezterm.time.call_after` or `wezterm.background_child_process` to defer work; see [12-state-and-timing.md](12-state-and-timing.md).
- **`gui-startup` runs before any window exists.** You can't `window:perform_action` from inside it — there's no window yet. Use `wezterm.mux.spawn_window` (returns a tab/pane/window triple) to create the initial layout.
- **`gui-startup` only fires for `wezterm start`,** not for `wezterm connect` to a remote mux, and not for the second-and-subsequent windows of the same process.
- **`mux-startup` runs in the mux process** — no GUI objects available, no `window:perform_action`. It's the right place for layouts that should exist before any GUI attaches; the wrong place for anything that touches the GUI.
- **Return values matter, but only for specific events.** `format-tab-title` / `format-window-title` need a string; `augment-command-palette` needs an array; `open-uri` / `new-tab-button-click` use `false` to swallow the default. Returning the wrong type gets the default behaviour silently. Returning `false` from a notification handler (`bell`, `update-status`, etc.) short-circuits any later-registered handlers — usually not what you want.
- **`EmitEvent` carries window+pane, `wezterm.emit` does not.** A keybind `EmitEvent 'foo'` calls handlers with `(window, pane)`. A bare `wezterm.emit('foo')` from Lua passes nothing; if your handler signature is `function(window, pane)` it'll get nil/nil. Pass them through if you have them, or use `EmitEvent` from inside an `action_callback`.
- **No unregistering.** Once `wezterm.on` adds a handler, it's registered for the process lifetime. To "disable" behaviour at runtime, use a module-scope flag the handler reads on every dispatch (early-return when off) — don't try to remove the registration.
- **Custom event naming collisions.** Plain names like `'open-picker'` risk colliding with future built-in events or with another plugin. Prefix with your project name (`termtools.open-picker`); the upstream docs explicitly recommend this.
- **`wezterm.on` registration must happen during config evaluation,** not lazily on first use. Registering inside an `action_callback` body (i.e. on first key press) means earlier presses won't fire it; it also re-registers on every press. Always register at config-build time.
- **Closures capture state.** A handler written `wezterm.on('foo', function() use(opts) end)` snapshots whatever `opts` was at registration. Since registrations are gated by `handlers_registered` and don't re-run on reload, the snapshot is stale forever. termtools sidesteps this by reading `M.opts()` *inside* the handler body — the function itself is captured once, but it dereferences live state on every dispatch.

## See also

- [01-architecture.md](01-architecture.md) — config-reload lifecycle, why `wezterm.on` doubles, where module-scope state survives.
- [08-actions-and-keys.md](08-actions-and-keys.md) — `EmitEvent` is one of the `KeyAssignment` types; how it pairs with `action_callback`.
- [11-pickers.md](11-pickers.md) — `InputSelector` callbacks are an `action_callback`, **not** a `wezterm.on` event. Don't try to bridge a picker through `wezterm.on`.
- [14-tab-bar-and-status.md](14-tab-bar-and-status.md) — deep-dive on `format-tab-title` / `format-window-title` / `update-status`.
- [17-palette.md](17-palette.md) — `augment-command-palette` event and `PaletteEntry` shape.
