# 19 — Filesystem I/O and logging

How to read directories and files from inside `wezterm.lua`, where log output goes, and how to debug a config that's misbehaving in the wild. Plain Lua's `io.*` works fine; WezTerm adds a few cross-platform helpers (`read_dir`, `glob`, `log_*`) on top.

## Overview

Two surfaces, one debugging story:

- **Filesystem I/O.** WezTerm augments Lua's stdlib with `wezterm.read_dir(path)` and `wezterm.glob(pattern, [base])` — the cross-platform wrappers that work the same on Windows, macOS, and Linux. Underneath, plain Lua `io.open`, `io.lines`, and `os.rename` all work; reach for them whenever the WezTerm-specific helpers don't add value.
- **Logging.** `wezterm.log_info`, `log_warn`, and `log_error` write to a per-process log file. Knowing where that file lives — and how to control verbosity via `WEZTERM_LOG` — is the difference between debugging blind and seeing exactly what your callbacks are doing.

The child-process pair (`run_child_process`, `background_child_process`) sits at the same level as logging — Lua's stdlib has no equivalent — but the full story is in [06-spawning.md](06-spawning.md). This file just recaps the surface for completeness.

All file I/O in WezTerm Lua is **synchronous**. There is no async file API. For large reads, do them at config-eval time (or behind a one-shot `gui-startup` event), not in a per-event handler.

## Key APIs

### Filesystem helpers — [docs](https://wezterm.org/config/lua/wezterm/read_dir.html)

- `wezterm.read_dir(path) -> string[]` — list directory entries as **full absolute paths** (not basenames). Synchronous. Errors on non-UTF-8 paths; `pcall` if the directory might not exist or contain such entries. One level deep — does not recurse.
- `wezterm.glob(pattern, [relative_to]) -> string[]` — shell-style wildcards (`/etc/*.conf`, `*.lua`). Returns absolute paths; if `relative_to` is given, that prefix is stripped from each result. Synchronous, also pcall-friendly.
- Plain Lua: `io.open(path, mode)`, `io.lines(path)`, `os.rename(old, new)`, `os.remove(path)`. These work in standalone Lua too — useful when a module is unit-testable outside WezTerm.

### Logging — [docs](https://wezterm.org/config/lua/wezterm/log_info.html)

- `wezterm.log_info(arg, ...)` — info-level. Goes to the wezterm log file and stdout (if launched from a terminal). Multi-arg since `20210814-124438-54e29167`.
- `wezterm.log_warn(arg, ...)` — warn-level. Stands out visually in the log.
- `wezterm.log_error(arg, ...)` — error-level. Also surfaces in the `ShowDebugOverlay` action.

Multiple args are concatenated with separators; non-string values are coerced. So `wezterm.log_info('opts:', opts)` works — the table is rendered, not error'd on.

### Log file location — [troubleshooting](https://wezterm.org/troubleshooting.html)

- **Linux** (and other Unix where `XDG_RUNTIME_DIR` is set): `$XDG_RUNTIME_DIR/wezterm/wezterm-gui-log-<pid>.txt` (typically `/run/user/1000/wezterm/...`).
- **macOS / Windows** (and Unix without `XDG_RUNTIME_DIR`): `$HOME/.local/share/wezterm/wezterm-gui-log-<pid>.txt` — i.e. `~/.local/share/wezterm/...` on macOS, `%USERPROFILE%\.local\share\wezterm\...` on Windows.
- The `<pid>` is the GUI process's PID, so the file changes every launch. Use a glob (`wezterm-gui-log-*.txt`) to find the current one, or `wezterm.procinfo.pid()` to construct the exact filename.

### Verbosity control

The `WEZTERM_LOG` env var follows Rust's `env_logger` format:

- `WEZTERM_LOG=info` — everything at info or above.
- `WEZTERM_LOG=debug` — info plus debug; verbose.
- `WEZTERM_LOG=trace` — even more.
- `WEZTERM_LOG=config=debug,info` — per-module: `config` module at debug, everything else at info.
- `WEZTERM_LOG=wezterm_term=trace,info` — common debugging incantation when chasing terminal-emulation oddities.

Set it in the shell before launching wezterm; reading it from inside Lua (with `os.getenv('WEZTERM_LOG')`) doesn't change the active filter.

### Child-process recap (full story in [06-spawning.md](06-spawning.md))

- `wezterm.run_child_process(argv) -> success, stdout, stderr` — synchronous. **Blocks the GUI thread.** Right at config-eval time for one-shot probes (e.g. macOS PATH resolution at `lua/platform/darwin.lua:58`); wrong in any per-event path.
- `wezterm.background_child_process(argv)` — fire-and-forget. No output, no exit code. Failures *may* throw on spawn, but only on some platforms — wrap in `pcall` and `log_error` if you want any signal.

## Examples

### Listing project candidates with `read_dir`

`lua/projects.lua:88` — discovery walks each `scan_root` and inspects every immediate subdirectory for marker files:

