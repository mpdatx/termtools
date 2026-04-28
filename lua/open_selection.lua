-- termtools.open_selection — read the active pane's selection and open it
-- as a file in the configured editor.
--
-- Not really a "picker" (no modal); kept at the top of lua/ rather than
-- under pickers/. Triggered by either a hotkey (opt-in via
-- `open_selection_key`) or the Ctrl+Shift+Click mouse binding wired by
-- lua/style.lua.

local util    = require('util')
local actions = require('actions')

local M = {}

local function strip_quotes_and_ws(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', '')
           :gsub('^["\']', ''):gsub('["\']$', ''))
end

local function is_absolute(path)
  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
end

function M.run(window, pane, opts)
  opts = opts or {}
  local raw = window:get_selection_text_for_pane(pane)
  if not raw or raw == '' then
    window:toast_notification('termtools',
      'No selection — highlight a file path first.', nil, 1500)
    return
  end

  local text = strip_quotes_and_ws(raw)
  if text == '' then return end

  -- Try path:line:col, then path:line, then bare path.
  local path, line, col = text:match('^(.+):(%d+):(%d+)$')
  if not path then
    path, line = text:match('^(.+):(%d+)$')
  end
  if not path then path = text end

  if not is_absolute(path) then
    local cwd = util.pane_cwd(pane)
    if cwd then path = util.path_join(cwd, path) end
  end

  if not util.file_exists(path) then
    window:toast_notification('termtools',
      'No such file: ' .. path, nil, 2500)
    return
  end

  -- Single editor-launch path lives in actions.open_in_editor; we just hand
  -- it the resolved path plus the optional line/col so it can pick the
  -- --goto form when the editor supports it.
  local editor_cmd = opts.editor_cmd or { 'code', '%s' }
  actions.open_in_editor(path, editor_cmd,
    line and { line = tonumber(line), col = tonumber(col) } or nil)
end

return M
