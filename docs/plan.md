# termtools — context-sensitive hotkeys for terminal tabs

## Context

The user runs Claude Code sessions in terminal tabs, one per project, and wants two keyboard-driven workflows:

1. **Project picker** — from anywhere, hit a hotkey, fuzzy-find a known project, and either focus its existing tab or spawn a new one rooted at it.
2. **Action picker** — from inside any tab, hit a hotkey to fuzzy-pick an action that runs in the **active pane's project context** (e.g. open `<root>/TODO.md`, spawn a Claude pane at root, run tests). Most actions are project-agnostic; per-project files can add or override actions.

The constraint that drove the architecture: Windows Terminal has no plugin API, no conditional keybindings, and no way for an external script to learn the focused tab's CWD without shell-title hacks or PEB reads. WezTerm exposes the active pane to Lua keybinding callbacks, including `pane:get_current_working_dir()` and `pane:get_foreground_process_name()`. That makes "context-sensitive hotkey" a one-line read instead of a multi-process Rube Goldberg machine.

**Decision: switch to WezTerm.** The whole tool becomes a single Lua module. No AHK, no daemon, no shell-side configuration required.

This plan file lives at `C:\Users\<you>\.claude\plans\` because plan mode restricts edits to that location. After approval, recommend moving the plan to `G:\claude\termtools\docs\plan.md` per the user's global rule about plan locations.

## Architecture

A Lua package that the user `require`s from `~/.wezterm.lua` and applies to a WezTerm config. The package owns:

- **Project root resolver** — walks up from a given CWD, returns first ancestor that contains a marker (`.git/`, `.termtools.lua`, `package.json`, `pyproject.toml`, `Cargo.toml`). Falls back to the CWD itself if no marker is found.
- **Project discoverer** — merges two sources into a deduplicated list of `{path, name, source}`:
  - *Auto-scan*: for each user-configured `scan_root`, list immediate subdirs containing `.git/` or `.termtools.lua`.
  - *Pinned*: explicit paths the user lists in `setup({ pinned = ... })`.
  - Result is cached; refreshed via a built-in "Refresh projects" action or on WezTerm reload.
- **Action library** — built-in catalogue keyed by label, each entry is `function(window, pane, root) -> nothing`. Initial set:
  - `Open TODO.md` / `Open README.md` — invoke configured `editor_cmd` on `<root>/<file>`.
  - `New Claude pane` — split active pane right, spawn `claude` with `cwd = root`.
  - `New shell pane` — split below, spawn shell with `cwd = root`.
  - `cd here` — send `cd <root>\r` to active pane via `pane:send_text`.
  - `git status` — split below, run `git -C <root> status` and pause for keypress.
  - `Refresh projects` — invalidates discovery cache.
- **Per-project override loader** — if a project's root contains `.termtools.lua` AND that root is under a configured `trusted_paths` entry, load the file once and merge its `actions` table over the built-in catalogue. Override is by label.
- **Pickers** — two `wezterm.action_callback` factories using `InputSelector`:
  - `project_picker()` — opens modal of discovered projects. On select: scan all panes/tabs in the current window's mux for one whose `get_current_working_dir().file_path` is inside the chosen root; focus it if found, else spawn new tab with `cwd = root` running the project's `default_cmd` (default: shell; per-project override possible).
  - `action_picker()` — resolves project root from the calling pane's CWD, builds the merged action list, opens modal showing `<project_name> — <label>` per row, invokes the chosen `run` on confirm.

## Layout — `G:\claude\termtools\`

```
G:\claude\termtools\
├── README.md                       installation, setup({}) options, examples
├── lua\
│   ├── init.lua                    public entrypoint: setup(opts), apply(config),
│   │                               project_picker(), action_picker()
│   ├── projects.lua                discoverer, root resolver, override loader, cache
│   ├── actions.lua                 built-in action catalogue
│   ├── pickers.lua                 project_picker / action_picker implementations
│   └── util.lua                    path normalisation, shell-quoting, fs helpers
├── examples\
│   ├── minimal.wezterm.lua         smallest viable ~/.wezterm.lua
│   └── full.wezterm.lua            every option exposed, with comments
└── docs\
    ├── plan.md                     this plan, after relocation
    └── project-overrides.md        spec for .termtools.lua files
```

User's `~/.wezterm.lua` (target shape):

```lua
local wezterm = require('wezterm')
package.path = 'G:/claude/termtools/lua/?.lua;' .. package.path
local termtools = require('init')

termtools.setup({
  scan_roots    = { 'G:/claude', 'C:/Users/you/projects' },
  pinned        = { 'C:/Users/you/dotfiles' },
  editor_cmd    = { 'code', '%s' },          -- %s = file path
  default_cmd   = { 'pwsh' },                -- when picker spawns a fresh tab
  trusted_paths = { 'G:/claude' },           -- where .termtools.lua may be loaded
  default_keys  = true,                       -- bind Ctrl+Shift+P / Ctrl+Shift+A
})

