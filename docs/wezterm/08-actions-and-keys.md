# Actions and keys

`wezterm.action.*`, `wezterm.action_callback`, `wezterm.action.EmitEvent`, `config.keys`, leader keys, key tables. The surface that turns "user pressed something" into "Lua ran" or "the terminal did the built-in thing".

Mouse bindings have the same `action = ...` field and the same catalogue, but their event/mods syntax is different — covered in [09-mouse.md](09-mouse.md). Pickers (`InputSelector`, `PromptInputLine`) are listed here because they're actions, but the modal flow lives in [11-pickers.md](11-pickers.md).

## Overview

Three primitives:

- **Action** — a typed value produced by `wezterm.action.<Name>` (or `wezterm.action.<Name> { args }`). Inert until something dispatches it.
- **Key binding** — `{ key = ..., mods = ..., action = ... }`. Goes into `config.keys`. Maps a physical-or-mapped keypress into one action.
- **Event** — `wezterm.on('name', fn)` listens; `wezterm.action.EmitEvent 'name'` (used as an action) fires. The handler receives `(window, pane, ...extra_args)`.

The wiring pattern that termtools uses everywhere: register a handler once via `wezterm.on('termtools.foo', fn)`, then anywhere you want a key, mouse binding, command-palette entry, or per-project action to run that logic, dispatch `wezterm.action.EmitEvent 'termtools.foo'`. One canonical handler, many call sites. Cite: `lua/pickers.lua:42` (the EmitEvent shim) and `lua/init.lua:296` (the handler).

`wezterm.action_callback` is the shortcut form: pass a closure, get back an action. It's the same machinery as EmitEvent under the hood (action_callback synthesises a unique event name), but the function lives at the call site instead of in a shared handler.

## Key APIs

### `wezterm.action.<Name>` — the catalogue

Two grammatical forms, depending on whether the action takes args:

```lua
local act = wezterm.action

-- Bare form: no args. Don't add empty braces — that's a different shape.
action = act.CloseCurrentPane          -- WRONG if it takes args
action = act.ReloadConfiguration       -- correct: no args
action = act.ResetTerminal             -- correct: no args
action = act.Nop                       -- correct: explicit no-op (eat the keypress)

-- Tuple/positional args: called like a function with one positional arg
action = act.ActivateTab(0)
action = act.ActivateTabRelative(1)
action = act.ScrollByPage(-1)
action = act.PasteFrom 'Clipboard'                  -- single string is positional
action = act.CopyTo 'ClipboardAndPrimarySelection'

-- Struct args: a table. Use this when there are named fields.
action = act.SpawnCommandInNewTab { args = { 'pwsh' }, cwd = 'C:/code' }
action = act.SplitPane { direction = 'Right', size = { Percent = 30 } }
action = act.ActivateKeyTable { name = 'resize_pane', one_shot = false, timeout_milliseconds = 1500 }
action = act.InputSelector { title = '...', choices = {...}, fuzzy = true, action = ... }
```

