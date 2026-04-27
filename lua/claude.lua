-- termtools.claude — multi-session Claude Code awareness.
--
-- Detects panes running `claude`, classifies their state (working /
-- waiting / waiting-too-long), and exposes:
--   • per-pane glyphs to splice into format-tab-title
--   • a status-bar summary with global counts
--   • an EmitEvent action that focuses the next waiting pane
--
-- All logic is opt-in via `claude_indicators = true` in setup({}). When
-- enabled, init.lua's apply() calls M.attach(config) which registers an
-- update-status handler that polls every poll_interval_ms.

local wezterm = require('wezterm')

local M = {}

local DEFAULTS = {
  poll_interval_ms  = 2000,
  scan_lines        = 40,
  idle_too_long_s   = 5 * 60,
  glyph_working     = '↻',
  glyph_waiting     = '✱',
  glyph_stuck       = '⚠',
  identify_patterns = { 'claude' },          -- match against pane argv/exe
  -- Match against the lowercase last `scan_lines` of buffer. Plain-string
  -- matches (case-insensitive). Default set covers Claude Code's "esc to
  -- interrupt" footer plus the braille spinner glyphs it cycles while
  -- thinking — at least one of those should be on screen at any moment of
  -- active work. Tune for your version if classification misses.
  working_patterns  = {
    'esc to interrupt',
    'press esc',
    -- Braille spinner half-cycle (Claude Code emits these as the busy
    -- indicator; any one being present is enough)
    '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏',
  },
  status_debug      = false,                 -- log per-pane classifier decisions
  show_status_bar   = true,
  status_position   = 'left',  -- 'left' / 'right' / 'both'
  -- Hex colors so the status reads vividly regardless of color scheme.
  -- AnsiColor names (e.g. 'Yellow') get remapped by some schemes and end
  -- up muted; explicit hex avoids that.
  status_color = {
    working = '#fbbf24',  -- amber: actively thinking
    waiting = '#22d3ee',  -- cyan:  ready for input
    stuck   = '#ef4444',  -- red:   overdue
  },
  status_separator_color = '#586e75',
}

local opts = {}
local state = {}     -- pane_id -> { state, since, pane }
local cursor = 0     -- index into the next-waiting cycle

local function lower(s) return tostring(s or ''):lower() end

local function any_match(text, patterns)
  local t = lower(text)
  for _, pat in ipairs(patterns) do
    if t:find(lower(pat), 1, true) then return true end
  end
  return false
end

local function is_claude_pane(pane)
  local ok, info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not info then return false end
  if type(info.argv) == 'table' then
    for _, arg in ipairs(info.argv) do
      if any_match(arg, opts.identify_patterns) then return true end
    end
  end
  if any_match(info.executable, opts.identify_patterns) then return true end
  if any_match(info.name, opts.identify_patterns) then return true end
  return false
end

local function classify(pane)
  local ok, text = pcall(pane.get_lines_as_text, pane, opts.scan_lines)
  if not ok or not text then
    if opts.status_debug then
      wezterm.log_warn('termtools.claude: get_lines_as_text failed for pane '
        .. tostring(pane:pane_id()))
    end
    return 'waiting'
  end
  local working = any_match(text, opts.working_patterns)
  if opts.status_debug then
    -- Show the LAST line of the visible buffer to help tune patterns.
    local last_line = text:match('([^\n]*)\n*$') or ''
    wezterm.log_warn(string.format(
      'termtools.claude: pane %d -> %s; last line: %q',
      pane:pane_id(), working and 'working' or 'waiting', last_line:sub(1, 120)))
  end
  return working and 'working' or 'waiting'
end

local function effective_state(entry, now)
  if entry.state == 'working' then return 'working' end
  now = now or os.time()
  if (now - entry.since) >= opts.idle_too_long_s then return 'stuck' end
  return 'waiting'
end

-- Re-classify Claude panes across every pane in every mux window. Preserves
-- the `since` timestamp when state hasn't changed so the stuck-too-long
-- counter measures time-in-current-state, not time-since-discovery.
function M.scan()
  local util = require('util')
  local now = os.time()
  local fresh = {}
  util.foreach_pane(function(pane)
    if not is_claude_pane(pane) then return end
    local s = classify(pane)
    local prev = state[pane:pane_id()]
    local since = (prev and prev.state == s) and prev.since or now
    fresh[pane:pane_id()] = { state = s, since = since, pane = pane }
  end)
  state = fresh
end

function M.glyph_for_pane(pane_id)
  local entry = state[pane_id]
  if not entry then return nil end
  if entry.state == 'working' then return opts.glyph_working end
  return opts.glyph_waiting
end

-- Returns the bucketed counts so callers (status bar, debug) can format.
function M.counts()
  local now = os.time()
  local working, waiting, stuck = 0, 0, 0
  for _, entry in pairs(state) do
    local s = effective_state(entry, now)
    if s == 'working' then working = working + 1
    elseif s == 'stuck' then stuck = stuck + 1
    else waiting = waiting + 1 end
  end
  return { working = working, waiting = waiting, stuck = stuck }
end

