# 17 — Command palette

`augment-command-palette` lets you add entries to WezTerm's built-in `Ctrl+Shift+P` palette. You don't draw your own modal, you don't bind your own key — you piggy-back on the modal users already know, alongside WezTerm's own commands. termtools uses this as the primary discovery surface for per-project actions.

## Overview

The command palette is WezTerm's built-in fuzzy-finder over actions. Default trigger is `Ctrl+Shift+P` (`wezterm.action.ActivateCommandPalette`); it opens a modal listing every built-in command (Copy, Paste, SplitHorizontal, ReloadConfiguration, every workspace switch, etc.) and matches the typed filter against the labels.

`augment-command-palette` is a window event ([10-events.md](10-events.md)) that fires every time the palette opens. The handler returns an array of `PaletteEntry` tables; WezTerm appends them to the built-in list before rendering. Your entries are searched by the same fuzzy filter, selected with `Enter`, and dispatched as ordinary `KeyAssignment` actions.

Why prefer this over a custom `InputSelector`:

- **Discoverability.** Users already know `Ctrl+Shift+P`. They don't need to learn a new keystroke or remember a custom picker exists.
- **No key real-estate.** No binding to register, no chord conflict, no leader-table push.
- **Free filtering and navigation.** WezTerm renders the modal, runs the fuzzy match, handles `Up/Down/Enter/Esc`. You hand back data.

The trade-off: less control. The palette is uniform — no sections, no rich `wezterm.format` styling on rows, no three-way dim/disabled/enabled distinction. If the row needs that, fall back to a custom `InputSelector` ([11-pickers.md](11-pickers.md)) and bind it to a key.

## Key APIs

### `wezterm.on('augment-command-palette', fn)`

```lua
wezterm.on('augment-command-palette', function(window, pane)
  return {
    -- ... PaletteEntry tables ...
  }
end)
```

Called every time the palette opens. `window` and `pane` are the GUI handles for the active window and its active pane at the moment the palette was triggered. Return an array of `PaletteEntry`. Returning an empty array `{}` is fine — return `nil` and you may crash WezTerm's palette renderer (see Gotchas).

The handler is **synchronous** — block here and you delay the palette appearing. Don't `wezterm.run_child_process` inside it (errors out anyway: "attempt to yield outside a coroutine"). Cache anything expensive at module scope or behind a `wezterm.GLOBAL` sentinel.

### `PaletteEntry` shape

```lua
{
  brief  = 'Open project README',           -- required, string
  icon   = 'md_file_document',              -- optional, Nerd Font glyph name
  action = wezterm.action.EmitEvent 'foo',  -- required, KeyAssignment value
  doc    = 'longer description',            -- optional, extended doc text
}
```

| Field | Required | Shape | What it does |
| --- | --- | --- | --- |
| `brief` | yes | string | The user-visible label. Fuzzy filter matches against this. |
| `action` | yes | `KeyAssignment` | What runs on `Enter`. Any action from [08-actions-and-keys.md](08-actions-and-keys.md) — `EmitEvent`, `SpawnCommandInNewTab`, `ActivateKeyTable`, `ReloadConfiguration`, etc. **Not** a bare Lua function. |
| `icon` | no | string | Nerd Font glyph name (e.g. `'md_apps'`, `'cod_terminal'`, `'fa_play'`). Resolved against `wezterm.nerdfonts` at render time. |
| `doc` | no | string | Longer description shown alongside `brief` in some renderings. |

Older WezTerm releases also surfaced a `group` field for ordered grouping — newer builds have de-emphasised it; `brief` plus a project-name prefix is the reliable way to cluster related entries.

### `wezterm.action.ActivateCommandPalette`

The bare action that opens the palette. Default binding is `Ctrl+Shift+P`; rebind by adding it to `config.keys`:

```lua
{ key = ' ', mods = 'LEADER', action = wezterm.action.ActivateCommandPalette },
```

No arguments. Triggering it fires `augment-command-palette` synchronously, then renders the resulting list.

## Examples

### termtools' palette entries — `lua/palette.lua:18-53`

The whole module is short. Two static rows pointing at the project / action picker, then one dynamic row per merged action for the current project's root:

```lua
function M.entries(_window, pane, opts)
  opts = opts or {}

  local entries = {
    {
      brief = 'termtools: Project picker',
      icon  = 'cod_folder_opened',
      action = pickers.project_picker(),
    },
    {
      brief = 'termtools: Action picker (current project)',
      icon  = 'cod_play',
      action = pickers.action_picker(),
    },
  }

  local cwd = util.pane_cwd(pane)
  local root = projects.find_root(cwd) or cwd
  if not root then return entries end

  local override = projects.load_overrides(root, opts.trusted_paths)
  local proj_name = (override and override.name) or util.basename(root)

  for _, action in ipairs(pickers.list_actions(root, opts)) do
    entries[#entries + 1] = {
      brief = string.format('termtools [%s]: %s', proj_name, action.label),
      icon  = 'cod_terminal',
      -- Indirect via wezterm event so the action runs after the palette
      -- has fully closed. Direct action_callback dispatch from the
      -- palette can race with the palette teardown and silently no-op.
      action = wezterm.action.EmitEvent('termtools.run-action', root, action.label),
    }
  end

  return entries
end
```

