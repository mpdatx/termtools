-- termtools.projects — project root resolution, discovery, and per-project
-- override loading.

local util     = require('util')
local platform = require('platform')

local M = {}

local DEFAULT_MARKERS = {
  '.git', '.termtools.lua', 'CLAUDE.md',
  'package.json', 'pyproject.toml', 'Cargo.toml',
}

-- Module-level caches. discover_refresh() invalidates both.
local cache = {
  discovered = nil,
  opts_key = nil,
  overrides = {}, -- normalized root path -> override table (or false for negative cache)
}

local function build_marker_set(markers)
  local s = {}
  for _, m in ipairs(markers) do s[m] = true end
  return s
end

-- One read_dir per directory, then a hash lookup per entry. Cheaper on
-- Windows than N stat calls for large marker lists or deep walk-ups.
local function dir_contains_any(dir, marker_set)
  local ok_wt, wezterm = pcall(require, 'wezterm')
  if ok_wt and wezterm.read_dir then
    local ok, entries = pcall(wezterm.read_dir, dir)
    if ok and type(entries) == 'table' then
      for _, full in ipairs(entries) do
        local name = full:match('([^/\\]+)$') or full
        if marker_set[name] then return true end
      end
    end
    return false
  end
  for name, _ in pairs(marker_set) do
    local p = util.path_join(dir, name)
    if util.file_exists(p) or util.dir_exists(p) then return true end
  end
  return false
end

function M.find_root(cwd, markers)
  if not cwd then return nil end
  local marker_set = build_marker_set(markers or DEFAULT_MARKERS)
  local dir = util.normalize(cwd)
  while dir do
    if dir_contains_any(dir, marker_set) then return dir end
    if util.is_root(dir) then break end
    dir = util.parent_dir(dir)
  end
  return nil
end

local function opts_signature(opts)
  local parts = {}
  for _, r in ipairs(opts.scan_roots or {}) do parts[#parts + 1] = 's:' .. r end
  for _, p in ipairs(opts.pinned or {}) do parts[#parts + 1] = 'p:' .. p end
  for _, m in ipairs(opts.markers or DEFAULT_MARKERS) do parts[#parts + 1] = 'm:' .. m end
  return table.concat(parts, '\0')
end

function M.discover(opts)
  opts = opts or {}
  local sig = opts_signature(opts)
  if cache.discovered and cache.opts_key == sig then
    return cache.discovered
  end

  local marker_set = build_marker_set(opts.markers or DEFAULT_MARKERS)
  local ok_wt, wezterm = pcall(require, 'wezterm')
  local seen, list = {}, {}

  local function add(path, source)
    local norm = util.normalize(path)
    local key = platform.fs_case_insensitive and norm:lower() or norm
    if seen[key] then return end
    local entry = { path = norm, name = util.basename(norm), source = source }
    seen[key] = entry
    list[#list + 1] = entry
  end

  for _, root in ipairs(opts.scan_roots or {}) do
    if ok_wt and wezterm.read_dir then
      local ok_read, entries = pcall(wezterm.read_dir, util.normalize(root))
      if ok_read and type(entries) == 'table' then
        for _, child in ipairs(entries) do
          if dir_contains_any(child, marker_set) then add(child, 'scan') end
        end
      end
    end
  end

  for _, path in ipairs(opts.pinned or {}) do add(path, 'pinned') end

  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)

  cache.discovered = list
  cache.opts_key = sig
  return list
end

function M.discover_refresh()
  cache.discovered = nil
  cache.opts_key = nil
  cache.overrides = {}
end

-- Load <root>/.termtools.lua if root is inside one of `trusted_paths`.
-- Trust is the entire security model: untrusted paths are ignored. There is
-- no Lua sandbox, because override files are expected to register callbacks
-- that need real wezterm APIs (SplitPane, SpawnTab, etc.) anyway.
function M.load_overrides(root, trusted_paths)
  if not root then return nil end
  local norm_root = util.normalize(root)
  local cached = cache.overrides[norm_root]
  if cached ~= nil then
    return cached or nil
  end

  local function miss()
    cache.overrides[norm_root] = false
    return nil
  end

  local trusted = false
  for _, t in ipairs(trusted_paths or {}) do
    if util.is_inside(norm_root, t) then trusted = true; break end
  end
  if not trusted then return miss() end

  local override_path = util.path_join(norm_root, '.termtools.lua')
  if not util.file_exists(override_path) then return miss() end

  local ok, result = pcall(dofile, override_path)
  if not ok then
    local ok_wt, wezterm = pcall(require, 'wezterm')
    if ok_wt then
      wezterm.log_error(string.format(
        'termtools: failed to load %s: %s', override_path, tostring(result)))
    end
    return miss()
  end
  if type(result) ~= 'table' then return miss() end

  cache.overrides[norm_root] = result
  return result
end

return M
