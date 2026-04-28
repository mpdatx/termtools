# 03 - Config object

The `~/.wezterm.lua` chunk runs once per WezTerm process (and again on every reload) and must `return` a config table. WezTerm reads keys off that table to drive everything from font choice to key bindings to multiplexer domains.

You don't have to use `wezterm.config_builder()` — a plain `{}` table works — but you almost always want to. The builder is a userdata that validates every key you set against the known schema and points at the offending line when you typo one. A bare table swallows typos silently.

## Key APIs

### `wezterm.config_builder() -> Config`

Returns a userdata that quacks like a table. Setting a known key stores it; setting an unknown key prints a warning with a Lua stack trace pointing at the assignment site. The "table" is what you `return` from the chunk.

```lua
local wezterm = require('wezterm')
local config  = wezterm.config_builder()
config.color_scheme = 'Batman'
return config
```

`config:set_strict_mode(true)` upgrades the warning to a hard Lua error — useful in CI / smoke tests, less useful day-to-day where you'd rather see the rest of the config load and the warning land in the log.

### Config evaluation: return the table

WezTerm `dofile`s your config and uses the chunk's return value. Anything you don't `return` is invisible. Forgetting `return` is the most common "my config does nothing" failure — silent because a chunk that returns `nil` is a valid empty config, not an error.

The chunk runs in WezTerm's Lua sandbox: full standard library, the `wezterm` module, no `debug` (so a script can't introspect its own location — see `examples/minimal.wezterm.lua:18-19` for the workaround termtools uses).

### Hot reload

WezTerm watches the file with the usual platform file-watcher and re-evaluates on save. You can also force a reload with the `ReloadConfiguration` key action, default `Ctrl+Shift+R`. CLI overrides (`--config foo=bar`) survive across reloads.

What's preserved on reload:

- All open windows / tabs / panes
- Mux state (workspaces, attached domains)
- `wezterm.GLOBAL` contents (this is the canonical place to stash state across reloads)
- Already-registered `wezterm.on` handlers (handlers don't get cleared — re-registering the same event name *adds another* handler, see gotchas)

What's lost / re-evaluated:

- Local variables in your config chunk
- Closures captured at the previous evaluation
- Any side-effecting calls in the chunk (they run again)

## Examples

### Minimal config

```lua
local wezterm = require('wezterm')
local config  = wezterm.config_builder()

config.color_scheme = 'Tokyo Night'
config.font = wezterm.font('JetBrains Mono')

return config
```

### Per-OS conditionals via `target_triple`

`wezterm.target_triple` is a string like `x86_64-pc-windows-msvc` or `aarch64-apple-darwin`. Match on it for OS-specific tweaks instead of branching on `package.config` or shelling out:

```lua
local config = wezterm.config_builder()

if wezterm.target_triple:find('windows') then
  config.default_prog = { 'pwsh', '-NoLogo' }
  config.win32_system_backdrop = 'Acrylic'
elseif wezterm.target_triple:find('darwin') then
  config.font_size = 14
  config.macos_window_background_blur = 30
else
  config.font_size = 11
end

return config
```

### Module that mutates config

The termtools pattern: a `setup(opts)` call stashes user options in module state, then `apply(config) -> config` mutates the passed-in config and returns it. The chunk hands the mutated config straight back to WezTerm.

From `lua/init.lua:233-320` — `apply` reads merged opts, optionally appends to `config.keys`, and registers events:

```lua
function M.apply(config)
  local o = M.opts()

  if o.apply_style then
    require('style').apply(config, o.style or {})
  end

  if o.default_keys then
    config.keys = config.keys or {}
    table.insert(config.keys, {
      key = o.project_key.key, mods = o.project_key.mods,
      action = M.project_picker(),
    })
    -- ...
  end

  if not handlers_registered then
    wezterm.on('termtools.project-picker', function(window, pane) ... end)
    -- ...
    handlers_registered = true
  end

  return config
end
```

Caller side (`examples/full.wezterm.lua:84-97`):

```lua
local config = wezterm.config_builder()
config.keys = { ... }                  -- user's own bindings first
return termtools.apply(config)         -- termtools appends and returns
```

The order matters: termtools appends to `config.keys`, so anything the user puts on `config.keys` before `apply()` survives. Setting `config.keys` *after* `apply()` clobbers what termtools added.

## Gotchas

- **No incremental updates.** The whole chunk re-runs on reload — there's no "just refresh this one key" path. Code defensively: assume every line will execute again. Don't open files, spawn processes, or write to disk at module scope without guarding it.

- **`wezterm.on` handlers re-register.** Calling `wezterm.on('foo', fn)` adds a handler; it doesn't replace the previous one. After three reloads your "foo" event fires three handlers. Guard with a registration flag — termtools uses a module-scope `handlers_registered` boolean (`lua/init.lua:231` and `:293-317`):

  ```lua
  local handlers_registered = false
  function M.apply(config)
    if not handlers_registered then
      wezterm.on('my-event', function(...) ... end)
      handlers_registered = true
    end
    return config
  end
  ```

  The flag survives reloads because module state persists in WezTerm's Lua VM (the `package.loaded` cache isn't cleared), but a fresh `dofile` of `~/.wezterm.lua` is a new chunk evaluation. Module-scope locals in the *config chunk itself* do reset; module-scope locals in `require`d modules don't.

- **Closures bake in state at config-eval time.** If you do `local v = some_value(); config.keys = { { ..., action = wezterm.action_callback(function() use(v) end) } }`, that closure captures `v` from the eval that registered it. After a reload, the action might still be the *old* closure if you re-registered via `wezterm.on` without un-registering — read state inside the callback (`M.opts()`-style) rather than capturing it.

- **`config_builder` catches typos noisily; bare tables don't.** `config.colour_scheme = 'Batman'` (British spelling) on a builder warns + stack-traces; on `{}` it silently sets a key WezTerm never reads. Always start with `wezterm.config_builder()`.

- **Some keys are not "live."** Most keys apply on reload, but font cache initialisation, GPU backend selection (`front_end`, `webgpu_*`), and a handful of window-creation-time options bake in at startup. If a config change appears not to take effect, restart WezTerm before assuming the key is wrong. Upstream docs don't enumerate the live/baked split — when in doubt, restart.

- **CLI overrides win.** `wezterm --config color_scheme=Dracula start` pins `color_scheme` for the life of that process; reloading the file won't change it. Useful for one-off launches; surprising when you forget you used it.

- **Chunk side effects run twice (or more).** The chunk evaluates at startup *and* on every reload. A `wezterm.run_child_process({ 'do-thing' })` at module scope runs every time. Wrap one-shot work in a `gui-startup` or `mux-startup` event handler instead — those fire once.

## See also

- [01-architecture.md](01-architecture.md) — config evaluation lifecycle, GUI vs mux process model
- [02-modules.md](02-modules.md) — what `wezterm.*` exposes inside the chunk
- [10-events.md](10-events.md) — `wezterm.on` mechanics, lifecycle events, the re-registration trap in detail
