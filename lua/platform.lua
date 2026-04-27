-- termtools.platform — picks the per-OS backend and re-exports it as the
-- module's surface. All platform-specific code lives in `platform/<os>.lua`
-- so cross-machine merges only ever touch one backend file at a time.

local M = {}

local function detect()
  local ok, wezterm = pcall(require, 'wezterm')
  local triple = (ok and wezterm.target_triple) or ''
  if triple:find('windows') then return 'windows' end
  if triple:find('darwin')  then return 'darwin' end
  -- Last resort for environments without wezterm in scope (e.g. tests).
  if package.config:sub(1, 1) == '\\' then return 'windows' end
  return 'darwin'
end

local backend_name = detect()
M.is_windows = (backend_name == 'windows')
M.is_macos   = (backend_name == 'darwin')
M.os         = backend_name

local backend = require('platform.' .. backend_name)
for k, v in pairs(backend) do
  if M[k] == nil then M[k] = v end
end

return M
