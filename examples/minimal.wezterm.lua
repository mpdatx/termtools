-- Minimal ~/.wezterm.lua using termtools.
-- Copy this file to:
--   Windows: %USERPROFILE%\.wezterm.lua
--   *nix:    ~/.wezterm.lua
--
-- Then adjust the paths below for your machine — see comments inline.

local wezterm = require('wezterm')
local config  = wezterm.config_builder()

-- Your other config goes here, e.g.:
-- config.color_scheme = 'Tokyo Night'
-- config.font = wezterm.font('JetBrains Mono')

-- Enable termtools. The dofile() path is the one path you must spell out:
-- it points at wherever you cloned this repo. `wezterm.home_dir` is the
-- portable way to express "my home directory" in WezTerm config (it's
-- $HOME on Unix, %USERPROFILE% on Windows). On Windows with a clone at
-- e.g. G:/claude/termtools, replace the dofile arg with that absolute path.
return dofile(wezterm.home_dir .. '/projects/termtools/include.lua')(config, {
  -- Each of these dirs is scanned for immediate subdirs that contain a
  -- project marker (.git/, .termtools.lua, package.json, pyproject.toml,
  -- Cargo.toml). Found projects appear in the project picker.
  scan_roots    = { wezterm.home_dir .. '/projects' },

  -- A trusted path is one where termtools is allowed to load .termtools.lua
  -- override files. Anything outside is silently ignored.
  trusted_paths = { wezterm.home_dir .. '/projects' },

  -- Bind Ctrl+P (project picker) and Ctrl+Shift+A (action picker)
  -- automatically. Ctrl+Shift+P is left alone for WezTerm's command palette.
  -- Set to false to bind your own keys (see full.wezterm.lua).
  default_keys  = true,
})