local config = wezterm.config_builder()
return termtools.apply(config)
```

If `default_keys = false`, the user binds manually:

```lua
config.keys = { ...,
  { key = 'p', mods = 'CTRL|SHIFT', action = termtools.project_picker() },
  { key = 'a', mods = 'CTRL|SHIFT', action = termtools.action_picker() },
}
```

## Implementation steps

1. **Scaffold the directory** — create `G:\claude\termtools\` with the layout above. README skeleton; empty Lua files with module headers.
2. **`util.lua`** — path normalisation (forward slashes, drive-letter-aware), `path_join`, `is_inside(child, parent)`, `file_exists`, `read_file`, shell-quoting helper for spawn args.
3. **`projects.lua`**
   - `find_root(cwd, markers)` — walk-up; cache last lookup so consecutive calls in the same dir are O(1).
   - `discover(opts)` — auto-scan + pinned, dedupe, sort by display name; results cached on a module-level table, invalidated by `discover_refresh()`.
   - `load_overrides(root, trusted_paths)` — only loads `.termtools.lua` if root is inside a trusted path; runs in a sandboxed `loadfile` with a restricted env (no `os.execute`, no `io` writes). Override file returns a table; we validate shape before merging.
4. **`actions.lua`** — built-in catalogue. Each action is `{ label, run = function(window, pane, root) ... end }`. Implement using `wezterm.action.SplitPane`, `SpawnTab`, `SendString`, and `wezterm.background_child_process` for editor launches.
5. **`pickers.lua`**
   - `project_picker()` returns an `action_callback` that calls `discover()`, builds InputSelector entries, and on confirm: walks `wezterm.mux.get_active_workspace()` panes/tabs to find a match for the chosen root (compare `pane:get_current_working_dir().file_path` via `is_inside`); focus if found, else `SpawnTab { cwd = root, args = default_cmd }`.
   - `action_picker()` returns an `action_callback` that resolves root from the calling pane's CWD, builds merged action list, and dispatches.
6. **`init.lua`** — `setup(opts)` stores opts in a module table; `apply(config)` mutates `config.keys` if `default_keys = true`; expose `project_picker` / `action_picker` for manual binding.
7. **Examples** — write `minimal.wezterm.lua` (just `setup` + defaults) and `full.wezterm.lua` (every option commented).
8. **README** — installation steps, `setup({})` reference, list of built-in actions, link to overrides doc.
9. **`docs/project-overrides.md`** — schema for `.termtools.lua` (table shape, available helpers, security model — i.e. only loaded under `trusted_paths`).

## Critical files (all to be created)

- `G:\claude\termtools\lua\init.lua` — public API
- `G:\claude\termtools\lua\projects.lua` — root resolution + discovery + override loader
- `G:\claude\termtools\lua\actions.lua` — built-in actions
- `G:\claude\termtools\lua\pickers.lua` — the two hotkey targets
- `G:\claude\termtools\lua\util.lua`
- `G:\claude\termtools\examples\minimal.wezterm.lua`
- `G:\claude\termtools\README.md`
- User's `~/.wezterm.lua` — to be edited (or created) to require the module

No existing functions to reuse — this is a greenfield project.

## Verification plan

End-to-end manual verification (no test framework for v1; the surface is small and the cost of automation outweighs the value):

1. **Install WezTerm**, point `~/.wezterm.lua` at `examples/minimal.wezterm.lua`'s pattern, set `scan_roots = { 'G:/claude' }`, restart WezTerm.
2. **Project picker** — `Ctrl+Shift+P`. Modal lists every immediate `G:/claude/*` subdir that contains `.git/` or `.termtools.lua`, plus pinned entries. Pick `termtools`: a new tab opens at `G:/claude/termtools` running the configured `default_cmd`.
3. **Idempotence** — press `Ctrl+Shift+P` again, pick `termtools` again. Existing tab is focused, no second tab is spawned.
4. **Sub-directory resolution** — `cd G:\claude\termtools\lua` in a tab, press `Ctrl+Shift+A`. Modal title reads `termtools` (resolver walked up to `.git`).
5. **Built-in action** — pick "Open TODO.md". Verify the configured editor opens `G:\claude\termtools\TODO.md` (create the file beforehand to confirm path).
6. **Per-project override** — drop `G:\claude\termtools\.termtools.lua` returning one custom action labelled `Run unit tests`; reload WezTerm; press `Ctrl+Shift+A` from inside the project; the custom action appears alongside the built-ins.
7. **Trust gate** — drop a `.termtools.lua` in `C:\temp\untrusted\`, `cd` into it, press `Ctrl+Shift+A`. The override is **not** loaded (the path is outside `trusted_paths`). Confirm via a debug log line.
8. **Refresh** — create a new project dir under a `scan_root`, run the "Refresh projects" action, reopen the picker — the new project is listed.

## Non-goals for v1

- AutoHotkey / global hotkey layer (hotkeys only fire while WezTerm is focused). Defer until requested.
- Sending prompts to the running Claude in the active tab. Out of scope per the workflow choice.
- Cross-WezTerm-window mux discovery beyond the active workspace.
- Migrating existing Windows Terminal tab state — user starts WezTerm fresh.
- Automated test suite. Manual verification only.
