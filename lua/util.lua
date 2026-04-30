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

-- Pick the editor command for an "open file" action. Pure: caller threads
-- opts. `override` (if non-nil) wins; otherwise `opts.editor_cmd`; otherwise
-- a `{'code','%s'}` fallback so the function is safe to call before setup().
function M.resolve_editor_cmd(override, opts)
  if override then return override end
  if opts and opts.editor_cmd then return opts.editor_cmd end
  return { 'code', '%s' }
end

-- Heuristic: does this editor command look like VS Code or Cursor (which
-- accept `--goto path:line:col` for jump-to-position)? Strips a trailing
-- `.exe` / `.cmd` from the program name before matching so the Windows
-- shim names work too.
function M.looks_like_vscode_editor(editor_cmd)
  if type(editor_cmd) ~= 'table' or not editor_cmd[1] then return false end
  local prog = editor_cmd[1]:lower():gsub('%.exe$', ''):gsub('%.cmd$', '')
  return prog:match('code$') ~= nil or prog:match('cursor$') ~= nil
end

-- Resolve `role` ('default' | 'inline') to a concrete editor spec.
-- Resolution order:
--   1. wezterm.GLOBAL runtime override for the role
--   2. opts.editors[role] → opts.editors.registry[name]
--   3. nil (only happens for 'inline' when no inline editor is configured)
--
-- The runtime overrides are:
--   wezterm.GLOBAL.termtools_editor_default — string registry name
--   wezterm.GLOBAL.termtools_editor_inline  — string name, or false to disable
function M.editor_spec(role, opts)
  if not (role == 'default' or role == 'inline') then return nil end
  local editors = opts and opts.editors
  if type(editors) ~= 'table' then return nil end
  local registry = editors.registry or {}

  local ok_wt, wezterm = pcall(require, 'wezterm')
  local global = (ok_wt and wezterm.GLOBAL) or {}
  local override = global['termtools_editor_' .. role]

  if override == false then return nil end -- explicit disable (inline only)
  local name = override or editors[role]
  if name and registry[name] then return registry[name] end
  return nil
end

-- ── WezTerm-pane helpers ──────────────────────────────────────────────────
-- These wrap two recurring patterns:
--   pane_cwd      — resolve a pane's working directory through OSC 7/9;9
--                   first, falling back to OS process-info. Works without
--                   shell integration on Windows powershell/cmd.
--   foreach_pane  — walk every pane in every mux window (or one specific
--                   window) and call `fn(pane, tab, win)`. If `fn` returns
--                   non-nil, walking stops and the value is returned.

-- Domain a pane belongs to (e.g. 'local', 'mux', 'myhost'). Defaults to
-- 'local' if the call raises or the method is missing — keeps the rest
-- of the codebase's "assume local" behaviour stable for older wezterm.
function M.pane_domain(pane)
  if not pane then return 'local' end
  local ok, dn = pcall(pane.domain_name, pane)
  return (ok and type(dn) == 'string' and dn) or 'local'
end

-- Picker dispatchers stash the active pane's domain here at picker-open
-- time so action factories (open_file etc.) can adjust their description /
-- dimmed_when behaviour without taking pane as a parameter. 'local' is
-- the safe default — predicates that fall through to the existence-check
-- branch behave as they always have for `local` panes.
local active_pane_domain = 'local'

function M.set_active_pane_domain(d)
  active_pane_domain = d or 'local'
end

function M.active_pane_domain()
  return active_pane_domain
end

-- Set of domain names whose filesystem the GUI's local Lua can probe via
-- io.open / read_dir. Always includes the built-in 'local' domain.
-- termtools.apply() populates this at config-load time from config.unix_domains
-- (unix sockets are by definition same-machine) plus any user-supplied
-- `local_domains` opt for the unusual cases (e.g. a TLS client connecting to
-- a mux on the same host).
local local_domain_names = { ['local'] = true }

function M.set_local_domains(names)
  local_domain_names = { ['local'] = true }
  for _, n in ipairs(names or {}) do
    if type(n) == 'string' and n ~= '' then local_domain_names[n] = true end
  end
end

function M.is_local_domain(name)
  return local_domain_names[name or 'local'] == true
end

function M.pane_cwd(pane)
  if not pane then return nil end

  -- Process-info first: this is the OS-reported live CWD of the foreground
  -- process, so it tracks `cd` immediately. OSC 7 is wezterm's cache of
  -- whatever the shell last emitted — bash/zsh/fish with shell integration
  -- emit on every prompt and stay accurate, but bare PowerShell and cmd
  -- only emit at spawn (or never), so OSC 7 lags behind a manual chdir
  -- there. We accept that the OSC 7 path used to win when the foreground
  -- process was a non-shell that "owned" a different cwd (an editor :cd'd
  -- elsewhere); that case is rare enough to not justify the staleness.
  local ok_pi, info = pcall(pane.get_foreground_process_info, pane)
  if ok_pi and info and type(info.cwd) == 'string' and info.cwd ~= '' then
    return info.cwd
  end

  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if ok and cwd then
    -- Plain string (very old wezterm).
    if type(cwd) == 'string' and cwd ~= '' then return cwd end
    -- Url userdata (modern) or path-table (transitional) — both expose
    -- .file_path. Indexing a userdata via `.file_path` is delegated to
    -- mlua's __index, which can raise; pcall the access to be safe.
    local ok_fp, fp = pcall(function() return cwd.file_path end)
    if ok_fp and type(fp) == 'string' and fp ~= '' then return fp end
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
