# 15 — OSC sequences and clipboard

OSC (Operating System Command) escape sequences are how a shell or program *talks back* to the terminal — telling it the cwd, marking prompt boundaries, declaring hyperlinks, copying to the system clipboard, or stashing arbitrary key-value pairs against the pane. Wezterm consumes a fixed set of OSCs and exposes the parsed results through Lua surfaces (`pane:get_current_working_dir`, `pane:get_user_vars`, `pane:get_semantic_zones`, the OSC 8 hyperlink machinery, etc.).

The clipboard is a parallel surface with its own copy/paste/selection APIs that sit alongside — but don't go through — OSC 52.

This file covers the shell-talks-to-terminal direction and the OS-clipboard direction. Mouse-driven selection (drag to select, double-click for words, semantic-zone hit-testing) lives in [09-mouse.md](09-mouse.md).

## Overview

Two surfaces, one document:

- **OSC consumption** — wezterm parses a known set of OSC sequences and updates pane state. Your shell emits, wezterm reads, your Lua queries via `Pane:*` methods.
- **Clipboard / selection** — `Window:copy_to_clipboard`, `Window:get_selection_text_for_pane`, and the `CopyTo` / `PasteFrom` / `CompleteSelection` actions. These touch the OS clipboard directly; they don't round-trip through OSC 52.

There's no public Lua hook for "register an OSC parser" — the set wezterm understands is fixed. To send custom data from your shell, use OSC 1337 user vars (covered below).

## OSC catalogue (consumed by wezterm)

### OSC 7 — current working directory

```
\033]7;file://hostname/cwd\033\\
```

The shell emits this on every prompt to tell the terminal where it is. Wezterm parses it and exposes via `pane:get_current_working_dir()`. Spawning a new tab with no explicit `cwd` inherits this value.

Bash on modern Fedora sources `/etc/profile.d/vte.sh` automatically. On other systems you wire it manually — bash:

```bash
PROMPT_COMMAND='printf "\033]7;file://%s%s\033\\" "$HOSTNAME" "$PWD"'
```

PowerShell, in `prompt`:

```powershell
function prompt {
  $cwd = ($PWD.Path -replace '\\','/' -replace '^','/')
  $h   = $env:COMPUTERNAME
  Write-Host -NoNewline "`e]7;file://$h$cwd`e\"
  "PS $($PWD.Path)> "
}
```

### OSC 9;9 — alternate cwd format

```
\033]9;9;C:\path\to\dir\033\\
```

ConEmu / Cmder convention. Wezterm honours it as a second cwd source. Useful from contexts where assembling a `file://` URL is awkward (Windows native shells with backslash paths).

### OSC 133 — semantic prompt markers

