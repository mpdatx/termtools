# WezTerm Lua Cookbook

A capability-oriented reference to the WezTerm Lua API — what we can do from termtools, how to do it, and the traps we've run into. Written for "plan future work" rather than as an exhaustive API mirror; the upstream docs at <https://wezterm.org/config/lua/general.html> are authoritative.

Each topic lives in its own file. They're meant to be skim-read; cross-references between files are explicit, not assumed.

## How to use this

- **Looking up a concrete API**: jump straight to wezterm.org. The cookbook gives orientation, not signatures-of-record.
- **Planning a new feature**: skim the relevant topic file. Each one ends with a *gotchas* section listing the non-obvious traps we'd hit.
- **Reusing a working pattern**: examples in each file are pulled from termtools' actual code where possible, with file-and-line citations so you can read the surrounding context.

## Topics

| File | Covers |
| ---- | ------ |
| [01-architecture.md](01-architecture.md) | GUI vs mux model, config evaluation lifecycle, where Lua runs |
| [02-modules.md](02-modules.md) | The `wezterm.*` module catalogue (mux, gui, color, time, serde, procinfo, url, plugin) |
| [03-config.md](03-config.md) | Config object, `config_builder()`, schema overview, hot reload |
| [04-pane-window-tab.md](04-pane-window-tab.md) | The GUI object trio: Pane / Window / Tab — methods, CWD/process info, content access |
| [05-mux-and-workspaces.md](05-mux-and-workspaces.md) | `wezterm.mux`, MuxWindow/Tab/Pane, workspace ops |
| [06-spawning.md](06-spawning.md) | `SpawnCommand`, `spawn_tab` / `spawn_window`, `background_child_process`, `run_child_process` |
| [07-splits.md](07-splits.md) | `pane:split` vs `SplitPane` action, direction-name quirks, focus behaviour |
| [08-actions-and-keys.md](08-actions-and-keys.md) | `KeyAssignment` types, `action_callback`, `EmitEvent`, `config.keys`, leader & key tables |
| [09-mouse.md](09-mouse.md) | `mouse_bindings`, scroll/click/drag, semantic-zone hit-testing |
| [10-events.md](10-events.md) | `wezterm.on`, lifecycle events (gui-startup, mux-startup, etc.), custom events |
| [11-pickers.md](11-pickers.md) | `InputSelector`, `PromptInputLine`, `alphabet` quick-select, no-wrap & timing gotchas |
| [12-state-and-timing.md](12-state-and-timing.md) | `wezterm.GLOBAL`, `config_dir`, `time.call_after`, sync vs async child processes |
| [13-format-and-colors.md](13-format-and-colors.md) | `wezterm.format`, `wezterm.color` manipulation, color schemes |
| [14-tab-bar-and-status.md](14-tab-bar-and-status.md) | `format-tab-title`, `format-window-title`, `update-right-status` |
| [15-osc-and-clipboard.md](15-osc-and-clipboard.md) | OSC 7 / 9;9 / 1337, custom OSC handlers, copy/paste, selection access |
| [16-domains.md](16-domains.md) | Local, SSH, WSL, mux (tls/unix), exec domains |
| [17-palette.md](17-palette.md) | `augment-command-palette` event, `PaletteEntry` shape |
| [18-procinfo-and-platform.md](18-procinfo-and-platform.md) | `wezterm.procinfo`, `target_triple`, `home_dir`, OS quirks |
| [19-io-and-logging.md](19-io-and-logging.md) | `read_dir`, `log_info/warn/error`, `run_child_process`, log file location |

## Conventions

Each topic file follows the same outline:

1. **Overview** — what the surface is, when you'd reach for it.
2. **Key APIs** — names + one-line description; full signatures live on wezterm.org.
3. **Examples** — runnable snippets. Where termtools already uses the API, the example cites our own code (`lua/<file>.lua:<line>`).
4. **Gotchas** — non-obvious traps. Includes anything we've personally been bitten by.
5. **See also** — pointers to neighbouring topics.

## Out of scope

- The `wezterm cli` subcommand interface (separate surface, not Lua).
- Configuration keys that are pure visual tweaks (font fallback chains, glyph cache, etc.) — wezterm.org's [config/lua/config](https://wezterm.org/config/lua/config/) page is the right place.
- Completeness — if a niche API isn't here and you need it, go upstream.
