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
--   -- enable termtools. The path appears twice — once as the dofile()
--   -- argument and once as the third argument so the include script knows
--   -- where to find lua/. Define it once locally to keep them in sync.
--   local TERMTOOLS = wezterm.home_dir .. '/projects/termtools'
--   return dofile(TERMTOOLS .. '/include.lua')(config, {
--     scan_roots    = { wezterm.home_dir .. '/projects' },
--     trusted_paths = { wezterm.home_dir .. '/projects' },
--     default_keys  = true,
--   }, TERMTOOLS)
--
-- The opts table accepts every key documented in setup({}). See README.md.
--
-- Why the explicit install_dir?
--   WezTerm runs user config under mlua's sandbox, which removes the `debug`
--   library — so the include script can't introspect its own path via
--   debug.getinfo. The 3rd argument is how we learn where lua/ lives.

return function(config, opts, install_dir)
  if type(install_dir) ~= 'string' or install_dir == '' then
    error('termtools: include.lua needs the install directory as its 3rd '
      .. 'argument. Define a local once and pass it in both places:\n'
      .. '  local TERMTOOLS = "/path/to/termtools"\n'
      .. '  dofile(TERMTOOLS .. "/include.lua")(config, opts, TERMTOOLS)')
  end
  package.path = install_dir .. '/lua/?.lua;' .. package.path
  -- Clear cached termtools modules so a wezterm config reload picks up
  -- edits to the lua/ files. Without this, require() returns the version
  -- Lua interned at first load and edits silently no-op.
  for _, name in ipairs({
    'init', 'pickers', 'projects', 'actions', 'util', 'wt', 'claude', 'style',
    'open_selection',
    'pickers.project', 'pickers.action',
    'platform', 'platform.windows', 'platform.darwin',
  }) do
    package.loaded[name] = nil
  end
  local termtools = require('init')
  termtools.setup(opts or {})
  return termtools.apply(config)
end
