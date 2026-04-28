# 18 — Procinfo and platform detection

Two related-but-separate surfaces: `wezterm.procinfo` for *what is running on this machine right now*, and `wezterm.target_triple` / `wezterm.home_dir` for *what kind of machine is this*. Together they let a config branch on OS, find the user's home, and reach into any running process to read its CWD, executable, argv, and child tree.

## Overview

`wezterm.procinfo` is an introspection module: pass it a PID, get back metadata. The same shape (`LocalProcessInfo`) is what `pane:get_foreground_process_info()` returns — see [04-pane-window-tab.md](04-pane-window-tab.md) — but procinfo's value is that you can walk *past* the foreground process. Want to know whether the shell in this pane has a `claude` child? Walk `info.children`. Want to know the CWD of a process that isn't a foreground in any pane (a daemon, a background task)? `current_working_dir_for_pid` will tell you.

`wezterm.target_triple` and `wezterm.home_dir` are platform-detection constants. They evaluate once at startup and don't change. The standard pattern is to dispatch on `target_triple` at config-evaluation time and import a per-OS backend module — termtools does exactly this in `lua/platform.lua`.

The two surfaces are paired in this file because they're both "runtime metadata" — neither configures wezterm, both let your config adapt to its environment.

## Key APIs

### `wezterm.procinfo` — [docs](https://wezterm.org/config/lua/wezterm.procinfo/index.html)

- `wezterm.procinfo.pid()` — PID of the wezterm process itself. Stable for the GUI's lifetime.
- `wezterm.procinfo.current_working_dir_for_pid(pid) -> string?` — best-effort CWD of any PID. `nil` on failure (process gone, ACL denial, missing `/proc`).
- `wezterm.procinfo.executable_path_for_pid(pid) -> string?` — absolute path to the binary.
- `wezterm.procinfo.get_info_for_pid(pid) -> LocalProcessInfo?` — full info table.

`LocalProcessInfo` shape:

| Field | Type | Notes |
| ----- | ---- | ----- |
| `pid` | number | The PID you queried. |
| `ppid` | number | Parent PID. |
| `name` | string | Short process name (no path). |
| `executable` | string | Absolute path to the binary. |
| `cwd` | string | Working directory. |
| `argv` | array of string | Full argv including argv[0]. |
| `status` | string | OS-specific (`Run`, `Sleep`, `Idle`, ...). |
| `start_time` | number | Process start timestamp. |
| `children` | **map**, keyed by child PID | Each value is itself a `LocalProcessInfo`, recursively. |

The `children` field is the headline feature. It's not an array — it's a `pairs`-iterable map where the keys are the child PIDs. Walking it is how you spot "the user is running `claude` inside `pwsh` in this pane". Termtools' `is_claude_pane` (`lua/claude.lua:65`) takes the simpler route — checks the *foreground* process's `argv` and `executable` — but if claude were ever wrapped by an outer launcher you'd descend into `info.children` to find it.

### `wezterm.target_triple` — [docs](https://wezterm.org/config/lua/wezterm/target_triple.html)

A string field, not a function. Set at build time to the Rust target triple of the wezterm binary. Common values:

- `x86_64-pc-windows-msvc` — Windows
- `x86_64-apple-darwin` — Intel macOS
- `aarch64-apple-darwin` — Apple Silicon macOS
- `x86_64-unknown-linux-gnu` — Linux

The wezterm docs example uses `==` against a specific full triple. That works when you only care about one exact platform, but it'll silently miss `aarch64-apple-darwin` if you wrote `== 'x86_64-apple-darwin'`. Substring matching with `:find('windows', 1, true)` is the portable pattern (`, 1, true` makes it a literal substring search starting at position 1, bypassing Lua patterns) — termtools does this in `lua/platform.lua:9`.

### `wezterm.home_dir` — [docs](https://wezterm.org/config/lua/wezterm/home_dir.html)

