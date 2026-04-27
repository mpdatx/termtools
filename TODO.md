* Code review of existing LUA to identify bad practices, opportunities for refactoring or code reuse
* Better project-level documentation of wezterm capabilities via LUA to plan future work
* Easier workflow to create a new project
* Can we make this project's configs editable via wezterm or is that a bad idea?
* Wire up `wezterm-mux-server` so panes survive a GUI restart. Run it as a daemon at login (Task Scheduler on Windows, launchd plist on macOS), expose a unix-domain mux in the wezterm config, and route new spawns through that domain. Lets us reload-vs-restart without losing long-running Claude sessions.
* Termtools settings UI via JSON sidecar (the VS Code `settings.json` pattern adapted for WezTerm). Sketch:
  * Sidecar at `~/.config/termtools/settings.json` holding a flat map of opt overrides (`{"apply_style": true, "claude_indicators": true, "style": {"color_scheme": "Tokyo Night"}}`).
  * `init.setup()` reads the sidecar at config-reload time and merges it on top of the user's inline opts (sidecar wins, since it's the "live edited" surface).
  * New action: `Termtools settings` — top-level entry in the action picker. Opens an `InputSelector` listing every opt with `<key>: <current value>`. Selecting one routes by type:
    * boolean → toggle and write back
    * enum (color scheme, cursor style, etc.) → secondary `InputSelector` from a known choice list
    * free-form (font size, paths, hex colors) → `PromptInputLine`, validate, write back
    * table (style, claude) → recurse into a sub-picker showing that table's keys
  * After write, fire `wezterm.action.ReloadConfiguration` so the change applies immediately.
  * Persistence is JSON via `wezterm.serde.json_encode` + `io.open(...,'w')`; pretty-print with 2-space indent for diffability.
  * Editing `wezterm.lua` programmatically is explicitly out of scope (loses comments/formatting). The sidecar is the single source of truth for "live" overrides.
  * Worth doing once we find ourselves flipping opts often enough that editing the file is friction. Until then, defer.

