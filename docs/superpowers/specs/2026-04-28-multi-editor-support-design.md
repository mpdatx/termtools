# Multi-editor support — design

## Context

`actions.open_in_editor` currently uses a single `editor_cmd` template and always launches via `wezterm.background_child_process` (a detached external process). The TODO entry "support multiple preferred editors (vscode, vim/nvim) and the ability to switch or assign them to edit tasks" calls out two distinct workflows:

1. **External / GUI editor** (current behaviour) — VS Code, Cursor, etc. open in their own windows; fast for ongoing edits.
2. **Terminal editor in a pane** — nvim, vim, less. Spawned in a wezterm pane next to the active one for a quick inline view of a file without losing terminal context.

These need separate launch mechanisms (`background_child_process` vs `SplitPane`), so the right surface is a small registry of editor specs plus role assignments rather than one flat command template.

## Goals

- Configure multiple named editors with two launch kinds: `external` (existing) and `pane` (new).
- Default-vs-inline role assignment, both runtime-switchable and persisting across config reloads.
- Per-platform defaults (nvim on Windows, vim on macOS) following the existing `lua/platform/{windows,darwin}.lua` pattern.
- Each `Open <file>` action gains an `Open <file> inline` sibling that uses the inline editor.
- Zero break for existing configs — `editor_cmd = { 'code', '%s' }` continues to work.

## Non-goals

- Inline-editor variants for `Open project in editor` and `Open selection in editor` — only the per-file open actions get the variant for v1.
- Per-action editor override at the user level (e.g. "this specific TODO.md uses nvim, that one uses code"). The role assignment is global.
- Auto-detection of installed editors. Users configure what they have.
- Selection-action inline launching. The `Ctrl+Shift+Click` mouse gesture stays external-only.

## Schema

A single new opt: `editors`, a table with three keys.

```lua
editors = {
  registry = {
    code   = { cmd = { 'code',   '%s' }, kind = 'external' },
    cursor = { cmd = { 'cursor', '%s' }, kind = 'external' },
    nvim   = { cmd = { 'nvim',   '%s' }, kind = 'pane', direction = 'Right' },
    vim    = { cmd = { 'vim',    '%s' }, kind = 'pane', direction = 'Right' },
    less   = { cmd = { 'less',   '%s' }, kind = 'pane', direction = 'Down'  },
  },
  default = 'code',  -- which registry entry serves the "default" role
  inline  = 'nvim',  -- which entry serves "inline"; nil → no inline variant
}
```

**Registry entry fields**:
- `cmd` *(table, required)* — argv template. `%s` is replaced with the target path. Same shape as today's `editor_cmd`.
- `kind` *(string, required)* — `'external'` (detached process via `background_child_process`) or `'pane'` (wezterm `SplitPane`).
- `direction` *(string, optional, `'pane'` only)* — split direction. `'Right'` / `'Down'` / `'Up'` / `'Left'`. Defaults to `'Right'`. Ignored for `'external'`.

**Role assignment fields**:
- `default` *(string)* — name in `registry`. The "default" role. Used by `Open TODO.md`-style actions and the existing external-launch consumers.
- `inline` *(string or nil)* — name in `registry`. The "inline" role. Drives the `Open TODO.md inline` action variant. `nil` disables the inline variant.

## Platform defaults

Each backend exposes `default_editors()`, mirroring `default_shell()`:

```lua
-- lua/platform/windows.lua
function M.default_editors()
  return {
    registry = {
      code = { cmd = { 'code', '%s' }, kind = 'external' },
      nvim = { cmd = { 'nvim', '%s' }, kind = 'pane', direction = 'Right' },
    },
    default = 'code',
    inline  = 'nvim',
  }
end

-- lua/platform/darwin.lua
function M.default_editors()
  return {
    registry = {
      code = { cmd = { 'code', '%s' }, kind = 'external' },
      vim  = { cmd = { 'vim',  '%s' }, kind = 'pane', direction = 'Right' },
    },
    default = 'code',
    inline  = 'vim',
  }
end
```

