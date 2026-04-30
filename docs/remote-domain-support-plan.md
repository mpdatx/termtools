# Remote-domain support for the project + action pickers

## Context

Termtools assumes the GUI client and the panes it dispatches to share a filesystem. That holds when wezterm is talking to its built-in `'local'` domain. It breaks down when a pane lives on a remote domain — a unix-domain mux, an SSH domain with `multiplexing = 'WezTerm'`, or a TLS-mux client — because the pane's CWD is on a different machine than the GUI's `io.open` / `wezterm.read_dir` reach.

Today the symptoms are:

- **Project picker** auto-scans `scan_roots` against the GUI's *local* filesystem only. Remote project trees are invisible.
- **Project root walk-up** in `find_root(cwd)` checks for marker files via `io.open` / `read_dir` against the GUI's local filesystem. A remote pane's CWD comes through correctly (procinfo reports the server-side cwd) but the marker check on that path fails locally, so `find_root` returns nil and the action picker silently falls back to "use CWD as root" — losing the marker invariant.
- **External editor for remote files** opens the local-path equivalent of the remote path, which usually doesn't exist on the local machine (modulo VS Code Remote-SSH or similar setups, which we don't try to detect). The inline editor path works correctly because `pane:split` inherits the calling pane's domain.

## Goals

1. Project picker surfaces remote projects — explicitly listed by the user — alongside locally discovered ones.
2. Action picker treats a remote pane's CWD as the project root without trying (and failing) to walk it up.
3. "Open `<file>`" actions hide their external-editor variant when the active pane is on a remote domain, so users can't accidentally pick an action that can't reach the file.
4. Project picker spawning into a remote project lands a tab in the right domain (so the new pane runs on the mux, not on the local machine).
5. Backward-compatible: a user with no remote domains configured sees no behavioural change.

## Non-goals

- Auto-scanning a remote filesystem from local Lua. Wezterm exposes no primitive for that, and shelling out via SSH per query is too slow for an interactive picker. Users hand-list remote projects.
- WSL-specific bridging. WSL distros expose as their own ExecDomain; mapping `\\wsl$\...` to `/...` and back is a separate workstream.
- Tracking nested SSH (a remote pane that's itself SSH'd somewhere else). The pane's `domain_name()` reflects the wezterm-domain, not where the foreground process is — that's the deepest we look.
- Detecting and rewriting paths for VS Code Remote-SSH / Cursor Remote / similar editor-side extensions.

## Design

### Domain concept

Every pane carries a domain (`pane:domain_name()`). The default `'local'` domain is the GUI's own filesystem. Anything else — `'mux'` from `unix_domains`, `'myhost'` from `ssh_domains`, etc. — is a domain whose filesystem is potentially elsewhere.

We don't try to introspect a domain's locality from its kind. Instead, the user opts in by declaring per-domain config. A domain that has no per-domain config is treated as local-equivalent (works correctly for `default_domain = 'mux'` over a unix socket on the same machine; only diverges from the local fs when the user has actually configured a remote pinned list).

### New opts

Add to `init.lua`'s `DEFAULTS_NESTED.paths`:

```lua
paths = {
  scan_roots    = {},
  pinned        = {},
  trusted_paths = {},
  markers       = nil,
  -- New: per-domain pinned project lists. Keys are domain names
  -- (matching pane:domain_name() return values); values are arrays of
  -- absolute paths on that domain's filesystem.
  domain_pinned = {},
}
```

A domain that appears as a key in `domain_pinned` is implicitly "remote-like": project root walk-up is skipped on its panes, external-editor file actions are hidden, and the project picker offers the listed paths under the domain's name.

### 1. Domain-aware project discovery

`projects.discover(opts)` stays as-is for local discovery. Add `projects.discover_for_domain(domain, opts)` that returns the configured pinned list for `domain`, normalized as `{path, name, source = 'pinned-domain', domain = name}`. Empty list if the domain has no entry.

The project picker calls both: local discovery for the local section, and `discover_for_domain(active_pane_domain)` for the active pane's domain. They're merged into a single list with a domain marker on each entry.

Display: per-domain entries get a small suffix or prefix in the picker label, e.g. `[myhost] foo` or `foo (myhost)`. Sort puts entries from the active pane's domain near the top so reattaching to a project on the same remote you're already in is one keystroke away.

### 2. Domain-aware root resolution

`projects.find_root(cwd)` walks up looking for marker files via `io.open`. We add an optional second argument:

```lua
projects.find_root(cwd, opts)
```

where `opts` carries `{ domain = '...' }`. If `domain` is a key of `domain_pinned`, the walk-up is skipped and the function returns the deepest pinned root that contains `cwd` (via `is_inside`); if no pinned root contains `cwd`, returns the CWD itself as a fallback. This keeps the action picker's `Open <file>` actions resolving paths relative to a sane root even on remote panes.

