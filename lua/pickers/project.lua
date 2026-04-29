-- termtools.pickers.project — the project picker.
--
-- Owns project picker UI, sort state (in wezterm.GLOBAL), MRU tracking,
-- and tab-counting for "is this project already open" decoration.
--
-- Public surface:
--   M.run(window, pane, opts)  the body called by the wezterm event handler
--   M.cycle_sort()             advance to the next sort mode; returns it
--   M.current_sort()           read the active sort mode

local wezterm  = require('wezterm')
local util     = require('util')
local projects = require('projects')

local M = {}

-- ── Persisted state ──────────────────────────────────────────────────────
-- MRU list and current sort mode live in wezterm.GLOBAL (survives config
-- reload) and are mirrored to <config_dir>/termtools-state.json (survives
-- full WezTerm restart). The disk file is the source of truth on a fresh
-- process; thereafter GLOBAL is authoritative and writes flow back to disk
-- on every push / sort cycle.

local SORT_MODES = { 'smart', 'alphabetical', 'mru' }
local MRU_CAP = 20

local function global_table()
  wezterm.GLOBAL = wezterm.GLOBAL or {}
  return wezterm.GLOBAL
end

local function state_path()
  return wezterm.config_dir .. '/termtools-state.json'
end

local function json_encode(t)
  if wezterm.serde and wezterm.serde.json_encode then
    return wezterm.serde.json_encode(t)
  end
  if wezterm.json_encode then return wezterm.json_encode(t) end
  return nil
end

local function json_decode(s)
  if wezterm.serde and wezterm.serde.json_decode then
    return wezterm.serde.json_decode(s)
  end
  if wezterm.json_parse then return wezterm.json_parse(s) end
  return nil
end

local function load_state_from_disk()
  local f = io.open(state_path(), 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then return {} end
  local ok, parsed = pcall(json_decode, content)
  if not ok or type(parsed) ~= 'table' then return {} end
  return parsed
end

local function save_state_to_disk()
  local g = global_table()
  local payload = {
    project_mru  = g.termtools_project_mru or {},
    project_sort = g.termtools_project_sort,
  }
  local content = json_encode(payload)
  if not content then return end -- no JSON encoder; silently skip
  local path = state_path()
  local tmp  = path .. '.tmp'
  local f, err = io.open(tmp, 'w')
  if not f then
    wezterm.log_error('termtools: state write failed (' .. tostring(err) .. ')')
    return
  end
  f:write(content)
  f:close()
  -- os.rename overwrites on POSIX, fails-if-exists on Windows. Remove
  -- the destination first so the rename succeeds on both.
  os.remove(path)
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    wezterm.log_error('termtools: state rename failed (' .. tostring(rerr) .. ')')
    os.remove(tmp)
  end
end

-- Hydrate GLOBAL from disk on first access in this module instance.
-- If GLOBAL already holds values (e.g. survived a config reload), those
-- win — disk state from the same process is, by construction, equal or
-- older than what's in memory.
local state_loaded = false
local function ensure_state_loaded()
  if state_loaded then return end
  state_loaded = true
  local on_disk = load_state_from_disk()
  local g = global_table()
  if not g.termtools_project_mru and type(on_disk.project_mru) == 'table' then
    g.termtools_project_mru = on_disk.project_mru
  end
  if not g.termtools_project_sort and type(on_disk.project_sort) == 'string' then
    g.termtools_project_sort = on_disk.project_sort
  end
end

local function mru_get()
  ensure_state_loaded()
  return global_table().termtools_project_mru or {}
end

local function mru_push(path)
  if not path or path == '' then return end
  ensure_state_loaded()
  local mru = global_table().termtools_project_mru or {}
  local out = { path }
  for _, p in ipairs(mru) do
    if p ~= path and #out < MRU_CAP then out[#out + 1] = p end
  end
  global_table().termtools_project_mru = out
  save_state_to_disk()
end

local function get_sort_mode(opts)
  ensure_state_loaded()
  return global_table().termtools_project_sort or opts.project_sort or 'smart'
end

function M.cycle_sort()
  ensure_state_loaded()
  local current = get_sort_mode({})
  for i, mode in ipairs(SORT_MODES) do
    if mode == current then
      local nxt = SORT_MODES[(i % #SORT_MODES) + 1]
      global_table().termtools_project_sort = nxt
      save_state_to_disk()
      return nxt
    end
  end
  global_table().termtools_project_sort = 'smart'
  save_state_to_disk()
  return 'smart'
end

function M.current_sort()
  return get_sort_mode({})
end

-- ── Helpers ──────────────────────────────────────────────────────────────

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

-- Per project root, count how many distinct tabs contain a pane whose CWD
-- lives under that root. Used to mark projects already open in the picker.
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

local function format_label(entry, count, is_mru, name_w)
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

-- ── Run ──────────────────────────────────────────────────────────────────

function M.run(window, pane, opts)
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
      label = format_label(entry, count, is_mru, name_w),
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

return M
