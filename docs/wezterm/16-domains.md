# 16 — Domains

A *domain* is the thing that owns a pane and runs processes for it. Out of the box there's exactly one — the local machine — and every spawn goes there. The interesting trick is that other domains let you transparently use SSH hosts, WSL distros, or remote `wezterm-mux-server`s as if they were local: same key bindings, same `SpawnCommand` shape, different backend doing the actual `execvp`.

## Overview

WezTerm splits "where do I render this pane" from "where does the process actually run". The mux (see [05-mux-and-workspaces.md](05-mux-and-workspaces.md)) is the object tree of windows/tabs/panes. Domains are the *backends* the mux delegates spawning and PTY ownership to.

| Domain type | Backend | Persistence | Declared via |
| --- | --- | --- | --- |
| Local (default) | direct fork/CreateProcess on this host | dies with the process | always present, no config |
| `SshDomain` | SSH transport, optionally with remote wezterm-mux-server | survives client disconnect if `multiplexing = 'WezTerm'` | `config.ssh_domains` |
| `WslDomain` | WSL distribution as a local domain variant | dies with the GUI process | `config.wsl_domains` (or `wezterm.default_wsl_domains()`) |
| `TlsDomainClient` / `TlsDomainServer` | TCP over TLS to a remote `wezterm-mux-server` | yes — server-side mux survives | `config.tls_clients` / `config.tls_servers` |
| Unix-domain mux | local socket to a `wezterm-mux-server` daemon | yes — across GUI restarts | `config.unix_domains` |
| `ExecDomain` | a Lua callback that rewrites the `SpawnCommand` before the local backend runs it | none of its own | `wezterm.exec_domain(name, fn)` |

Two non-obvious facts up front:

1. **Domains and workspaces are orthogonal.** A pane has a domain (where its bytes are produced) and is in a window that's in a workspace (which named group of windows is currently visible). Switching workspace doesn't change domains; attaching a domain doesn't change workspace.
2. **The mux server is itself a domain.** Running `wezterm-mux-server` and connecting to it via `unix_domains` or `tls_clients` is what wires up the persistence story sketched in [05-mux-and-workspaces.md](05-mux-and-workspaces.md). The TODO.md wishlist item ([line 4](../../TODO.md)) is exactly this configuration — local daemon plus a unix-domain entry — to get reload-vs-restart without losing long-running sessions.

## Key APIs

### Config keys

```lua
config.ssh_domains   = { { name = ..., remote_address = ..., ... }, ... }
config.wsl_domains   = { { name = ..., distribution = ..., ... }, ... }
config.unix_domains  = { { name = ..., socket_path = ..., ... }, ... }
config.tls_clients   = { { name = ..., remote_address = ..., ... }, ... }
config.tls_servers   = { { bind_address = ..., pem_cert = ..., ... }, ... }
config.exec_domains  = { wezterm.exec_domain('name', fn), ... }
```

`exec_domains` is the odd one out — its entries are constructed by `wezterm.exec_domain(name, fixup_fn [, label])`, not plain tables.

### Action-table dispatch — see [08-actions-and-keys.md](08-actions-and-keys.md)

- `wezterm.action.AttachDomain 'name'` — connect to a domain. If it has remote panes already, they're imported into the local GUI; otherwise a default program is spawned.
- `wezterm.action.DetachDomain { DomainName = 'name' }` — drop the domain's windows/tabs from this GUI. Panes keep running on the remote side and reappear on re-attach. `'CurrentPaneDomain'` (string form) detaches whatever the current pane lives in.
- `wezterm.action.SpawnTab { DomainName = 'name' }` — bare-domain tab spawn. Same domain-selector shapes (`CurrentPaneDomain` / `DefaultDomain` / `{ DomainName = ... }`) are accepted by `SpawnCommandInNewTab` and friends — see [06-spawning.md](06-spawning.md).

### Spawn-time selection

The `domain` field on a `SpawnCommand` accepts:

- `"CurrentPaneDomain"` — same domain as the pane the action fired from. Default for `SpawnCommandInNewTab` / `pane:split`.
- `"DefaultDomain"` — whatever `wezterm.mux.set_default_domain` last set, otherwise the local domain. Default for `wezterm.mux.spawn_window` (there is no "current pane" for headless spawns).
- `{ DomainName = 'unix' }` — a specific named domain.

### Mux-side queries

