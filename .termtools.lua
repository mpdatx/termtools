-- Per-project override for the termtools repo itself. Loaded by the action
-- picker when the calling pane's project root resolves to this directory.
-- Also acts as the project marker that makes termtools discoverable in the
-- project picker.

local actions = require('actions')

return {
  name = 'termtools',

  actions = {
    -- open_file resolves the default editor through util.editor_spec at
    -- fire time, dims when the file doesn't exist, and switches the
    -- description to "create <path>" in that case. Pass 'inline' as the
    -- second arg for a sibling entry that opens the file in a wezterm
    -- pane via the inline editor.
    actions.open_file('docs/plan.md', 'default'),
    actions.open_file('docs/plan.md', 'inline'),
  },
}