```lua
for _, root in ipairs(opts.scan_roots or {}) do
  if ok_wt and wezterm.read_dir then
    local ok_read, entries = pcall(wezterm.read_dir, util.normalize(root))
    if ok_read and type(entries) == 'table' then
      for _, child in ipairs(entries) do
        if dir_contains_any(child, marker_set) then add(child, 'scan') end
      end
    end
  end
end
```

Two patterns worth lifting:

1. **Feature-gated**. The `ok_wt and wezterm.read_dir` check lets the same module load in standalone Lua (the unit-test harness) where `wezterm` doesn't exist.
2. **`pcall` around the call**. `read_dir` errors on UTF-8-broken paths (and possibly non-existent ones, depending on version). Wrapping protects discovery from one bad directory torpedoing the whole walk.

### Stripping basenames from `read_dir` results

`lua/projects.lua:34` — `read_dir` returns full paths, but the marker check needs just the entry name:

```lua
local ok, entries = pcall(wezterm.read_dir, dir)
if ok and type(entries) == 'table' then
  for _, full in ipairs(entries) do
    local name = full:match('([^/\\]+)$') or full
    if marker_set[name] then return true end
  end
end
```

The `[^/\\]+$` regex handles both forward and backslash separators — WezTerm normalises most things, but `read_dir` on Windows can return either depending on what was passed in.

### `util.dir_exists` — graceful degradation outside WezTerm

`lua/util.lua:69` — wraps `read_dir` for "does this directory exist?", with a fallback for standalone Lua:

```lua
function M.dir_exists(path)
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if ok_wt and wezterm.read_dir then
    local ok = pcall(wezterm.read_dir, path)
    return ok
  end
  return M.file_exists(M.path_join(path, '.'))
end
```

The `pcall(require, 'wezterm')` pattern is the standard way to make a module work both inside and outside WezTerm. Fallback uses plain `io.open` against a `.` joined to the path — works on every OS Lua runs on.

### `util.file_exists` — pure `io.open` probe

`lua/util.lua:61` — no WezTerm dependency at all:

```lua
function M.file_exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() return true end
  return false
end
```

`'rb'` is binary read; the only thing we care about is whether `open` succeeds. Doesn't distinguish "doesn't exist" from "exists but no read permission" — that's fine for our use cases.

### Reading file content with plain Lua `io.open`

`lua/wt.lua:29` — `read_file` for the WezTerm desktop config sniffer (handles JSONC, hence the binary read):

```lua
local function read_file(path)
  local f, err = io.open(path, 'rb')
  if not f then return nil, err end
  local content = f:read('*a')
  f:close()
  return content
end
```

`f:read('*a')` slurps the whole file. Fine for config-sized files (a few KB). For multi-MB files, `io.lines(path)` iterates line-by-line without loading everything into memory.

### `wezterm.log_error` capturing background spawn failures

`lua/actions.lua:52` — `open_in_editor` wraps `background_child_process` in `pcall` and routes failures to the log:

```lua
args = require('platform').editor_launch_args(args)
local ok, err = pcall(wezterm.background_child_process, args)
if not ok then
  wezterm.log_error('termtools: editor launch failed: ' .. tostring(err))
end
```

