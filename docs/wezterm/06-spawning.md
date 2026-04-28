# 06 — Spawning processes

How to start a program from Lua: into a tab, into a window, into a split, or out-of-band as a fire-and-forget child. The `SpawnCommand` table is the lingua franca; everything else is a delivery mechanism.

## Overview

Three audiences for the spawn surface, with different ergonomics:

- **Action-table dispatch** — `wezterm.action.SpawnCommandInNewTab { ... }`, `SpawnCommandInNewWindow`, `SpawnTab`, `SpawnWindow`. Bound to keys or fired via `window:perform_action(act, pane)` from a callback. The standard path for "user pressed a key, open a thing".
- **Mux API direct** — `wezterm.mux.spawn_window {...}`, `MuxWindow:spawn_tab {...}`, `pane:split {...}`. Returns the new objects synchronously, so the caller can keep operating on them (rename the tab, set the workspace, focus a sibling). The right path from inside `gui-startup` / `mux-startup` event handlers.
- **Fire-and-forget child** — `wezterm.background_child_process(argv)` for "shell out to an external GUI program" (VS Code, IDE, browser). `wezterm.run_child_process(argv)` for "I need stdout" — but it blocks the GUI thread and has a documented lockup history in this project.

The `SpawnCommand` shape is shared across the first two surfaces. Everything else is plumbing.

## Key APIs

### `SpawnCommand` table — [docs](https://wezterm.org/config/lua/SpawnCommand.html)

The argument shape passed to action constructors and mux spawn methods. All fields optional:

- `label` — string. Only used by `launch_menu` config entries; ignored elsewhere.
- `args` — argv array. `{ 'nvim', '/path/to/file' }`. **Omit or pass `{}` to spawn the domain's default program** (your shell).
- `cwd` — absolute path string. **Must exist** — non-existent CWDs fail the spawn (silently on some platforms, with a tab-bar error on others).
- `set_environment_variables` — string-keyed table; merged on top of inherited env.
- `domain` — selects multiplexer domain. `"CurrentPaneDomain"` (default for spawn-tab/split), `"DefaultDomain"`, or `{ DomainName = 'unix' }`.
- `position` — GUI window position (`SpawnCommandInNewWindow` and `mux.spawn_window` only).

Accepted by: `wezterm.action.SpawnCommandInNewTab`, `SpawnCommandInNewWindow`, `wezterm.mux.spawn_window`, `MuxWindow:spawn_tab`, `pane:split` (which adds `direction`, `size`, `top_level` — see [07-splits.md](07-splits.md)).

### Action-table entrypoints — [docs](https://wezterm.org/config/lua/keyassignment/SpawnCommandInNewTab.html)

- `wezterm.action.SpawnTab(domain_or_table)` — minimal: just choose a domain, spawn its default program. `act.SpawnTab 'CurrentPaneDomain'`.
- `wezterm.action.SpawnWindow` — bare action (no args). New window with default program in the default domain.
- `wezterm.action.SpawnCommandInNewTab(spawn_command)` — full `SpawnCommand` in a new tab of the current window.
- `wezterm.action.SpawnCommandInNewWindow(spawn_command)` — same but a new window.

All four are dispatched via `window:perform_action(act, pane)` from inside a callback, or as the `action` of a key binding. See [08-actions-and-keys.md](08-actions-and-keys.md).

### Mux spawn methods — [docs](https://wezterm.org/config/lua/wezterm.mux/spawn_window.html)

