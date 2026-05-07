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
  local domain = util.pane_domain(pane)
  -- Mirrors pickers/action.lua M.run: walk up only when the pane's domain
  -- is one whose filesystem we can probe locally (unix_domains and the
  -- user-supplied `local_domains` list, plus the built-in 'local').
  local root
  if util.is_local_domain(domain) then
    root = projects.find_root(cwd) or cwd
  else
    root = cwd
  end
  if not root then return entries end

  -- Same domain-stash as pickers/action.lua M.run so action factories
  -- skip local-fs existence checks for non-local panes when this palette
  -- pass enumerates them.
  util.set_active_pane_domain(domain)

  local override = projects.load_overrides(root, opts.trusted_paths)
  local proj_name = (override and override.name) or util.basename(root)

  for _, action in ipairs(pickers.list_actions(root, opts)) do
    -- Per-entry capture for the closure below — `action` is the loop var.
    local entry_root, entry_label = root, action.label
    entries[#entries + 1] = {
      brief = string.format('termtools [%s]: %s', proj_name, action.label),
      icon  = 'cod_terminal',
      -- Two-step dispatch:
      --   1. action_callback fires when the user picks the entry; it just
      --      stashes (root, label) in wezterm.GLOBAL — no I/O, no modal,
      --      so no race surface against the palette teardown.
      --   2. perform_action queues an EmitEvent that wezterm fires after
      --      the palette has fully closed; the handler reads the stash
      --      and runs the action.
      -- We can't pass args directly through EmitEvent — its KeyAssignment
      -- form takes only the event name, so any extras get dropped on the
      -- floor (this was the original cause of run_by_label receiving
      -- label=nil, root=nil and silently no-op'ing).
      action = wezterm.action_callback(function(window, pane)
        wezterm.GLOBAL = wezterm.GLOBAL or {}
        wezterm.GLOBAL.termtools_pending_action = {
          root  = entry_root,
          label = entry_label,
        }
        window:perform_action(
          wezterm.action.EmitEvent('termtools.run-action'), pane)
      end),
    }
  end

  return entries
end

return M