A string field with the user's home directory, resolved cross-platform. On Windows it's `C:\Users\<name>`; on macOS / Linux it's `$HOME`. Prefer this over `os.getenv('HOME')` (which is empty on Windows by default) or `os.getenv('USERPROFILE')` (Windows-only). Termtools wraps it as `platform.home_dir()` so platform-specific fallbacks live in one place.

## Examples

### `target_triple` dispatch — termtools' platform backend selector

`lua/platform.lua:7-15` — single source of truth for "which OS are we on" with a deterministic fallback for environments where wezterm isn't loaded (unit tests):

```lua
local function detect()
  local ok, wezterm = pcall(require, 'wezterm')
  local triple = (ok and wezterm.target_triple) or ''
  if triple:find('windows') then return 'windows' end
  if triple:find('darwin')  then return 'darwin' end
  -- Last resort for environments without wezterm in scope (e.g. tests).
  if package.config:sub(1, 1) == '\\' then return 'windows' end
  return 'darwin'
end
```

Two things to flag:

1. `:find('windows', 1, true)` — except here it's the two-arg form because we don't pass `init`. The `true` for `plain` is the load-bearing bit; otherwise `find` would interpret the needle as a Lua pattern. (`'darwin'` happens to be regex-safe; `'x86_64'` is not — the `_` is fine but `.` would bite.)
2. The `pcall(require, 'wezterm')` lets the same module load under standalone Lua for tests.

The detected name then drives `require('platform.' .. backend_name)` (`lua/platform.lua:22`) — Windows gets `lua/platform/windows.lua`, macOS gets `lua/platform/darwin.lua`, both are re-exported as the public `platform.*` surface.

### Windows PATHEXT shim — `editor_launch_args` wraps via `cmd.exe /c`

`lua/platform/windows.lua:40-44` — `CreateProcess` (used by `wezterm.background_child_process`) only auto-appends `.exe`. A bare `code` finds nothing because VS Code installs `code.cmd`. Same trap for `idea.cmd`, `cursor.cmd`, npm-shimmed CLIs (`claude.cmd`):

```lua
function M.editor_launch_args(args)
  local out = { 'cmd.exe', '/c' }
  for _, a in ipairs(args) do out[#out + 1] = a end
  return out
end
```

The wrapper applies once at the action layer (`lua/actions.lua:51`). It's *not* applied to `pane:split { args = ... }` — pane spawns go through wezterm's PTY layer, which handles PATHEXT correctly. Cross-reference [06-spawning.md](06-spawning.md) for the spawn-path-vs-shim split.

### macOS PATH shim — login+interactive shell lookup

`lua/platform/darwin.lua:52-68` — GUI-launched WezTerm on macOS only inherits the system PATH (`/usr/bin:/bin:...`). Anything in `~/.claude/local`, `/opt/homebrew/bin`, or an asdf/npm prefix is invisible to `execvp`. The fix: ask the user's login shell where the program lives, *once*, at setup time, and cache the absolute path.

```lua
function M.resolve_argv(args)
  if not args or #args == 0 then return args end
  local prog = args[1]
  if prog:sub(1, 1) == '/' then return args end
  local wezterm = require('wezterm')
  local shell = os.getenv('SHELL') or '/bin/zsh'
  local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
  if not ok or not stdout then return args end
  local path = (stdout:gsub('%s+$', ''))
  if path == '' or path:sub(1, 1) ~= '/' then
    -- Empty result, alias text, or shell function — nothing we can exec directly.
    return args
  end
  local out = { path }
  for i = 2, #args do out[#out + 1] = args[i] end
  return out
end
```

The result is plumbed back into `claude_cmd` (`lua/init.lua:154`), so subsequent `pane:split { args = claude_cmd }` calls fire `execvp` against an absolute path with no shell middleman. The Windows backend's equivalent (`lua/platform/windows.lua:50-52`) is the identity function — Windows doesn't have the GUI-PATH-stripping problem.

### `home_dir` for cross-platform path expansion

