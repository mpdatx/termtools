-- termtools.platform.darwin — macOS backend.
-- Selected by lua/platform.lua when wezterm.target_triple matches "darwin".

local M = {}

M.path_sep = '/'
-- APFS (and HFS+ before it) is case-insensitive in its default config —
-- comparison-wise that matches Windows. Set this to false in your override
-- if you've explicitly formatted volumes as case-sensitive.
M.fs_case_insensitive = true

function M.home_dir()
  return os.getenv('HOME')
end

function M.default_shell()
  -- Modern macOS defaults to zsh; honour $SHELL if the user uses something
  -- else (fish, bash, nushell, ...).
  return { os.getenv('SHELL') or '/bin/zsh' }
end

-- Per-platform editor defaults consumed by the file-open / inline-view
-- actions. `registry` keys are user-facing names; `cmd` is an argv template
-- where '%s' is replaced with the target file. `kind = 'external'` means
-- launch via background_child_process (GUI editor); `kind = 'pane'` means
-- spawn into a wezterm pane split in the given `direction`.
function M.default_editors()
  return {
    registry = {
      code = { cmd = { 'code', '%s' }, kind = 'external' },
      vim  = { cmd = { 'vim',  '%s' }, kind = 'pane', direction = 'Right' },
    },
    default = 'code',
    inline  = 'vim',
  }
end

-- macOS spawns work directly: no PATHEXT trap, no .cmd shims, the program
-- name in `args[1]` is found by execvp searching $PATH. No wrapping needed.
function M.editor_launch_args(args)
  return args
end

-- Resolve argv[1] to an absolute path. Needed because a GUI-launched WezTerm
-- only inherits the system PATH (`/usr/bin:/bin:...`) — anything installed
-- under ~/.claude/local, /opt/homebrew, or an npm prefix won't be found by
-- execvp when SpawnCommand fires. Two-stage lookup:
--
--   1. Stat a list of well-known install dirs (microseconds, no fork). This
--      covers ~all real installs and avoids paying the slow path on startup.
--   2. Fall back to asking the login+interactive shell (`$SHELL -lic
--      'command -v ...'`) only if no candidate hit. That sources .zshrc and
--      can be hundreds of ms.
--
-- Returns argv unchanged if resolution fails or argv[1] is already a path.
local KNOWN_BIN_DIRS = {
  '~/.claude/local/bin',
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '~/.bun/bin',
  '~/.npm-global/bin',
  '~/.local/bin',
  '~/.volta/bin',
}

local function file_exists(path)
  local f = io.open(path, 'r')
  if not f then return false end
  f:close()
  return true
end

local function with_resolved_first(args, path)
  local out = { path }
  for i = 2, #args do out[#out + 1] = args[i] end
  return out
end

function M.resolve_argv(args)
  if not args or #args == 0 then return args end
  local prog = args[1]
  -- Already an absolute or relative path — caller knows where it is.
  if prog:find('/') then return args end

  local home = os.getenv('HOME') or ''
  for _, dir in ipairs(KNOWN_BIN_DIRS) do
    local p = (dir:gsub('^~', home)) .. '/' .. prog
    if file_exists(p) then return with_resolved_first(args, p) end
  end

  -- Slow path: ask the user's login+interactive shell.
  local wezterm = require('wezterm')
  local shell = os.getenv('SHELL') or '/bin/zsh'
  local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
  if not ok or not stdout then return args end
  local path = (stdout:gsub('%s+$', ''))
  if path == '' or path:sub(1, 1) ~= '/' then
    -- Empty result, alias text, or shell function — nothing we can exec directly.
    return args
  end
  return with_resolved_first(args, path)
end

-- No drive letters to normalise — identity.
function M.normalize_path(path)
  return path
end

function M.is_root(path)
  return path == '/'
end

-- Never preserve trailing slashes on macOS paths.
function M.preserve_trailing_slash(_path)
  return false
end

function M.parent_dir(path)
  if path == '/' then return nil end
  local idx = path:match('^.*()/')
  if not idx then return nil end
  if idx == 1 then return '/' end
  return path:sub(1, idx - 1)
end

return M
