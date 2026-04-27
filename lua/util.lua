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

return M
