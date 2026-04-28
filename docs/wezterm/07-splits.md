# 07 — Splits

Two routes to splitting a pane: the mux-direct `pane:split { ... }` and the GUI action `wezterm.action.SplitPane { ... }`. Same outcome on screen; different vocabularies, different timing, different failure modes when called from inside a modal callback.

## Overview

| | `pane:split { ... }` | `wezterm.action.SplitPane { ... }` |
| --- | --- | --- |
| Surface | Mux Pane method | Key assignment / action |
| Dispatch | Synchronous mux call | Queued through GUI action loop |
| Direction names | `Right` / `Left` / `Top` / `Bottom` | `Right` / `Left` / `Up` / `Down` |
| Returns | The new Pane | Nothing |
| Spawn shape | Top-level `args`, `cwd`, `set_environment_variables` | Wrapped in `command = { args = ..., cwd = ... }` |
| Available in | event handlers, action callbacks, key bindings | anywhere `window:perform_action` works |

Reach for `pane:split` when you're inside an `action_callback` (picker confirm, custom event handler) and you want the split to happen *now*, deterministically. Reach for `SplitPane` when you're authoring a key binding — the action shape is the natural fit, and there's no race because the binding *is* the user input the action loop is built around.

The legacy `SplitHorizontal { ... }` and `SplitVertical { ... }` actions still work but lack `top_level` and `size`. Use `SplitPane` for new key bindings.

## Key APIs

### `pane:split { direction, size, args, cwd, set_environment_variables, domain, top_level }`

Splits this pane and spawns a program into the new half. Returns the new Pane synchronously.

- `direction` — `'Right'` (default), `'Left'`, `'Top'`, `'Bottom'`. Note: `Top`/`Bottom`, *not* `Up`/`Down`.
- `size` — fractional (`0.5`) or absolute. The structured form `{ Cells = N }` / `{ Percent = N }` matches the action shape; a bare number `0.3` also works (< 1.0 = fraction, ≥ 1 = cell count).
- `args` — argv for the spawned program. Omit to use the configured `default_prog`.
- `cwd` — working directory. Defaults to the parent pane's CWD via `default_cwd` resolution.
- `set_environment_variables` — extra env vars merged into the spawned process.
- `domain` — `'CurrentPaneDomain'` (default), `'DefaultDomain'`, or `{ DomainName = 'foo' }`.
- `top_level` — when `true`, splits at the tab's root rather than inside the current pane group.

### `wezterm.action.SplitPane { direction, command, size, top_level }`

Dispatched via `window:perform_action(act, pane)`. The `pane` argument is the target.

- `direction` — `'Up'`, `'Down'`, `'Left'`, `'Right'`. Note: `Up`/`Down`, *not* `Top`/`Bottom`.
- `command` — a `SpawnCommand`: `{ args = {...}, cwd = ..., set_environment_variables = {...}, domain = ... }`. Omit to use `default_prog`.
- `size` — `{ Cells = N }` or `{ Percent = N }`. Defaults to `{ Percent = 50 }`.
- `top_level` — same semantics as `pane:split`.

### Legacy: `SplitHorizontal { args, cwd, ... }` / `SplitVertical { args, cwd, ... }`

Older single-axis actions taking a bare `SpawnCommand` (no nested `command =`). `SplitHorizontal` puts the new pane on the right; `SplitVertical` puts it on the bottom. No `size`, no `top_level`. Functional but superseded — `SplitPane` covers both with one action.

### Direction-name table

| User intent | `pane:split` | `SplitPane` action | `SplitHorizontal/Vertical` |
| --- | --- | --- | --- |
| New pane on right | `direction = 'Right'` | `direction = 'Right'` | `SplitHorizontal {...}` |
| New pane on left | `direction = 'Left'` | `direction = 'Left'` | — |
| New pane on top | `direction = 'Top'` | `direction = 'Up'` | — |
| New pane on bottom | `direction = 'Bottom'` | `direction = 'Down'` | `SplitVertical {...}` |

Only the vertical axis differs. The four-arrow names (`Up`/`Down`) are the action's; the cardinal-edge names (`Top`/`Bottom`) are the Pane method's.

## Examples

### Inline-editor split via `pane:split`

`lua/actions.lua:44-49` — when the configured editor is `kind = 'pane'` (a terminal editor like nvim), `M.open_in_editor` calls the mux-direct path:

