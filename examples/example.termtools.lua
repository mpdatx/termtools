-- Example .termtools.lua — drop one of these at the root of any project that
-- lives under a `trusted_paths` entry. termtools loads it once per session
-- (cached) and merges the actions in below over the built-in catalogue.
--
-- The full WezTerm Lua API is available at the top of the file (this is a
-- regular Lua chunk, not sandboxed — the trust gate is your only safety net).

local wezterm = require('wezterm')
local actions = require('actions')

return {
  -- Override the display name in the picker. Defaults to the directory name.
  name = 'My Project',

  -- Override what the project picker spawns when there's no existing tab
  -- for this project.
  default_cmd = { 'pwsh', '-NoLogo' },

  -- Add or override actions. By-label match: an entry with the same label
  -- as a built-in replaces the built-in.
  actions = {
    {
      label = 'Run unit tests',
      description = 'split down; npm test in a kept-open shell',
      run = function(window, pane, root)
        window:perform_action(
          wezterm.action.SplitPane {
            direction = 'Down',
            command = {
              args = { 'pwsh', '-NoExit', '-Command', 'npm test' },
              cwd = root,
            },
          },
          pane
        )
      end,
    },
    {
      label = 'Tail server log',
      description = 'open a new tab tailing logs/server.log',
      -- dimmed_when: the action stays selectable but renders dim/grey when
      -- the log file isn't there yet — handy for projects that only create
      -- the log on first run.
      dimmed_when = function(root)
        local f = io.open(root .. '/logs/server.log', 'r')
        if f then f:close() return false end
        return true
      end,
      run = function(window, pane, root)
        window:perform_action(
          wezterm.action.SpawnCommandInNewTab {
            cwd = root,
            args = { 'pwsh', '-NoExit', '-Command', 'Get-Content', '-Wait', '-Tail', '40', 'logs/server.log' },
          },
          pane
        )
      end,
    },

    -- Reuse the built-in factory to add more "Open <file>" entries with the
    -- same dim-when-missing behaviour as the built-in TODO/README actions.
    actions.open_file('CHANGELOG.md'),
    actions.open_file('docs/architecture.md'),
  },
}
