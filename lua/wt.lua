-- termtools.wt — read Windows Terminal's settings.json so we can reuse the
-- profiles you've already configured (default shell + per-profile spawn
-- actions). All entry points return nil/empty rather than erroring; callers
-- treat absence of WT as "no profiles available".

local util = require('util')

local M = {}

local CANDIDATE_PATHS = {
  -- Store install
  'Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json',
  -- Preview Store install
  'Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json',
  -- Unpackaged install
  'Microsoft/Windows Terminal/settings.json',
}

function M.locate_settings()
  local localappdata = os.getenv('LOCALAPPDATA')
  if not localappdata then return nil end
  for _, rel in ipairs(CANDIDATE_PATHS) do
    local full = util.path_join(localappdata, rel)
    if util.file_exists(full) then return full end
  end
  return nil
end

local function read_file(path)
  local f, err = io.open(path, 'rb')
  if not f then return nil, err end
  local content = f:read('*a')
  f:close()
  return content
end

-- Strip JSONC artefacts (line comments, block comments, trailing commas).
-- Tracks string state so it doesn't molest comment-like sequences inside
-- string literals.
function M.strip_jsonc(s)
  local out, i, in_string, escape = {}, 1, false, false
  while i <= #s do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if escape then
        escape = false
      elseif c == '\\' then
        escape = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == '/' and s:sub(i + 1, i + 1) == '/' then
      while i <= #s and s:sub(i, i) ~= '\n' do i = i + 1 end
    elseif c == '/' and s:sub(i + 1, i + 1) == '*' then
      i = i + 2
      while i <= #s do
        if s:sub(i, i + 1) == '*/' then i = i + 2; break end
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  local stripped = table.concat(out)
  stripped = stripped:gsub(',(%s*[%]}])', '%1')
  return stripped
end

local function json_decode(s)
  local wezterm = require('wezterm')
  if wezterm.serde and wezterm.serde.json_decode then
    return wezterm.serde.json_decode(s)
  end
  if wezterm.json_parse then
    return wezterm.json_parse(s)
  end
  error('no JSON decoder available in this wezterm version')
end

-- Expand %FOO% references using the current process env.
local function expand_env(s)
  return (s:gsub('%%([^%%]+)%%', function(name)
    return os.getenv(name) or ('%' .. name .. '%')
  end))
end

-- Tokenise a Windows-style command line into argv. Handles double-quoted
-- spans; doesn't implement the full backslash-escape rules of
-- CommandLineToArgvW (which are rare in WT profiles).
function M.split_commandline(s)
  local args, cur, in_quotes = {}, nil, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_quotes = not in_quotes
      cur = cur or ''
    elseif c:match('%s') and not in_quotes then
      if cur then args[#args + 1] = cur; cur = nil end
    else
      cur = (cur or '') .. c
    end
  end
  if cur then args[#args + 1] = cur end
  return args
end

local function args_for_profile(p)
  if type(p.commandline) == 'string' then
    local expanded = expand_env(p.commandline)
    local args = M.split_commandline(expanded)
    if #args > 0 then return args end
  end
  if p.source == 'Windows.Terminal.Wsl' and type(p.name) == 'string' then
    return { 'wsl.exe', '-d', p.name }
  end
  return nil
end

-- Returns { list = { { name, args, guid, hidden }, ... },
--           default = entry-or-nil,
--           settings_path = string }
-- or nil if WT settings can't be located/parsed.
function M.read_profiles()
  local path = M.locate_settings()
  if not path then return nil end
  local raw, err = read_file(path)
  if not raw then return nil, err end

  local ok, parsed = pcall(function()
    return json_decode(M.strip_jsonc(raw))
  end)
  if not ok or type(parsed) ~= 'table' then return nil end

  local profiles = parsed.profiles
  local raw_list = (type(profiles) == 'table' and profiles.list) or nil
  if type(raw_list) ~= 'table' then return nil end

  local list = {}
  for _, p in ipairs(raw_list) do
    if type(p) == 'table' and not p.hidden then
      local args = args_for_profile(p)
      if args then
        list[#list + 1] = {
          name = p.name or p.guid or 'unnamed',
          args = args,
          guid = p.guid,
          hidden = false,
        }
      end
    end
  end

  local default_guid = parsed.defaultProfile
  local default_entry
  if type(default_guid) == 'string' then
    for _, entry in ipairs(list) do
      if entry.guid == default_guid then
        default_entry = entry
        break
      end
    end
  end

  return {
    list = list,
    default = default_entry,
    settings_path = path,
  }
end

return M