A four-letter alphabet that lets the terminal know where prompts, input, and output begin and end. Once the shell emits these, wezterm can do *semantic zone* selection (drag-select an entire command's output with one click) and Lua can query the parsed zones.

| Code | Meaning |
| --- | --- |
| `\033]133;A\033\\` | Start of prompt |
| `\033]133;B\033\\` | End of prompt / start of user input |
| `\033]133;C\033\\` | Start of command output |
| `\033]133;D[;exit_code]\033\\` | End of command output (optional exit code) |

zsh/bash with the wezterm shell-integration script emit these. Pwsh needs the wezterm pwsh module. Bare `cmd.exe` and an unconfigured pwsh don't, so `SelectTextAtMouseCursor 'SemanticZone'` falls back to behaving like `'Line'`.

### OSC 1337 — iTerm2 protocol (user vars)

```
\033]1337;SetUserVar=<name>=<base64-value>\033\\
```

The user-var subset of iTerm2's OSC 1337 protocol. The value is base64-encoded; the name is plain. Wezterm stores `{name = value}` against the pane and emits a `user-var-changed` event plus an `update-status` for tab/status renderers.

Set a "current git branch" user var from a bash prompt:

```bash
PROMPT_COMMAND+=$'\nprintf "\\033]1337;SetUserVar=branch=%s\\033\\\\" "$(git branch --show-current 2>/dev/null | base64)"'
```

Read it from Lua:

```lua
local vars = pane:get_user_vars()
local branch = vars.branch or '?'
```

Wezterm pre-populates a few of its own: `WEZTERM_PROG`, `WEZTERM_USER`, `WEZTERM_HOST`, `WEZTERM_IN_TMUX`. The shell-integration script is what sets them — if you don't source it, they're absent.

### OSC 52 — copy from terminal to clipboard

```
\033]52;c;<base64-payload>\033\\
```

A program inside the terminal asks for text to land on the host clipboard. Wezterm honours it by default, gated by `enable_kitty_clipboard` and related security flags. This is how `tmux` `set -g set-clipboard on` propagates a yank to your OS clipboard, or how an SSH'd remote vim's `+y` works without X forwarding.

### OSC 8 — hyperlinks

```
\033]8;;http://example.com\033\\link text\033]8;;\033\\
```

Inline URI metadata. The `text` is what the user sees; clicking it (with `OpenLinkAtMouseCursor` bound — the default Ctrl+Click) opens the URI. `ls --hyperlink=auto` and modern build tooling emit these.

Beyond explicit OSC 8, wezterm also runs `hyperlink_rules` patterns over plain text to detect URLs, issue numbers, etc. — that's a config-side surface, not an OSC.

### OSC 1337 — other iTerm2 bits

Wezterm implements a subset: `SetUserVar` (above), `SetMark`, `CurrentDir=`, `RemoteHost=`. Image inline-protocol support is partial; check upstream before relying on it. There's no general-purpose "register handler for arbitrary OSC" hook — pick something already parsed.

### OSC 9;4 — progress

```
\033]9;4;<state>;<percent>\033\\
```

Stripe / progress bar reporting (Microsoft Terminal convention). Read via `pane:get_progress()`. Mostly used by CI tools and long-running CLIs.

## Lua surfaces

### Reading cwd: `pane:get_current_working_dir()`

Returns a `Url` userdata in modern wezterm, a string in older versions. Handle both:

```lua
local cwd = pane:get_current_working_dir()
if type(cwd) == 'table' and cwd.file_path then
  cwd = cwd.file_path
end
```

OSC 7 is wezterm's *cache* of whatever the shell most-recently emitted — bash/zsh/fish with shell integration emit on every prompt, but bare PowerShell and cmd often emit only at spawn (or never), so the OSC 7 cache lags behind a manual `cd`. `pane:get_foreground_process_info().cwd` is the OS-reported live CWD of the foreground process and tracks `cd` immediately. termtools' `util.pane_cwd` (`lua/util.lua:166`) prefers procinfo, falling back to OSC 7 only if procinfo isn't available:

```lua
function M.pane_cwd(pane)
  if not pane then return nil end
  local ok_pi, info = pcall(pane.get_foreground_process_info, pane)
  if ok_pi and info and type(info.cwd) == 'string' and info.cwd ~= '' then
    return info.cwd
  end
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if ok and cwd then
    if type(cwd) == 'string' and cwd ~= '' then return cwd end
    -- Url userdata (modern) or path-table (transitional) — both expose
    -- .file_path. type(userdata) ~= 'table', so we can't gate on table;
    -- pcall the index access in case it raises.
    local ok_fp, fp = pcall(function() return cwd.file_path end)
    if ok_fp and type(fp) == 'string' and fp ~= '' then return fp end
  end
  return nil
end
```

The `pcall`s matter — calling either method on a pane that closed during a teardown race raises rather than returns `nil`.

### Reading user vars: `pane:get_user_vars()`

```lua
local vars = pane:get_user_vars()
-- vars is { ['branch'] = 'main', WEZTERM_PROG = 'vim', ... }
```

Returns a flat table. Set via OSC 1337 `SetUserVar` from the shell. Changes broadcast across mux clients, so multiple GUIs attached to the same mux see updates simultaneously.

### Reading semantic zones: `pane:get_semantic_zones(zone_type?)`

```lua
local zones = pane:get_semantic_zones('Output')
-- list of { start_x, start_y, end_x, end_y, semantic_type = 'Output' }
```

`zone_type` is one of `'Prompt' | 'Input' | 'Output'`, or omitted for all. Each zone is a rectangle in stable-row-index coordinates. Useful for "scroll to the start of the previous command", "yank the last command's output", etc. Empty list when the shell doesn't emit OSC 133 — there's no error, just silence.

### Reading the selection: `window:get_selection_text_for_pane(pane)`

```lua
local raw = window:get_selection_text_for_pane(pane)
if not raw or raw == '' then ... end
```

Returns a plain string (no ANSI). The companion `window:get_selection_escapes_for_pane(pane)` keeps the escapes if you need styling.

This is a *window* method that takes a pane, not a pane method, because the selection lives in the window's render state. The same pane visible in two windows can have two independent selections.

## Clipboard surface

### Programmatic copy: `window:copy_to_clipboard(text, target?)`

```lua
window:copy_to_clipboard('hello', 'Clipboard')
window:copy_to_clipboard('hello', 'PrimarySelection')
window:copy_to_clipboard('hello', 'ClipboardAndPrimarySelection') -- default
```

`target` is one of `'Clipboard' | 'PrimarySelection' | 'ClipboardAndPrimarySelection'`. The call is **asynchronous** — it returns immediately and the OS clipboard updates in a background thread. If subsequent Lua code needs the new value visible to other apps (e.g. spawning a process that pastes from clipboard), schedule it with `wezterm.time.call_after(0.05, ...)`.

Goes directly to the OS clipboard — does not round-trip through OSC 52.

### Programmatic paste: `pane:paste(text)`

```lua
pane:paste('cd /tmp\r')
```

Writes through the pane's bracketed-paste machinery if the program inside has it enabled. Use this for multi-line text. For a single command `pane:send_text('ls\r')` is fine — see [04-pane-window-tab.md](04-pane-window-tab.md).

### Action-side: copy current selection

| Action | Use |
| --- | --- |
| `wezterm.action.CopyTo 'Clipboard'` | hotkey-triggered copy of the selection |
| `wezterm.action.CopyTo 'PrimarySelection'` | X11/Wayland primary only |
| `wezterm.action.CopyTo 'ClipboardAndPrimarySelection'` | both |
| `wezterm.action.CompleteSelection 'Clipboard'` | finalise an in-progress drag-select *and* copy in one mouse-up |
| `wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor 'Clipboard'` | same, plus open the OSC 8 link if there's nothing selected |

`CompleteSelection` is the partner of `SelectTextAtMouseCursor` — without it on the matching `Up` event, the selection visually highlights but never copies. `CopyTo` works on whatever's already selected; it doesn't start a selection.

### Action-side: paste

```lua
wezterm.action.PasteFrom 'Clipboard'
wezterm.action.PasteFrom 'PrimarySelection'
```

`PrimarySelection` is X11/Wayland-only; on macOS/Windows it falls back to `Clipboard`. Wezterm wraps the inserted text in bracketed-paste markers (`\033[200~...\033[201~`) when the program has bracketed paste enabled.

## Examples

### Resolve cwd via procinfo with OSC 7 fallback

`util.pane_cwd` (`lua/util.lua:166`–`186`) — see the snippet above. Used everywhere a termtools picker needs to know "where's this pane really running": project picker, action picker, claude scanner. Procinfo-first is what makes termtools track manual `cd` on Windows pwsh, where OSC 7 lags behind the shell's actual working directory.

### Read the selection for an editor handoff

`open_selection.lua:23`–`30`:

```lua
function M.run(window, pane, opts)
  opts = opts or {}
  local raw = window:get_selection_text_for_pane(pane)
  if not raw or raw == '' then
    window:toast_notification('termtools',
      'No selection — highlight a file path first.', nil, 1500)
    return
  end
  ...
end
```

The selection is whatever the user double-click-selected (or drag-selected) before invoking the action. Combined with the `Ctrl+Shift+Click` mouse binding in `lua/style.lua:171`, the user double-clicks a file path, then `Ctrl+Shift+Click`s anywhere — termtools reads the selection (not the URI under the cursor) and routes the path to their editor.

### Copy-on-select via `CompleteSelection`

`lua/style.lua:148`:

```lua
if s.copy_on_select then
  config.mouse_bindings = config.mouse_bindings or {}
  table.insert(config.mouse_bindings, {
    event = { Up = { streak = 1, button = 'Left' } },
    mods  = 'NONE',
    action = wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor
      'ClipboardAndPrimarySelection',
  })
end
```

Drag to select; on mouse-up the selection lands on both clipboard and primary. If nothing was selected, the action falls through to opening the OSC 8 link under the cursor.

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

Bound to `Down` — paste fires on press, not on release.

### Set a user var from a shell prompt

Bash:

```bash
__set_user_var() {
  local name=$1; shift
  local val
  val=$(printf '%s' "$*" | base64 | tr -d '\n')
  printf '\033]1337;SetUserVar=%s=%s\033\\' "$name" "$val"
}
PROMPT_COMMAND+=$'\n__set_user_var branch "$(git branch --show-current 2>/dev/null)"'
```

Then in your wezterm config:

```lua
wezterm.on('format-tab-title', function(tab)
  local branch = tab.active_pane.user_vars.branch
  return branch and (' [' .. branch .. '] ') or ''
end)
```

Note `tab.active_pane.user_vars` (a snapshot field on the event payload) vs `pane:get_user_vars()` (a live method call) — both work; the snapshot is cheaper inside `format-tab-title` which fires often. See [14-tab-bar-and-status.md](14-tab-bar-and-status.md).

### Programmatic paste

```lua
{
  label = 'Reload dev server',
  run = function(_window, pane, _root)
    pane:paste('rs\r')
  end,
}
```

Multi-line is fine (`pane:paste('foo\nbar\r')`); the bracketed-paste wrapper means most shells treat it as a single submission unit.

## Gotchas

### `get_current_working_dir` return type changed

Older wezterm returned a string. Modern wezterm returns a `Url` userdata with `.file_path`, `.host`, `.scheme` fields. `tostring(url)` gives the full `file://host/path` form, which is rarely what callers want. termtools' `util.pane_cwd` (`lua/util.lua:166`) handles both — copy that pattern, don't roll your own.

### OSC 7 needs a hostname segment

The grammar is `file://HOSTNAME/PATH`. An empty hostname (`file:///path`) is technically legal but some wezterm versions and downstream consumers misparse it. Always include a hostname (`$HOSTNAME` on Unix, `$env:COMPUTERNAME` on Windows). Paths with spaces should be URL-encoded (`%20`) — bash and zsh's standard helpers do this; hand-rolled `printf "\033]7;file://...\033\\"` will silently break on `~/My Documents`.

Termtools' user-side guide for emitting OSC 7 from each common shell — required when running mux/SSH-attached panes since procinfo doesn't always travel over the mux protocol — lives at [`docs/shell-integration.md`](../shell-integration.md).

### OSC 133 markers depend on shell integration

Bare `pwsh.exe` and `cmd.exe` don't emit prompt markers. Without them, `SelectTextAtMouseCursor 'SemanticZone'` falls back to `'Line'` and `pane:get_semantic_zones()` returns an empty list. termtools' `style.lua` notes this in mouse-binding gotchas. Wire the shell-integration scripts wezterm ships with, or note in your readme that semantic-zone features need them.

### User vars reset when foreground process changes

The vars are set against the pane, not against a process. They persist across `cd` and across subshells started by the same shell. But `bash → vim → bash` may clear them — vim's startup overwrites the screen, and the new bash instance hasn't run its prompt hook yet, so `pane:get_user_vars().branch` will be stale or absent until the next prompt fires.

### OSC 52 is a security gate

Letting any program inside the terminal write to the host clipboard is a known attack surface (escape sequences in fetched text, etc.). Wezterm honours OSC 52 by default but gates with config flags. Don't disable the gates without thinking about what you're letting through. Inverse problem: some sandboxed remotes refuse to emit OSC 52 — that's why `pane:paste(window:get_selection_text_for_pane(other_pane))` is a useful Lua-side workaround for cross-pane copy without OSC 52.

### `copy_to_clipboard` does *not* go through OSC 52

It writes directly to the OS clipboard via the GUI process. Other applications see a normal clipboard event, not a stripped escape sequence. This means `window:copy_to_clipboard` works even with OSC 52 disabled, and isn't constrained by the OSC 52 gate.

### `copy_to_clipboard` is async

The call returns before the OS clipboard updates. Spawning a process that pastes immediately afterwards can race. If you must chain, schedule the spawn with `wezterm.time.call_after(0.05, ...)` — see [12-state-and-timing.md](12-state-and-timing.md).

### Bracketed paste needs program cooperation

`pane:paste` and `PasteFrom` both wrap the text in `\033[200~...\033[201~` if the program inside has bracketed paste mode enabled. Programs that *don't* understand these markers will see literal `[200~` characters at the start of pasted text. Most modern shells handle it fine; some old REPLs and `cat`-style tools don't. There's no Lua knob to disable wrapping per call — it's the program's job to opt in via the corresponding DEC mode.

### `PrimarySelection` is Linux-only

X11 has the primary selection (middle-click paste). Wayland has it via `primary-selection-unstable-v1` or the Gtk legacy protocol. Neither macOS nor Windows has the concept; `CopyTo 'PrimarySelection'` and `PasteFrom 'PrimarySelection'` silently fall back to the regular clipboard (or no-op) on those platforms. `'ClipboardAndPrimarySelection'` is safe everywhere — it just acts like `'Clipboard'` where primary doesn't exist.

### Selection text != hyperlink URI

`window:get_selection_text_for_pane(pane)` returns the highlighted text. `OpenLinkAtMouseCursor` reads the URI metadata under the cursor (OSC 8 hyperlink, or a `hyperlink_rules` match). The two are independent — clicking text that happens to be inside a hyperlink doesn't make the URI part of the selection, and selecting hyperlinked text gives you the visible text, not the URI. termtools' Ctrl+Shift+Click deliberately reads the *selection*, not the URI, because the user's intent ("open this path I just selected") doesn't match the OSC 8 model.

### No public OSC handler hook

There is no `wezterm.on('osc', fn)` or "register custom OSC 1337 verb" surface. The set wezterm parses is fixed in the source. To get arbitrary data from your shell into Lua, encode it as a `SetUserVar` value. To hook the *moment* a value changes, listen for `user-var-changed`.

### `get_selection_text_for_pane` returns empty string for "no selection"

Not `nil`. Always test with `if not raw or raw == ''` — termtools' `open_selection.lua:26` shows the shape. A pure `if raw` test passes for empty strings in Lua.

### Tmux passthrough

Inside tmux, OSCs from the inner shell are swallowed by default. Set `set -g allow-passthrough on` in `tmux.conf` for OSC 7, OSC 1337 user vars, and OSC 52 to reach wezterm. If your branch user-var works directly in wezterm but not under tmux, check this first.

## See also

- [04-pane-window-tab.md](04-pane-window-tab.md) — `Pane:get_current_working_dir`, `Pane:get_user_vars`, `Pane:get_semantic_zones`, `Window:get_selection_text_for_pane`, `Window:copy_to_clipboard`.
- [09-mouse.md](09-mouse.md) — `SelectTextAtMouseCursor`, `CompleteSelection`, `OpenLinkAtMouseCursor`, the mouse-binding shape that wires copy-on-select and right-click paste.
- [14-tab-bar-and-status.md](14-tab-bar-and-status.md) — surfacing user vars in tab titles and status bars; the `user-var-changed` and `update-status` events.
- [12-state-and-timing.md](12-state-and-timing.md) — `wezterm.time.call_after` for sequencing after the async clipboard write completes.