Three patterns to lift:

- **Project-scoped prefix.** `termtools [project-name]: <label>` doubles as a search anchor. Typing `tt:` narrows to all termtools entries; typing `myproj run` finds run-actions in `myproj`.
- **Cheap project resolution.** `util.pane_cwd(pane)` is a single OSC-7 lookup; `projects.find_root` walks upward to a marker. The expensive bit (override-file read) is cached per-session inside `projects.load_overrides`.
- **Dispatch via `EmitEvent` with extras.** Each row carries `(root, label)` to one shared handler — the palette doesn't embed action closures. Receiving end below.

### Registration in `lua/init.lua:312-314`

Inside the one-shot `if not handlers_registered then` block:

```lua
wezterm.on('augment-command-palette', function(window, pane)
  return require('palette').entries(window, pane, M.opts())
end)
```

The handler defers to the `palette` module so the registration is one line and the logic is testable. `M.opts()` is read at dispatch time so a re-run `setup({...})` takes effect on the next palette open. The `if not handlers_registered` guard ([01-architecture.md](01-architecture.md)) keeps reload from stacking duplicate handlers — which would compound the issue, since each handler returns its own array and WezTerm concatenates them.

### The companion handler — `lua/init.lua:304-306`

The per-action palette rows emit `termtools.run-action` with `(root, label)`. The handler dispatches by label through the action picker's by-label runner:

```lua
wezterm.on('termtools.run-action', function(window, pane, root, label)
  pickers.run_action_by_label(window, pane, root, label, M.opts())
end)
```

`run_action_by_label` (`lua/pickers/action.lua:171-184`) re-resolves the action list for `root`, finds the matching entry, and `pcall`s its `run`. Re-resolving (rather than caching at palette-build time) handles the case where `visible_when` flipped between palette-open and `Enter`.

### Static one-row addition — Reload config

The simplest possible entry: one row, one bare action, no `EmitEvent` indirection.

```lua
wezterm.on('augment-command-palette', function(_window, _pane)
  return {
    { brief = 'Reload config', icon = 'md_refresh',
      action = wezterm.action.ReloadConfiguration },
  }
end)
```

The built-in already has "Reload Configuration" — this gives you a different brief / keyword. Bare `ReloadConfiguration` is fine because it takes no args.

### Dynamic enumeration — switch to a workspace

`SwitchToWorkspace` plus per-workspace rows gets you a fuzzy-find workspace switcher inside the palette users already know:

```lua
wezterm.on('augment-command-palette', function(_window, _pane)
  local entries = {}
  for _, workspace in ipairs(require('wezterm').mux.get_workspace_names()) do
    entries[#entries + 1] = {
      brief  = 'Workspace: ' .. workspace,
      icon   = 'md_view_dashboard',
      action = wezterm.action.SwitchToWorkspace { name = workspace },
    }
  end
  return entries
end)
```

Same pattern for any "list of named things to fuzzy-match into a context switch": tabs by title, recent CWDs, SSH domains.

## Gotchas

### The handler fires every time the palette opens

Fresh enumeration on every `Ctrl+Shift+P`. That's the right place to read live state — current project, current workspace list, current pane CWD — but a slow handler delays the palette appearing. Practical budget: the user expects the palette in well under 100 ms, ideally under 30. Anything heavier needs caching at module scope or behind `wezterm.GLOBAL`.

`palette.lua` keeps it cheap by deferring to already-cached project resolution; the override-file read is one-shot per session courtesy of `projects.load_overrides`.

### `brief` is the matched string

The fuzzy filter runs over `brief` only — not `doc`, not `icon`. To make an entry findable by a keyword that's not in the visible label, append it to `brief`. termtools' project-name prefix doubles as a search anchor for exactly this reason. If you want hidden keywords without uglifying the brief, a trailing low-emphasis suffix works, but usually the right answer is rewording the brief.

### Disabled actions can't be inert in the palette

WezTerm's palette has no idiomatic "dim and unselectable" state — every row is selectable; selecting a row dispatches its action. termtools' action picker has three states (enabled / dimmed / disabled) but the palette only surfaces enabled+dimmed. The comment at `lua/pickers/action.lua:69-71`:

```
-- Used by the command-palette augmentation. Includes enabled and dimmed
-- entries (both runnable); skips disabled ones since wezterm's palette has
-- no good way to mark a row as inert.
```

