-- termtools.pickers.action — the action picker.
--
-- Owns action-list assembly (built-ins + per-project overrides), the
-- enabled / dimmed / disabled three-way classification, the InputSelector
-- modal, and the dispatcher used by the command palette's per-action
-- entries.
--
-- Public surface:
--   M.run(window, pane, opts)                          -- modal picker body
--   M.run_by_label(window, pane, root, label, opts)    -- palette dispatch
--   M.list(root, opts)                                 -- merged actions for palette

local wezterm  = require('wezterm')
local util     = require('util')
local projects = require('projects')
local actions  = require('actions')

local M = {}

local function build_action_list(root, opts)
  local builtin = actions.catalogue(opts)
  local override = projects.load_overrides(root, opts.trusted_paths)

  -- Merge built-ins with overrides; overrides win by label.
  local merge_order, resolved = {}, {}
  for _, a in ipairs(builtin) do
    resolved[a.label] = a
    merge_order[#merge_order + 1] = a.label
  end
  if override and type(override.actions) == 'table' then
    for _, a in ipairs(override.actions) do
      if type(a) == 'table' and type(a.label) == 'string' and type(a.run) == 'function' then
        if not resolved[a.label] then
          merge_order[#merge_order + 1] = a.label
        end
        resolved[a.label] = a
      end
    end
  end

  -- Three-way classification (override's predicates replace the built-in's):
  --   visible_when=false  -> disabled: dim, sorted last, selecting toasts
  --   dimmed_when=true    -> dimmed: dim, sorted after enabled, selecting runs
  --   otherwise           -> enabled: normal display, runs
  local enabled, dimmed_list, disabled_list = {}, {}, {}
  local dimmed, disabled = {}, {}
  for _, label in ipairs(merge_order) do
    local a = resolved[label]
    if a.visible_when and not a.visible_when(root) then
      disabled[label] = true
      disabled_list[#disabled_list + 1] = label
    elseif a.dimmed_when and a.dimmed_when(root) then
      dimmed[label] = true
      dimmed_list[#dimmed_list + 1] = label
    else
      enabled[#enabled + 1] = label
    end
  end

  local order = {}
  for _, l in ipairs(enabled) do order[#order + 1] = l end
  for _, l in ipairs(dimmed_list) do order[#order + 1] = l end
  for _, l in ipairs(disabled_list) do order[#order + 1] = l end

  return order, resolved, override, dimmed, disabled
end

-- Flat array of `{ label, run }` entries (built-ins + per-project overrides).
-- Used by the command-palette augmentation. Includes enabled and dimmed
-- entries (both runnable); skips disabled ones since wezterm's palette has
-- no good way to mark a row as inert.
function M.list(root, opts)
  local order, by_label, _, _dimmed, disabled = build_action_list(root, opts)
  local out = {}
  for _, label in ipairs(order) do
    if not disabled[label] then
      out[#out + 1] = by_label[label]
    end
  end
  return out
end

function M.run(window, pane, opts)
  opts = opts or {}
  local cwd = util.pane_cwd(pane)
  local root = projects.find_root(cwd) or cwd
  if not root then
    window:toast_notification('termtools',
      'Could not determine current directory; action picker unavailable.',
      nil, 3000)
    return
  end

  local order, by_label, override, dimmed, disabled = build_action_list(root, opts)
  local proj_name = (override and override.name) or util.basename(root)

  -- Two-column display: pad each label to the longest, then append the
  -- action's description (when supplied). Fuzzy match runs over the whole
  -- visible string, so users can match against either the label or the
  -- description text. Both dimmed (advisory) and disabled (inert) entries
  -- are sorted below the enabled ones and rendered dim/grey.
  local max_w = 0
  for _, label in ipairs(order) do
    if #label > max_w then max_w = #label end
  end

  local choices = {}
  for i, label in ipairs(order) do
    local action = by_label[label]
    local desc
    if type(action.description) == 'function' then
      local ok, result = pcall(action.description, root)
      if ok then desc = result end
    elseif type(action.description) == 'string' then
      desc = action.description
    end

    local plain = (desc and desc ~= '')
      and string.format('%-' .. max_w .. 's   %s', label, desc)
      or label

    local display
    if dimmed[label] or disabled[label] then
      -- Italic + an explicit hex grey so the row stays legible on dark
      -- schemes. Half-intensity stacked on Solarized's Grey (~#586e75) drops
      -- it to ~#2c3a3e, which is invisible against base03 (#002b36).
      display = wezterm.format {
        { Attribute = { Italic = true } },
        { Foreground = { Color = '#93a1a1' } },
        { Text = plain },
        'ResetAttributes',
      }
    else
      display = plain
    end
    choices[i] = { id = tostring(i), label = display }
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = 'Action: ' .. proj_name,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(w, p, id, _label)
        if not id then return end
        local idx = tonumber(id)
        if not idx or not order[idx] then return end
        local picked = order[idx]
        if disabled[picked] then
          w:toast_notification('termtools',
            picked .. ' is unavailable for this project.', nil, 1500)
          return
        end
        local entry = by_label[picked]
        if not entry or not entry.run then return end
        local target_pane = w:active_pane() or p
        local ok, err = pcall(entry.run, w, target_pane, root)
        if not ok then
          wezterm.log_error('termtools: action "' .. picked
            .. '" failed: ' .. tostring(err))
        end
      end),
    },
    pane
  )
end

-- Run a single action, identified by label, against a known root. Used by
-- the per-action palette entries: the entry emits an event carrying root
-- and label, and the handler resolves the action and runs it.
function M.run_by_label(window, pane, root, label, opts)
  opts = opts or {}
  if not root or not label then return end
  for _, action in ipairs(M.list(root, opts)) do
    if action.label == label then
      local ok, err = pcall(action.run, window, pane, root)
      if not ok then
        wezterm.log_error('termtools: palette action "' .. label
          .. '" failed: ' .. tostring(err))
      end
      return
    end
  end
end

return M