`lua/init.lua:115` — `default_scan_roots` expands `~` against `platform.home_dir()`:

```lua
function M.default_scan_roots()
  local util     = require('util')
  local platform = require('platform')
  local home = platform.home_dir()
  if not home then return {} end

  local result, seen = {}, {}
  for _, candidate in ipairs(CANDIDATE_PROJECT_DIRS) do
    local expanded = util.normalize((candidate:gsub('^~', home)))
    -- ... dedupe + dir_exists filter
  end
  return result
end
```

The platform backends wrap the OS-native env var (`USERPROFILE` on Windows, `HOME` on macOS/Linux), but `wezterm.home_dir` would have worked just as well — it's the same value. The wrapper exists mainly so the module can be loaded from a non-wezterm context.

### Procinfo: walk a pane's foreground process for identification

`lua/claude.lua:65-76` — termtools detects "this pane is running claude" by reading `pane:get_foreground_process_info()` (which returns the same `LocalProcessInfo` shape as `procinfo.get_info_for_pid`), then grepping `argv` / `executable` / `name` against the user-configurable `identify_patterns`:

```lua
local function is_claude_pane(pane)
  local ok, info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not info then return false end
  if type(info.argv) == 'table' then
    for _, arg in ipairs(info.argv) do
      if any_match(arg, opts.identify_patterns) then return true end
    end
  end
  if any_match(info.executable, opts.identify_patterns) then return true end
  if any_match(info.name, opts.identify_patterns) then return true end
  return false
end
```

The `pcall` is there because procinfo can fail (Linux without `/proc`, hardened-runtime macOS apps querying other-user PIDs); the function defaults to `false` rather than raising.

### Procinfo: descend into the child tree

If the foreground process is a wrapper and the thing you care about is one level deeper, switch to `procinfo.get_info_for_pid` and iterate `children`:

```lua
local fg = pane:get_foreground_process_info()
if not fg then return end
local info = wezterm.procinfo.get_info_for_pid(fg.pid)
if not info then return end
for child_pid, child in pairs(info.children or {}) do
  -- child is itself a LocalProcessInfo (recursive shape)
  if child.name == 'claude' then
    return child_pid, child.cwd
  end
end
```

The `pairs` (not `ipairs`) is load-bearing: `children` is a map keyed by PID, not a 1-indexed array. Iterating with `ipairs` will silently see zero entries.

### Procinfo: CWD lookup when OSC 7 isn't available

OSC 7 is the standard "shell tells terminal its CWD" protocol. Bash/zsh emit it via shell-integration; pwsh on Windows often doesn't (cmd.exe never does). When `pane:get_current_working_dir()` returns nil, `procinfo.current_working_dir_for_pid` is the fallback:

```lua
local cwd = pane:get_current_working_dir()
if not cwd then
  local fg = pane:get_foreground_process_info()
  if fg then
    cwd = wezterm.procinfo.current_working_dir_for_pid(fg.pid)
  end
end
```

Termtools' `util.pane_cwd` (`lua/util.lua:166`) does the same dance via `pane:get_foreground_process_info().cwd` directly — same data, fewer round trips.

## Gotchas

