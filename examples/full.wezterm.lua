-- Full example ~/.wezterm.lua using termtools, showing every option.
--
-- This example doesn't use include.lua because it binds the pickers to
-- custom keys (default_keys = false) and so needs direct access to the
-- termtools module. If you don't need that level of control, see
-- examples/minimal.wezterm.lua for the include.lua-based one-liner.

local wezterm = require('wezterm')

-- Make termtools' Lua modules importable. Adjust the path to wherever
-- you cloned the repo. Forward slashes work on every platform Lua runs on
-- (Windows included). On Windows with a clone at G:/claude/termtools,
-- this would be 'G:/claude/termtools/lua'.
package.path = wezterm.home_dir .. '/projects/termtools/lua/?.lua;' .. package.path
local termtools = require('init')

termtools.setup({
  -- Directories to auto-scan. Each immediate subdir containing a marker file
  -- becomes a known project.
  scan_roots = {
    wezterm.home_dir .. '/projects',
  },

  -- Explicit project paths to add to the picker, regardless of scan_roots.
  -- Useful for one-offs outside your scan dirs.
  pinned = {
  },

  -- Roots under which `.termtools.lua` override files may be loaded.
  -- Anything outside is ignored, even if a `.termtools.lua` exists.
  trusted_paths = {
    wezterm.home_dir .. '/projects',
  },

  -- Editor command for "Open TODO.md" / "Open README.md". `%s` is the file
  -- path; the command is launched as a detached background process.
  editor_cmd = { 'code', '%s' },

  -- Shell used when the project picker spawns a fresh tab (and by the
  -- "New shell pane" / "New tab at project root" actions). Can be overridden
  -- per-project in `.termtools.lua` via `default_cmd`. Leave unset to let
  -- termtools pick a sensible default per-OS ($SHELL on Unix, powershell
  -- on Windows).
  -- default_cmd = { 'pwsh' },

  -- Command for "New Claude pane".
  claude_cmd = { 'claude' },

  -- Override the project-marker list (default: .git, .termtools.lua,
  -- package.json, pyproject.toml, Cargo.toml).
  -- markers = { '.git', '.hg', 'go.mod' },

  -- Read Windows Terminal's settings.json: use its default profile as
  -- default_cmd (when default_cmd is not set) and add a "New tab: <profile>"
  -- action per non-hidden WT profile. No-ops on macOS/Linux.
  wt_profiles = true,

  -- Auto-bind hotkeys. If false, bind them yourself in config.keys below.
  default_keys = false,

  -- Used only when default_keys = true.
  -- Default project_key avoids CTRL|SHIFT|P, which is wezterm's command palette.
  project_key = { key = 'p', mods = 'CTRL' },
  action_key  = { key = 'a', mods = 'CTRL|SHIFT' },
})

local config = wezterm.config_builder()

-- Manually bind the pickers to keys of your choice.
config.keys = {
  { key = 'p', mods = 'LEADER',     action = termtools.project_picker() },
  { key = 'a', mods = 'LEADER',     action = termtools.action_picker()  },
  { key = 'P', mods = 'CTRL|SHIFT', action = termtools.project_picker() },
  { key = 'A', mods = 'CTRL|SHIFT', action = termtools.action_picker()  },
}

-- e.g. set Ctrl+A as the leader key for tmux-style sequences.
-- config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1500 }

return termtools.apply(config)
