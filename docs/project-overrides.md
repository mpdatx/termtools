# `.termtools.lua` reference

A `.termtools.lua` file at the root of a project lets you customise that project's behaviour in termtools. It's a normal Lua chunk that returns a table.

termtools loads it **only** if the project root is inside one of the `trusted_paths` you passed to `setup({})`. Files outside trusted paths are silently ignored. There is no sandbox: inside a trusted path, the chunk can do anything WezTerm Lua can do.

## Table shape

```lua
return {
  -- Optional. Display name in the action picker title and (where applicable)
  -- the project picker. Defaults to the directory's basename.
  name = 'My Project',

  -- Optional. Command used by the project picker when it spawns a fresh tab
  -- for this project. Falls back to `default_cmd` from setup({}).
  default_cmd = { 'pwsh', '-NoLogo' },

  -- Optional. Extra actions, plus overrides of built-ins by label.
  actions = {
    {
      label = 'Run unit tests',
      run = function(window, pane, root)
        -- ...
      end,
    },
    {
      -- Replaces the built-in action with the same label.
      label = 'Open TODO.md',
      run = function(window, pane, root) ... end,
    },
  },
}
```

## The action `run` signature

```lua
run = function(window, pane, root) end
```

- `window` — the WezTerm GUI window object the picker was opened from. Use `window:perform_action(act, pane)` to dispatch standard WezTerm actions; `window:toast_notification(...)` for transient messages.
- `pane` — the pane that was active when the action picker opened. Use `pane:send_text(...)` to type into it.
- `root` — the project root path (already normalised to forward slashes, drive letter uppercased on Windows).

## Optional `description`

```lua
description = 'short text shown alongside the label'
-- or
description = function(root) -> string end
```

Renders as a second column in the action picker. Useful for showing the actual command being run, the file path, or any other clarifying detail. Fuzzy filter matches both label and description, so `description` is also a good place to put alternate keywords. Omitted = no second column for that entry.

## Availability: `visible_when` and `dimmed_when`

Two predicates control how an action appears in the picker:

```lua
visible_when = function(root) -> boolean end   -- false  -> fully disabled
dimmed_when  = function(root) -> boolean end   -- true   -> advisory / dim
```

Three states result:

| State    | Sort order      | Style       | Selecting it      | Use for |
| -------- | --------------- | ----------- | ----------------- | ------- |
| enabled  | top             | normal      | runs `run`        | the default |
| dimmed   | after enabled   | dim / grey  | runs `run`        | "advisory" — e.g. file doesn't exist yet but the editor will create it on save |
| disabled | bottom          | dim / grey  | toasts "unavailable" | action genuinely can't run right now |

`visible_when` returning false wins over `dimmed_when`. Actions without either predicate are always enabled.

The wezterm command palette only surfaces enabled and dimmed entries — it has no idiomatic way to render an inert row, so disabled ones are hidden there.

### Predicates and remote panes

If the active pane lives in a domain whose filesystem the GUI can't reach locally (ssh_domains, tls_clients to a different host, etc.), `io.open` / `wezterm.read_dir` / `util.file_exists` all probe the GUI's local fs and give the wrong answer for that pane's files. A `dimmed_when` like `not util.file_exists(util.path_join(root, 'TODO.md'))` would dim every row even when the file genuinely exists on the remote.

termtools tracks which domains are "filesystem-local". The set is:

- The built-in `'local'` domain.
- Every entry in `config.unix_domains` (unix sockets only work on the same machine, so they're always local).
- Every name in `setup({ local_domains = { ... } })` — for unusual cases like a TLS client connecting to a mux on the same host where the domain isn't a unix_domain but the filesystem is still reachable.

Use `util.is_local_domain(domain)` together with `util.active_pane_domain()` to gate filesystem-probing predicates:

```lua
local util = require('util')

dimmed_when = function(root)
  if not util.is_local_domain(util.active_pane_domain()) then
    return false   -- can't reach the remote fs, fail open
  end
  return not util.file_exists(util.path_join(root, 'logs/server.log'))
end,
```

Returning `false` (don't dim) is the right "fail open" for non-local-fs panes — the action will fire and either succeed or be a no-op, but it won't be misleadingly dimmed.

The built-in `actions.open_file` factory already handles this — its `dimmed_when` and `description` skip the existence check on domains that aren't filesystem-local.

## Grouping: optional `group`

Within each enabled / dimmed / disabled bucket, actions are sorted by group. Set `group = '...'` on an action to place it deliberately; otherwise the picker infers from the label prefix.

```lua
{ label = 'Run unit tests', group = 'spawn', run = function(...) ... end }
```

Group order in the picker:

| Group          | Default content                                              |
| -------------- | ------------------------------------------------------------ |
| `open-project` | `Open project in editor`                                     |
| `open-file`    | `Open <file>` actions (TODO, README, `actions.open_file(...)` results) |
| `spawn`        | `New <something>` actions (panes, tabs, profile spawns)      |
| `editor`       | `Switch <role> editor` actions                               |
| `project`      | per-project overrides without a recognisable prefix (the default if no `group` is set and no prefix matches) |
| `admin`        | `Refresh projects`, `Cycle project sort`                     |

Inference rules (applied when `group` isn't set): `Open project ` → `open-project`, `Open ` → `open-file`, `New ` → `spawn`, `Switch ` → `editor`. Anything else falls into `project`.

### Helper: `actions.open_file(filename, role)`

The built-in `Open TODO.md` / `Open README.md` entries are produced by this factory. `role` is `'default'` (an external editor — VS Code etc.) or `'inline'` (a terminal editor in a wezterm pane — nvim etc.) and resolves through the `editors` opt at fire time, picking up runtime `Switch X editor` overrides. The factory dims when the file doesn't exist and updates its description to indicate creation. Reuse it from your override file:

```lua
local actions = require('actions')
return {
  actions = {
    -- Two action picker rows for the same file: the default external
    -- editor and the inline pane editor.
    actions.open_file('CHANGELOG.md', 'default'),
    actions.open_file('CHANGELOG.md', 'inline'),
    actions.open_file('docs/architecture.md', 'default'),
    actions.open_file('docs/architecture.md', 'inline'),
  },
}
```

`role` defaults to `'default'` if omitted, so legacy single-argument calls (`actions.open_file('CHANGELOG.md')`) still work.

## Common patterns

**Split right with a long-running command:**

```lua
{
  label = 'Tail server',
  run = function(window, pane, root)
    window:perform_action(
      wezterm.action.SplitPane {
        direction = 'Right',
        command = {
          args = { 'pwsh', '-NoExit', '-Command', 'Get-Content -Wait logs/server.log' },
          cwd = root,
        },
      }, pane)
  end,
}
```

**Open a file with the OS handler (Windows):**

```lua
{
  label = 'Open architecture.png',
  run = function(_window, _pane, root)
    os.execute(string.format('cmd /c start "" "%s\\docs\\architecture.png"',
      root:gsub('/', '\\')))
  end,
}
```

**Send commands to the active pane:**

```lua
{
  label = 'Reload dev server',
  run = function(_window, pane, _root)
    pane:send_text('rs\r')
  end,
}
```

## Caching and reloading

Override files are loaded once per project per WezTerm session and cached. To pick up edits, run the built-in **Refresh projects** action (or restart WezTerm).

## Override-by-label

Built-in actions are matched by exact `label` string. To replace a built-in with custom behaviour, give your override the same label. To add a new action, give it a unique label.
