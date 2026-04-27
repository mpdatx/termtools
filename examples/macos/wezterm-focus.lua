-- Hammerspoon recipe: global hotkey to focus WezTerm.
--
-- Install:
--   1. Install Hammerspoon (https://www.hammerspoon.org).
--   2. Add this line to ~/.hammerspoon/init.lua, with the path adjusted:
--        dofile(os.getenv('HOME')..'/path/to/termtools/examples/macos/wezterm-focus.lua')
--   3. Reload Hammerspoon ("Reload Config" in the menu bar).
--
-- Behavior: pressing the hotkey brings WezTerm to the foreground if it's
-- running. No-op when WezTerm isn't running — does not launch it.

local HOTKEY = { mods = { 'ctrl', 'alt', 'cmd' }, key = 'space' }
local BUNDLE_ID = 'com.github.wez.wezterm'

local function focus()
  local app = hs.application.applicationsForBundleID(BUNDLE_ID)[1]
  if not app then return end
  app:activate(true)
  local win = app:focusedWindow() or app:mainWindow()
  if win then win:focus() end
end

hs.hotkey.bind(HOTKEY.mods, HOTKEY.key, focus)
