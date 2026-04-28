# 11 — Pickers

Modal input surfaces. `InputSelector` is a fuzzy-finding chooser; `PromptInputLine` is a free-text prompt. Both are *actions* you dispatch via `window:perform_action`, and both fire an `action_callback` with the user's choice when they confirm (or `nil` on cancel). termtools leans on `InputSelector` for the project picker, the action picker, and the per-kind editor switchers.

## Overview

A picker is a transient overlay pane. WezTerm renders it on top of the active pane, draws a filter line and a list, and routes keystrokes to its own internal navigation until the user confirms with `Enter` or cancels with `Esc`/`Ctrl+G`/`Ctrl+C`. While the modal is open, your callback hasn't run yet — the choice doesn't exist. When the user confirms, the modal closes and the callback fires with `(window, pane, id, label)` for `InputSelector` or `(window, pane, line)` for `PromptInputLine`.

Two consequences of the action+callback shape:

1. **You build the choice list at dispatch time, not at config-evaluation time.** The action's `choices` field is a fixed array — once dispatched, it's frozen for that modal. Refresh against live data inside the function that wraps the `perform_action` call (a `wezterm.on` handler, an `action_callback`, an `EmitEvent` handler), never at the top of the config chunk.
2. **The pane and window arguments are GUI handles**, not mux handles. They're what you'd pass to `window:perform_action`, `pane:split`, `pane:send_text`, etc. directly — see [04-pane-window-tab.md](04-pane-window-tab.md).

The full GUI key-event taxonomy lives in [08-actions-and-keys.md](08-actions-and-keys.md); pickers are the action-callback shape applied to a built-in modal UI.

## Key APIs

### `wezterm.action.InputSelector { ... }`

Modal fuzzy chooser. Required fields are `choices` and `action`; everything else has a default.

| Field | Shape | Default | What it does |
| --- | --- | --- | --- |
| `title` | string | `""` | Shown in the overlay pane's title bar |
| `choices` | `{ id, label }[]` | required | The selectable rows. `label` is what's displayed; `id` is what your callback gets back |
| `action` | `KeyAssignment` | required | An `action_callback` (or any other action). Receives `(window, pane, id, label)` |
| `fuzzy` | bool | `false` | Start in fuzzy-matching mode rather than exact-prefix mode |
| `fuzzy_description` | string | `"Fuzzy matching: "` | Prompt text shown next to the filter while in fuzzy mode |
| `description` | string | `"Select an item and press Enter = accept, Esc = cancel, / = filter"` | Prompt text in non-fuzzy mode |
| `alphabet` | string | `"1234567890abcdefghilmnopqrstuvwxyz"` | Characters that act as quick-select shortcuts to visible rows |

Each choice is a table — both fields are strings:

```lua
choices = {
  { id = '1', label = 'first option' },
  { id = '2', label = 'second option' },
}
```

`label` may also be a [`wezterm.format`](13-format-and-colors.md) result for italic/colour/bold formatting (the project picker uses this for status markers; the action picker uses it for dimming).

`id` is the value handed back to your callback; if you omit it, `label` is used as the id. termtools always sets `id = tostring(i)` and converts back with `tonumber(id)` because the choices are addressed by index into a parallel array — see *Examples*.

The `action` callback is invoked synchronously after the modal closes:

```lua
wezterm.action_callback(function(window, pane, id, label)
  if not id then return end   -- user cancelled
  -- ... id is the chosen choice's id field; label is its label
end)
```

`id` and `label` are both `nil` on cancel (Esc / Ctrl+G / Ctrl+C).

### `wezterm.action.PromptInputLine { ... }`

Free-text prompt. One line, no list.

| Field | Shape | Default | What it does |
| --- | --- | --- | --- |
| `description` | string (or `wezterm.format` result) | `""` | Header shown above the input |
| `action` | `KeyAssignment` | required | Callback receiving `(window, pane, line)` |
| `initial_value` | string | `nil` | Pre-fills the input line |
| `prompt` | string | `"> "` | The prompt prefix shown next to the input (recent-ish addition) |

Cancel returns `line == nil`. Submitting an empty input returns `line == ""`. Distinguish the two if it matters.