local function summary_format()
  local c = M.counts()
  -- Status bar collapses waiting + stuck into one "idle" bucket. The age
  -- distinction is preserved in the underlying state and surfaced by the
  -- session picker.
  local idle = c.waiting + c.stuck
  if c.working + idle == 0 then return nil end
  local out = { { Attribute = { Intensity = 'Bold' } } }
  local function push(color, glyph, n)
    if n <= 0 then return end
    out[#out + 1] = { Foreground = { Color = color } }
    out[#out + 1] = { Text = string.format(' %s %d ', glyph, n) }
  end
  push(opts.status_color.working, opts.glyph_working, c.working)
  push(opts.status_color.waiting, opts.glyph_waiting, idle)
  if opts.status_position == 'left' or opts.status_position == 'both' then
    out[#out + 1] = { Foreground = { Color = opts.status_separator_color } }
    out[#out + 1] = { Text = ' ▏ ' }
  end
  out[#out + 1] = 'ResetAttributes'
  return out
end

-- Focus the next pane that's not actively working (waiting OR stuck).
-- Cycles deterministically by pane_id; returns true on success.
function M.focus_next_waiting()
  local now = os.time()
  local list = {}
  for pane_id, entry in pairs(state) do
    if effective_state(entry, now) ~= 'working' then
      list[#list + 1] = { id = pane_id, pane = entry.pane }
    end
  end
  if #list == 0 then return false end
  table.sort(list, function(a, b) return a.id < b.id end)
  cursor = (cursor % #list) + 1
  local pane = list[cursor].pane
  if not pane then return false end

  local tab = pane:tab()
  if tab then tab:activate() end
  pane:activate()
  if tab then
    local mw = tab:window()
    if mw and mw.gui_window then
      local gui = mw:gui_window()
      if gui then pcall(gui.focus, gui) end
    end
  end
  return true
end

function M.next_waiting_action()
  return wezterm.action.EmitEvent 'termtools.claude-next-waiting'
end

local function format_age(secs)
  if secs < 60   then return string.format('%ds', secs) end
  if secs < 3600 then return string.format('%dm', math.floor(secs / 60)) end
  return string.format('%dh', math.floor(secs / 3600))
end

local function project_label_for_pane(pane)
  local util = require('util')
  local cwd = util.pane_cwd(pane)
  if not cwd then return '?' end
  local ok_projects, projects = pcall(require, 'projects')
  local root = ok_projects and projects.find_root(cwd) or cwd
  return root:match('([^/\\]+)$') or root
end

-- Open an InputSelector listing every Claude pane with project, state,
-- duration and pane-id. Selecting one focuses it. Working sessions sort
-- first; idle sessions follow, sorted youngest-first; sessions older than
-- `idle_too_long_s` are rendered dim/grey but remain selectable.
function M.run_session_picker(window, pane)
  if next(state) == nil then
    window:toast_notification('termtools',
      'No Claude sessions detected.', nil, 1500)
    return
  end

  local now = os.time()
  local items = {}
  for pid, entry in pairs(state) do
    items[#items + 1] = {
      pid = pid, entry = entry,
      proj = project_label_for_pane(entry.pane),
      age  = now - entry.since,
    }
  end

  -- Working first, then idle by age (newest first); old/stuck idle sink to
  -- the bottom of their bucket via the dim style alone.
  table.sort(items, function(a, b)
    if a.entry.state ~= b.entry.state then
      return a.entry.state == 'working'
    end
    return a.age < b.age
  end)

  local proj_w = 0
  for _, it in ipairs(items) do
    if #it.proj > proj_w then proj_w = #it.proj end
  end

  local choices = {}
  for i, it in ipairs(items) do
    local glyph = it.entry.state == 'working'
      and opts.glyph_working or opts.glyph_waiting
    local plain = string.format('%s  %-' .. proj_w .. 's   %5s   pane %d',
      glyph, it.proj, format_age(it.age), it.pid)
    local is_old = it.entry.state ~= 'working' and it.age >= opts.idle_too_long_s
    local label
    if is_old then
      label = wezterm.format {
        { Attribute = { Intensity = 'Half' } },
        { Foreground = { AnsiColor = 'Grey' } },
        { Text = plain },
      }
    else
      label = plain
    end
    choices[i] = { id = tostring(i), label = label }
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = 'Claude sessions',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(w, _p, id, _label)
        if not id then return end
        local it = items[tonumber(id)]
        if not it or not it.entry.pane then return end
        local target = it.entry.pane
        local tab = target:tab()
        if tab then tab:activate() end
        target:activate()
        if tab then
          local mw = tab:window()
          if mw and mw.gui_window then
            local gui = mw:gui_window()
            if gui then pcall(gui.focus, gui) end
          end
        end
      end),
    },
    pane
  )
end

function M.session_picker_action()
  return wezterm.action.EmitEvent 'termtools.claude-session-picker'
end

function M.setup(user_opts)
  opts = require('util').merge_defaults(DEFAULTS, user_opts)
end

local attached = false

function M.attach(config)
  if attached then return end
  attached = true

  config.status_update_interval = opts.poll_interval_ms

  wezterm.on('update-status', function(window, _pane)
    M.scan()
    local pos = opts.status_position or 'left'
    local fmt = opts.show_status_bar and summary_format() or nil
    local rendered = fmt and wezterm.format(fmt) or ''
    if pos == 'left' or pos == 'both' then
      window:set_left_status(rendered)
    else
      window:set_left_status('')
    end
    if pos == 'right' or pos == 'both' then
      window:set_right_status(rendered)
    else
      window:set_right_status('')
    end
  end)

  wezterm.on('termtools.claude-next-waiting', function(window, _pane)
    if not M.focus_next_waiting() then
      window:toast_notification('termtools',
        'No Claude session is currently waiting.', nil, 1500)
    end
  end)

  wezterm.on('termtools.claude-session-picker', function(window, pane)
    M.run_session_picker(window, pane)
  end)
end

return M