So the `M.list` helper used by palette enumeration filters disabled out entirely. If your action's `visible_when(root)` returns false, it doesn't appear in the palette at all — versus the picker, where it appears greyed out at the bottom and toasts "unavailable" when selected.

### `action` is a `KeyAssignment` value, not a Lua function

```lua
-- WRONG: bare closure crashes at palette-open time
{ brief = 'do thing', action = function(window, pane) end }

-- RIGHT: action_callback wraps the closure into a KeyAssignment
{ brief = 'do thing', action = wezterm.action_callback(function(w, p) end) }

-- BEST: EmitEvent into a shared, registered-once handler
{ brief = 'do thing', action = wezterm.action.EmitEvent 'termtools.do-thing' }
```

`action_callback` works but synthesises a fresh closure-and-event-id every time the palette opens (which is every keypress). `EmitEvent` to a pre-registered handler is the cross-reload-safe form — same reasoning as for keybindings ([08-actions-and-keys.md](08-actions-and-keys.md)).

### `EmitEvent` with arguments — table form vs call form

Both work, but the call form is what termtools uses everywhere:

```lua
-- Call form (extras as positional args)
action = wezterm.action.EmitEvent('termtools.run-action', root, label)

-- Table form (event name in [1], extras after)
action = wezterm.action.EmitEvent { 'termtools.run-action', root, label }
```

The handler signature is `function(window, pane, ...extras)` — `window` and `pane` are always prepended. Extras must be Lua values WezTerm can serialise across the dispatch boundary (numbers, strings, booleans, tables of those — not closures, not userdata).

### Icons are Nerd Font glyph names only

```lua
icon = 'md_apps'       -- Material Design "apps"
icon = 'cod_terminal'  -- Codicons "terminal"
icon = 'fa_play'       -- Font Awesome "play"
```

The string is resolved through `wezterm.nerdfonts` (the same lookup as `wezterm.nerdfonts.md_apps` from Lua). Pasting a literal unicode glyph into `icon` produces a broken render — look up the right Nerd Font name on the [cheat sheet](https://www.nerdfonts.com/cheat-sheet) or omit `icon` entirely. Entries without an icon render a blank icon column without breaking alignment.

### No way to suppress built-ins

`augment-command-palette` only **adds** entries. Built-in commands stay in the palette regardless. If users find a particular built-in noisy ("Spawn New Tab" appearing twice when they only want yours), the only workaround is to rename your entry so fuzzy-search prioritises it ahead of the built-in match.

### Returning `nil` is unsafe; empty array is fine

The contract is "an array of PaletteEntry tables". Returning `{}` is the right way to add nothing — WezTerm walks an empty array and proceeds. Returning `nil` has historically crashed the palette renderer in some versions; even where it doesn't, downstream code tries to `ipairs(nil)`. Always end your handler with an explicit `return entries` (where `entries` is at least `{}`).

### `action_callback` from the palette races the modal teardown

The comment at `palette.lua:46-47` is load-bearing: dispatching an `action_callback` directly from a palette row sometimes runs before the palette finishes tearing down, and the closure body silently no-ops. Bridging through `EmitEvent` to a registered handler defers the work onto the next event-loop turn, after the modal is gone. If you need to carry per-row state (a path, a label, a numeric id), bake it into the `EmitEvent` extras at palette-build time as `palette.lua:48` does.

### Fuzzy ranking favours prefix matches

WezTerm's palette fuzzy-matcher weights leading-character matches and word-boundary matches more heavily than mid-string matches. Typing `tt` finds a `termtools [...]:` entry ahead of "Cut This Tab" because the prefix is a stronger signal. This is a free win — pick your `brief` prefix to be the shortest-distinct query you'd want users to type. termtools chose `termtools [...]:` over `[...] (termtools):` for exactly this reason.

### `window` and `pane` may be `nil` in edge cases

When the palette is triggered very early in window construction (or by `wezterm cli`), `window` and `pane` can arrive as `nil`. termtools' handler treats a missing CWD as "no project context" and returns just the two static picker rows. Don't assume non-nil; branch defensively before calling methods.

## See also

- [08-actions-and-keys.md](08-actions-and-keys.md) — `KeyAssignment` types, `EmitEvent` shape and extras handling, why `action_callback` is racy here.
- [10-events.md](10-events.md) — `augment-command-palette` is one of the window events; registration guarding and the `wezterm.on` doubling trap.
- [11-pickers.md](11-pickers.md) — `InputSelector` and `PromptInputLine`, the alternative when you need rich row formatting, three-way dim/disabled state, or behaviour the palette can't model.
- [13-format-and-colors.md](13-format-and-colors.md) — the `wezterm.format` DSL the palette doesn't accept on rows but does on `doc` and similar fields in some builds.