### `wezterm.action_callback(fn)` — the callback wrapper

```lua
wezterm.action_callback(function(window, pane, ...) end)
```

Returns a `KeyAssignment` value, suitable for `InputSelector { action = ... }`, `PromptInputLine { action = ... }`, key bindings, mouse bindings, etc. Internally it synthesises a unique event id, registers a one-shot `wezterm.on` for it, and returns an `EmitEvent` action targeted at that id. The `...` extra args are whatever the dispatching surface forwards — `id, label` for `InputSelector`, `line` for `PromptInputLine`, nothing extra for plain key/mouse bindings.

The closure runs **synchronously** on the GUI thread. Heavy work blocks input — see [08-actions-and-keys.md](08-actions-and-keys.md) and [12-state-and-timing.md](12-state-and-timing.md).

### `alphabet` — quick-select shortcuts

A string of single characters. Each visible row picks up the next character as a hotkey: pressing it (without modifiers) selects the row immediately, no Enter required. The default alphabet (`"1234567890abcdefghilmnopqrstuvwxyz"`) covers up to 35 visible rows. Setting `alphabet = '1234567890'` limits to 10 rows but reserves all letters for typing into the filter — useful when your `label` text starts with letters that would otherwise jump-select.

### Built-in navigation keys (not configurable)

| Key | Action |
| --- | --- |
| `Up` / `Ctrl+P` / `Ctrl+K` | Previous row |
| `Down` / `Ctrl+N` / `Ctrl+J` | Next row |
| `PageUp` / `PageDown` | Jump by a page |
| `Enter` / `LeftClick` | Confirm selection |
| `Backspace` | Delete from filter |
| `/` | Toggle fuzzy mode |
| `Esc` / `Ctrl+C` / `Ctrl+G` | Cancel |

`j` / `k` work as Vim-style movement *only* when they aren't in the `alphabet`; with the default alphabet they jump-select instead.

## Examples

### termtools' action picker — fuzzy column display, three-way classification

`lua/pickers/action.lua:139-165` — the full `InputSelector` call with id-by-index, dim styling for advisory rows, and `pcall`-wrapped dispatch. The interesting bits:

```lua
-- lua/pickers/action.lua:107-137 — build choices from a sorted action list
local choices = {}
for i, label in ipairs(order) do
  local action = by_label[label]
  -- ... resolve the description (string or function)
  local plain = (desc and desc ~= '')
    and string.format('%-' .. max_w .. 's   %s', label, desc)
    or label

  local display
  if dimmed[label] or disabled[label] then
    display = wezterm.format {
      { Attribute = { Italic = true } },
      { Foreground = { Color = '#93a1a1' } },
      { Text = plain },
      'ResetAttributes',
    }
  else
    display = plain
  end
  choices[i] = { id = tostring(i), label = display }
end

window:perform_action(
  wezterm.action.InputSelector {
    title = 'Action: ' .. proj_name,
    choices = choices,
    fuzzy = true,
    action = wezterm.action_callback(function(w, p, id, _label)
      if not id then return end                    -- cancel
      local idx = tonumber(id)
      if not idx or not order[idx] then return end -- defensive
      local picked = order[idx]
      if disabled[picked] then
        w:toast_notification('termtools',
          picked .. ' is unavailable for this project.', nil, 1500)
        return
      end
      local entry = by_label[picked]
      if not entry or not entry.run then return end
      local target_pane = w:active_pane() or p
      local ok, err = pcall(entry.run, w, target_pane, root)
      if not ok then
        wezterm.log_error('termtools: action "' .. picked
          .. '" failed: ' .. tostring(err))
      end
    end),
  },
  pane
)
```

Three patterns worth lifting:

- **Index-as-id.** `choices[i] = { id = tostring(i), label = ... }`, then `tonumber(id)` on the way out, then `order[idx]` resolves back to the sorted-array entry. Lets `label` be a freely-formatted display string while `id` stays a stable handle.
- **`wezterm.format` for dim/disabled rows.** Italic + an explicit foreground colour. The plain `Foreground = ...` table style uses the format DSL covered in [13-format-and-colors.md](13-format-and-colors.md). The `'ResetAttributes'` string at the end stops the dim styling leaking into the next row's render.
- **Re-fetch the active pane.** `target_pane = w:active_pane() or p`. The `p` argument is the closure-captured pane from when the picker opened; the user may have switched focus or closed that pane while choosing. Prefer the live focus, fall back to the original. See *Gotchas*.

