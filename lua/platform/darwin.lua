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

-- macOS spawns work directly: no PATHEXT trap, no .cmd shims, the program
-- name in `args[1]` is found by execvp searching $PATH. No wrapping needed.
function M.editor_launch_args(args)
  return args
end

-- Resolve argv[1] to an absolute path by asking the user's login+interactive
-- shell where the program lives. Needed because a GUI-launched WezTerm only
-- inherits the system PATH (`/usr/bin:/bin:...`) — anything installed under
-- ~/.claude/local, /opt/homebrew, or an npm prefix won't be found by execvp
-- when SpawnCommand fires. Doing the lookup once at setup time keeps spawns
-- direct (no shell middleman per pane) and survives PATH set in .zshrc.
-- Returns argv unchanged if resolution fails or the program is already an
-- absolute path.
function M.resolve_argv(args)
  if not args or #args == 0 then return args end
  local prog = args[1]
  if prog:sub(1, 1) == '/' then return args end
  local wezterm = require('wezterm')
  local shell = os.getenv('SHELL') or '/bin/zsh'
  local ok, stdout = wezterm.run_child_process({ shell, '-lic', 'command -v ' .. prog })
  if not ok or not stdout then return args end
  local path = (stdout:gsub('%s+$', ''))
  if path == '' or path:sub(1, 1) ~= '/' then
    -- Empty result, alias text, or shell function — nothing we can exec directly.
    return args
  end
  local out = { path }
  for i = 2, #args do out[#out + 1] = args[i] end
  return out
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
