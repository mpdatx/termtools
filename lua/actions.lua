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

local M = {}

-- Spawn the configured editor on `target` (a file path or directory).
-- editor_spec is `{ cmd = {...}, kind = 'external' | 'pane', direction? }`.
-- position is optional `{ line = N, col = N }` — only honoured for
-- VS Code / Cursor external editors (--goto path:line:col).
function M.open_in_editor(window, pane, target, editor_spec, position)
  if not editor_spec or not editor_spec.cmd then return end

  local args
  if editor_spec.kind == 'external' and position and position.line
      and util.looks_like_vscode_editor(editor_spec.cmd) then
    local goto_target = position.col
      and (target .. ':' .. position.line .. ':' .. position.col)
      or  (target .. ':' .. position.line)
    args = { editor_spec.cmd[1], '--goto', goto_target }
  else
    args = util.format_cmd(editor_spec.cmd, target)
  end

  if editor_spec.kind == 'pane' then
    if not window or not pane then return end
    window:perform_action(wezterm.action.SplitPane {
      direction = editor_spec.direction or 'Right',
      command   = { args = args },
    }, pane)
  else
    args = require('platform').editor_launch_args(args)
    local ok, err = pcall(wezterm.background_child_process, args)
    if not ok then
      wezterm.log_error('termtools: editor launch failed: ' .. tostring(err))
    end
  end
end

-- Local alias for in-file callers below.
local open_in_editor = M.open_in_editor

local function cmd_to_string(template, value)
  local parts = {}
  for _, p in ipairs(template) do
    if p == '%s' then parts[#parts + 1] = value else parts[#parts + 1] = p end
  end
  return table.concat(parts, ' ')
end

-- Public factory for "open <root>/<filename> in the configured editor".
-- `role` is 'default' (an external editor — VS Code etc.) or 'inline'
-- (a terminal editor in a wezterm pane — nvim etc.). Returns one action;
-- callers wanting both variants call open_file twice.
function M.open_file(filename, role)
  role = role or 'default'
  local label_suffix = role == 'inline' and ' inline' or ''
  return {
    label = 'Open ' .. filename .. label_suffix,
    description = function(root)
      local opts = require('init').opts()
      local spec = util.editor_spec(role, opts)
      local file_path = util.path_join(root, filename)
      if not spec then
        return role == 'inline' and 'no inline editor configured' or 'no default editor configured'
      end
      if util.file_exists(file_path) then
        return cmd_to_string(spec.cmd, file_path)
      end
      return 'create ' .. file_path .. ' (file does not exist)'
    end,
    dimmed_when = function(root)
      return not util.file_exists(util.path_join(root, filename))
    end,
    run = function(window, pane, root)
      local opts = require('init').opts()
      local spec = util.editor_spec(role, opts)
      if not spec then
        if role == 'inline' and window then
          window:toast_notification('termtools',
            'inline editor not configured.', nil, 1500)
        end
        return
      end
      open_in_editor(window, pane, util.path_join(root, filename), spec)
    end,
  }
end

function M.catalogue(opts)
  opts = opts or {}
  -- opts.default_cmd is always populated by init.setup() (it falls through
  -- to a per-OS default), so no fallback is needed here.
  local default_cmd = opts.default_cmd
  local claude_cmd  = opts.claude_cmd  or { 'claude' }

  local default_cmd_str = table.concat(default_cmd, ' ')
  local claude_cmd_str  = table.concat(claude_cmd, ' ')

  local list = {
    {
      label = 'Open project in editor',
      description = function(root)
        local spec = util.editor_spec('default', opts)
        if not spec then return 'no default editor configured' end
        return cmd_to_string(spec.cmd, root)
      end,
      run = function(window, pane, root)
        local spec = util.editor_spec('default', opts)
        if not spec then return end
        open_in_editor(window, pane, root, spec)
      end,
    },
    M.open_file('TODO.md', 'default'),
    M.open_file('TODO.md', 'inline'),
    M.open_file('README.md', 'default'),
    M.open_file('README.md', 'inline'),
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
    {
      label = 'Cycle project sort',
      description = function()
        return 'currently: ' .. require('pickers').current_project_sort()
      end,
      run = function(window, _pane, _root)
        local new_mode = require('pickers').cycle_project_sort()
        if window then
          window:toast_notification('termtools',
            'Project sort: ' .. new_mode, nil, 1500)
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