Linux: deferred. The current platform dispatcher falls back to `darwin` for non-Windows non-darwin targets, so Linux users get the macOS defaults until a dedicated backend exists.

## Resolution order in `init.setup()`

When merging user opts:

1. Start with `platform.default_editors()` as the baseline.
2. If `user_opts.editors` is a table, **two-level shallow merge** on top:
   - At the top level, missing keys (`registry`, `default`, `inline`) inherit from the platform baseline; present keys replace.
   - Inside `editors.registry`, the merge is **per-name**: user-provided names add to (or replace) the platform's registry entries, but each registry *entry* is replaced as a whole — there is no field-level merge inside `{ cmd, kind, direction }`. If a user redefines `code`, they supply a complete entry.
3. If `user_opts.editors` is absent **and** `user_opts.editor_cmd` is set (legacy form), inject a synthetic registry entry `{ cmd = editor_cmd, kind = 'external' }` and point `default` at it. `inline` stays as the platform default.
4. If neither is set, the full platform default applies.

A user who only wants to flip the inline editor (top-level merge keeps platform `registry` and `default`):
```lua
editors = { inline = 'nvim' }   -- on macOS, keeps registry+default from platform, swaps vim→nvim
```

A user who adds a registry entry (per-name merge keeps platform's `code` / `nvim` / `vim`):
```lua
editors = {
  registry = { kitty = { cmd = { 'kitty', '%s' }, kind = 'external' } },
  default  = 'kitty',
}
```

A user who replaces a platform entry (full entry, not just one field):
```lua
editors = {
  registry = { code = { cmd = { 'codium', '%s' }, kind = 'external' } },
}
```

## `actions.open_in_editor` — signature change

```lua
-- New signature
M.open_in_editor(window, pane, target, editor_spec, position)
```

`editor_spec` is a registry entry (`{ cmd, kind, direction? }`). `position` is the existing optional `{ line, col }` table.

Behaviour:
- **`kind == 'external'`** — current pipeline: optional `--goto` rewrite for VS Code / Cursor commands when `position.line` is set, then `platform.editor_launch_args(args)` (cmd.exe wrap on Windows), then `pcall(wezterm.background_child_process, args)`.
- **`kind == 'pane'`** — `window:perform_action(wezterm.action.SplitPane { direction = editor_spec.direction or 'Right', command = { args = args } }, pane)`. No `platform.editor_launch_args` wrap (pane editors are real .exe's; `cmd.exe /c` would just stack a shell layer that exits when the editor exits and closes the pane).
- The `--goto` rewrite is **external-only**. Terminal editors handle line addressing with their own argv conventions which we don't unify in v1.

`window`/`pane` were not previously parameters; callers (catalogue's `M.open_file`, `open_selection.lua`) already have them in the action's `run(window, pane, root)` callback.

## `actions.open_file(filename, role)`

`role` is `'default'` or `'inline'`. Default if omitted: `'default'`.

Returns a single action:
- **`role == 'default'`** — label `Open <filename>`, run dispatches to `default` editor.
- **`role == 'inline'`** — label `Open <filename> inline`, run dispatches to `inline` editor. If `inline` is `nil`, run shows a toast `inline editor not configured` and no-ops.

Both variants share the existing `dimmed_when` (file doesn't exist → dim) and the existing description text (showing the resolved cmd line).

The catalogue calls `M.open_file('TODO.md', 'default')` and `M.open_file('TODO.md', 'inline')` — two entries, side by side, dimmed independently.

User `.termtools.lua` files that currently call `actions.open_file('CHANGELOG.md')` continue working (defaults to `'default'` role). Users who want the inline variant for a custom file add a second line `actions.open_file('CHANGELOG.md', 'inline')`.

## Runtime switching

Two new entries in `actions.lua` catalogue:

- **`Switch default editor`** — opens an `InputSelector` listing every `registry` entry with `kind = 'external'`. Picking sets `wezterm.GLOBAL.termtools_editor_default` to that entry's name. Toasts the change.
- **`Switch inline editor`** — same shape, lists `kind = 'pane'`. The first row is `(disable)` and clears the inline override.

State lives in `wezterm.GLOBAL`:
- `termtools_editor_default` *(string or nil)* — overrides `editors.default` when set.
- `termtools_editor_inline` *(string, false, or nil)* — `string` overrides; `false` explicitly disables; `nil` means "use config".

Both reset on full WezTerm restart (consistent with `termtools_project_sort` and `termtools_project_mru`).

## `util.editor_spec(role, opts)` — new helper

```lua
function util.editor_spec(role, opts)
  -- 1. wezterm.GLOBAL runtime override
  -- 2. opts.editors[role] → opts.editors.registry[name]
  -- 3. nil  (only happens for 'inline' when no inline editor is configured)
end
```

Used by `M.open_file`'s `run` to fetch the spec at action-fire time so runtime switches take effect immediately.

## Backward-compat summary

| User config | Behaviour |
| --- | --- |
| Sets neither `editors` nor `editor_cmd` | Platform default applies (code + nvim/vim). |
| Sets only `editor_cmd` (legacy) | Synthesized into `registry.default_external`, becomes the `default` role. Platform's inline editor stays. |
| Sets only `editors = { ... }` | Shallow-merged on top of platform default. |
| Sets both | `editors` wins; `editor_cmd` ignored. |

## Files touched

- `lua/platform/windows.lua` — new `M.default_editors()`
- `lua/platform/darwin.lua` — new `M.default_editors()`
- `lua/util.lua` — new `M.editor_spec(role, opts)`
- `lua/actions.lua` — `open_in_editor` signature change; `open_file` accepts role; two new catalogue entries; catalogue emits both default + inline open-file variants
- `lua/init.lua` — `editors` opt resolution in `setup()`; backward-compat for `editor_cmd`
- `lua/open_selection.lua` — call-site update for new `open_in_editor` signature (passes `editor_spec` of the default role)
- `README.md` — docs for the new opt + two new actions
- `examples/full.wezterm.lua` — example showing per-platform editor config
- `examples/example.termtools.lua` — example of `actions.open_file('CHANGELOG.md', 'inline')`
- `TODO.md` — remove the multi-editor entry

No new top-level modules.

## Verification

Manual smoke tests on a Windows machine with VS Code + nvim:
1. With default config — `Open TODO.md` opens VS Code. `Open TODO.md inline` opens nvim in a pane to the right.
2. `Switch inline editor` → `(disable)` — `Open TODO.md inline` toasts "inline editor not configured", no spawn.
3. `Switch default editor` → cursor (if registered) — `Open TODO.md` now spawns Cursor.
4. Legacy config `editor_cmd = { 'cursor', '%s' }` — `Open TODO.md` spawns Cursor; `Open TODO.md inline` still uses the platform-default nvim.
5. `Ctrl+Shift+Click` on a `path:line` selection — opens VS Code with `--goto` (external `default` role; line/col preserved).

On macOS, repeat with `vim` as the inline editor.

## Risks

- **`SplitPane` argv on Windows for non-`.exe` programs** — if a user adds an editor like `nvim-qt.cmd` to the pane registry, `CreateProcess` won't find it (PATHEXT issue). Mitigation: the user picks a real `.exe` for pane editors, or wraps the cmd themselves: `cmd = { 'cmd.exe', '/c', 'nvim-qt', '%s' }`. We don't auto-wrap pane editors because the wrap-and-spawn pattern can interact badly with the editor's signal handling inside the pty.
- **VS Code's `code.cmd` shim on Windows for the *external* path** — already handled by `platform.editor_launch_args` which wraps with `cmd.exe /c` for external launches. Unchanged.
- **`Ctrl+Shift+Click` on a path with `:line:col` while default editor is non-vscode** — `--goto` doesn't apply, line/col are silently dropped. Acceptable; documented.
