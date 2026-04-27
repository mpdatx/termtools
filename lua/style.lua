-- termtools.style — opinionated WezTerm appearance / behaviour / tab-title
-- defaults. Opt in via `apply_style = true` in your termtools setup opts.
-- Per-key overrides live in `style = { … }` alongside that flag.
--
-- The intent is to centralise the styling that's worth sharing across
-- machines. Per-machine paths (TERMTOOLS, scan_roots, …) stay in your
-- ~/.wezterm.lua; everything visual lives here.

local wezterm = require('wezterm')

local M = {}

local DEFAULTS = {
  -- Font: try the patched Nerd-Font first (gives icon glyphs the command
  -- palette uses), fall back to plain Fira Code, then to wezterm's bundled
  -- JetBrains Mono. Both `FiraCode NF` (Windows naming) and `FiraCode Nerd
  -- Font` (macOS naming) are listed because the same font registers under
  -- different family names on different platforms. Size and other faces
  -- inherit wezterm's defaults.
  font_family_with_fallback = {
    'FiraCode NF',
    'FiraCode Nerd Font',
    'Fira Code',
    'JetBrains Mono',
  },
  font_size                 = 11.0,

  -- Solarized Dark — wezterm bundles it under 'Builtin Solarized Dark'.
  -- Other useful values: 'Catppuccin Mocha', 'Tokyo Night', 'Nord (base16)'.
  color_scheme              = 'Builtin Solarized Dark',

  -- Vintage / underline cursor, steady (no blinking).
  cursor_style              = 'SteadyUnderline',

  -- No OS title bar; resize handles preserved.
  window_decorations        = 'RESIZE',

  window_padding            = { left = 8, right = 8, top = 4, bottom = 4 },

  -- Inactive panes lose a bit of saturation/brightness so the focused pane
  -- is obvious without being heavy-handed about it.
  inactive_pane_hsb         = { saturation = 0.85, brightness = 0.75 },

  scrollback_lines          = 10000,
  audible_bell              = 'Disabled',
  warn_about_missing_glyphs = false,
  enable_scroll_bar         = false,
  adjust_window_size_when_changing_font_size = false,

  use_fancy_tab_bar           = false,
  hide_tab_bar_if_only_one_tab = false,
  tab_max_width               = 32,

  -- Auto-copy on left-button release (Windows Terminal / iTerm2 convention).
  copy_on_select            = true,

  -- Right-click pastes from the clipboard (Windows Terminal / PuTTY
  -- convention). No-op on macOS by user habit; safe to leave on regardless
  -- since macOS users rarely right-click in a terminal.
  right_click_paste         = true,

  -- Ctrl+Shift+Click on a selection: opens the selected text as a file in
  -- editor_cmd. Same semantics as the keybind (path:line:col parsing,
  -- relative-to-pane-cwd resolution), just on a mouse gesture so you can
  -- highlight and click without leaving the mouse.
  open_selection_on_click   = true,

  -- Format the tab title as " <idx> ▏ <claude-glyph?> <title> "; if any
  -- pane in the tab is a Claude session, that pane wins for both title and
  -- glyph regardless of focus. Strips Claude's own leading dingbat from
  -- the title to avoid double-glyph rendering.
  format_tab_title          = true,
}

local function merge(opts)
  return require('util').merge_defaults(DEFAULTS, opts)
end

local function apply_tab_title_format()
  wezterm.on('format-tab-title', function(tab, _tabs, _panes, _conf, _hover, max_width)
    local termtools = package.loaded['init']
    local glyph_of = termtools and termtools.claude_glyph_for_pane

    local representative = tab.active_pane
    if glyph_of and tab.panes then
      for _, p in ipairs(tab.panes) do
        if glyph_of(p.pane_id) then
          representative = p
          break
        end
      end
    end

    local idx = tab.tab_index + 1
    local title = (representative.title or '')
      :gsub('^Administrator: ', '')
      -- Strip a leading dingbat / arrow / braille glyph (U+2000–U+2FFF in
      -- 3-byte UTF-8) — drops the indicator Claude Code prepends to the
      -- title. Leaves CJK and other non-Latin scripts alone.
      :gsub('^\xE2[\x80-\xBF][\x80-\xBF]%s*', '')
    if title == '' then title = 'shell' end

    local glyph = glyph_of and glyph_of(representative.pane_id)
    local glyph_part = glyph and (glyph .. ' ') or ''
    local label = string.format(' %d ▏ %s%s ', idx, glyph_part, title)
    if #label > max_width then
      label = label:sub(1, max_width - 1) .. '… '
    end
    return label
  end)
end

function M.apply(config, opts)
  local s = merge(opts)

  if s.font_family_with_fallback then
    config.font = wezterm.font_with_fallback(s.font_family_with_fallback)
  end
  if s.font_size then config.font_size = s.font_size end

  if s.color_scheme              then config.color_scheme              = s.color_scheme              end
  if s.cursor_style              then config.default_cursor_style      = s.cursor_style              end
  if s.window_decorations        then config.window_decorations        = s.window_decorations        end
  if s.window_padding            then config.window_padding            = s.window_padding            end
  if s.inactive_pane_hsb         then config.inactive_pane_hsb         = s.inactive_pane_hsb         end
  if s.scrollback_lines          then config.scrollback_lines          = s.scrollback_lines          end
  if s.audible_bell              then config.audible_bell              = s.audible_bell              end
  if s.warn_about_missing_glyphs ~= nil then
    config.warn_about_missing_glyphs = s.warn_about_missing_glyphs
  end
  if s.enable_scroll_bar ~= nil then
    config.enable_scroll_bar = s.enable_scroll_bar
  end
  if s.adjust_window_size_when_changing_font_size ~= nil then
    config.adjust_window_size_when_changing_font_size = s.adjust_window_size_when_changing_font_size
  end

  if s.use_fancy_tab_bar ~= nil then
    config.use_fancy_tab_bar = s.use_fancy_tab_bar
  end
  if s.hide_tab_bar_if_only_one_tab ~= nil then
    config.hide_tab_bar_if_only_one_tab = s.hide_tab_bar_if_only_one_tab
  end
  if s.tab_max_width then
    config.tab_max_width = s.tab_max_width
  end

  if s.copy_on_select then
    config.mouse_bindings = config.mouse_bindings or {}
    table.insert(config.mouse_bindings, {
      event = { Up = { streak = 1, button = 'Left' } },
      mods  = 'NONE',
      action = wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
    })
  end

  if s.right_click_paste then
    config.mouse_bindings = config.mouse_bindings or {}
    table.insert(config.mouse_bindings, {
      event = { Down = { streak = 1, button = 'Right' } },
      mods  = 'NONE',
      action = wezterm.action.PasteFrom 'Clipboard',
    })
  end

  if s.open_selection_on_click then
    config.mouse_bindings = config.mouse_bindings or {}
    -- Binding the Down event with the explicit CTRL|SHIFT mod combo means
    -- the default "Down{Left} clears selection" path doesn't fire, so the
    -- selection persists into our handler.
    table.insert(config.mouse_bindings, {
      event = { Down = { streak = 1, button = 'Left' } },
      mods  = 'CTRL|SHIFT',
      action = wezterm.action.EmitEvent 'termtools.open-selection',
    })
  end

  if s.format_tab_title then
    apply_tab_title_format()
  end

  return config
end

return M
