# 09 — Mouse bindings

Click, drag, and scroll-wheel handling. The shape mirrors `config.keys` but the event side is richer (button, streak, up vs down vs drag) and the actions are mostly distinct from key actions. See [08-actions-and-keys.md](08-actions-and-keys.md) for the keyboard half; this file covers mouse-only territory.

## Overview

`config.mouse_bindings` is an array of `{ event, mods, action }` entries — same general shape as `config.keys`, but `event` is a tagged structure rather than a string. WezTerm matches on:

- **The button event** — `Down`, `Up`, or `Drag`, each carrying `{ streak, button }`. Streak is the click count (1 single, 2 double, 3 triple). Button is `'Left' | 'Right' | 'Middle'`, or for the wheel a nested table `{ WheelUp = N }` / `{ WheelDown = N }`.
- **Modifiers** — `'NONE'`, `'CTRL'`, `'SHIFT'`, `'ALT'`, `'SUPER'`, joined with `|` (`'CTRL|SHIFT'`).
- **Optional filters** — `mouse_reporting = bool` (only when the program does/doesn't have mouse reporting enabled) and `alt_screen = true | false | 'Any'`.

Both `Down` and `Up` fire for every click. Most user-facing actions (open link, paste) bind to `Up` so they fire after the click completes — matches OS conventions and lets the user cancel by dragging away. Selection actions are split: `Down` starts the selection (`SelectTextAtMouseCursor`), `Drag` extends it (`ExtendSelectionToMouseCursor`), `Up` finalises and copies (`CompleteSelection`).

## Key APIs

### `config.mouse_bindings`

```lua
config.mouse_bindings = {
  { event = { Up = { streak = 1, button = 'Left' } },
    mods  = 'CTRL',
    action = wezterm.action.OpenLinkAtMouseCursor },
}
```

Each entry's `action` is any `wezterm.action.*` value or a `wezterm.action_callback(fn)`. The optional fields:

- `mouse_reporting = true` — only fire when the foreground program has mouse reporting on (via `DECSET 1000`/`1003`/etc.). Default matches always.
- `alt_screen = false` — only fire on the main screen, not the alt screen (vim, less, etc.). Default `'Any'`.

Wheel-scroll bindings only apply when `alt_screen = false` because alt-screen apps usually translate the wheel into arrow keys themselves.

### Event shapes

| Event | Use |
| --- | --- |
| `{ Down = { streak = N, button = 'Left' } }` | press began |
| `{ Up = { streak = N, button = 'Left' } }` | press released — most "do something" bindings live here |
| `{ Drag = { streak = N, button = 'Left' } }` | mouse moved while held; fires continuously |

For wheel:

```lua
event = { Down = { streak = 1, button = { WheelUp = 1 } } }
event = { Down = { streak = 1, button = { WheelDown = 1 } } }
```

The `1`s are required but inert — wezterm sets streak and wheel-amount to 1 for matching purposes, the actual delta is delivered to the action via `ScrollByCurrentEventWheelDelta`.

### Mouse-specific actions

- `SelectTextAtMouseCursor 'Cell' | 'Word' | 'Line' | 'Block' | 'SemanticZone'` — start (or replace) a selection at the cursor with the given granularity.
- `ExtendSelectionToMouseCursor 'Cell' | 'Word' | 'Line' | 'Block'` — extend the current selection out to the cursor with the given granularity. Bound to `Drag` to continue a selection that started in `Down`.
- `CompleteSelection 'Clipboard' | 'PrimarySelection' | 'ClipboardAndPrimarySelection'` — finalise the in-progress selection and copy. Bound to `Up`. Without this, the selection visually appears but never lands on the clipboard.
- `CompleteSelectionOrOpenLinkAtMouseCursor 'Clipboard' | 'PrimarySelection' | 'ClipboardAndPrimarySelection'` — same, but if there's no in-progress selection, it instead opens the OSC 8 link under the cursor. The default plain-left-click binding.
- `OpenLinkAtMouseCursor` — open the URI at the cursor (OSC 8 hyperlink, or a recognised URL pattern). No clipboard interaction.
- `ScrollByCurrentEventWheelDelta` / `ScrollByLine N` / `ScrollByPage N` — scroll the viewport. The `CurrentEventWheelDelta` form respects the actual wheel motion; the others are fixed amounts.
- `Nop` / `DisableDefaultAssignment` — explicit "do nothing", used to suppress a default binding.

### Related config keys

- `mouse_wheel_scrolls_tabs = true` — wheel over the tab bar switches tabs. Cheap quality-of-life, off by default.
- `alternate_buffer_wheel_scroll_speed` — number of arrow-key presses synthesised per wheel notch when the alt screen is active. Default 3.
- `swallow_mouse_click_on_pane_focus = true` — clicks that focus a pane don't also reach the program inside. Useful with mouse-aware TUIs.
- `pane_focus_follows_mouse = true` — focus shifts under the cursor without a click.
- `bypass_mouse_reporting_modifiers = 'SHIFT'` — when a pane has mouse reporting on, holding this modifier lets you select/scroll locally instead. Default is SHIFT.

## Examples

### Plain `Ctrl+Click` to open links (default)

This is wezterm's built-in default, shown for reference:

```lua
{ event = { Up = { streak = 1, button = 'Left' } },
  mods = 'CTRL',
  action = wezterm.action.OpenLinkAtMouseCursor },
```

Bound to `Up` so the click completes before the URL opens. Pairing with `Down`+`Nop` is recommended if the program inside has mouse reporting on — see *Gotchas*.

### Copy-on-select (single click finalises selection)

`lua/style.lua:148`:

```lua
if s.copy_on_select then
  config.mouse_bindings = config.mouse_bindings or {}
  table.insert(config.mouse_bindings, {
    event = { Up = { streak = 1, button = 'Left' } },
    mods  = 'NONE',
    action = wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
  })
end
```

Replaces the default `Up{Left}` binding. After the user drags-to-select, releasing the button copies to both clipboard and primary. If they didn't drag, it falls through to opening the link under the cursor.

### Right-click pastes

`lua/style.lua:157`:

```lua
if s.right_click_paste then
  config.mouse_bindings = config.mouse_bindings or {}
  table.insert(config.mouse_bindings, {
    event = { Down = { streak = 1, button = 'Right' } },
    mods  = 'NONE',
    action = wezterm.action.PasteFrom 'Clipboard',
  })
end
```

Familiar Windows-terminal behaviour. Bound to `Down` because the user expects paste to fire as soon as the button presses (the "release" half is silent).

### `Ctrl+Shift+Click` opens the selection in an editor

`lua/style.lua:166`:

```lua
if s.open_selection_on_click then
  config.mouse_bindings = config.mouse_bindings or {}
  -- Binding the Down event with the explicit CTRL|SHIFT mod combo means
  -- the default "Down{Left} clears selection" path doesn't fire, so the
  -- selection persists into our handler.
  table.insert(config.mouse_bindings, {
    event = { Down = { streak = 1, button = 'Left' } },
    mods  = 'CTRL|SHIFT',
    action = wezterm.action.EmitEvent 'termtools.open-selection',
  })
end
```

Two subtleties worth calling out:

1. The handler reads the *selection text* (via `window:get_selection_text_for_pane(pane)`), not the URI under the cursor. The user double-clicks a path, then `Ctrl+Shift+Click`s anywhere — the selection is what gets routed.
2. The binding is on `Down`, not `Up`. Wezterm's default `Down{Left}` clears the selection, but a *different mod combo* registers as a different binding entirely, so the default never runs and the selection survives into the handler.

### Drag-to-select-words (default)

```lua
{ event = { Drag = { streak = 2, button = 'Left' } },
  mods = 'NONE',
  action = wezterm.action.ExtendSelectionToMouseCursor 'Word' },
```

Shipped as a default. The `streak = 2` matches "second click held and dragged" — i.e. double-click-drag — and grows the selection a word at a time rather than a cell at a time.

### Wheel-up scrolls 5 lines

```lua
{ event = { Down = { streak = 1, button = { WheelUp = 1 } } },
  mods = 'NONE',
  alt_screen = false,
  action = wezterm.action.ScrollByLine(-5) },
```

`alt_screen = false` ensures vim/htop/less still see the wheel as arrow keys. `Down` is the conventional wheel event; there's no `Up` for wheels.

### Suppressing a default

```lua
-- Disable the default Ctrl+Click open-link.
{ event = { Up = { streak = 1, button = 'Left' } },
  mods = 'CTRL',
  action = wezterm.action.DisableDefaultAssignment },
```

`DisableDefaultAssignment` removes wezterm's binding without replacing it. `Nop` does the same but swallows the event from the program too — useful when you also want to block a `Down` partner.

## Gotchas

### `Up` bindings without `Down` partners leak the press to the program
If you bind only the `Up` half of a click, the `Down` half still goes to the foreground program (when mouse reporting is on). Bind `Down{button}` to `Nop` if you want to fully claim the click. The wezterm docs call this out explicitly.

### `CompleteSelection` is the partner of `SelectTextAtMouseCursor`
Without a `CompleteSelection` (or `CompleteSelectionOrOpenLinkAtMouseCursor`) on the `Up` event, double-click visually selects but never copies. The default bindings include both halves; if you replace `Up{Left}` with something else, you've broken copy-on-select unless your replacement also completes.

### `Drag` events fire continuously while held
Every cursor movement during a held button is one event. Don't do expensive work inside a `Drag` action callback — it'll lag the cursor. The built-in `ExtendSelectionToMouseCursor` is fine; custom Lua-side callbacks should debounce (e.g. via `wezterm.time.call_after` with a guard, see [12-state-and-timing.md](12-state-and-timing.md)).

### Streak counting is timing-dependent
Streak increments only if the next click lands within wezterm's debounce window and within the same cell. Rapid double-clicks on a slow display, or clicks that drift between cells, can register as two streak-1 events instead of one streak-2. There's no Lua knob for the threshold.

### `SemanticZone` selection needs OSC 133
`SelectTextAtMouseCursor 'SemanticZone'` only does anything useful if the shell emits OSC 133 prompt markers (zsh / bash with shell-integration; pwsh with the wezterm module). Bare `pwsh.exe` and `cmd.exe` don't, so the binding falls back to behaving like `'Line'`. See [15-osc-and-clipboard.md](15-osc-and-clipboard.md).

### Hyperlinks vs file paths in `Ctrl+Shift+Click`
`OpenLinkAtMouseCursor` reads the URI under the cursor — that's an OSC 8 hyperlink (set by `ls --hyperlink` etc.) or a wezterm-detected URL pattern. termtools' `Ctrl+Shift+Click` is *different* — it reads `window:get_selection_text_for_pane(pane)`, which is whatever the user already double-click-selected. Click without a selection toasts; click with a selection routes to the editor. The two paths can't be conflated.

### `SUPER` modifier portability
`SUPER` is Cmd on macOS, the Windows logo key on Windows, and Super on Linux. A binding using `SUPER` works everywhere but means three different physical keys. `ALT` on macOS is Option, which the OS may also use to type composed characters — see `send_composed_key_when_left_alt_is_pressed` in [03-config.md](03-config.md).

### `Down` clearing selections
Wezterm's default `Down{Left}` with `mods = 'NONE'` clears any active selection before the press lands. Different-mod variants are independent bindings, so binding `Down{Left}` with `'CTRL|SHIFT'` does *not* trigger the clear. termtools relies on this in `style.lua:171`.

### Wheel event button shape is nested
The button is `{ WheelUp = 1 }`, not `'WheelUp'`. The number is required for the matcher even though the actual scroll delta arrives with the event. Easy to mistype; the failure mode is silent (the binding never matches).

### `mouse_reporting` filter is opt-in
By default, mouse bindings match regardless of whether the foreground program has mouse reporting on. If you want a binding that *only* applies when reporting is off (so the program doesn't get its mouse stolen), add `mouse_reporting = false`. The reverse — bindings that fire only when a TUI has reporting on — uses `mouse_reporting = true`.

## See also

- [08-actions-and-keys.md](08-actions-and-keys.md) — `wezterm.action.*` catalogue, `EmitEvent`, `action_callback`, key-binding shape that mouse-binding shape mirrors.
- [04-pane-window-tab.md](04-pane-window-tab.md) — `window:get_selection_text_for_pane(pane)` (selection access from a mouse-event handler), `pane:get_semantic_zones` (the OSC 133 surface that `SemanticZone` selection rides on).
- [15-osc-and-clipboard.md](15-osc-and-clipboard.md) — OSC 8 hyperlinks (read by `OpenLinkAtMouseCursor`), OSC 133 (semantic zones), clipboard targets used by `CompleteSelection`.
- [10-events.md](10-events.md) — `EmitEvent` dispatching from a mouse binding into a registered handler (the termtools `open-selection` pattern).
