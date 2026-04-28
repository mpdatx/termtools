-- termtools — context-sensitive hotkeys for terminal tabs.
--
-- Public API:
--   termtools.setup(opts)         configure once, before .apply()
--   termtools.apply(config)       returns the mutated wezterm config
--   termtools.project_picker()    bind to a key yourself
--   termtools.action_picker()     bind to a key yourself
--   termtools.opts()              read back the merged opts (mainly for tests)
--
-- Typical use in ~/.wezterm.lua (see also examples/minimal.wezterm.lua,
-- which uses include.lua to skip the package.path / require dance):
--   local wezterm = require('wezterm')
--   package.path = wezterm.home_dir .. '/projects/termtools/lua/?.lua;' .. package.path
--   local termtools = require('init')
--   termtools.setup({ scan_roots = { wezterm.home_dir .. '/projects' }, default_keys = true })
--   return termtools.apply(wezterm.config_builder())

local pickers = require('pickers')

local M = {}

-- DEFAULTS — grouped by concern for readability. Internal code keeps
-- reading flat keys (opts.scan_roots, opts.project_key, ...); we flatten
-- once at module load. user_opts passed to setup() may be either flat
-- (legacy form, still supported) or nested (matching the structure
-- below). The flatten() helper accepts both.
local DEFAULTS_NESTED = {
  paths = {
    scan_roots    = {},
    pinned        = {},
    trusted_paths = {},
    markers       = nil, -- nil = use projects.lua's defaults
  },
  hotkeys = {
    default_keys       = false,
    project_key        = { key = 'p', mods = 'CTRL' },        -- CTRL|SHIFT P is wezterm's command palette
    action_key         = { key = 'A', mods = 'CTRL|SHIFT' },  -- uppercase: SHIFT-held keypress is 'A', not 'a'
    claude_next_key    = { key = 'J', mods = 'CTRL|SHIFT' },  -- only used when claude_indicators = true
    -- Highlighted-path → editor. Default trigger is the Ctrl+Shift+Click
    -- mouse binding from style.lua (`open_selection_on_click`). Set to
    -- e.g. `{ key = 'O', mods = 'CTRL|SHIFT' }` if you also want a hotkey.
    open_selection_key = false,
  },
  -- Spawn commands. Not editors per se — `editor_cmd` is the legacy
  -- single-template form that's now resolved through the `editors` opt
  -- (see setup()), so this grouping only holds the shell + claude argv.
  commands = {
    default_cmd = nil, -- resolved per-platform at setup time
    claude_cmd  = { 'claude' },
  },
  features = {
    wt_profiles       = false, -- read Windows Terminal settings.json for shells
    apply_style       = false, -- apply opinionated wezterm appearance/behaviour defaults
    claude_indicators = false, -- multi-session Claude awareness
  },
  project_picker = {
    project_sort = 'smart', -- 'smart' | 'alphabetical' | 'mru'; runtime cycle persists in wezterm.GLOBAL
  },
  -- Pass-through tables forwarded to module setup()s. Kept at the top
  -- level (not flattened) so the inner key set is owned by the module.
  style  = {},  -- per-key overrides; see lua/style.lua
  claude = {},  -- forwarded to claude.setup()
}

-- Names of the grouping sections. Used by flatten() to spread group
-- contents into the top level. Anything not in this set stays as-is —
-- including the pass-through tables (style, claude) and any flat-form
-- keys a user passes for backward compat.
local DEFAULT_SECTIONS = {
  paths = true, hotkeys = true, commands = true,
  features = true, project_picker = true,
}

-- Spread one level of named sections into a flat table. Tolerates either
-- form — flat user_opts keys pass through untouched, nested ones get
-- flattened. Pass-through tables (style, claude) stay at the top level.
local function flatten(t)
  local flat = {}
  for k, v in pairs(t or {}) do
    if DEFAULT_SECTIONS[k] and type(v) == 'table' then
      for sub_k, sub_v in pairs(v) do flat[sub_k] = sub_v end
    else
      flat[k] = v
    end
  end
  return flat