### termtools' project picker — `wezterm.format` for status markers

`lua/pickers/project.lua:199-232` builds rich labels showing `●` (open) or `○` (closed), name in amber if MRU, dim path text, and a tab-count suffix. The `format_label` helper at `lua/pickers/project.lua:136-162` does the format-list construction; the callback at `lua/pickers/project.lua:204-229` records the MRU entry, looks for an existing tab to activate, and otherwise spawns a new tab via `SpawnCommandInNewTab`:

```lua
-- lua/pickers/project.lua:189-232 — the dispatch shape
local choices = {}
for i, entry in ipairs(list) do
  local count = tabs_count[entry.path] or 0
  local is_mru = mru_positions[entry.path] ~= nil
  choices[i] = {
    id = tostring(i),
    label = format_label(entry, count, is_mru, name_w),  -- wezterm.format result
  }
end

window:perform_action(
  wezterm.action.InputSelector {
    title = string.format('Switch to project  (sort: %s)', mode),
    choices = choices,
    fuzzy = true,
    action = wezterm.action_callback(function(w, p, id, _label)
      if not id then return end
      local entry = list[tonumber(id)]
      if not entry then return end
      mru_push(entry.path)
      -- ... activate existing tab, or spawn a fresh one
      local target_pane = w:active_pane() or p
      w:perform_action(
        wezterm.action.SpawnCommandInNewTab { cwd = entry.path, args = cmd },
        target_pane
      )
    end),
  },
  pane
)
```

Note the `SpawnCommandInNewTab` action dispatched from inside the callback is safe — it operates on the tab strip, not on the modal's pane group. The racy case is `SplitPane` from inside a picker callback; see *Gotchas*.

### termtools' editor switcher — optional "(disable)" row, GLOBAL state update

`lua/actions.lua:113-169`, `pick_editor_modal`. Filters the registry by `kind`, optionally prepends a `(disable)` row, sets `wezterm.GLOBAL[global_key]` on confirm, and toasts a confirmation:

```lua
-- lua/actions.lua:128-168
table.sort(names)
local entries = {}
if allow_disable then
  entries[#entries + 1] = { name = nil, label = '(disable)' }
end
for _, name in ipairs(names) do
  local spec = registry[name]
  entries[#entries + 1] = {
    name = name,
    label = string.format('%-12s %s', name, table.concat(spec.cmd, ' ')),
  }
end

local choices = {}
for i, e in ipairs(entries) do
  choices[i] = { id = tostring(i), label = e.label }
end

window:perform_action(
  wezterm.action.InputSelector {
    title = title,
    choices = choices,
    fuzzy = true,
    action = wezterm.action_callback(function(w, _p, id, _label)
      if not id then return end
      local entry = entries[tonumber(id)]
      if not entry then return end
      wezterm.GLOBAL = wezterm.GLOBAL or {}
      if allow_disable and entry.name == nil then
        wezterm.GLOBAL[global_key] = false
        if w then w:toast_notification('termtools',
          'Inline editor disabled.', nil, 1500) end
      else
        wezterm.GLOBAL[global_key] = entry.name
        if w then w:toast_notification('termtools',
          kind:gsub('^%l', string.upper) .. ' editor: ' .. entry.name, nil, 1500) end
      end
    end),
  },
  pane
)
```

The `false` vs `nil` distinction in `wezterm.GLOBAL[global_key]` is load-bearing: callers read `nil = "no override, use the configured default"` and `false = "explicitly disabled by the user."` Cancelling the picker (id is nil) leaves the existing GLOBAL state untouched — distinct from a deliberate `(disable)` selection.

### `PromptInputLine` — rename the active tab