```lua
if editor_spec.kind == 'pane' then
  if not pane then return end
  pane:split {
    direction = split_direction(editor_spec.direction or 'Right'),
    args = args,
  }
```

`args` is the editor argv with the target file appended; `cwd` is left to the default (inherits from the parent pane).

### "New shell pane" — split bottom with explicit cwd

`lua/actions.lua:213-219`:

```lua
run = function(_window, pane, root)
  pane:split {
    direction = 'Bottom',
    args = default_cmd,
    cwd = root,
  }
end,
```

Two notes:
- `direction = 'Bottom'` — the Pane-method vocabulary. `'Down'` here would silently fail (no error, no split).
- The `_window` underscore — `pane:split` doesn't need the window object, so we ignore it. Compare to the `SpawnCommandInNewTab` entry just below at `lua/actions.lua:222-229` which *does* take `window` because it dispatches via `window:perform_action`.

### "New Claude pane" — same shape, opposite axis

`lua/actions.lua:200-209`:

```lua
{
  label = 'New Claude pane',
  description = 'split right; ' .. claude_cmd_str .. ' at project root',
  run = function(_window, pane, root)
    pane:split {
      direction = 'Right',
      args = claude_cmd,
      cwd = root,
    }
  end,
},
```

### `DIRECTION_MAP` — translate user-facing names at the boundary

`lua/actions.lua:20-24`:

```lua
-- pane:split uses Top/Bottom for vertical splits; wezterm.action.SplitPane
-- uses Up/Down. Accept either at the user-facing config layer (editor_spec
-- direction, catalogue entries) and translate to pane:split's vocabulary.
local DIRECTION_MAP = { Up = 'Top', Down = 'Bottom' }
local function split_direction(d) return DIRECTION_MAP[d] or d end
```

Users writing an `editors.registry` entry can pass either `direction = 'Down'` (intuitive — "the new pane goes down") or `direction = 'Bottom'` (literal — "the bottom edge"). The shim normalises both into `pane:split`'s expected vocabulary at the call site, so neither user is surprised. `Left`/`Right` pass through untouched (the two paths agree on those).

### `top_level = true` — split the whole tab

```lua
pane:split {
  direction = 'Bottom',
  top_level = true,
  args = { 'bash' },
  size = { Percent = 25 },
}
```

Without `top_level`, the new pane carves space out of the *current* pane (whatever group of splits it lives in). With `top_level`, it spans the full bottom edge of the tab — useful for status/log strips that should run the entire width regardless of the current split layout.

### `size` — relative vs absolute

```lua
-- 30% of the parent's space, on the right
pane:split { direction = 'Right', size = { Percent = 30 } }

-- exactly 12 cells tall, on the bottom
pane:split { direction = 'Bottom', size = { Cells = 12 } }

-- bare-number form (also accepted by pane:split)
pane:split { direction = 'Right', size = 0.3 }   -- 30%
pane:split { direction = 'Right', size = 80 }    -- 80 cells
```

The `SplitPane` action accepts only the structured form (`{ Cells = N }` / `{ Percent = N }`).

### Action form — when you're authoring a key binding

```lua
{ key = '"', mods = 'CTRL|SHIFT', action = wezterm.action.SplitPane {
  direction = 'Down',
  command = { args = { 'pwsh' } },
  size = { Percent = 40 },
} },
```

This is the natural shape for `config.keys`. Inside an `action_callback`, prefer `pane:split` — see *Gotchas*.

## Gotchas

### Direction names differ between the two paths

`pane:split` wants `Top` / `Bottom`; `SplitPane` wants `Up` / `Down`. Mixing them silently no-ops:

```lua
-- BROKEN: 'Down' is not a pane:split direction
pane:split { direction = 'Down', args = ... }   -- nothing visible happens

-- BROKEN: 'Top' is not a SplitPane direction
window:perform_action(wezterm.action.SplitPane {
  direction = 'Top', command = { args = ... },
}, pane)
```

Neither raises a Lua error in our experience — the call returns and the user sees no split. termtools translates at the user-facing boundary via `DIRECTION_MAP` (`lua/actions.lua:20-24`) so callers can write whichever feels natural.

### `window:perform_action(SplitPane, pane)` is racy from inside an `action_callback`