- `wezterm.mux.all_domains()` — every domain registered with the mux (local + everything declared in config).
- `wezterm.mux.get_domain(name_or_id)` — fetch one; nil arg returns the current default.
- `wezterm.mux.set_default_domain(domain)` — change what new spawns target.
- `pane:get_domain_name()` — read the domain name of an existing pane (handy from inside `format-tab-title` to badge tabs that aren't local).

## Examples

### SSH domain with a key binding to attach

```lua
config.ssh_domains = {
  {
    name = 'devbox',
    remote_address = 'devbox.example.com:22',
    username = 'mpd',
    multiplexing = 'WezTerm',  -- bootstrap wezterm-mux-server on the remote
    ssh_option = {
      identityfile = '~/.ssh/id_ed25519',
    },
  },
}

config.keys = {
  { key = 'a', mods = 'LEADER', action = wezterm.action.AttachDomain 'devbox' },
  { key = 'd', mods = 'LEADER', action = wezterm.action.DetachDomain { DomainName = 'devbox' } },
}
```

First attach takes a few seconds — wezterm checks for `wezterm-mux-server` on the remote, scp's a binary if missing, and starts it. Subsequent attaches reconnect instantly to the still-running server.

### WSL auto-discovery

```lua
config.wsl_domains = wezterm.default_wsl_domains()
```

That single call parses `wsl -l -v` and produces a domain per distribution, named `WSL:<distro>` (e.g. `WSL:Ubuntu`, `WSL:Debian`). Override per-distro entries by spreading and patching:

```lua
local domains = wezterm.default_wsl_domains()
for _, d in ipairs(domains) do
  if d.name == 'WSL:Ubuntu' then
    d.default_cwd = '/home/mpd/code'
    d.default_prog = { 'fish' }
  end
end
config.wsl_domains = domains
```

### Spawn a tab on a specific WSL distro

```lua
{ key = 'u', mods = 'LEADER|SHIFT', action = act.SpawnCommandInNewTab {
    domain = { DomainName = 'WSL:Ubuntu' },
    args = { 'bash', '-l' },
  },
},
```

`args` is interpreted on the WSL side, so `bash` resolves via the distro's PATH, not Windows'. `cwd`, if you set it, must be a Linux path (`/home/mpd`), not a Windows one (see Gotchas).

### Local mux server via unix domain — TODO.md line 4

The configuration that would make `Ctrl+Shift+R`-then-restart not nuke long-running sessions:

```lua
-- In ~/.wezterm.lua, paired with a wezterm-mux-server running as a daemon
-- (Task Scheduler on Windows, launchd plist on macOS).
config.unix_domains = {
  {
    name = 'mux',
    socket_path = wezterm.home_dir .. '/.local/share/wezterm/mux.sock',
  },
}

config.default_domain = 'mux'  -- new spawns go through the daemon
```

Once `wezterm-mux-server` is running and listening on that socket, every new tab/pane is owned by the daemon. Killing the GUI window leaves the panes alive in the daemon; reopening the GUI re-attaches and the panes reappear with their scrollback.

The piece termtools doesn't do *yet* is the daemon launching itself — `wezterm-mux-server` doesn't auto-start the way some mux daemons do. You install it as a login-time scheduled task / launch agent. TODO.md tracks it.

### ExecDomain wrapping every command in tmux

The fixup callback receives a `SpawnCommand` and must return one. Anything goes — rewrite `args`, prepend a wrapper, set env vars, change `cwd` — as long as you return the (possibly mutated) table:

```lua
config.exec_domains = {
  wezterm.exec_domain('tmux-wrapped', function(cmd)
    -- cmd.args is nil if the user spawned with no explicit argv (default shell).
    local user_args = cmd.args or { os.getenv('SHELL') or '/bin/bash' }
    cmd.args = {
      'tmux', 'new-session', '-A', '-s', 'wezterm',
      table.concat(user_args, ' '),
    }
    return cmd
  end),
}
```

Then attach via `act.AttachDomain 'tmux-wrapped'` or set `domain = { DomainName = 'tmux-wrapped' }` on a specific spawn. Every pane in this domain ends up multiplexed inside a single tmux session — useful for "I want a server-side fallback if wezterm dies" without standing up a real `wezterm-mux-server`.

### Reading a pane's domain in `format-tab-title`

```lua
wezterm.on('format-tab-title', function(tab, _tabs, _panes, _config, _hover, _max)
  local pane = tab.active_pane
  local dom = pane.domain_name or 'local'
  if dom == 'local' then
    return tab.active_pane.title
  end
  return string.format('[%s] %s', dom, tab.active_pane.title)
end)
```

The tab's `active_pane` here is the snapshot table the event hands you, not a live `Pane` — its `domain_name` field is one of the few `Pane` properties exposed there directly. See [14-tab-bar-and-status.md](14-tab-bar-and-status.md).

## Gotchas

- **`multiplexing = 'None'` for SSH means no persistence.** When the GUI disconnects, the SSH connection drops and the processes die. `multiplexing = 'WezTerm'` (the default) bootstraps `wezterm-mux-server` on the remote first, then talks to *that* — surviving disconnects, reattaching cleanly, retaining scrollback. `'None'` is occasionally useful for one-shot SSH sessions where you don't want the bootstrap, but for normal use `'WezTerm'` is what you want.
- **WSL `default_cwd` must be a Linux path.** `/home/mpd` works; `C:\Users\mpd` silently fails (the WSL side can't `chdir` to a Windows path). The failure mode on Windows is a tab that flashes open and closes; on macOS/Linux the error is louder. Pick the Linux mount-point form (`/mnt/c/Users/mpd`) if you really need to start in a Windows dir.
- **`wezterm-mux-server` doesn't auto-start.** The client connects to an *existing* server; if nothing's listening on `socket_path` the attach silently fails (or with a faint error in the wezterm log). Install it as a login-time daemon — Task Scheduler on Windows, launchd plist on macOS, systemd user unit on Linux. TODO.md ([line 4](../../TODO.md)) tracks termtools' wishlist for this wiring.
- **`wezterm.gui.*` is unavailable inside the mux server.** Code paths that load when `wezterm-mux-server` evaluates the same `wezterm.lua` (it does — modulo `--skip-config`) must not unconditionally `require 'wezterm.gui'`. `pcall(require, 'wezterm.gui')` and feature-gate any use. Same rule applies to `wezterm.gui_window_for_mux_window`. See [02-modules.md](02-modules.md).
- **SSH options are a moving target.** `ssh_option = { identityfile = ... }` mirrors OpenSSH's config-file keys, but support varies by wezterm version, and fancy stuff (jump hosts, `ProxyCommand`, `ControlMaster`) is hit-or-miss. The robust workaround: configure the host normally in `~/.ssh/config` and reference it by name from `remote_address`. WezTerm's SSH client honours `~/.ssh/config` for `Host` blocks.
- **`AttachDomain` is async.** The action returns immediately; the connection happens in the background. Don't expect `wezterm.mux.get_domain('foo'):attach()` to be observable on the next line of Lua. If you need to fire something *after* the attach completes, listen for `mux-startup` on the remote side or poll `wezterm.mux.all_windows()` from a `time.call_after` (see [12-state-and-timing.md](12-state-and-timing.md)).
- **TLS client cert pinning.** TLS domains require either explicit `pem_private_key` / `pem_cert` / `pem_ca` paths or a `bootstrap_via_ssh = 'user@host:port'` clause that does the cert exchange for you on first connect. Skip the manual cert dance unless you know what you're doing — `bootstrap_via_ssh` is the path of least resistance. WezTerm's docs walk through generating self-signed certs if you go the manual route.
- **`ExecDomain` return value is mandatory.** If your fixup callback returns `nil` (or `false`), the spawn silently breaks. Always end with `return cmd`. `cmd.args` may itself be `nil` — that's the "no explicit argv, use the default shell" case — so guard before doing `table.concat(cmd.args, ' ')` or it'll throw on a default-shell spawn.
- **`ExecDomain` runs synchronously on every spawn into that domain.** No expensive work in the fixup. If you need to read a file or shell out to compute the rewritten args, do it once at config eval and cache in a module-level local.
- **Domain selection differs by entrypoint.** Action spawns (`SpawnCommandInNewTab`, `pane:split`) default to `CurrentPaneDomain`; `wezterm.mux.spawn_window` defaults to `DefaultDomain`. If you're spawning into a non-default domain from a context that defaults to `CurrentPaneDomain` (e.g. an `action_callback` in a pane that's already in a different domain), set `domain` explicitly.
- **`DetachDomain` doesn't kill panes.** The remote panes keep running; only the local view goes away. Re-attaching brings them back with scrollback intact. To actually terminate, kill the panes (or the mux server) yourself.
- **Local domain is named `'local'`.** If you ever need to test "is this pane on the local machine?" without enumerating all domains, `pane:get_domain_name() == 'local'` works.
- **Don't confuse `unix_domains` with the OS-level Unix domain socket on Windows.** Unix-domain mux works on Windows too (wezterm uses AF_UNIX where available, named pipes elsewhere via the `proxy_command` field). The "Unix" in the name refers to the WezTerm domain *type*, not the host OS.

## See also

- [05-mux-and-workspaces.md](05-mux-and-workspaces.md) — `wezterm.mux` operations, MuxWindow/Tab/Pane handles, and the in-process-mux vs daemonised-mux split that domains sit on top of.
- [06-spawning.md](06-spawning.md) — `SpawnCommand` shape; the `domain` field is one of its keys, and the action-vs-mux entrypoints have different defaults.
- [08-actions-and-keys.md](08-actions-and-keys.md) — `AttachDomain` / `DetachDomain` action constructors and how they slot into key bindings.
- [10-events.md](10-events.md) — `mux-startup` fires once per mux process, including inside `wezterm-mux-server`; useful for seeding workspace/tab layouts on the daemon side.
- [01-architecture.md](01-architecture.md) — GUI vs mux process, why daemonising the mux is what unlocks pane persistence across GUI restarts.
