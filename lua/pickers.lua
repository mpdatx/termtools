-- termtools.pickers — facade over the picker submodules.
--
-- Keeps the public API stable (init.lua, claude.lua, actions.lua all
-- import from `pickers`) while the implementations live next door:
--   pickers/project.lua   — project picker, sort, MRU
--   pickers/action.lua    — action picker, list_actions, run-by-label
--   open_selection.lua    — Ctrl+Shift+Click / hotkey "open path in editor"
--                           (top-level, not a picker — no modal)
--
-- Every public surface that used to live in this file is re-exported below.
-- The EmitEvent shims at the bottom are unchanged: they emit the wezterm
-- events that init.apply() wires to the run_* bodies.

local wezterm        = require('wezterm')
local util           = require('util')
local project_picker = require('pickers.project')
local action_picker  = require('pickers.action')
local open_selection = require('open_selection')

local M = {}

-- CWD resolver re-export so external callers (init.palette_entries,
-- claude.project_label_for_pane) keep working without churn.
M.pane_cwd = util.pane_cwd

-- Picker bodies — called by init.lua's wezterm.on handlers.
M.run_project_picker = project_picker.run
M.run_action_picker  = action_picker.run
M.run_action_by_label = action_picker.run_by_label
M.run_open_selection = open_selection.run

-- Used by init.palette_entries to enumerate per-action palette rows.
M.list_actions = action_picker.list

-- Project picker sort-mode controls (used by the Cycle project sort action).
M.cycle_project_sort   = project_picker.cycle_sort
M.current_project_sort = project_picker.current_sort

-- EmitEvent shims: return wezterm KeyAssignment values bound to events that
-- init.apply() registers handlers for. Drop these straight into config.keys
-- or palette entries.
function M.project_picker(_opts)
  return wezterm.action.EmitEvent 'termtools.project-picker'
end

function M.action_picker(_opts)
  return wezterm.action.EmitEvent 'termtools.action-picker'
end

function M.open_selection_action()
  return wezterm.action.EmitEvent 'termtools.open-selection'
end

return M
