-- termtools.actions — built-in action catalogue.
--
-- An action is `{ label, run, [description], [visible_when], [dimmed_when] }`:
--   label          string shown in the picker (the fuzzy-match key)
--   run(w,p,root)  callback when selected
--   description    string OR function(root) -> string. Shown alongside label.
--   visible_when   (root) -> bool. Returning false fully disables the action
--                  (sorts to bottom, dim, can't select — toasts instead).
--   dimmed_when    (root) -> bool. Returning true sorts to bottom and dims
--                  the entry but keeps it selectable. Use for "advisory"
--                  states like "file doesn't exist yet but the editor will
--                  create it on save".

local wezterm  = require('wezterm')
local act      = wezterm.action
local util     = require('util')
local platform = require('platform')

local M = {}

local function open_in_editor(target, editor_cmd)
  local template = editor_cmd or { 'code', '%s' }
  local args = platform.editor_launch_args(util.format_cmd(template, target))
  local ok, err = pcall(wezterm.background_child_process, args)
  if not ok then
    wezterm.log_error('termtools: editor launch failed: ' .. tostring(err))
  end
end

local function cmd_to_string(template, value)
  local parts = {}
  for _, p in ipairs(template) do
    if p == '%s' then parts[#parts + 1] = value else parts[#parts + 1] = p end
  end
  return table.concat(parts, ' ')
end

local function resolve_editor_cmd(override)
  if override then return override end
  local ok, init = pcall(require, 'init')
  if ok and init.opts then
    local o = init.opts()
    if o and o.editor_cmd then return o.editor_cmd end
  end
  return { 'code', '%s' }
end

-- Public factory for "open <root>/<filename> in the configured editor".
-- Reused for the built-in TODO.md / README.md entries and exposed so that
-- per-project `.termtools.lua` files can do `actions.open_file('CHANGELOG.md')`
-- without re-deriving the editor command.
function M.open_file(filename, editor_cmd_override)
  return {
    label = 'Open ' .. filename,
    description = function(root)
      local ec = resolve_editor_cmd(editor_cmd_override)
      local file_path = util.path_join(root, filename)
      if util.file_exists(file_path) then
        return cmd_to_string(ec, file_path)
      end
      return 'create ' .. file_path .. ' (file does not exist)'
    end,
    dimmed_when = function(root)
      return not util.file_exists(util.path_join(root, filename))
    end,
    run = function(_window, _pane, root)
      local ec = resolve_editor_cmd(editor_cmd_override)
      open_in_editor(util.path_join(root, filename), ec)
    end,
  }
end

function M.catalogue(opts)
  opts = opts or {}
  local editor_cmd  = opts.editor_cmd or { 'code', '%s' }
  -- opts.default_cmd is always populated by init.setup() (it falls through
  -- to a per-OS default), so no fallback is needed here.
  local default_cmd = opts.default_cmd
  local claude_cmd  = opts.claude_cmd  or { 'claude' }

  local default_cmd_str = table.concat(default_cmd, ' ')
  local claude_cmd_str  = table.concat(claude_cmd, ' ')

  local list = {
    {
      label = 'Open project in editor',
      description = function(root) return cmd_to_string(editor_cmd, root) end,
      run = function(_window, _pane, root)
        open_in_editor(root, editor_cmd)
      end,
    },
    M.open_file('TODO.md', editor_cmd),
    M.open_file('README.md', editor_cmd),
    {
      label = 'New Claude pane',
      description = 'split right; ' .. claude_cmd_str .. ' at project root',
      run = function(window, pane, root)
        window:perform_action(act.SplitPane {
          direction = 'Right',
          command = { args = claude_cmd, cwd = root },
        }, pane)
      end,
    },
    {
      label = 'New shell pane',
      description = 'split down; ' .. default_cmd_str .. ' at project root',
      run = function(window, pane, root)
        window:perform_action(act.SplitPane {
          direction = 'Down',
          command = { args = default_cmd, cwd = root },
        }, pane)
      end,
    },
    {
      label = 'New tab at project root',
      description = 'spawn tab; ' .. default_cmd_str .. ' at project root',
      run = function(window, pane, root)
        window:perform_action(act.SpawnCommandInNewTab {
          cwd = root, args = default_cmd,
        }, pane)
      end,
    },
    {
      label = 'Refresh projects',
      description = 'invalidate the project discovery cache',
      run = function(window, _pane, _root)
        require('projects').discover_refresh()
        if window then
          window:toast_notification('termtools', 'Project cache refreshed.', nil, 2000)
        end
      end,
    },
  }

  -- One "New tab: <profile>" per non-hidden Windows Terminal profile when
  -- wt_profiles is enabled. Appended after built-ins so they don't crowd
  -- the top of the picker; fuzzy filter handles long lists.
  if opts._wt and type(opts._wt.list) == 'table' then
    for _, profile in ipairs(opts._wt.list) do
      local args = profile.args
      local args_str = table.concat(args, ' ')
      list[#list + 1] = {
        label = 'New tab: ' .. profile.name,
        description = args_str,
        run = function(window, pane, root)
          window:perform_action(act.SpawnCommandInNewTab {
            cwd = root, args = args,
          }, pane)
        end,
      }
    end
  end

  return list
end

return M
