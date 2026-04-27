-- Minimal ~/.wezterm.lua using termtools.
-- Copy this file to:
--   Windows: %USERPROFILE%\.wezterm.lua
--   *nix:    ~/.wezterm.lua
--
-- Then adjust the install path below for your machine.

local wezterm = require('wezterm')
local config  = wezterm.config_builder()

-- Your other config goes here, e.g.:
-- config.color_scheme = 'Tokyo Night'
-- config.font = wezterm.font('JetBrains Mono')

-- Path to your termtools clone — NOT to your projects. It's the install
-- location of this tool. Define it once; we hand it to include.lua twice
-- (as the dofile() path and as the 3rd argument so the include knows where
-- its own lua/ directory lives — WezTerm's Lua sandbox doesn't expose
-- `debug` so the script can't introspect its own location).
--
-- Examples:
--   macOS / Linux:  wezterm.home_dir .. '/src/termtools'
--                   wezterm.home_dir .. '/.local/share/termtools'
--   Windows:        'G:/claude/termtools'
--                   'C:/Users/me/src/termtools'
-- Forward slashes work on every platform (Windows included).
local TERMTOOLS = wezterm.home_dir .. '/src/termtools'

return dofile(TERMTOOLS .. '/include.lua')(config, {
  -- Each of these dirs is scanned for immediate subdirs that contain a
  -- project marker (.git/, .termtools.lua, package.json, pyproject.toml,
  -- Cargo.toml). Found projects appear in the project picker. Adjust to
  -- whatever parents you actually keep your projects under.
  scan_roots    = { wezterm.home_dir .. '/code', wezterm.home_dir .. '/work' },

  -- Roots where termtools is allowed to load `.termtools.lua` override
  -- files. Anything outside is silently ignored. Usually mirrors scan_roots.
  trusted_paths = { wezterm.home_dir .. '/code', wezterm.home_dir .. '/work' },

  -- Bind Ctrl+P (project picker) and Ctrl+Shift+A (action picker)
  -- automatically. Ctrl+Shift+P is left alone for WezTerm's command palette.
  -- Set to false to bind your own keys (see full.wezterm.lua).
  default_keys  = true,
}, TERMTOOLS)