The full list is on [wezterm.org](https://wezterm.org/config/lua/keyassignment/index.html). The ones you'll reach for first:

| Action | Form | What it does |
| --- | --- | --- |
| `SendString` | string | Type literal text into the pane |
| `SendKey` | `{ key, mods? }` | Synthesise a keypress (post-binding remap) |
| `ActivateTab` | int | Switch to tab N (0-based) |
| `ActivateTabRelative` | int (signed) | Move N tabs from current |
| `ActivatePaneDirection` | `'Up'`/`'Down'`/`'Left'`/`'Right'`/`'Next'`/`'Prev'` | Focus a sibling pane |
| `CloseCurrentPane` | `{ confirm = bool }` | Close active pane |
| `CloseCurrentTab` | `{ confirm = bool }` | Close active tab |
| `SpawnTab` | `'CurrentPaneDomain'`/`'DefaultDomain'`/`{ DomainName='..'}` | New tab in same/specified domain |
| `SpawnCommandInNewTab` | `SpawnCommand` table | New tab running an explicit command. See [06-spawning.md](06-spawning.md) |
| `SplitPane` | `{ direction, size?, command?, top_level? }` | Split the current pane. See [07-splits.md](07-splits.md) |
| `EmitEvent` | `'name'` or `('name', a, b, ...)` | Fire `wezterm.on('name', fn)` |
| `Multiple` | `{ act1, act2, ... }` | Run actions in order |
| `InputSelector` | table — see [11-pickers.md](11-pickers.md) | Modal fuzzy chooser |
| `PromptInputLine` | table — see [11-pickers.md](11-pickers.md) | Free-text input prompt |
| `ActivateKeyTable` | `{ name, one_shot?, replace_current?, until_unknown?, timeout_milliseconds? }` | Push key-table layer |
| `PopKeyTable` | bare | Pop the top key-table layer |
| `ClearKeyTableStack` | bare | Empty the entire stack |
| `ResetTerminal` | bare | DECSTR-style reset of the active pane |
| `ReloadConfiguration` | bare | Re-evaluate the config file |
| `ScrollByPage` / `ScrollByLine` | int (signed) | Scroll the viewport |
| `CopyTo` / `PasteFrom` | string target/source | Clipboard ops |
| `Search` | `{ CaseSensitiveString='..'}` etc. | Open scrollback search |
| `SwitchToWorkspace` | `{ name?, spawn? }` | Activate or create a workspace |
| `ShowLauncher` | bare | Open built-in launcher |
| `Nop` | bare | Eat the keypress, do nothing |
| `DisableDefaultAssignment` | bare | Remove a default binding cleanly |

### `wezterm.action_callback(fn)`

```lua
local act = wezterm.action

action = wezterm.action_callback(function(window, pane, ...)
  -- whatever Lua you want
end)
```

Returns a `KeyAssignment` value usable in `config.keys`, `mouse_bindings`, an `InputSelector { action = ... }` field, etc. The callback fires synchronously on dispatch — heavy work blocks the GUI. Hand off to `wezterm.time.call_after` or `wezterm.background_child_process` if needed (see [12-state-and-timing.md](12-state-and-timing.md)).

The `...` extra args are passed through when this is the inner action of an `InputSelector` (the selected `id` and `label`), a `PromptInputLine` (the typed line), and similar surfaces.

### `wezterm.action.EmitEvent`

```lua
action = wezterm.action.EmitEvent 'my-event'              -- no extras
action = wezterm.action.EmitEvent('my-event', root, label) -- extras forwarded
```

Fires `wezterm.on('my-event', fn)`. The handler signature is `function(window, pane, ...extras)`. Extras must be Lua values WezTerm can serialise across the dispatch boundary (numbers, strings, booleans, tables of those — not closures).

### `wezterm.action.Multiple { ... }`

Sequence of actions, run in order:

```lua
action = wezterm.action.Multiple {
  wezterm.action.ClearScrollback 'ScrollbackOnly',
  wezterm.action.SendKey { key = 'L', mods = 'CTRL' },
}
```

Useful for "clear and redraw", chord finalisers (`Multiple { do_thing, PopKeyTable }`), or grouping a handful of canonical actions behind one binding without writing a callback.

### `wezterm.action.ActivateKeyTable`

```lua
action = wezterm.action.ActivateKeyTable {
  name = 'leader',
  one_shot = false,            -- stay in the table until something pops it
  replace_current = false,     -- push a new layer instead of swapping the top
  until_unknown = true,        -- pop on any keypress not in the table
  timeout_milliseconds = 1500, -- pop after this long
}
```

Combine with `PopKeyTable` (or `Multiple { do_thing, PopKeyTable }`) for vi-style chord sequences. See *Key tables* below.

## `config.keys` shape

```lua
config.keys = {
  { key = 'p', mods = 'CTRL|SHIFT', action = wezterm.action.EmitEvent 'termtools.project-picker' },
  { key = 'F1', mods = 'NONE',      action = wezterm.action.ActivateTab(0) },
  { key = ']', mods = 'CTRL',       action = wezterm.action.ActivateTabRelative(1) },
}
```

Each entry needs `key`, `action`, and (effectively always) `mods`.

**`mods`** — pipe-joined string. Always uppercase: `'CTRL|SHIFT'`, not `'Ctrl|Shift'`. Lowercase used to fail outright in older versions; uppercase has always worked. The named modifiers are:

- `CTRL`
- `SHIFT`
- `ALT` (synonyms: `OPT`, `META`)
- `SUPER` (synonyms: `CMD`, `WIN`)
- `LEADER` — the virtual modifier (see *Leader keys*)
- `NONE` — explicit "no modifiers" (preferred over omitting the field)
- `VoidSymbol` — X11 specific

**`key`** — the keypress to match. Five forms:

| Syntax | Means |
| --- | --- |
| `'a'` | Default: physical position of `a` on a US layout (changes per `key_map_preference`) |
| `'F1'` / `'PageUp'` / `'Backspace'` | Named non-character keys |
| `'phys:A'` | Physical position of A regardless of layout |
| `'mapped:a'` | Whatever the layout *produces* `a` for |
| `'raw:123'` | Raw OS keycode |

For most users, plain `'a'` works because `key_map_preference` defaults to "Physical" but falls back to mapped when there's no physical match. If you're hitting layout problems on Dvorak/AZERTY, switch to explicit `phys:` or `mapped:` per binding rather than guessing.

## Leader keys

A modal prefix, in the tmux sense.

```lua
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1500 }
config.keys = {
  { key = 'p', mods = 'LEADER',         action = wezterm.action.EmitEvent 'termtools.project-picker' },
  { key = 'a', mods = 'LEADER',         action = wezterm.action.EmitEvent 'termtools.action-picker'  },
  { key = '|', mods = 'LEADER|SHIFT',   action = wezterm.action.SplitPane { direction = 'Right' } },
}
```

After CTRL+A is pressed, WezTerm enters "leader active" state for `timeout_milliseconds`. While active, only bindings whose `mods` includes `LEADER` can match; everything else is swallowed. The next matching keypress (or the timeout) clears the state.

Cite: `examples/full.wezterm.lua:95` shows the commented-out form and the corresponding `LEADER`-keyed bindings just above. The default timeout is 1000 ms — bump to 1500–2000 ms when you actually press chords; 1000 ms is a typing speed cliff for two-key sequences.

## Key tables

Generalised leader. A named bag of bindings that gets pushed onto a per-window stack via `ActivateKeyTable`. The active stack searches top-down before falling through to `config.keys`.

```lua
config.key_tables = {
  resize_pane = {
    { key = 'h',      action = wezterm.action.AdjustPaneSize { 'Left',  1 } },
    { key = 'j',      action = wezterm.action.AdjustPaneSize { 'Down',  1 } },
    { key = 'k',      action = wezterm.action.AdjustPaneSize { 'Up',    1 } },
    { key = 'l',      action = wezterm.action.AdjustPaneSize { 'Right', 1 } },
    { key = 'Escape', action = wezterm.action.PopKeyTable },
    { key = 'Enter',  action = wezterm.action.PopKeyTable },
  },
}

config.keys = {
  { key = 'r', mods = 'LEADER',
    action = wezterm.action.ActivateKeyTable {
      name = 'resize_pane',
      one_shot = false,         -- stay in the table for repeated h/j/k/l
      timeout_milliseconds = 2000,
    } },
}
```

Built-in tables `copy_mode` and `search_mode` ship with their own default bindings; override entries by name to extend or replace them. See [11-pickers.md](11-pickers.md) for `copy_mode` interactions.

## Examples

### EmitEvent bridging — the termtools pattern

`lua/pickers.lua:42` returns a bare action that fires a named event:

```lua
function M.project_picker(_opts)
  return wezterm.action.EmitEvent 'termtools.project-picker'
end
```

`lua/init.lua:296` registers the matching handler exactly once (guarded by a module-level flag):

```lua
wezterm.on('termtools.project-picker', function(window, pane)
  pickers.run_project_picker(window, pane, M.opts())
end)
```

The pay-off: `M.project_picker()` can be dropped into `config.keys`, the command palette ([17-palette.md](17-palette.md)), a per-project `.termtools.lua` action, or a `Multiple { ... }` sequence — every call site goes through one handler that re-reads live opts at dispatch time.

### EmitEvent with extra args — palette dispatch

`lua/palette.lua:48` carries `(root, label)` along with the event:

```lua
action = wezterm.action.EmitEvent('termtools.run-action', root, action.label),
```

Handler in `lua/init.lua:304`:

```lua
wezterm.on('termtools.run-action', function(window, pane, root, label)
  pickers.run_action_by_label(window, pane, root, label, M.opts())
end)
```

The extra `root` and `label` show up as the third and fourth handler parameters.

### The defensive twin — SHIFT plus an uppercase letter

`lua/init.lua:255` registers both `'A'` and `'a'` when the binding is `CTRL|SHIFT+A`:

```lua
table.insert(config.keys, {
  key = o.action_key.key, mods = o.action_key.mods,
  action = M.action_picker(),
})
if string.find(o.action_key.mods or '', 'SHIFT')
    and o.action_key.key:match('^%u$') then
  table.insert(config.keys, {
    key = o.action_key.key:lower(), mods = o.action_key.mods,
    action = M.action_picker(),
  })
end
```

WezTerm's matching has historically accepted either; depending on platform, layout, and `key_map_preference`, a SHIFT-held A reaches Lua as `'A'` *or* `'a'` with `SHIFT` in the mods. We register both so the binding fires regardless. See *Gotchas*.

### `wezterm.action_callback` — the InputSelector dispatcher

`lua/pickers/action.lua:144`:

```lua
window:perform_action(
  wezterm.action.InputSelector {
    title = 'Action: ' .. proj_name,
    choices = choices,
    fuzzy = true,
    action = wezterm.action_callback(function(w, p, id, _label)
      if not id then return end
      local idx = tonumber(id)
      if not idx or not order[idx] then return end
      local picked = order[idx]
      ...
      local target_pane = w:active_pane() or p
      local ok, err = pcall(entry.run, w, target_pane, root)
      ...
    end),
  },
  pane
)
```

`InputSelector`'s `action` field expects a `KeyAssignment`; `action_callback` adapts a Lua closure into one. The extra args (`id`, `_label`) come from InputSelector itself — the chosen choice's `id` field and label.

### `Multiple` — clear-and-redraw

```lua
{ key = 'l', mods = 'CTRL|SHIFT',
  action = wezterm.action.Multiple {
    wezterm.action.ClearScrollback 'ScrollbackOnly',
    wezterm.action.SendKey { key = 'L', mods = 'CTRL' },  -- shells redraw on ^L
  } },
```

### Key-table chord — leader-style "leader, p" project picker

When you don't want to commit to a global leader but do want a chord:

```lua
config.key_tables = {
  termtools = {
    { key = 'p', action = wezterm.action.Multiple {
        wezterm.action.EmitEvent 'termtools.project-picker',
        wezterm.action.PopKeyTable,
      } },
    { key = 'a', action = wezterm.action.Multiple {
        wezterm.action.EmitEvent 'termtools.action-picker',
        wezterm.action.PopKeyTable,
      } },
    { key = 'Escape', action = wezterm.action.PopKeyTable },
  },
}

config.keys = {
  { key = 't', mods = 'CTRL|SHIFT',
    action = wezterm.action.ActivateKeyTable {
      name = 'termtools',
      one_shot = true,        -- single chord follow-up
      until_unknown = true,
      timeout_milliseconds = 1500,
    } },
}
```

Compare to the simpler `default_keys` form in `lua/init.lua:247`, which binds the same emit events directly to `o.project_key` / `o.action_key` without a chord layer.

### `DisableDefaultAssignment` — drop a built-in cleanly

```lua
{ key = 'F11', mods = 'NONE', action = wezterm.action.DisableDefaultAssignment },
```

Prefer this over `Nop`. `Nop` eats the keypress (so nothing else can match it either); `DisableDefaultAssignment` removes the built-in binding so a later override (or the OS / terminfo path) can reach the program.

## Gotchas

### Uppercase keys plus SHIFT

When `mods` includes `SHIFT` and the unshifted key would be a letter, WezTerm's matching can deliver the keypress as either `'A'` (uppercase, with SHIFT still in mods) or `'a'` (lowercase, with SHIFT in mods). Which one varies by platform, OS-level remapping, and `key_map_preference`. The defensive twin in `lua/init.lua:255` registers both forms so the binding fires either way. If you only register `'A'`, users on the wrong combination see the keypress fall through to a default binding or to nothing.

### Leader timeout default is too short for chords

Default `timeout_milliseconds` is 1000 ms. A two-key chord with a noticeable mode-press-then-key gap dies at the cliff. Bump to 1500–2000 ms. termtools' commented-out leader example uses 1500.

### Bare vs args form is not interchangeable

`wezterm.action.ResetTerminal` and `wezterm.action.ResetTerminal {}` are not equivalent. The first is the unit variant; the second tries to construct a struct variant from an empty table and either errors at config load or silently produces a different action. Match the docs precisely — bare for no-args, table only when there are named args, function-call for tuple-positional args.

### `EmitEvent` is the cross-reload-safe way to share handlers

`action_callback` synthesises a fresh closure (and a fresh internal event id) every time the config chunk runs. Two issues fall out:

1. Without a re-registration guard, every reload accumulates another anonymous handler — same problem as plain `wezterm.on`, just hidden behind a different surface.
2. The closure captures whatever upvalues were live at registration. Re-reading from a module-level `opts` inside the body, or going through an `EmitEvent` -> shared handler, side-steps this.

`EmitEvent` lets one canonical handler (registered exactly once with `if not handlers_registered then ...`) serve every `config.keys`, `mouse_bindings`, palette, or `.termtools.lua` action that wants the behaviour. termtools uses this throughout — see `lua/init.lua:293`.

### `action_callback` runs synchronously

The function body executes on the GUI thread, in the keypress dispatch path. Filesystem walks, `wezterm.run_child_process`, big string parses — anything slower than a couple of milliseconds — visibly stutters input. Hand off to `wezterm.background_child_process` (fire-and-forget) or `wezterm.time.call_after` (deferred) for non-trivial work. Detail in [12-state-and-timing.md](12-state-and-timing.md).

### Modifier strings are case-sensitive in practice

`'CTRL|SHIFT'` works on every version. `'Ctrl|Shift'` used to silently fail to bind on older releases. Stick to uppercase. The same applies inside `mouse_bindings` mods strings.

### `key = ' '` for space — but `key = 'Space'` also works

Both work. The named form is clearer in diffs and search, and lines up with how `Backspace`, `Tab`, `Enter`, `Escape` are written. Pick one convention per file.

### `LEADER` swallows non-LEADER keys while active

While the leader is active, anything not in a `LEADER`-mods binding gets eaten. The user sees a "press X, nothing happens, press X again, it works" surprise if their finger overlaps the leader timeout. Either accept it (vi/tmux convention) or use a key table with `until_unknown = true` instead, which falls through unmatched keys to the parent stack.

### Handlers fire in the GUI process; mux-only events don't have a window

`EmitEvent` actions only fire from key bindings, mouse bindings, palette entries — all GUI surfaces. The handler always gets `(window, pane, ...)`. Don't try to dispatch an action from inside `mux-startup` — there's no GUI yet. See [10-events.md](10-events.md) for the GUI/mux event split.

### Per-window key-table stack

`ActivateKeyTable` pushes onto a stack scoped to the *current GUI window*. A second window has its own stack. `ClearKeyTableStack` only clears the active window's. If a binding leaves a window in a key table mode and the user switches windows, the other window is unaffected — but switching back will return them to the active table.

### `SpawnCommandInNewTab` vs `SpawnCommand` (the value)

`SpawnCommandInNewTab` is the *action*; its argument is a `SpawnCommand` value (`{ args, cwd, set_environment_variables, domain, label }`). The same `SpawnCommand` shape is used by `SplitPane`'s `command` field, `pane:split { ... }`, and `wezterm.mux.spawn_window`. See [06-spawning.md](06-spawning.md).

## See also

- [07-splits.md](07-splits.md) — `SplitPane` action, `pane:split` method, direction-name vocabulary mismatch.
- [09-mouse.md](09-mouse.md) — `mouse_bindings` (same `action = ...` field, different event/mods syntax).
- [10-events.md](10-events.md) — `wezterm.on`, `wezterm.emit`, the other half of `EmitEvent`.
- [11-pickers.md](11-pickers.md) — `InputSelector` and `PromptInputLine` callback shape, modal-time-vs-confirm-time pane race.
- [17-palette.md](17-palette.md) — `augment-command-palette`, `PaletteEntry` shape, `EmitEvent` from a palette row.
