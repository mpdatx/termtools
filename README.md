# termtools

Context-sensitive hotkeys for terminal tabs, built as a [WezTerm](https://wezterm.org) Lua module.

Two hotkeys, two fuzzy modals:

- **Project picker** — from anywhere, fuzzy-find a known project and either focus its existing tab or spawn a new one rooted at it.
- **Action picker** — from inside any tab, run an action in the active pane's project context (open `TODO.md`, spawn a Claude pane, run tests, …). Most actions are project-agnostic; per-project files can add or override actions.

The whole tool is a single Lua module. There's no daemon, no AHK script, and no shell-side configuration — WezTerm's Lua keybindings can read the active pane's CWD natively, which is enough.

## Why WezTerm and not Windows Terminal

Windows Terminal has no plugin API and no conditional keybindings: there's no way for an external script to learn the focused tab's CWD without shell-title hacks or PEB reads. WezTerm exposes the active pane to keybinding callbacks, including `pane:get_current_working_dir()`. That makes "context-sensitive hotkey" a one-line read instead of a multi-process Rube Goldberg machine.

## Install

1. Install WezTerm: <https://wezterm.org/install/>.
2. Clone or copy this repo somewhere stable. Pick a path you'll remember:
   - Windows: e.g. `G:\claude\termtools` or `C:\Users\me\src\termtools`.
   - macOS / Linux: e.g. `~/projects/termtools` or `/opt/termtools`.
3. Wire it into your `~/.wezterm.lua` (on Windows: `%USERPROFILE%\.wezterm.lua`). Pick the integration style that matches what you already have:

### A. Drop into an existing `.wezterm.lua` (recommended if you have one)

`include.lua` returns a function that **mutates** `config` in place — adding the keybindings — and returns it. So you can call it for its side effect anywhere in your config and `return config` yourself at the end. You don't have to make the include the final line, and you can include other config files alongside it the same way.

```lua
local wezterm = require('wezterm')
local config  = wezterm.config_builder()

-- your existing config, untouched:
config.color_scheme = 'Tokyo Night'
config.font         = wezterm.font('JetBrains Mono')

-- TERMTOOLS = where you cloned this repo. It's NOT the same as where you
-- keep your projects (those go in `scan_roots` below).
--   On macOS / Linux: e.g. ~/src/termtools, ~/.local/share/termtools
--   On Windows:       e.g. G:/claude/termtools, C:/Users/me/src/termtools
local TERMTOOLS = wezterm.home_dir .. '/src/termtools'

-- scan_roots = the parent directories of your actual projects. Whatever
-- subdirs of these contain a project marker (.git/, package.json, etc.) will
-- show up in the project picker.
dofile(TERMTOOLS .. '/include.lua')(config, {
  scan_roots    = { wezterm.home_dir .. '/code', wezterm.home_dir .. '/work' },
  trusted_paths = { wezterm.home_dir .. '/code', wezterm.home_dir .. '/work' },
  default_keys  = true,
}, TERMTOOLS)

-- include other things you maintain in separate files:
-- dofile(wezterm.home_dir .. '/dotfiles/wezterm-keys.lua')(config)

-- more of your config:
config.window_decorations = 'RESIZE'

return config
```

The one-liner form `return dofile(...)(config, {...}, TERMTOOLS)` also works because the include returns the same `config` object — the multi-line form above is just for when you want to thread other config in alongside.

> Why the 3rd argument? WezTerm runs user config under `mlua`'s sandbox, which strips the `debug` library — so `include.lua` can't introspect its own path via `debug.getinfo`. Passing the install path explicitly is the simplest way around that. Define it as a local once and the duplication stays in one place.
>
> `wezterm.home_dir` is the portable way to write "my home directory" — `$HOME` on Unix, `%USERPROFILE%` on Windows. (WezTerm doesn't auto-expand `~` in path strings.) If your clone lives outside HOME — e.g. `G:\claude\termtools` on Windows or `/opt/termtools` on Linux — set `TERMTOOLS` to that absolute path. Forward slashes work on every platform.

### B. Start fresh from a minimal config

If you don't have a `.wezterm.lua` yet, copy `examples/minimal.wezterm.lua` to `%USERPROFILE%\.wezterm.lua` and edit `scan_roots` / `trusted_paths` to point at your project parents.

### C. Bind the pickers to your own keys

For full control (leader keys, custom mods, multiple bindings), set `default_keys = false` and reference `termtools.project_picker()` / `termtools.action_picker()` from your `config.keys`. See `examples/full.wezterm.lua`.

After any of these, restart WezTerm. `Ctrl+P` opens the project picker; `Ctrl+Shift+A` opens the action picker. (`Ctrl+Shift+P` is left for WezTerm's built-in command palette.)

> **Note**: `include.lua` clears `package.loaded[…]` so most edits to termtools' Lua modules are picked up on a config reload (`Ctrl+Shift+R`). But changes that affect `wezterm.on` event registrations or palette augmentation sometimes need a **full WezTerm restart** (close every window). If a code change you expect to see isn't taking effect, that's the first thing to try.

### Command palette integration

termtools also augments WezTerm's built-in command palette (`Ctrl+Shift+P`). Open it and you'll see:

- `termtools: Project picker` — same as the `Ctrl+P` shortcut.
- `termtools: Action picker (current project)` — same as `Ctrl+Shift+A`.
- `termtools [<project>]: <action>` — one entry per built-in action, per-project override action, and (when `wt_profiles = true`) WT profile, scoped to whatever project the active pane is in. So `Ctrl+Shift+P → "todo"` fires `Open TODO.md` for the current project without going through the action picker.

The palette entries are computed per palette-open, so they always reflect the active pane's project root.

## `setup({})` options

Options can be passed in either form — the table below uses flat keys for compactness, but you can also group them by section to mirror the source structure (`paths`, `hotkeys`, `commands`, `features`, `project_picker`):

```lua
-- flat (legacy form, fully supported):
termtools.setup({
  scan_roots = { … }, default_keys = true, project_key = { … },
})

-- nested (mirrors lua/init.lua's DEFAULTS_NESTED):
termtools.setup({
  paths   = { scan_roots = { … } },
  hotkeys = { default_keys = true, project_key = { … } },
})

-- mixed forms also work — flatten() walks one level.
```

The `style` and `claude` keys are always at the top level (passed straight through to the relevant module's setup).

| Option          | Default                  | Description |
| --------------- | ------------------------ | ----------- |
| `scan_roots`    | `{}`                     | Dirs whose immediate subdirs are auto-discovered as projects. |
| `pinned`        | `{}`                     | Explicit project paths to add to the picker. |
| `trusted_paths` | `{}`                     | Roots under which `.termtools.lua` override files may be loaded. |
| `editors`       | platform default         | Named editor registry plus role assignments — `{ registry = { name = { cmd, kind, direction? }, … }, default = name, inline = name \| nil }`. The platform default supplies `code` (external) plus `nvim` on Windows / `vim` on macOS as the inline editor. User opts shallow-merge on top, with per-name merging inside `registry`. |
| `editor_cmd`    | (legacy)                 | Pre-multi-editor single-template form — still accepted. If set without `editors`, gets synthesized into a registry entry that becomes the `default` role. New configs should use `editors` instead. |
| `default_cmd`   | `{ 'powershell' }` on Windows | Shell used when the picker spawns a fresh tab. Set to `{ 'pwsh' }` if you have PowerShell 7+. |
| `claude_cmd`    | `{ 'claude' }`           | Command for "New Claude pane". |
| `markers`       | see below                | Override the project-marker list. |
| `wt_profiles`   | `false`                  | Read Windows Terminal's `settings.json`: use the default profile as `default_cmd` (if not set) and add a `New tab: <profile>` action per non-hidden profile. |
| `apply_style`   | `false`                  | Apply opinionated WezTerm appearance + behaviour defaults from `lua/style.lua` (font, color scheme, cursor, padding, tab-title format, copy-on-select, …). Per-key overrides go in `style = { … }`. |
| `style`         | `{}`                     | Per-key overrides for the style defaults (only consulted when `apply_style=true`). E.g. `style = { color_scheme = 'Tokyo Night', font_size = 12.5 }`. See `lua/style.lua` for the full set of keys. |
| `project_sort`  | `'smart'`                | Initial sort for the project picker — `'smart'` (MRU first, then has-tabs, then alphabetical), `'alphabetical'`, or `'mru'`. The "Cycle project sort" action in the action picker overrides this at runtime; the override persists in `wezterm.GLOBAL` (survives reloads, resets on full restart). |
| `default_keys`  | `false`                  | Auto-bind `project_key` / `action_key` to the pickers. |
| `project_key`   | `{ key='p', mods='CTRL' }`       | Hotkey for the project picker (only used if `default_keys=true`). |
| `action_key`    | `{ key='A', mods='CTRL\|SHIFT' }` | Hotkey for the action picker (only used if `default_keys=true`). When `SHIFT` is in `mods`, use the uppercase letter — shift-held keypresses are uppercase, lowercase won't match. |
| `open_selection_key` | `false`                  | Optional hotkey for "open active pane's selection as a file in the default editor" (set to e.g. `{ key='O', mods='CTRL\|SHIFT' }` to bind one). The default trigger is the **`Ctrl+Shift+Click`** mouse gesture wired by `lua/style.lua` when `apply_style=true` — drag-select a path, then `Ctrl+Shift+Click` it to open. Parses `path:line:col` suffixes; resolves relative paths against the pane's CWD; for VS Code / Cursor as the default editor, uses `--goto path:line:col` so the editor jumps to the right line. |

Default project markers: `.git`, `.termtools.lua`, `package.json`, `pyproject.toml`, `Cargo.toml`.

If you want to bind the hotkeys yourself (e.g. behind a leader key), set `default_keys = false` and reference `termtools.project_picker()` / `termtools.action_picker()` from your `config.keys`. See `examples/full.wezterm.lua`.

## Built-in actions

| Label                        | What it does |
| ---------------------------- | ------------ |
| `Open project in editor`     | Launches the default editor (`editors.default`) on `<root>` (opens the whole project folder). |
| `Open TODO.md`               | Launches `editors.default` on `<root>/TODO.md`. The companion `Open TODO.md inline` row spawns `editors.inline` in a wezterm pane next to the active one. Both rows dim when the file doesn't exist; selecting still runs and the editor creates the file on first save. |
| `Open README.md`             | Same, for `README.md`. Inline sibling: `Open README.md inline`. |
| `New Claude pane`            | Splits active pane right; runs `claude_cmd` with cwd at root. |
| `New shell pane`             | Splits active pane down; runs `default_cmd` with cwd at root. |
| `New tab at project root`    | Spawns a new tab at root running `default_cmd`. |
| `Switch default editor`      | Open a picker listing every external-kind editor in `editors.registry`. Selection sets `wezterm.GLOBAL.termtools_editor_default`; persists across config reloads, resets on full WezTerm restart. |
| `Switch inline editor`       | Same shape for pane-kind editors. Includes a `(disable)` row that turns the inline variant off until you set it again. |
| `Refresh projects`           | Invalidates the discovery cache. |
| `Cycle project sort`         | Cycle the project picker's sort mode (smart → alphabetical → mru → smart). Toasts the new mode; persists in `wezterm.GLOBAL`. |
| `New tab: <profile>` (×N)    | One per Windows Terminal profile when `wt_profiles = true`. Currently commented out in `lua/actions.lua`; uncomment the block at the bottom to re-enable. |

Each action also has a short **description** that appears alongside its label in the picker (e.g. the actual editor command, the cmdline of a spawned profile). Fuzzy filter matches against both columns.

Actions have a three-state availability model. **Enabled** entries appear at the top in normal style. **Dimmed** entries (where `dimmed_when(root)` is true) are sorted below them, rendered dim/grey, but still selectable — used for "advisory" cases like Open-TODO when the file doesn't exist yet. **Disabled** entries (where `visible_when(root)` is false) sort to the very bottom and toast "unavailable" if picked. The wezterm command palette only surfaces enabled and dimmed; disabled entries are hidden there since the palette has no inert-row treatment.

## Cross-platform default scan roots

If you keep projects in conventional locations, `termtools.default_scan_roots()` returns the subset of the following paths that actually exist on the current machine — handy for sharing one config across Windows / macOS / Linux:

```
~/projects   ~/Projects
~/code       ~/Code
~/src
~/dev
~/repos
~/work
```

Use it directly, or extend it with your own paths:

```lua
local termtools = require('init')

local roots = termtools.default_scan_roots()
table.insert(roots, 'G:/claude')   -- machine-specific addition (Windows example)

termtools.setup({
  scan_roots = roots,
  -- ...
})
```

`~` is expanded from `$USERPROFILE` (Windows) or `$HOME` (Unix).

## Inheriting Windows Terminal profiles

(**Windows-only.** On macOS/Linux this option silently no-ops — `wt.lua` returns nil when there's no `LOCALAPPDATA` to look in.)

If you've already configured shells in Windows Terminal (PowerShell 7, Git Bash, WSL distros, Azure Cloud Shell, etc.), set `wt_profiles = true` to reuse them:

```lua
termtools.setup({
  scan_roots    = { 'G:/claude' },
  trusted_paths = { 'G:/claude' },
  default_keys  = true,
  wt_profiles   = true,    -- read %LOCALAPPDATA%\…\Windows Terminal\settings.json
})
```

Two effects:

1. **Default shell**: if you haven't set `default_cmd` yourself, the WT *default profile* (`defaultProfile` GUID in WT's settings) is used. So if WT opens with PowerShell 7 by default, so does termtools.
2. **Per-profile spawn actions**: every non-hidden profile becomes a `New tab: <profile>` entry in the action picker, which spawns a tab at the active project's root using that profile's commandline. Type-to-filter handles long lists. *(Currently commented out at the bottom of `lua/actions.lua` — uncomment that block to re-enable.)*

The reader probes the three known WT settings paths in order (Store, Preview, unpackaged). If none exist, the option is a no-op and termtools falls back to the platform default. Profiles using `source` other than `Windows.Terminal.Wsl` (e.g. Azure Cloud Shell auto-generated) are skipped — they need WT-specific machinery termtools doesn't have.

## Multi-session Claude awareness

Designed for workflows where you keep many Claude Code sessions open at once. Set `claude_indicators = true`:

```lua
dofile(TERMTOOLS .. '/include.lua')(config, {
  -- … your other opts …
  claude_indicators = true,
}, TERMTOOLS)
```

What you get:

- **Per-tab state glyph.** Every tab whose foreground pane is running `claude` gets a glyph next to its title:
  - `↻` working (the buffer shows "esc to interrupt" or a braille spinner)
  - `✱` idle (waiting on input — includes long-idle sessions; the age distinction is reserved for the session picker)

  termtools doesn't register its own `format-tab-title` (that would clash with your existing one). Instead expose a helper:

  ```lua
  wezterm.on('format-tab-title', function(tab, ...)
    local termtools = package.loaded['init']  -- lazy: filled in by include.lua
    local glyph = termtools and termtools.claude_glyph_for_pane(tab.active_pane.pane_id)
    -- splice glyph into your title
  end)
  ```

- **Status-bar summary** showing aggregate counts: `↻ 3   ✱ 4`. Empty when no Claude panes are open. Working / idle is the only distinction here — the age detail (`⚠` stuck) is preserved internally and surfaced inside the session picker so the bar stays calm. Position via `status_position = 'left' | 'right' | 'both'`.

- **`Ctrl+Shift+J`** (when `default_keys = true`) opens a **session picker** — an InputSelector listing every Claude pane with project, state, age, and pane-id. Selecting one focuses it. Working sessions sort first; idle sessions follow newest-first, with sessions older than `idle_too_long_s` rendered dim/grey but still selectable. The hotkey is configurable via `claude_next_key`. (For a "cycle to next waiting" alternative, bind `termtools.claude` module's `next_waiting_action()` directly.)

Tunable inside `claude = { … }` in setup opts (forwarded to the module's defaults):

| Option | Default | Notes |
| --- | --- | --- |
| `poll_interval_ms` | `2000` | Also drives `status_update_interval`. |
| `idle_too_long_s` | `300` | Seconds in `waiting` before promotion to `stuck` (`⚠`). |
| `scan_lines` | `40` | Lines of pane buffer scanned per poll for state heuristics. |
| `identify_patterns` | `{ 'claude' }` | If any matches an argv element / executable / process name, the pane is treated as Claude. |
| `working_patterns` | `{ 'esc to interrupt' }` | If any matches the last `scan_lines`, state = working. Otherwise waiting. |
| `glyph_working` / `glyph_waiting` / `glyph_stuck` | `↻` / `✱` / `⚠` | |
| `show_status_bar` | `true` | Set false to skip rendering counts. |

Detection is pattern-based — the `working_patterns` default works for the version of Claude Code that prints `esc to interrupt` while it's busy. Tune the list if your build prints something different.

## Per-project overrides

Drop `.termtools.lua` at the root of any project that lives under one of your `trusted_paths`. It returns a Lua table that can override the project's display name and default spawn command, and can add or replace actions by label. See `examples/example.termtools.lua` for a fully-commented template.

The trust gate is the entire security model: override files are loaded as ordinary Lua chunks (so they can use `wezterm.action.*` etc.), and termtools only loads them under explicitly listed `trusted_paths`. There is no sandbox.

## Layout

```
include.lua      one-line integration helper for existing .wezterm.lua configs
lua/
  init.lua       public API
  projects.lua   root resolver + discovery + override loader
  actions.lua    built-in action catalogue
  pickers.lua    facade re-exporting the picker submodules
  pickers/
    project.lua  project picker, sort modes, MRU, tab-counting
    action.lua   action picker, list_actions, run-by-label
  open_selection.lua  Ctrl+Shift+Click / hotkey "open path in editor"
  palette.lua    entries that augment WezTerm's command palette
  util.lua       generic path/fs helpers (delegates platform specifics);
                 hosts util.foreach_pane and util.pane_cwd
  claude.lua     multi-session Claude awareness (opt-in via claude_indicators)
  style.lua      opinionated appearance/behaviour defaults (opt-in via apply_style)
  wt.lua         Windows Terminal settings.json reader (opt-in via wt_profiles)
  platform.lua   dispatcher that picks the per-OS backend
  platform/
    windows.lua  Windows backend: drive letters, cmd.exe editor wrap, USERPROFILE
    darwin.lua   macOS backend: bare argv spawn, $SHELL/$HOME, no drive letters
examples/
  minimal.wezterm.lua        smallest viable user config (start fresh)
  full.wezterm.lua           every option exposed
  example.termtools.lua      drop-in per-project override template
  macos/wezterm-focus.lua    Hammerspoon recipe: global hotkey to focus WezTerm
docs/
  project-overrides.md   spec for .termtools.lua files
  plan.md                design notes
```

## Non-goals (for v1)

- No global hotkeys built in: pickers fire only when WezTerm is focused. macOS users can wire one with the Hammerspoon recipe at `examples/macos/wezterm-focus.lua` — `dofile` it from `~/.hammerspoon/init.lua` and the script binds bare `` ` `` (backtick) to focus WezTerm. A Windows recipe is not yet shipped.
- No "send a prompt to the running Claude in the active tab" — out of scope by design.
- No automated test suite. The surface is small enough that manual verification suffices.
