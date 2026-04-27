-- Per-project override for the termtools repo itself. Loaded by the action
-- picker when the calling pane's project root resolves to this directory.
-- Also acts as the project marker that makes termtools discoverable in the
-- project picker.

local actions = require('actions')

return {
  name = 'termtools',

  actions = {
    -- open_file picks up editor_cmd from setup, dims when the file doesn't
    -- exist, and switches the description to "create <path>" in that case.
    actions.open_file('docs/plan.md'),
  },
}
