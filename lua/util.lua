-- termtools.util — generic path/fs helpers. The few operations that diverge
-- per OS (drive-letter handling, root detection, filesystem case-sensitivity)
-- are delegated to lua/platform/<os>.lua via lua/platform.lua.

local platform = require('platform')

local M = {}

M.is_windows = platform.is_windows
M.is_macos   = platform.is_macos

-- Convert backslashes to forward slashes, collapse `//`, drop trailing slash
-- except where the platform wants it preserved (e.g. `C:/` on Windows), and
-- apply per-platform normalisation (drive-letter case on Windows, identity
-- on macOS).
function M.normalize(path)
  if not path or path == '' then return path end
  local p = path:gsub('\\', '/'):gsub('//+', '/')
  p = platform.normalize_path(p)
  if #p > 1 and p:sub(-1) == '/' then
    if not platform.preserve_trailing_slash(p) then
      p = p:sub(1, -2)
    end
  end
  return p
end

function M.path_join(...)
  local out
  for _, part in ipairs({ ... }) do
    if part and part ~= '' then
      if not out then
        out = part
      else
        out = out:gsub('/$', '') .. '/' .. part:gsub('^/', '')
      end
    end
  end
  return M.normalize(out or '')
end

function M.is_inside(child, parent)
  if not child or not parent then return false end
  local c, p = M.normalize(child), M.normalize(parent)
  if platform.fs_case_insensitive then
    c, p = c:lower(), p:lower()
  end
  if c == p then return true end
  local prefix = p:sub(-1) == '/' and p or p .. '/'
  return c:sub(1, #prefix) == prefix
end

function M.parent_dir(path)
  return platform.parent_dir(M.normalize(path))
end

function M.is_root(path)
  return platform.is_root(M.normalize(path))
end

function M.file_exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() return true end
  return false
end

-- Best-effort directory check. Uses wezterm.read_dir when available
-- (only when called from inside a WezTerm Lua context).
function M.dir_exists(path)
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if ok_wt and wezterm.read_dir then
    local ok = pcall(wezterm.read_dir, path)
    return ok
  end
  return M.file_exists(M.path_join(path, '.'))
end

-- Substitute occurrences of `%s` in a template array with successive args.
-- format_cmd({ 'code', '%s' }, 'C:/foo/bar.md') -> { 'code', 'C:/foo/bar.md' }
function M.format_cmd(template, ...)
  local args = { ... }
  local out, idx = {}, 1
  for _, part in ipairs(template) do
    if part == '%s' then
      out[#out + 1] = args[idx] or ''
      idx = idx + 1
    else
      out[#out + 1] = part
    end
  end
  while idx <= #args do
    out[#out + 1] = args[idx]
    idx = idx + 1
  end
  return out
end

function M.basename(path)
  local p = M.normalize(path)
  return p:match('([^/]+)$') or p
end

-- Returns a fresh table with `defaults` overlaid by `user_opts`. Both args
-- are optional; nil/missing keys are skipped, so calling with `nil` for
-- either side returns a safe shallow copy of the other.
function M.merge_defaults(defaults, user_opts)
  local merged = {}
  for k, v in pairs(defaults or {}) do merged[k] = v end
  for k, v in pairs(user_opts or {}) do merged[k] = v end
  return merged
end

-- ── WezTerm-pane helpers ──────────────────────────────────────────────────
-- These wrap two recurring patterns:
--   pane_cwd      — resolve a pane's working directory through OSC 7/9;9
--                   first, falling back to OS process-info. Works without
--                   shell integration on Windows powershell/cmd.
--   foreach_pane  — walk every pane in every mux window (or one specific
--                   window) and call `fn(pane, tab, win)`. If `fn` returns
--                   non-nil, walking stops and the value is returned.

function M.pane_cwd(pane)
  if not pane then return nil end
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if ok and cwd then
    if type(cwd) == 'table' and cwd.file_path then return cwd.file_path end
    if type(cwd) == 'string' and cwd ~= '' then return cwd end
  end
  local ok2, info = pcall(pane.get_foreground_process_info, pane)
  if ok2 and info and type(info.cwd) == 'string' and info.cwd ~= '' then
    return info.cwd
  end
  return nil
end

function M.foreach_pane(fn, opts)
  opts = opts or {}
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if not ok_wt then return nil end

  local windows
  if opts.window then
    windows = { opts.window }
  else
    local ok, all = pcall(wezterm.mux.all_windows)
    if not ok then return nil end
    windows = all
  end

  for _, win in ipairs(windows) do
    for _, tab in ipairs(win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        local result = fn(pane, tab, win)
        if result ~= nil then return result end
      end
    end
  end
  return nil
end

return M