```lua
{ key = ',', mods = 'LEADER', action = wezterm.action.PromptInputLine {
  description = 'Enter new tab title',
  action = wezterm.action_callback(function(window, _pane, line)
    if not line then return end          -- cancel
    if line == '' then return end        -- empty submit — leave title alone
    local tab = window:active_tab()
    if tab then tab:set_title(line) end
  end),
} },
```

`window:active_tab()` here returns the GUI window's active MuxTab; `tab:set_title(line)` overrides any auto-title rule. See [04-pane-window-tab.md](04-pane-window-tab.md) for the tab object.

### `alphabet = '1234567890'` — digits jump to rows, letters reserved for filter

```lua
wezterm.action.InputSelector {
  title = 'Pick a profile',
  choices = profiles,
  fuzzy = true,
  alphabet = '1234567890',  -- digits 1..9, 0 are quick-select; letters go to filter
  action = wezterm.action_callback(function(window, pane, id, _label)
    -- ...
  end),
}
```

With this alphabet, pressing `1` jumps to the first row, `2` to the second, etc. Pressing `a` types `a` into the fuzzy filter. The default alphabet eats every lowercase letter except `f`/`g`/`j`/`k` (those are reserved for navigation), which is rarely what you want once your filter terms start with letters.

### `wezterm.format` in `description`

Either field that takes string text accepts a `wezterm.format` result for rich attributes:

```lua
wezterm.action.PromptInputLine {
  description = wezterm.format {
    { Attribute = { Intensity = 'Bold' } },
    { Foreground = { AnsiColor = 'Yellow' } },
    { Text = 'Rename tab:' },
    'ResetAttributes',
  },
  action = ...,
}
```

Plain strings are fine for the common case; reach for the format DSL when the prompt should stand out or carry colour cues.

## Gotchas

### No wrap-around in `InputSelector`

Pressing `Up` at the top row stays on the top row; same for `Down` at the bottom. WezTerm doesn't expose a config option to change this. Live with it, or set `alphabet` to digits and tell users to jump by number when the list is long.

### `alphabet` consumes typed characters

Any character in `alphabet` is a quick-select shortcut, **not** typing into the fuzzy filter. With the default alphabet, typing `a` selects whatever row the `a` shortcut is bound to instead of starting a filter for "a...". If your labels begin with letters users will type to filter, set `alphabet = '1234567890'` (or `''` if you want pure-fuzzy mode) so the letter keys reach the filter unmolested. Trade-off: fewer quick-select rows.

### Dispatching `SplitPane` from inside an `action_callback` is racy

When a picker confirms, the modal's tear-down and your callback's body run roughly simultaneously through the GUI's action queue. Dispatching another action that targets the *modal's pane group* — `SplitPane`, especially — sometimes lands and sometimes gets dropped, with no error.

The fix is to bypass the action queue. `pane:split { ... }` is a synchronous mux call; it doesn't care about the GUI's modal-tear-down state. termtools migrated `M.open_in_editor` and the `New Claude pane` / `New shell pane` catalogue entries to `pane:split` for exactly this reason. See [07-splits.md](07-splits.md) for the full story and the `pane:split` direction-name vocabulary (`Top`/`Bottom`, *not* `Up`/`Down`).

`SpawnCommandInNewTab` from inside a callback is safe — it operates on the tab strip, not the modal's containing pane group. termtools' project picker uses `w:perform_action(SpawnCommandInNewTab{...}, target_pane)` and it fires reliably on every confirm.

### The `pane` argument to your callback is the *original* active pane

The callback's `pane` parameter is whatever was active when the modal **opened**. By the time the user confirms a choice, focus may have moved, or the original pane may have closed. termtools' pattern, used at `lua/pickers/action.lua:156` and `lua/pickers/project.lua:221`:

```lua
local target_pane = w:active_pane() or p
```

`w:active_pane()` queries the *current* focus; `p` is the original. Prefer current, fall back to original. Calling methods on a closed pane raises a Lua error rather than returning `nil`, so a bare `p:split{...}` after a closed-pane case will explode.

There's also a brief focus-transition window right as the modal closes — `w:active_pane()` may briefly return the modal's overlay pane handle in older WezTerm versions. The `or p` fallback keeps things working if it does.