- `wezterm.mux.spawn_window(opts)` — `opts` is `SpawnCommand` plus `workspace`, `width`, `height`. Returns `(tab, pane, window)` — three handles, ready to inspect or mutate. Default domain is `"DefaultDomain"` (not `CurrentPaneDomain` — there's no current pane in headless contexts).
- `MuxWindow:spawn_tab(opts)` — append a tab to a specific mux window. Returns `(tab, pane, window)`.
- `pane:split(opts)` — split a pane in two; `opts` extends `SpawnCommand` with `direction`, `size`, `top_level`. Detail in [07-splits.md](07-splits.md).

There is no `pane:spawn_tab`. To spawn a tab from a pane handle, either bridge to its mux window (`pane:tab():window():spawn_tab{...}`) or dispatch `act.SpawnCommandInNewTab` against the GUI window.

### Standalone child processes — [docs](https://wezterm.org/config/lua/wezterm/background_child_process.html)

- `wezterm.background_child_process(argv)` — async fire-and-forget. No return value. **Stdout, stderr, and exit code are all discarded.** A spawn-time error *may* throw (executable not found on some platforms), so `pcall` it if you want to know.
- `wezterm.run_child_process(argv)` — synchronous. Returns `(success, stdout, stderr)`. **Blocks the GUI thread for the duration.** No `run_child_process_async` exists in upstream WezTerm as of writing.

## Examples

### `SpawnCommandInNewTab` — new tab at project root

`lua/actions.lua:225` — the catalogue's "New tab at project root" entry. The action runs from inside an `InputSelector` callback, so `window` and `pane` are already in scope:

```lua
{
  label = 'New tab at project root',
  description = 'spawn tab; ' .. default_cmd_str .. ' at project root',
  run = function(window, pane, root)
    window:perform_action(act.SpawnCommandInNewTab {
      cwd = root, args = default_cmd,
    }, pane)
  end,
},
```

`default_cmd` is `{ 'powershell' }` on Windows, `{ os.getenv('SHELL') }` on macOS — set once at `setup()` time. `root` is the project directory chosen by the picker.

### `pane:split` — adjacent tool pane

`lua/actions.lua:202` — split right and run `claude` in the new pane:

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

`pane:split` accepts the same `args`/`cwd`/`set_environment_variables`/`domain` fields as the action variants; the `direction` and `size` extras are split-specific. The Top/Bottom vs Up/Down direction-name quirk is detailed in [07-splits.md](07-splits.md).

### `background_child_process` — external editor

`lua/actions.lua:52` — `M.open_in_editor`'s external-editor branch. Wrapped in `pcall` so a missing binary surfaces as a log line rather than a Lua traceback:

```lua
args = require('platform').editor_launch_args(args)
local ok, err = pcall(wezterm.background_child_process, args)
if not ok then
  wezterm.log_error('termtools: editor launch failed: ' .. tostring(err))
end
```

Output is dropped on the floor; that's fine for a GUI editor — the editor itself becomes the user-visible feedback.

### Windows PATHEXT shim — `cmd.exe /c` wrapper

`lua/platform/windows.lua:40` — `editor_launch_args` wraps the argv so PATHEXT lookup happens. `CreateProcess` (used by `background_child_process` on Windows) only auto-appends `.exe`; bare `code` finds nothing because VS Code installs `code.cmd`:

```lua
function M.editor_launch_args(args)
  local out = { 'cmd.exe', '/c' }
  for _, a in ipairs(args) do out[#out + 1] = a end
  return out
end
```

Same trap for `idea.cmd`, `cursor.cmd`, npm-shimmed CLIs (`claude.cmd`). The wrapper is applied once in the action layer at `lua/actions.lua:51`, kept off `pane:split` because pane spawns happen via the PTY layer, which does honour PATHEXT.

### macOS PATH shim — login+interactive shell lookup

`lua/platform/darwin.lua:52` — `resolve_argv` resolves a program name to an absolute path by asking `$SHELL -lic 'command -v PROG'`. GUI-launched WezTerm on macOS only inherits the system PATH (`/usr/bin:/bin:...`); anything in `~/.claude/local`, `/opt/homebrew`, or an npm prefix is invisible:

```lua
function M.resolve_argv(args)
  if not args or #args == 0 then return args end
  local prog = args[1]
  if prog:sub(1, 1) == '/' then return args end
  local wezterm = require('wezterm')
  local shell = os.getenv('SHELL') or '/bin/zsh'
  local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
  if not ok or not stdout then return args end
  -- ... drop trailing whitespace, validate it's an absolute path, return new argv
end
```

Two things to flag:

1. This *does* call `run_child_process` synchronously. It runs once at `setup()` time (not per-spawn), the cost is bounded (one shell startup), and the result is cached in module-level state. Calling this from a per-keypress handler would be wrong.
2. The result is plumbed back into `claude_cmd` so subsequent `pane:split { args = claude_cmd }` calls fire `execvp` against an absolute path — no shell middleman in the per-pane spawn path.

### `mux.spawn_window` — workspace + cwd in one call

For "open a new window in workspace X with cwd Y running Z", the mux API is the most direct path. It returns the handles, so you can immediately tweak the result:

```lua
local tab, pane, window = wezterm.mux.spawn_window {
  workspace = 'review',
  cwd = '/home/user/code/repo',
  args = { 'lazygit' },
  set_environment_variables = { TERM_PROGRAM = 'wezterm' },
}
window:set_title('Review: repo')
```

Pair with `wezterm.mux.set_active_workspace('review')` to switch to it, or fire it from a `mux-startup` handler to seed a workspace at daemon launch. See [05-mux-and-workspaces.md](05-mux-and-workspaces.md).

## Gotchas

- **`args = {}` (or omitted) spawns the user's default shell.** Per the spawn-command docs: "If omitted, the default program for the target domain will be spawned." Pass an explicit argv if you want a deterministic command — relying on the user's `default_prog` makes the spawn behave differently between machines.
- **`cwd` must exist.** A non-existent path fails the spawn. On Windows you'll see a tab open and immediately close with a brief error; on macOS the failure is quieter. `pcall` won't help — the failure is async, after the spawn call has returned. Validate with `wezterm.read_dir(cwd)` first if the path is user-supplied.
- **Windows: `CreateProcess` doesn't honour PATHEXT.** A bare `code` won't find `code.cmd`. termtools wraps external-editor argv via `cmd.exe /c` (`lua/platform/windows.lua:40`); pane spawns don't need this because the PTY layer goes through a different path. If you spawn a `.cmd` shim via `background_child_process` or the action API directly, wrap it.
- **macOS: GUI-launched WezTerm has a stripped PATH.** `claude`, `code`, anything in `~/.claude/local` or an npm/asdf prefix may not resolve via `execvp`. termtools shells out once at setup time to resolve to an absolute path (`lua/platform/darwin.lua:52`); cache the result and re-use it. Don't call the resolver per-keypress.
- **`wezterm.run_child_process` blocks the GUI thread.** Documented in the Lua reference. We hit a particularly nasty variant in commit `890bf16`: a `font_with_fallback` probe that shelled out to `wezterm ls-fonts --list-system` from inside config eval. The child re-evaluated `wezterm.lua` (because that's what `wezterm` does on launch), which re-entered `run_child_process` — fork bomb on the GUI thread. Reverted in `620a92e`. Documented in `TODO.md` as a "do not retry without `--skip-config` plus probing outside config eval". The headline rule: never call `run_child_process` from a path that runs on every config reload.
- **`background_child_process` discards stdout, stderr, and exit code.** Failures are silent unless the OS rejects the spawn synchronously. If you need output, `run_child_process` is the only built-in option (no `run_child_process_async` exists in upstream as of writing) — gate it behind a one-shot startup event or a deliberate user action, never a per-event handler.
- **Spawn-time errors are partly platform-dependent.** Quoting the upstream `background_child_process` docs: "May generate an error if the command is not able to be spawned (eg: perhaps the executable doesn't exist), but not all operating systems/environments report all types of spawn failures immediately upon spawn." `pcall` catches some failures, not all.
- **`pane:spawn_tab` doesn't exist.** Pane spawns either split (`pane:split`) or dispatch a tab/window action against the GUI window. To spawn a tab from a pane handle inside a callback, use `window:perform_action(act.SpawnCommandInNewTab{...}, pane)`.
- **`wezterm-mux-server` headless context.** GUI-flavoured spawns (via `act.SpawnCommandInNewTab` etc.) only fire when a GUI is attached. Inside a `mux-startup` handler running in the daemon, use `wezterm.mux.spawn_window` and `MuxWindow:spawn_tab` directly. If you must spawn into a specific domain from a context that defaults to `CurrentPaneDomain` and there is no current pane, set `domain = "DefaultDomain"` or `{ DomainName = 'unix' }` explicitly.
- **`SpawnCommandInNewWindow` opens a brand-new GUI window.** It does not reuse an existing one. If you wanted "raise the existing window with workspace X", use `wezterm.mux.set_active_workspace` instead — see [05-mux-and-workspaces.md](05-mux-and-workspaces.md).
- **Domain selection differs by entrypoint.** Action-table spawns default to `CurrentPaneDomain`; `mux.spawn_window` defaults to `DefaultDomain`. If you're spawning into an SSH/WSL/unix-mux domain, set `domain` explicitly — the inherited default may surprise you.

## See also

- [02-modules.md](02-modules.md) — `wezterm.run_child_process` / `background_child_process` in the broader module catalogue.
- [05-mux-and-workspaces.md](05-mux-and-workspaces.md) — `wezterm.mux.*` object handles and workspace ops.
- [07-splits.md](07-splits.md) — `pane:split` extras (direction names, sizing, focus behaviour).
- [08-actions-and-keys.md](08-actions-and-keys.md) — dispatching `SpawnCommandInNewTab` etc. via `window:perform_action` and key bindings.
- [12-state-and-timing.md](12-state-and-timing.md) — sync vs async children, `wezterm.time.call_after` for non-blocking deferral.
- [16-domains.md](16-domains.md) — what to put in the `domain` field; SSH/WSL/unix-mux specifics.
- [18-procinfo-and-platform.md](18-procinfo-and-platform.md) — the PATHEXT/PATH shimming context, `target_triple` dispatch.
