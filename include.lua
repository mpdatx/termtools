-- One-liner integration for an existing ~/.wezterm.lua.
--
-- Usage:
--
--   local wezterm = require('wezterm')
--   local config = wezterm.config_builder()
--
--   -- your existing config:
--   config.color_scheme = 'Tokyo Night'
--   config.font = wezterm.font('JetBrains Mono')
--
--   -- enable termtools (returns the same config object, mutated):
--   return dofile(wezterm.home_dir .. '/projects/termtools/include.lua')(config, {
--     scan_roots    = { wezterm.home_dir .. '/projects' },
--     trusted_paths = { wezterm.home_dir .. '/projects' },
--     default_keys  = true,
--   })
--
-- The opts table accepts every key documented in setup({}). See README.md.
--
-- This file locates its own directory at runtime so you don't need to
-- hardcode the install path anywhere except in the dofile() call above.

local function script_dir()
  -- debug.getinfo(1).source is "@/abs/path/to/include.lua"; strip the '@'
  -- and trim the trailing filename to get the directory.
  local src = debug.getinfo(1, 'S').source
  local path = src:sub(1, 1) == '@' and src:sub(2) or src
  return (path:gsub('[/\\][^/\\]+$', ''))
end

return function(config, opts)
  local lua_dir = script_dir() .. '/lua'
  package.path = lua_dir .. '/?.lua;' .. package.path
  -- Clear cached termtools modules so a wezterm config reload picks up
  -- edits to the lua/ files. Without this, require() returns the version
  -- Lua interned at first load and edits silently no-op.
  for _, name in ipairs({ 'init', 'pickers', 'projects', 'actions', 'util', 'wt', 'claude' }) do
    package.loaded[name] = nil
  end
  local termtools = require('init')
  termtools.setup(opts or {})
  return termtools.apply(config)
end
