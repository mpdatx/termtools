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

-- Group classification for the action picker. Entries appear in this order;
-- within a group, original insertion order is preserved.
local GROUP_ORDER = {
  'open-project', 'open-file', 'spawn', 'editor', 'project', 'admin',
}
local GROUP_INDEX = {}
for i, g in ipairs(GROUP_ORDER) do GROUP_INDEX[g] = i end

-- Label-prefix → group, applied when an action doesn't set `group`
-- explicitly. Order matters: 'Open project ' must be tested before 'Open '.
local PREFIX_GROUPS = {
  { 'Open project ', 'open-project' },
  { 'Open ',         'open-file'    },
  { 'New ',          'spawn'        },
  { 'Switch ',       'editor'       },
}

local function action_group(action)
  if action.group then return action.group end
  for _, pair in ipairs(PREFIX_GROUPS) do
    local prefix, group = pair[1], pair[2]
    if action.label:sub(1, #prefix) == prefix then return group end
  end
  return 'project'
end

-- ── Vimium-style 2-letter shortcuts ──────────────────────────────────────
-- Each visible action gets a stable 2-letter code shown as a prefix in the
-- picker (e.g. "qj  Open TODO.md"). Typing the code in the fuzzy filter
-- narrows the picker to that one action; press Enter to fire it.
--
-- The pool is restricted to digraphs that don't naturally occur in our
-- action labels or in normal English text — so typing a code matches only
-- the entry it was assigned to, not random label substrings.
--
-- Codes are picked by hashing the label (djb2) into the pool, with linear
-- probing on collisions. Probing happens in label-sorted order so that the
-- assignment is stable across runs given the same set of actions present.
-- Adding a new action with a colliding hash can shift codes for actions it
-- collides with, but the pool is large enough that this is rare in practice.

local SHORTCUT_POOL = {
  'jq','jx','jz','qj','qk','qx','qz','vk','vq','vx','vz',
  'xj','xk','xq','xv','xz','zj','zq','zv','zx',
  'kq','kx','kz','fq','fx','fz','wq','wx','wj','wz',
  'yq','yx','yz','pq','pz','hx','mx','mz','tx','tz',
  'bq','bx','bz','dx','dz','gq','gx','gz',
}

local function djb2(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 0x7FFFFFFF
  end
  return h
end

local function assign_shortcuts(labels)
  local sorted = {}
  for _, l in ipairs(labels) do sorted[#sorted + 1] = l end
  table.sort(sorted)

  local out, used = {}, {}
  local n = #SHORTCUT_POOL
  for _, label in ipairs(sorted) do
    local start = (djb2(label) % n) + 1
    for k = 0, n - 1 do
      local probe = ((start - 1 + k) % n) + 1
      local code = SHORTCUT_POOL[probe]
      if not used[code] then
        used[code] = true
        out[label] = code
        break
      end
    end
  end
  return out
end

-- Stable sort `labels` by (group order, original index). Lua's table.sort
-- isn't stable, so we carry the original index as a secondary key.
local function sort_by_group(labels, by_label)
  local with_idx = {}
  for i, label in ipairs(labels) do
    with_idx[i] = {
      label = label,
      idx   = i,
      grp   = GROUP_INDEX[action_group(by_label[label])] or #GROUP_ORDER + 1,
    }
  end
  table.sort(with_idx, function(a, b)
    if a.grp ~= b.grp then return a.grp < b.grp end
    return a.idx < b.idx
  end)
  local out = {}
  for i, e in ipairs(with_idx) do out[i] = e.label end
  return out
end

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

  -- Group within each three-way bucket. Disabled stays in insertion order
  -- (it's already visually inert at the bottom; further sorting adds noise).
  enabled     = sort_by_group(enabled,     resolved)
  dimmed_list = sort_by_group(dimmed_list, resolved)

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
  local shortcut = assign_shortcuts(order)

  -- Three-column display: shortcut | padded label | description. Fuzzy
  -- match runs over the whole visible string, so typing the 2-letter code
  -- matches only that row (the pool is digraph-rare; see comment above on
  -- assign_shortcuts). Dimmed and disabled entries are styled grey/italic.
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

    local body = (desc and desc ~= '')
      and string.format('%-' .. max_w .. 's   %s', label, desc)
      or label
    -- Two-space gutter after the code so the shortcut visually separates
    -- from the label; '  ' (two spaces) is a no-op fallback when the pool
    -- is exhausted so columns stay aligned.
    local sc = shortcut[label] or '  '

    local display
    if dimmed[label] or disabled[label] then
      -- Italic + an explicit hex grey so the row stays legible on dark
      -- schemes. Half-intensity stacked on Solarized's Grey (~#586e75) drops
      -- it to ~#2c3a3e, which is invisible against base03 (#002b36).
      display = wezterm.format {
        { Foreground = { Color = '#586e75' } },
        { Text = sc .. '  ' },
        'ResetAttributes',
        { Attribute = { Italic = true } },
        { Foreground = { Color = '#93a1a1' } },
        { Text = body },
        'ResetAttributes',
      }
    else
      display = wezterm.format {
        { Foreground = { Color = '#586e75' } },
        { Text = sc .. '  ' },
        'ResetAttributes',
        { Text = body },
      }
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