This is the one that bit termtools. When a picker (`InputSelector`) confirms a choice, its `action_callback` runs while the modal is closing — the GUI action queue is mid-tear-down. Dispatching another action there sometimes lands, sometimes gets dropped:

> "takes several attempts before it fires" — observed when the inline-editor open path went through `perform_action(SplitPane)`.

The fix is to bypass the queue entirely. `pane:split` is a synchronous mux call; it doesn't care about the GUI action loop's state. termtools migrated `M.open_in_editor` and the `New Claude pane` / `New shell pane` catalogue entries from `perform_action(SplitPane)` to `pane:split` for exactly this reason.

Rule of thumb: **if you're already inside an `action_callback` and want to split, use `pane:split`.** If you're outside callback context (a key binding's direct action, a `format-tab-title` callback, etc.), either path is safe.

See [11-pickers.md](11-pickers.md) for more on the modal-confirm race; [08-actions-and-keys.md](08-actions-and-keys.md) for the action queue's general semantics.

### Return-value asymmetry

`pane:split` returns the new Pane immediately. `perform_action(SplitPane, pane)` returns nothing — the action is queued, and there's no synchronous handle to the result.

If you need to do something to the new pane (rename it, send initial text, capture its `pane_id`), `pane:split` is the only path:

```lua
local new_pane = pane:split { direction = 'Right', args = { 'bash' } }
new_pane:send_text('cd ~/work\r')
```

To do the same after a `SplitPane` action, you'd have to scan tabs for a fresh pane id — clumsy.

### `pane:split` skips action-queue side effects

`perform_action` runs the action through the GUI's dispatch path, which means any keytable activations or pre-action hooks bound to that action fire. `pane:split` skips all of that. termtools doesn't bind anything to splits, so it's a non-issue here — but if you add a hook that, say, shows a status line during split mode, the `pane:split` path won't trigger it.

### `cwd` defaults to the parent pane's CWD

If you omit `cwd`, the new pane inherits — usually what you want for "open another shell here." If you need a specific directory (e.g. project root regardless of where the user has wandered), pass `cwd = root` explicitly. Both built-in pane-spawn entries (`New Claude pane`, `New shell pane`) pass `cwd = root` because they're project-rooted; the inline-editor split *omits* `cwd` because the editor is opening a specific file path, not running in some arbitrary directory.

### `args = {}` (or omitted) inherits the user's default shell

Same as everywhere else in the spawn surface (see [06-spawning.md](06-spawning.md)). On Windows, that means whatever `default_prog` resolves to — usually pwsh / cmd. Don't assume bash.

### Both paths activate the new pane

Neither has a flag to keep focus on the original. The new pane becomes active, the old one loses focus. If you need the inverse, capture the old pane id first and re-activate after the split:

```lua
local old = pane
pane:split { direction = 'Right', args = { 'top' } }
old:activate()   -- bring focus back
```

### `top_level` only works on `pane:split` and `SplitPane`, not the legacy actions

`SplitHorizontal` / `SplitVertical` predate `top_level` and silently ignore it. If you need full-edge splits, use one of the two modern paths.

### `size` shapes vary slightly

| Form | `pane:split` | `SplitPane` action |
| --- | --- | --- |
| `{ Cells = 10 }` | yes | yes |
| `{ Percent = 30 }` | yes | yes |
| `0.3` (bare number, fraction) | yes | no |
| `10` (bare number, cells) | yes | no |

If you're writing code that picks a path conditionally, use the structured form everywhere — it works in both.

### The `pane` argument to `perform_action` is the *target*, not the source

`window:perform_action(SplitPane{...}, pane)` splits *that* pane, not necessarily the active one. Useful when an event hands you a pane you want to operate on regardless of focus. `pane:split` makes this implicit — the receiver *is* the target.

## See also

- [04-pane-window-tab.md](04-pane-window-tab.md) — the Pane object and its other methods.
- [06-spawning.md](06-spawning.md) — the broader `SpawnCommand` shape, `SpawnCommandInNewTab`, `background_child_process`.
- [08-actions-and-keys.md](08-actions-and-keys.md) — `wezterm.action.*`, action queue, the dispatch race that motivates the `pane:split` migration.
- [11-pickers.md](11-pickers.md) — modal callback context where the `perform_action` race manifests.