Without the `pcall` + `log_error`, a missing editor binary would surface as a Lua traceback in the debug overlay (or be silently dropped on the platforms where `background_child_process` doesn't throw on spawn). The log line is the only structured signal you get.

### `wezterm.log_warn` for soft failures in pane operations

`lua/claude.lua:82` and `lua/claude.lua:91` — pane reads can fail if the pane was closed mid-event. `log_warn` (not `log_error`) because the operation is best-effort:

```lua
wezterm.log_warn('termtools.claude: get_lines_as_text failed for pane ' .. id)
```

Convention worth copying: prefix log messages with the module name (`termtools.claude:`). When you're scrolling 50 KB of mux/term/wezterm-internal logs hunting for your output, the prefix is what makes `grep` useful.

### `log_info` for ad-hoc debugging

The cheapest way to inspect runtime state is `log_info` plus a tail. Tables are stringified, so this just works:

```lua
wezterm.log_info('termtools opts:', opts)
wezterm.log_info('discover result:', projects.discover(opts))
```

Tail the log to see it scroll:

```bash
# Linux/macOS
tail -f ~/.local/share/wezterm/wezterm-gui-log-*.txt

# Windows (PowerShell)
Get-Content -Wait $env:USERPROFILE\.local\share\wezterm\wezterm-gui-log-*.txt
```

If you don't see your output, double-check the log level — `WEZTERM_LOG=info` (or higher) needs to be in the env at launch time.

### Failed override loads logged with full path

`lua/projects.lua:143` — when a `.termtools.lua` override file errors out, the path and error text both go to the log so the user can find the problem:

```lua
local ok, result = pcall(dofile, override_path)
if not ok then
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if ok_wt then
    wezterm.log_error(string.format(
      'termtools: failed to load %s: %s', override_path, tostring(result)))
  end
  return miss()
end
```

The `pcall(require, 'wezterm')` guard is for standalone Lua again. In the WezTerm runtime, `wezterm` is always present, but the projects module is shared with the unit-test harness.

## Gotchas

- **`wezterm.read_dir` only exists in WezTerm's Lua runtime.** Standalone `lua` / `luajit` don't have it. `lua/util.lua:69` (`dir_exists`) and `lua/projects.lua:29` (`dir_contains_any`) both `pcall(require, 'wezterm')` and feature-gate on `wezterm.read_dir` — copy that pattern in any module that might be unit-tested outside wezterm.
- **`read_dir` returns absolute paths, not basenames.** Strip with `path:match('([^/\\]+)$')` if you want just the entry name (`lua/projects.lua:34`). The mixed `/\\` class is intentional — Windows can return either separator.
- **`read_dir` is one level deep.** No recursive walk. Implement recursion yourself if you need it; remember to guard against symlink cycles. For most "is this a project root?" use cases, one level is what you want anyway.
- **`wezterm.glob` may not exist in older builds.** It's been around since `20200503-171512-b13ef15f`, but if you're targeting old WezTerm versions, feature-gate (`if wezterm.glob then ...`) and roll your own with `read_dir` plus `string.match`.
- **No async file I/O.** All file ops block the GUI thread. For large reads, do them at config-eval time (or behind a one-shot `gui-startup` event), not in a per-event handler. See [12-state-and-timing.md](12-state-and-timing.md) for the timing rules.
- **No atomic-write helper.** `io.open(path, 'w')` truncates immediately, so a crash mid-write leaves an empty file. Write to `path .. '.tmp'`, close, then `os.rename` over the original — `rename` is atomic on the same filesystem on every OS WezTerm supports.
- **Log file PID changes per launch.** `wezterm-gui-log-<pid>.txt`. Use a glob (`wezterm-gui-log-*.txt`) for tailing, or `wezterm.procinfo.pid()` to construct the exact filename from inside Lua.
- **Log levels honour `WEZTERM_LOG` set at launch, not at runtime.** Setting `os.setenv('WEZTERM_LOG', 'debug')` from Lua does nothing — the env_logger filter is built once on process startup. To bump verbosity, restart with `WEZTERM_LOG=debug wezterm` (or `$env:WEZTERM_LOG="debug"; wezterm` in PowerShell).
- **`log_info` / `log_warn` / `log_error` formatting**. Tables are stringified, but cyclic references can spin forever. If you log a deeply-shared structure, sanitize or stringify it explicitly with `wezterm.serde.json_encode_pretty` first.
- **Log destinations differ by launch context.** Run from a terminal: stdout. Run as the macOS GUI app or via daemon mode: only the log file. The debug overlay (`ShowDebugOverlay` action) shows a recent ring buffer regardless. If your `log_info` calls don't appear in the terminal, check the log file.
- **`run_child_process` blocks the GUI thread for the duration of the child.** The fork-bomb story is in [06-spawning.md](06-spawning.md): commit `890bf16` shelled out to `wezterm ls-fonts --list-system` from config eval, the child re-evaluated the user's wezterm.lua, which re-entered `run_child_process` — locked up Windows and macOS instances. Reverted in `620a92e`. The rule: never call `run_child_process` from a path that runs on every config reload, and never let the child re-enter wezterm without `--skip-config`.
- **`background_child_process` errors silently.** Stdout, stderr, and exit code are all dropped. Wrap in `pcall` and route to `log_error` to capture spawn-time failures (`lua/actions.lua:52`); even then, runtime failures inside the child are invisible.
- **Path separators on Windows.** Use forward slashes everywhere in Lua strings — WezTerm normalises them. Backslashes need escaping in literals (`'C:\\\\Users'`), which is why `util.normalize` (`lua/util.lua:16`) converts everything to forward slashes up front.
- **`config_dir` may not exist on a fresh install.** `io.open(path_inside_config_dir, 'w')` will fail if the parent directory hasn't been created yet. Either `mkdir -p` via `wezterm.background_child_process` at startup, or fall back gracefully on write failure. See [12-state-and-timing.md](12-state-and-timing.md) for the sidecar JSON pattern.

## See also

- [02-modules.md](02-modules.md) — the `wezterm.*` surface where `read_dir`, `glob`, `log_*`, and the child-process helpers live.
- [06-spawning.md](06-spawning.md) — `run_child_process` vs `background_child_process` head-to-head, the `890bf16` lockup story in full, the `SpawnCommand` shape.
- [12-state-and-timing.md](12-state-and-timing.md) — sidecar JSON persistence to disk (`io.open` plus `wezterm.serde.json_encode_pretty` plus `os.rename`), why all I/O is sync, when to defer with `time.call_after`.
- [18-procinfo-and-platform.md](18-procinfo-and-platform.md) — `wezterm.procinfo.pid()` for constructing the exact log filename, `target_triple` for OS-specific log path branches, `home_dir` for the cross-platform base.
