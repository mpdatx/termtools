-- termtools.state — JSON-persisted user state.
--
-- Holds MRU list, project picker sort mode, and the user-pinned project
-- list. Authoritative copy lives in `wezterm.GLOBAL` (survives config
-- reload); mirrored to `<config_dir>/termtools-state.json` (survives full
-- WezTerm restart). The disk file is the source of truth on a fresh
-- process; thereafter GLOBAL is authoritative and writes flow back to disk
-- on every mutation.
--
-- Public surface:
--   state.mru()             -> array of paths
--   state.mru_push(path)
--   state.sort_mode()       -> string | nil
--   state.set_sort_mode(s)
--   state.user_pinned()     -> array of normalised paths
--   state.is_pinned(path)   -> bool
--   state.toggle_pin(path)  -> bool   (true if path is now pinned)

local wezterm = require('wezterm')

local M = {}

local MRU_CAP = 20

local function gtab()
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

local function load_disk()
  local f = io.open(state_path(), 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then return {} end
  local ok, parsed = pcall(json_decode, content)
  if not ok or type(parsed) ~= 'table' then return {} end
  return parsed
end

local function save_disk()
  local g = gtab()
  local payload = {
    project_mru  = g.termtools_project_mru  or {},
    project_sort = g.termtools_project_sort,
    user_pinned  = g.termtools_user_pinned  or {},
  }
  local content = json_encode(payload)
  if not content then return end
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
  -- destination first so the rename succeeds on both.
  os.remove(path)
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    wezterm.log_error('termtools: state rename failed (' .. tostring(rerr) .. ')')
    os.remove(tmp)
  end
end

local loaded = false
local function ensure()
  if loaded then return end
  loaded = true
  local d = load_disk()
  local g = gtab()
  if not g.termtools_project_mru and type(d.project_mru) == 'table' then
    g.termtools_project_mru = d.project_mru
  end
  if not g.termtools_project_sort and type(d.project_sort) == 'string' then
    g.termtools_project_sort = d.project_sort
  end
  if not g.termtools_user_pinned and type(d.user_pinned) == 'table' then
    g.termtools_user_pinned = d.user_pinned
  end
end

-- ── MRU ──────────────────────────────────────────────────────────────────

function M.mru()
  ensure()
  return gtab().termtools_project_mru or {}
end

function M.mru_push(path)
  if not path or path == '' then return end
  ensure()
  local mru = gtab().termtools_project_mru or {}
  local out = { path }
  for _, p in ipairs(mru) do
    if p ~= path and #out < MRU_CAP then out[#out + 1] = p end
  end
  gtab().termtools_project_mru = out
  save_disk()
end

-- ── Sort mode ────────────────────────────────────────────────────────────

function M.sort_mode()
  ensure()
  return gtab().termtools_project_sort
end

function M.set_sort_mode(mode)
  ensure()
  gtab().termtools_project_sort = mode
  save_disk()
end

-- ── User-pinned ──────────────────────────────────────────────────────────
-- Stored normalised so equality checks against discovered paths (which are
-- also normalised by projects.discover) match without per-call rework.

local function normalize(p)
  return require('util').normalize(p)
end

function M.user_pinned()
  ensure()
  return gtab().termtools_user_pinned or {}
end

function M.is_pinned(path)
  if not path or path == '' then return false end
  local norm = normalize(path)
  for _, p in ipairs(M.user_pinned()) do
    if p == norm then return true end
  end
  return false
end

local function pin(path)
  if not path or path == '' then return end
  ensure()
  local norm = normalize(path)
  if M.is_pinned(norm) then return end
  local list = gtab().termtools_user_pinned or {}
  list[#list + 1] = norm
  gtab().termtools_user_pinned = list
  save_disk()
end

local function unpin(path)
  if not path or path == '' then return end
  ensure()
  local norm = normalize(path)
  local list = gtab().termtools_user_pinned or {}
  local out = {}
  for _, p in ipairs(list) do
    if p ~= norm then out[#out + 1] = p end
  end
  gtab().termtools_user_pinned = out
  save_disk()
end

function M.toggle_pin(path)
  if M.is_pinned(path) then unpin(path); return false end
  pin(path); return true
end

return M
