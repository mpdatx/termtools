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

-- Walk every pane in every mux window. Re-classify Claude panes; preserve
-- the `since` timestamp when state hasn't changed so the stuck-too-long
-- counter measures time-in-current-state, not time-since-discovery.
function M.scan()
  local now = os.time()
  local fresh = {}
  local ok_w, windows = pcall(wezterm.mux.all_windows)
  if not ok_w then return end
  for _, win in ipairs(windows) do
    for _, tab in ipairs(win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        if is_claude_pane(pane) then
          local s = classify(pane)
          local prev = state[pane:pane_id()]
          local since = (prev and prev.state == s) and prev.since or now
          fresh[pane:pane_id()] = { state = s, since = since, pane = pane }
        end
      end
    end
  end
  state = fresh
end

function M.glyph_for_pane(pane_id)
  local entry = state[pane_id]
  if not entry then return nil end
  local s = effective_state(entry)
  if s == 'working' then return opts.glyph_working end
  if s == 'stuck'   then return opts.glyph_stuck end
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
  if c.working + c.waiting + c.stuck == 0 then return nil end
  local out = { { Attribute = { Intensity = 'Bold' } } }
  local function push(color, glyph, n)
    if n <= 0 then return end
    out[#out + 1] = { Foreground = { Color = color } }
    out[#out + 1] = { Text = string.format(' %s %d ', glyph, n) }
  end
  push(opts.status_color.working, opts.glyph_working, c.working)
  push(opts.status_color.waiting, opts.glyph_waiting, c.waiting)
  push(opts.status_color.stuck,   opts.glyph_stuck,   c.stuck)
  -- Subtle separator before the tab bar starts, only on left positioning.
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

function M.setup(user_opts)
  opts = {}
  for k, v in pairs(DEFAULTS) do opts[k] = v end
  for k, v in pairs(user_opts or {}) do opts[k] = v end
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
end

return M