### Cancel returns `nil` for everything

`InputSelector` callback: `(window, pane, nil, nil)` on cancel. `PromptInputLine` callback: `(window, pane, nil)` on cancel. Always check at the top:

```lua
action = wezterm.action_callback(function(w, p, id, _label)
  if not id then return end
  -- ...
end)
```

For `PromptInputLine`, *empty submit* (`line == ""`) is distinct from cancel (`line == nil`) — distinguish them if behaviour should differ.

### `choices.id` must be a string

Numbers don't error at config load but cause weird mismatches in the callback. termtools always converts via `tostring(i)` when building the array and `tonumber(id)` on the way out:

```lua
choices[i] = { id = tostring(i), label = ... }
-- ...
local idx = tonumber(id)
if not idx or not order[idx] then return end
```

If you skip the `id` field entirely, the `label` text is used as the id — fine for short label strings, breaks for `wezterm.format` results because the rendered display string contains escape sequences.

### `label` rendering supports `wezterm.format`; plain strings are fine too

A bare string `label = 'Open project'` renders as plain text. A `wezterm.format { ... }` result renders with the encoded attributes (italic, foreground colour, etc.). Both work in the same `choices` array — termtools mixes them at `lua/pickers/action.lua:122-135`, where dim entries get the format treatment and enabled entries are plain strings.

### Pickers can't be nested cleanly

Opening a picker from inside another picker's callback works, but the second one opens *after* the first finishes its tear-down. There's no overlap, no stacking, no "wizard". If you need a multi-step flow, dispatch through events (or a `wezterm.time.call_after(0, ...)` defer — see [12-state-and-timing.md](12-state-and-timing.md)) rather than recursing into a fresh `perform_action` mid-callback.

### No keyboard shortcut config inside the modal

The navigation keys table above is baked into WezTerm's overlay implementation. There's no `key_tables` integration for `copy_mode`-style remapping inside an `InputSelector` or `PromptInputLine`. If a user really wants `gg` for top-of-list, they don't get it.

### `fuzzy` defaults to false; `fuzzy_description` defaults to "Fuzzy matching: "

Without `fuzzy = true`, the modal opens in prefix-match mode — typing `op` only matches rows starting with `op`. termtools always sets `fuzzy = true` because users expect tab-completion-style substring matching. The `fuzzy_description` is the prompt next to the filter line; default is acceptable but you can override for context (`'Filter projects: '`, etc.).

### `action_callback` runs synchronously

The body executes on the GUI thread. Filesystem walks, `wezterm.run_child_process`, large string parses — anything slower than a few milliseconds — visibly stutters input and delays the post-confirm focus transition. Defer expensive work via `wezterm.time.call_after(0, fn)` or hand off via `wezterm.background_child_process`. See [12-state-and-timing.md](12-state-and-timing.md).

### The picker only fires from a context that has a window

`window:perform_action(InputSelector{...}, pane)` is the only sane dispatch path. Trying to fire one from a `mux-startup` event won't work — there's no GUI window yet. From a `wezterm.on('augment-command-palette', ...)` handler, the window exists but the palette is itself a modal; opening a picker from inside a palette entry chains them sequentially (palette closes, picker opens) which is usually what you want.

## See also

- [07-splits.md](07-splits.md) — the `perform_action(SplitPane)`-from-callback race and the `pane:split` migration that fixes it.
- [08-actions-and-keys.md](08-actions-and-keys.md) — `wezterm.action_callback`, `EmitEvent`, and the broader action catalogue.
- [10-events.md](10-events.md) — alternative dispatch via shared `wezterm.on` handlers and `EmitEvent`, the cross-reload-safe way to share callbacks across many key bindings and palette entries.
- [13-format-and-colors.md](13-format-and-colors.md) — `wezterm.format`, the DSL for rich `label` and `description` strings.
- [04-pane-window-tab.md](04-pane-window-tab.md) — the `(window, pane)` objects your callback receives, and the `active_pane() or p` pattern in detail.
- [17-palette.md](17-palette.md) — `augment-command-palette`, a related modal that's *not* a picker (no callback, no fuzzy filter — it's a menu of actions).