For local domains, behaviour is unchanged — full walk-up against local fs.

Callers updated: `pickers/project.lua` (existing-tab matching for "switch to project") and `pickers/action.lua` (root for action dispatch).

### 3. Domain-aware action availability

The cleanest way to hide the external-editor path on remote panes is to extend `visible_when` with the active pane's domain. Two options:

**Option A**: change the predicate signature to `visible_when(root, ctx)` where `ctx` carries `{ domain = '...' }`. Action picker passes `ctx`. Built-in `actions.open_file` (factory) checks `ctx.domain` against `domain_pinned` and returns false for `role == 'default'` on remote.

**Option B**: stash the active domain on `opts` at picker time (`opts._active_domain = domain`), and have the catalogue's `open_file` factory close over it via `local opts = require('init').opts()` at fire time. No predicate signature change.

Option A is more explicit; Option B is less invasive. Recommend Option B — the existing `description` and `run` already do the late-bind dance with `require('init').opts()`, so adding `opts._active_domain` is a minimal extension of the same pattern.

Concrete: in `pickers/action.lua` `M.run`, before calling `build_action_list`, set `opts._active_domain = pane:domain_name()`. The factory in `actions.open_file` reads `opts._active_domain` inside `visible_when`:

```lua
visible_when = function(root)
  if role == 'default' then
    local opts = require('init').opts()
    local d = opts._active_domain or 'local'
    local pinned = opts.domain_pinned or {}
    if pinned[d] then return false end -- remote: hide external-editor variant
  end
  return true
end,
```

`Open project in editor` (the `open-project` group) gets the same treatment.

### 4. Spawn dispatch into the right domain

The project picker's "spawn a tab for this project" flow uses `wezterm.action.SpawnCommandInNewTab { cwd = ..., args = ... }` with no explicit domain. Wezterm interprets that as the calling pane's domain.

For domain-pinned project entries, the picker should dispatch with an explicit domain:

```lua
wezterm.action.SpawnCommandInNewTab {
  domain = { DomainName = entry.domain },
  cwd = entry.path,
  args = cmd,
}
```

`entry.domain` is the domain key the user listed the project under in `domain_pinned`. For locally-discovered entries, `entry.domain` is `'local'` (or omit `domain` entirely — same result).

The "find existing pane in this window" check in `find_existing_pane_in_window` should also be domain-aware: only consider panes whose `domain_name()` matches `entry.domain` as candidates. A `myhost`-domain pane's CWD might literally equal `/home/foo/proj` even when the user picked the local-domain project at `/home/foo/proj` (different machines, same path) — without the domain filter, the picker would focus the wrong tab.

## Concrete changes

| File | Change |
| ---- | ------ |
| `lua/init.lua` | Add `domain_pinned = {}` to `DEFAULTS_NESTED.paths`. Pass through to opts. No section/grouping change. |
| `lua/util.lua` | Add `M.pane_domain(pane)` returning `pane:domain_name()` via pcall, defaulting to `'local'`. |
| `lua/projects.lua` | Add `M.discover_for_domain(domain, opts)`. Extend `M.find_root(cwd, walk_opts)` with optional `walk_opts.domain` to short-circuit walk-up. Cache stays per-`opts_key`, keyed off the union of pinned + per-domain pinned now. |
| `lua/pickers/project.lua` | Compute active pane domain. Merge local discovery with per-domain pinned. Decorate entries with their domain. Sort: same-domain-as-active first. On select, pass `domain = { DomainName = entry.domain }` to `SpawnCommandInNewTab` (omit for `'local'`). Filter `find_existing_pane_in_window` by entry domain. |
| `lua/pickers/action.lua` | Compute active pane domain. Stash on `opts._active_domain` for catalogue closures. Pass `{ domain = ... }` to `find_root` so walk-up is skipped on remote. |
| `lua/actions.lua` | `open_file` factory: `visible_when` checks `opts._active_domain` against `opts.domain_pinned` and returns false for `role == 'default'` on remote. `Open project in editor`: same gate. |
| `README.md` | Document `domain_pinned`. Add a short "Remote (mux/SSH) tabs" section near `scan_roots`. |
| `docs/wezterm/16-domains.md` | Cross-reference termtools' per-domain pinned config. |
| `examples/full.wezterm.lua` | Show a `domain_pinned` example with a fictional `myhost` SSH domain. |

## Edge cases

