-- termtools.palette — entries that augment WezTerm's built-in command
-- palette (Ctrl+Shift+P). Called once per palette-open by the
-- `augment-command-palette` handler init.lua wires up.
--
-- Entries are computed at palette-open time, so `pane` is always the
-- currently active pane — we use it to resolve the project root for the
-- per-action rows. Picker shortcut rows (project / action picker) are
-- always present; per-action rows depend on the active pane having a
-- discoverable project root.

local wezterm  = require('wezterm')
local util     = require('util')
local projects = require('projects')
local pickers  = require('pickers')

local M = {}

function M.entries(_window, pane, opts)
  opts = opts or {}

  local entries = {
    {
      brief = 'termtools: Project picker',
      icon  = 'cod_folder_opened',
      action = pickers.project_picker(),
    },
    {
      brief = 'termtools: Action picker (current project)',
      icon  = 'cod_play',
      action = pickers.action_picker(),
    },
  }

  local cwd = util.pane_cwd(pane)
  local root = projects.find_root(cwd) or cwd
  if not root then return entries end

  local override = projects.load_overrides(root, opts.trusted_paths)
  local proj_name = (override and override.name) or util.basename(root)

  for _, action in ipairs(pickers.list_actions(root, opts)) do
    entries[#entries + 1] = {
      brief = string.format('termtools [%s]: %s', proj_name, action.label),
      icon  = 'cod_terminal',
      -- Indirect via wezterm event so the action runs after the palette
      -- has fully closed. Direct action_callback dispatch from the
      -- palette can race with the palette teardown and silently no-op.
      action = wezterm.action.EmitEvent('termtools.run-action', root, action.label),
    }
  end

  return entries
end

return M