- **`target_triple` substring matching uses `:find(needle, 1, true)`.** The `, 1, true` is the literal-string flag for Lua's `string.find` — without it, your needle is a Lua pattern and `.` matches anything. Equality (`triple == 'x86_64-apple-darwin'`) works for one exact platform but silently misses `aarch64-apple-darwin`. Substring on the OS family (`windows`, `darwin`, `linux`) is the portable choice.
- **`current_working_dir_for_pid` returns `nil` on permission denial.** Windows applies ACLs to process introspection; macOS hardened runtime restricts cross-user queries; Linux containers without `/proc` mounted will fail every call. Always check for nil — never assume a valid PID gives back a string.
- **`get_info_for_pid` walks the process tree once per call and is *not* cheap.** It's fine to call from a key binding or a one-shot picker. Calling it from `update-right-status` (which fires every ~1s by default) or from an `augment-command-palette` handler (which fires every time the palette opens) is asking for noticeable hitches. Cache the result, or denormalise to just the field you need.
- **`children` is a map, not an array.** Iterate with `for pid, child_info in pairs(info.children) do ...` — `ipairs` returns nothing because the keys aren't 1-indexed integers. Same trap for the recursive walk: each `child_info.children` is also a map.
- **Windows PATHEXT trap.** `CreateProcess` (and therefore `wezterm.background_child_process` on Windows) only auto-appends `.exe`. PATHEXT (`.CMD;.BAT;.PS1;...`) is honoured by `cmd.exe`, by Explorer, and by the wezterm PTY spawn path — but *not* by the bare `CreateProcess` fire-and-forget path. Termtools wraps editor argv as `{ 'cmd.exe', '/c', ...args }` (`lua/platform/windows.lua:40`) for `background_child_process` calls. If you spawn anything ending in `.cmd`/`.bat`/`.ps1` via the action API or directly, wrap it the same way.
- **macOS GUI PATH stripping.** A wezterm launched from Finder, Dock, or Spotlight inherits a minimal PATH — basically `/usr/bin:/bin:/usr/sbin:/sbin`. Anything in `/opt/homebrew/bin`, `~/.claude/local`, `~/.asdf/shims`, an npm prefix, or a Nix profile won't be on PATH. Bare `claude`, `code`, `gh`, `rg` will all fail to resolve. Termtools shells out to `$SHELL -lic 'command -v PROG'` once at setup time (`lua/platform/darwin.lua:58`) and rewrites `args[1]` to the absolute path; the `-l` is for login shell, `-i` for interactive — that combination is what reliably sources `.zshrc`/`.zprofile`/`/etc/paths.d`. Don't call this resolver per-keypress; cache the result.
- **Linux `/proc` dependency.** procinfo on Linux reads `/proc/<pid>/`. Containers without `/proc` mounted (rare but seen with some hardened minimal images) return `nil` for everything. There's no fallback — the data simply isn't available.
- **`home_dir` is cross-platform; OS env vars are not.** On Windows, `os.getenv('HOME')` is empty by default — you want `USERPROFILE`. On macOS/Linux, `USERPROFILE` is empty. Use `wezterm.home_dir` (or termtools' `platform.home_dir()`) and skip the branching.
- **`pid()` returns the process you're running in, not always the GUI.** Inside the GUI process it's the GUI's PID; inside `wezterm-mux-server` (a daemonised mux) it's the server's PID. If you need the GUI specifically and your code might run headlessly, gate on `wezterm.gui` being available — see [01-architecture.md](01-architecture.md).
- **`target_triple` reflects the *build*, not the *runtime*.** A wezterm binary built for `x86_64-pc-windows-msvc` running under WSL still reports the Windows triple — but it's actually executing inside Linux. The mismatch is rare in practice (people build wezterm for the host they run it on) but the field is technically build-time, not runtime introspection.
- **`status` strings are OS-specific.** `Run`/`Sleep`/`Idle`/`Stop`/`Zombie` on Linux/BSD, simpler categories on Windows. Don't write portable code that branches on `info.status` unless you've checked all three.

## See also

- [02-modules.md](02-modules.md) — the broader `wezterm.*` module catalogue, including the procinfo and `wezterm` field listings.
- [04-pane-window-tab.md](04-pane-window-tab.md) — `pane:get_foreground_process_info()` returns the same `LocalProcessInfo` shape as `procinfo.get_info_for_pid`; the gotchas around `nil` returns and OSC-7-vs-procinfo CWD fallback live there.
- [06-spawning.md](06-spawning.md) — the PATHEXT and GUI-PATH-stripping context, including where in the spawn pipeline each shim applies.
- [16-domains.md](16-domains.md) — domains (SSH, WSL, mux) where procinfo's notion of "PID" reaches across hosts; the local-only assumption built into `wezterm.procinfo` matters there.