- **`default_domain = 'mux'` (local mux)**. Most users with a local mux server have no `domain_pinned` entry for `'mux'` — they want auto-scan to apply. Behavior: scan_roots run as today (local fs is reachable), no `domain_pinned['mux']` so walk-up works normally, all rows show. ✓
- **`default_domain = 'mux'` plus `domain_pinned = { mux = { ... } }`**. User explicitly opts the local mux into the per-domain list. Behavior: walk-up skipped on mux panes, default-mode editor rows hidden, project picker uses the pinned list. Less useful for a local mux but supported.
- **Stale CWD on a remote shell that doesn't emit OSC 7**. Already fixed in `722b7a1` — procinfo wins. Remote panes get a live CWD.
- **Multiple GUIs attached to the same mux**. Each GUI's local Lua independently computes `domain_pinned` based on its own `~/.wezterm.lua`. They can disagree on what's "remote". Not a bug; just a property of the architecture.
- **`pane:domain_name()` raising**. We pcall and default to `'local'`. Consistent with current code's defensive style for pane-method calls.
- **A `domain_pinned` path that doesn't exist on the remote**. Listed in the picker, selected, spawn fails. The user will notice. Not worth pre-validating (we can't check the remote fs).

## Verification plan

Manual smoke test, end-to-end. No new automated tests (consistent with the project's "manual verification only" stance from `docs/plan.md`).

1. **Local-only baseline (no `domain_pinned`)**. Open project picker, verify nothing changes from current behaviour. Open action picker in a local pane, verify all rows still appear.
2. **Add a unix_domain mux** (`config.unix_domains = { { name = 'mux' } }`, `config.default_domain = 'mux'`). With no `domain_pinned['mux']`: project picker still works (auto-scan reaches the same fs), action picker rows all appear, walk-up succeeds. ✓ behaviour unchanged.
3. **Add a fake remote domain** to `domain_pinned`:
   ```lua
   domain_pinned = { mux = { '/home/mpd/projects/foo' } }
   ```
   In a `mux`-domain pane, open the project picker — `[mux] foo` appears. Open action picker in a `mux` pane sitting at `/home/mpd/projects/foo/src` — root resolves to `/home/mpd/projects/foo` (deepest pinned root containing CWD), `Open TODO.md` is hidden, `Open TODO.md inline` is shown. Picking inline opens nvim on the mux server (i.e. the same machine, same fs — but via the inline path).
4. **Real remote domain**. Add an `ssh_domains` entry (`myhost`, `multiplexing = 'WezTerm'`); add `domain_pinned['myhost']`. Attach. Repeat #3 in the remote pane. Verify:
   - Project picker shows local entries plus `[myhost] <project>` rows; sort places `[myhost]` rows above local when the active pane is `myhost`.
   - Selecting a `myhost` project from a local pane spawns a new tab on `myhost`.
   - `Open TODO.md inline` opens the file on the remote.
   - `Open TODO.md` (default) is hidden.
5. **Cross-domain switching**. From a local pane, open the project picker, pick a `myhost` project — verify a new tab is created in the `myhost` domain (not the local one). From inside that tab, open the project picker, pick a local project — verify a new local tab is created.
6. **Existing-tab focus**. Select the same `myhost` project twice; second time the existing tab should be focused, not duplicated. Select the local-fs version of a project that happens to share a path string with a `myhost` project; verify the local one focuses, not the `myhost` one (domain filter on `find_existing_pane_in_window`).

## Open questions

1. **Display format for domain-tagged entries**. `[myhost] foo` vs. `foo (myhost)` vs. distinct color/dim. Picker readability vs. fuzzy-match noise. Pick one in the implementation pass.
2. **Should `domain_pinned` paths participate in `find_root` walk-up across pinned roots**? Currently the design says "deepest pinned root containing cwd, else cwd". An alternative: walk up until either a pinned root or the filesystem root, treating pinned as virtual markers. The first option is simpler; the second handles "cd into a subproject of a pinned root" without surprises. Defer to implementation; likely the deepest-pinned-root rule is sufficient.
3. **Should `Open project in editor` (default mode) also be hidden on remote**? Probably yes — same justification as `Open <file>` (default). The plan above includes this; flagged here to confirm during implementation.
4. **Per-domain `default_cmd`**? Probably not in v1. Users who want a different shell on the remote can set it via the SSH domain's spawn config or per-project `default_cmd` in a remote `.termtools.lua`.
5. **Per-domain `trusted_paths`**? Yes if we want `.termtools.lua` overrides to load from a remote project. But trusted_paths checks `io.open` against the local fs — same issue as the rest. Defer to a follow-up; .termtools.lua on remote is its own can.

## Effort estimate

A focused day. The design has no novel primitives — it's plumbing the existing pane-domain accessor through the existing opts/predicate machinery. The riskiest bit is the `Open <file>` predicate route (Option B above); if the closure-late-bind feels too magical during implementation, fall back to Option A (predicate signature change) and update three call sites.
