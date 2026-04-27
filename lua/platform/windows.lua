-- termtools.platform.windows — Windows backend.
-- Selected by lua/platform.lua when wezterm.target_triple matches "windows".

local M = {}

M.path_sep            = '\\'
M.fs_case_insensitive = true

function M.home_dir()
  return os.getenv('USERPROFILE')
end

function M.default_shell()
  -- powershell.exe (Windows PowerShell 5.1) ships with Windows; pwsh.exe
  -- (PowerShell 7+) is opt-in. Default to the universal one.
  return { 'powershell' }
end

-- Wrap an editor argv so its program name resolves through PATHEXT.
-- CreateProcess (used by wezterm.background_child_process) only auto-appends
-- .exe — it doesn't honour PATHEXT, so a bare `code` finds nothing because
-- VS Code installs a `code.cmd` shim. Same trap for idea.cmd, cursor.cmd, etc.
-- Routing through cmd.exe makes PATHEXT lookup happen.
function M.editor_launch_args(args)
  local out = { 'cmd.exe', '/c' }
  for _, a in ipairs(args) do out[#out + 1] = a end
  return out
end

-- Pane spawns inherit the user's PATH from the GUI process on Windows, so no
-- resolution is needed — return argv unchanged. The darwin backend has to ask
-- the login+interactive shell to find the program because GUI-launched apps
-- there have a stripped PATH; that problem doesn't exist here.
function M.resolve_argv(args)
  return args
end

-- Apply OS-specific normalisation to a forward-slash-normalised path. Here we
-- uppercase the drive letter so paths compare equal regardless of how the
-- user typed it.
function M.normalize_path(path)
  return (path:gsub('^(%a):', function(c) return c:upper() .. ':' end))
end

function M.is_root(path)
  return path:match('^%a:/?$') ~= nil
end

-- Trailing slash stays only at filesystem roots ('C:/'). util.normalize calls
-- this to decide whether to drop the trailing slash.
function M.preserve_trailing_slash(path)
  return path:match('^%a:/$') ~= nil
end

-- Walk one level up from a normalised path. Returns nil at filesystem root.
function M.parent_dir(path)
  if M.is_root(path) then return nil end
  local idx = path:match('^.*()/')
  if not idx then return nil end
  if idx == 3 and path:sub(2, 2) == ':' then
    return path:sub(1, 3) -- C:/foo -> C:/
  end
  if idx == 1 then return '/' end
  return path:sub(1, idx - 1)
end

return M