end

local DEFAULTS = flatten(DEFAULTS_NESTED)

local function default_shell()
  return require('platform').default_shell()
end

local CANDIDATE_PROJECT_DIRS = {
  -- The common conventions across Windows / macOS / Linux. Listed in
  -- approximate frequency-of-use; case variants (~/projects vs ~/Projects)
  -- both probed because case-insensitive Windows/macOS will return one,
  -- case-sensitive Linux will return whichever the user actually uses.
  '~/projects', '~/Projects',
  '~/code',     '~/Code',
  '~/src',
  '~/dev',
  '~/repos',
  '~/work',
}

-- Returns the subset of well-known project-parent directories that exist on
-- this machine, normalised. Use as `scan_roots = termtools.default_scan_roots()`
-- (optionally extended with your own paths) to get a sensible starting set
-- without per-OS branching in your config.
function M.default_scan_roots()
  local util     = require('util')
  local platform = require('platform')
  local home = platform.home_dir()
  if not home then return {} end

  local result, seen = {}, {}
  for _, candidate in ipairs(CANDIDATE_PROJECT_DIRS) do
    local expanded = util.normalize((candidate:gsub('^~', home)))
    local key = platform.fs_case_insensitive and expanded:lower() or expanded
    if not seen[key] and util.dir_exists(expanded) then
      seen[key] = true
      result[#result + 1] = expanded
    end
  end
  return result
end

local opts = nil

function M.setup(user_opts)
  user_opts = user_opts or {}
  -- Flatten first so callers can pass either flat keys (legacy form) or
  -- nested sections matching DEFAULTS_NESTED — both end up flat for the
  -- internal merge.
  local flat_user = flatten(user_opts)
  local merged = require('util').merge_defaults(DEFAULTS, flat_user)
  if merged.wt_profiles then
    local ok, wt = pcall(require, 'wt')
    if ok then
      merged._wt = wt.read_profiles()
      if merged._wt and merged._wt.default and not flat_user.default_cmd then
        merged.default_cmd = merged._wt.default.args
      end
    end
  end
  if not merged.default_cmd then
    merged.default_cmd = default_shell()
  end
  -- GUI-launched WezTerm on macOS inherits a stripped PATH, so a bare
  -- `claude` won't resolve via execvp. Ask the login+interactive shell where
  -- it lives once and cache the absolute path. No-op on Windows.
  merged.claude_cmd = require('platform').resolve_argv(merged.claude_cmd)

  -- Resolve `editors` opt:
  --   1. start with platform.default_editors() as baseline
  --   2. shallow-merge user_opts.editors on top (per-name inside registry)
  --   3. if user only set legacy editor_cmd (no editors), synthesize a
  --      single-entry registry from it and use that as the default role
  do
    local platform = require('platform')
    local base = platform.default_editors and platform.default_editors() or
      { registry = {}, default = nil, inline = nil }
    local user_editors = flat_user.editors

    if type(user_editors) == 'table' then
      local registry = {}
      for k, v in pairs(base.registry or {}) do registry[k] = v end
      for k, v in pairs(user_editors.registry or {}) do registry[k] = v end
      merged.editors = {
        registry = registry,
        default  = user_editors.default ~= nil and user_editors.default or base.default,
        inline   = user_editors.inline  ~= nil and user_editors.inline  or base.inline,
      }
    elseif flat_user.editor_cmd then
      -- Legacy: synthesize a registry entry from editor_cmd.
      local synth_name = '_legacy_default'
      local registry = {}
      for k, v in pairs(base.registry or {}) do registry[k] = v end
      registry[synth_name] = { cmd = flat_user.editor_cmd, kind = 'external' }
      merged.editors = {
        registry = registry,
        default  = synth_name,
        inline   = base.inline,
      }
    else
      merged.editors = base
    end

    -- Mirror the resolved default-editor cmd back onto editor_cmd for any
    -- legacy reader that still expects it (palette, action descriptions
    -- that fall through to util.resolve_editor_cmd).
    local default_spec = merged.editors.registry[merged.editors.default]
    merged.editor_cmd = default_spec and default_spec.cmd or flat_user.editor_cmd
  end

  if merged.claude_indicators then
    local ok, claude = pcall(require, 'claude')
    if ok then
      claude.setup(merged.claude or {})
      merged._claude = claude
    end
  end
  opts = merged
  return M
end

function M.opts()
  if not opts then M.setup({}) end
  return opts
end

function M.project_picker()
  return pickers.project_picker(M.opts())
end

function M.action_picker()
  return pickers.action_picker(M.opts())
end

-- Look up the Claude state-glyph for a pane (working / waiting / stuck), or
-- nil if the pane isn't a Claude session or claude_indicators is off.
-- Designed to be called from a user-supplied format-tab-title handler.
function M.claude_glyph_for_pane(pane_id)
  local o = M.opts()
  if o._claude then return o._claude.glyph_for_pane(pane_id) end
  return nil
end

local handlers_registered = false

function M.apply(config)
  local o = M.opts()

  -- Apply opinionated style defaults BEFORE keys are wired so any styling
  -- that touches config.keys / config.mouse_bindings doesn't clobber later
  -- additions (and vice versa: termtools' own keys append to whatever
  -- style touches).
  if o.apply_style then
    local ok, style = pcall(require, 'style')
    if ok then style.apply(config, o.style or {}) end
  end

  if o.default_keys then
    config.keys = config.keys or {}
    table.insert(config.keys, {
      key = o.project_key.key, mods = o.project_key.mods,
      action = M.project_picker(),
    })
    table.insert(config.keys, {
      key = o.action_key.key, mods = o.action_key.mods,
      action = M.action_picker(),
    })
    -- Defensive twin: when SHIFT is in mods and key is uppercase, also
    -- register the lowercase variant. WezTerm's key-matching has historically
    -- accepted both; we don't gamble.
    if string.find(o.action_key.mods or '', 'SHIFT')
        and o.action_key.key:match('^%u$') then
      table.insert(config.keys, {
        key = o.action_key.key:lower(), mods = o.action_key.mods,
        action = M.action_picker(),
      })
    end
    if o._claude and o.claude_next_key then
      table.insert(config.keys, {
        key = o.claude_next_key.key, mods = o.claude_next_key.mods,
        action = o._claude.session_picker_action(),
      })
    end
    if o.open_selection_key then
      table.insert(config.keys, {
        key = o.open_selection_key.key, mods = o.open_selection_key.mods,
        action = pickers.open_selection_action(),
      })
      -- Same defensive lowercase twin as for action_key, since SHIFT-held
      -- keypresses arrive as the uppercase letter.
      if string.find(o.open_selection_key.mods or '', 'SHIFT')
          and o.open_selection_key.key:match('^%u$') then
        table.insert(config.keys, {
          key = o.open_selection_key.key:lower(),
          mods = o.open_selection_key.mods,
          action = pickers.open_selection_action(),
        })
      end
    end
  end

  if o._claude then o._claude.attach(config) end

  -- Register wezterm event handlers once. The handlers re-read M.opts() at
  -- dispatch time so opts can change between setup() calls without restart.
  if not handlers_registered then
    local wezterm = require('wezterm')

    wezterm.on('termtools.project-picker', function(window, pane)
      pickers.run_project_picker(window, pane, M.opts())
    end)

    wezterm.on('termtools.action-picker', function(window, pane)
      pickers.run_action_picker(window, pane, M.opts())
    end)

    wezterm.on('termtools.run-action', function(window, pane, root, label)
      pickers.run_action_by_label(window, pane, root, label, M.opts())
    end)

    wezterm.on('termtools.open-selection', function(window, pane)
      pickers.run_open_selection(window, pane, M.opts())
    end)

    wezterm.on('augment-command-palette', function(window, pane)
      return require('palette').entries(window, pane, M.opts())
    end)

    handlers_registered = true
  end

  return config
end

return M
