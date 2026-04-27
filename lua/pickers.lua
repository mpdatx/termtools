-- termtools.pickers — picker logic.
--
-- The two top-level pickers (project, action) are dispatched via wezterm
-- events rather than action_callbacks. Going through `EmitEvent` decouples
-- the picker from whatever modal triggered it (a keybinding, the command
-- palette, etc.) — the canonical wezterm pattern for custom commands.
-- init.lua is responsible for registering the event handlers via
-- `wezterm.on('termtools.<name>', ...)`.

local wezterm = require('wezterm')
local util = require('util')
local projects = require('projects')
local actions = require('actions')

local M = {}

-- Backward-compat re-export so external callers (init.palette_entries,
-- claude.project_label_for_pane) keep working without churn.
M.pane_cwd = util.pane_cwd

local function find_existing_pane_in_window(window, root)
  if not window or not root then return nil, nil end
  local ok, mux_window = pcall(wezterm.mux.get_window, window:window_id())
  if not ok or not mux_window then return nil, nil end
  local found = util.foreach_pane(function(pane)
    local path = util.pane_cwd(pane)
    if path and util.is_inside(path, root) then return pane end
  end, { window = mux_window })
  if found then return found:tab(), found end
  return nil, nil
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
function M.list_actions(root, opts)
  local order, by_label, _, _dimmed, disabled = build_action_list(root, opts)
  local out = {}
  for _, label in ipairs(order) do
    if not disabled[label] then
      out[#out + 1] = by_label[label]
    end
  end
  return out
end

-- ── Project picker state (persisted in wezterm.GLOBAL) ─────────────────────
-- MRU and the runtime sort-mode override survive config reloads but reset
-- on a full WezTerm restart. Persisting to disk is a TODO.

local SORT_MODES = { 'smart', 'alphabetical', 'mru' }
local MRU_CAP = 20

local function global_table()
  wezterm.GLOBAL = wezterm.GLOBAL or {}
  return wezterm.GLOBAL
end

local function mru_get()
  return global_table().termtools_project_mru or {}
end

local function mru_push(path)
  if not path or path == '' then return end
  local mru = mru_get()
  local out = { path }
  for _, p in ipairs(mru) do
    if p ~= path and #out < MRU_CAP then out[#out + 1] = p end
  end
  global_table().termtools_project_mru = out
end

local function get_sort_mode(opts)
  return global_table().termtools_project_sort or opts.project_sort or 'smart'
end

-- Cycle through SORT_MODES; returns the new mode for caller to surface.
function M.cycle_project_sort()
  local current = get_sort_mode({})
  for i, mode in ipairs(SORT_MODES) do
    if mode == current then
      local nxt = SORT_MODES[(i % #SORT_MODES) + 1]
      global_table().termtools_project_sort = nxt
      return nxt
    end
  end
  global_table().termtools_project_sort = 'smart'
  return 'smart'
end

function M.current_project_sort()
  return get_sort_mode({})
end

-- Per project root, count how many distinct tabs contain a pane whose CWD
-- lives under that root. Used to mark projects that are already open in
-- the picker.
local function count_tabs_per_root(roots_list)
  local seen_tabs = {}
  util.foreach_pane(function(pane, tab)
    local cwd = util.pane_cwd(pane)
    if not cwd then return end
    for _, root in ipairs(roots_list) do
      if util.is_inside(cwd, root) then
        seen_tabs[root] = seen_tabs[root] or {}
        seen_tabs[root][tab:tab_id()] = true
        break
      end
    end
  end)
  local out = {}
  for root, tabset in pairs(seen_tabs) do
    local n = 0
    for _ in pairs(tabset) do n = n + 1 end
    out[root] = n
  end
  return out
end

local function sort_entries(entries, mode, tabs_count, mru_positions)
  if mode == 'alphabetical' then
    table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
  elseif mode == 'mru' then
    table.sort(entries, function(a, b)
      local ap = mru_positions[a.path] or math.huge
      local bp = mru_positions[b.path] or math.huge
      if ap ~= bp then return ap < bp end
      return a.name:lower() < b.name:lower()
    end)
  else
    -- smart: MRU first (in MRU order), then has-tabs, then alphabetical.
    table.sort(entries, function(a, b)
      local ap = mru_positions[a.path]
      local bp = mru_positions[b.path]
      if ap and bp then return ap < bp end
      if ap then return true end
      if bp then return false end
      local at = (tabs_count[a.path] or 0) > 0
      local bt = (tabs_count[b.path] or 0) > 0
      if at ~= bt then return at end
      return a.name:lower() < b.name:lower()
    end)
  end
end

local PICKER_COLOR = {
  marker_open   = '#86efac', -- soft green
  marker_closed = '#586e75', -- solarized base01 (dim)
  name_mru      = '#fbbf24', -- amber, calls out the recently-used row
  path          = '#93a1a1', -- solarized base1 (muted)
  count         = '#586e75', -- same as closed marker
}

local function format_project_label(entry, count, is_mru, name_w)
  local marker = count > 0 and '●' or '○'
  local marker_color = count > 0 and PICKER_COLOR.marker_open or PICKER_COLOR.marker_closed
  local count_str = ''
  if count == 1 then count_str = '  · open'
  elseif count > 1 then count_str = '  · ' .. count .. ' tabs' end

  local fmt = {
    { Foreground = { Color = marker_color } },
    { Text = marker .. '  ' },
  }
  if is_mru then
    fmt[#fmt + 1] = { Foreground = { Color = PICKER_COLOR.name_mru } }
  else
    fmt[#fmt + 1] = 'ResetAttributes'
  end
  fmt[#fmt + 1] = { Text = string.format('%-' .. name_w .. 's', entry.name) }
  fmt[#fmt + 1] = 'ResetAttributes'
  fmt[#fmt + 1] = { Foreground = { Color = PICKER_COLOR.path } }
  fmt[#fmt + 1] = { Text = '  ' .. entry.path }
  if count_str ~= '' then
    fmt[#fmt + 1] = { Foreground = { Color = PICKER_COLOR.count } }
    fmt[#fmt + 1] = { Text = count_str }
  end
  fmt[#fmt + 1] = 'ResetAttributes'
  return wezterm.format(fmt)
end

-- Logic body for the project picker. Called by the event handler in init.lua.
function M.run_project_picker(window, pane, opts)
  opts = opts or {}
  local list = projects.discover(opts)
  if #list == 0 then
    window:toast_notification('termtools',
      'No projects discovered. Set scan_roots or pinned in setup({}).',
      nil, 4000)
    return
  end

  -- Snapshot tab counts and MRU once per picker open; sort accordingly.
  local roots = {}
  for _, e in ipairs(list) do roots[#roots + 1] = e.path end
  local tabs_count = count_tabs_per_root(roots)
  local mru_positions = {}
  for i, p in ipairs(mru_get()) do mru_positions[p] = i end

  local mode = get_sort_mode(opts)
  sort_entries(list, mode, tabs_count, mru_positions)

  local name_w = 0
  for _, e in ipairs(list) do if #e.name > name_w then name_w = #e.name end end

  local choices = {}
  for i, entry in ipairs(list) do
    local count = tabs_count[entry.path] or 0
    local is_mru = mru_positions[entry.path] ~= nil
    choices[i] = {
      id = tostring(i),
      label = format_project_label(entry, count, is_mru, name_w),
    }
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = string.format('Switch to project  (sort: %s)', mode),
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(w, p, id, _label)
        if not id then return end
        local entry = list[tonumber(id)]
        if not entry then return end

        mru_push(entry.path)

        local tab, _existing_pane = find_existing_pane_in_window(w, entry.path)
        if tab then
          tab:activate()
          return
        end

        local override = projects.load_overrides(entry.path, opts.trusted_paths)
        local cmd = (override and override.default_cmd) or opts.default_cmd
        -- Re-fetch the active pane: the `p` we were handed when the picker
        -- opened may have been closed by the time the user confirms.
        local target_pane = w:active_pane() or p
        w:perform_action(
          wezterm.action.SpawnCommandInNewTab {
            cwd = entry.path,
            args = cmd,
          },
          target_pane
        )
      end),
    },
    pane
  )
end

-- Logic body for the action picker. Called by the event handler in init.lua.
function M.run_action_picker(window, pane, opts)
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
-- the per-action palette entries: the entry emits an event carrying root and
-- label, and the handler resolves the action and runs it.
function M.run_action_by_label(window, pane, root, label, opts)
  opts = opts or {}
  if not root or not label then return end
  for _, action in ipairs(M.list_actions(root, opts)) do
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

-- ── Open-selection-as-file ────────────────────────────────────────────────
-- Read the active pane's mouse selection, parse any `path:line:col` suffix,
-- resolve relative paths against the pane's CWD, and open in the configured
-- editor. Triggered by either a hotkey (opt-in via `open_selection_key`) or
-- a Ctrl+Shift+Click mouse binding from style.lua.

local function strip_quotes_and_ws(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', '')
           :gsub('^["\']', ''):gsub('["\']$', ''))
end

local function is_absolute(path)
  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
end

local function looks_like_vscode(editor_cmd)
  if type(editor_cmd) ~= 'table' or not editor_cmd[1] then return false end
  local prog = editor_cmd[1]:lower():gsub('%.exe$', ''):gsub('%.cmd$', '')
  return prog:match('code$') ~= nil or prog:match('cursor$') ~= nil
end

function M.run_open_selection(window, pane, opts)
  opts = opts or {}
  local raw = window:get_selection_text_for_pane(pane)
  if not raw or raw == '' then
    window:toast_notification('termtools',
      'No selection — highlight a file path first.', nil, 1500)
    return
  end

  local text = strip_quotes_and_ws(raw)
  if text == '' then return end

  -- Try path:line:col, then path:line, then bare path.
  local path, line, col = text:match('^(.+):(%d+):(%d+)$')
  if not path then
    path, line = text:match('^(.+):(%d+)$')
  end
  if not path then path = text end

  if not is_absolute(path) then
    local cwd = util.pane_cwd(pane)
    if cwd then path = util.path_join(cwd, path) end
  end

  if not util.file_exists(path) then
    window:toast_notification('termtools',
      'No such file: ' .. path, nil, 2500)
    return
  end

  local editor_cmd = opts.editor_cmd or { 'code', '%s' }
  local args
  if line and looks_like_vscode(editor_cmd) then
    -- VS Code / Cursor accept --goto path:line[:col] for jump-to-line.
    local target = path
    if col then target = path .. ':' .. line .. ':' .. col
    else        target = path .. ':' .. line end
    args = { editor_cmd[1], '--goto', target }
  else
    args = util.format_cmd(editor_cmd, path)
  end

  args = require('platform').editor_launch_args(args)
  local ok, err = pcall(wezterm.background_child_process, args)
  if not ok then
    wezterm.log_error('termtools: open_selection launch failed: ' .. tostring(err))
  end
end

-- Compatibility shims: return EmitEvent actions so callers can drop these
-- straight into config.keys or palette entries. The handlers must be
-- registered first by init.lua's apply().
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
