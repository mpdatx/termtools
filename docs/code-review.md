# Code review — Lua codebase

Three parallel reviews covering bad practices, refactoring opportunities, and code-reuse opportunities. This doc consolidates findings, drops false positives, and proposes an order of attack. Nothing is fixed yet — only catalogued.

## Methodology

Each agent read the full Lua surface (`include.lua`, `lua/init.lua`, `lua/pickers.lua`, `lua/projects.lua`, `lua/actions.lua`, `lua/claude.lua`, `lua/style.lua`, `lua/util.lua`, `lua/wt.lua`, `lua/platform.lua`, `lua/platform/{windows,darwin}.lua`, `.termtools.lua`). Findings below are deduplicated; `[file:line]` references are precise.

## Confirmed bugs

1. **`pickers.lua` action picker — root may be nil after early-return is skipped.**
   In `M.run_action_picker` (line ~335), if `pane_cwd(pane)` returns nil, `projects.find_root(nil)` returns nil and `root = nil or cwd = nil`. The `if not root then toast end return` block does fire, so this is **defensive working-as-intended**, not a bug. Reviewer flagged it; on inspection the early return prevents the downstream nil deref. **Filed as: false positive.**

2. **`wt.lua:84` — silent JSON-decode error if neither parser API exists.**
   `json_decode` calls `error()` if both `wezterm.serde.json_decode` and `wezterm.json_parse` are missing. Caught by the surrounding `pcall` in `read_profiles`, returning `nil`. User sees no diagnostic. Severity: **nit** — neither parser missing requires a very old WezTerm; logging the failure once would be enough.

3. **`claude.lua:132` — `glyph_for_pane` returns the waiting glyph for stuck state.**
   *This is intentional.* User asked to collapse waiting + stuck into one ✱ at the tab level (the age detail is preserved internally and surfaced inside the session picker). The agent flagged it as a bug; it's a deliberate design choice. **Filed as: false positive.**

**Net real bugs: 0.** The codebase is in better shape than the agents' bug counts suggested.

## High-priority refactors (all three reviewers converged)

### A. Split `lua/pickers.lua` (currently 519 lines, five distinct concerns)

The file holds: project picker, action picker, action-by-label dispatch, open-selection logic, MRU/sort/format helpers, pane-walk helpers, and EmitEvent shims.

**Proposal:**
```
lua/pickers/
  project.lua    -- run_project_picker, sort, format_project_label, MRU
  action.lua     -- run_action_picker, build_action_list, run_action_by_label
  selection.lua  -- run_open_selection (path:line:col parsing, editor launch)
  state.lua      -- count_tabs_per_root, find_existing_pane_in_window,
                    pane_cwd, MRU helpers
lua/pickers.lua   -- thin facade: re-exports + EmitEvent shims
```
Each sub-module ends up ~80-120 lines. The shims stay where callers (init.lua, command palette) import from now, so external callers don't change.
**Effort:** Medium. **Impact:** High — unlocks (B) and (C).

### B. Extract `util.foreach_pane(callback)` and migrate three callers

Same nested loop appears three times:
- `claude.lua:108-126` (`M.scan` — classify per-pane state)
- `pickers.lua:170-197` (`count_tabs_per_root` — count distinct tabs per root)
- `pickers.lua:41-54` (`find_existing_pane_in_window` — find first match in current window)

**Proposal:** A single `util.foreach_pane(fn, opts)` that walks all mux windows × tabs × panes (or `current_window_only=true`), calls `fn(window, tab, pane, cwd)` per pane (with cwd already resolved via `pane_cwd`), and returns a list of whatever `fn` returns. Three call sites collapse to ~5 lines each.
**Effort:** Small once (A) lands. **Impact:** High — eliminates the most-duplicated loop and an inconsistency (one walker reads CWD differently from the others).

### C. Unify the merge-defaults pattern

Three near-identical implementations:
- `init.lua:50-52` (`shallow_merge`)
- `style.lua:67-72` (`merge`)
- `claude.lua:307-311` (inline copy in `setup`)

**Proposal:** `util.merge_defaults(defaults, user_opts)` returns the merged table. All three modules call it from their `setup`. Consider a `recursive=true` option for the nested-DEFAULTS work in (D).
**Effort:** Small. **Impact:** Medium — boilerplate down, single source of truth for "how config merges."

## Medium-priority refactors

### D. Group `init.lua` DEFAULTS into sections

Currently 18+ flat keys mixing hotkeys, paths, feature flags, and nested style/claude tables. Proposed grouping:

```lua
DEFAULTS = {
  hotkeys  = { default_keys=false, project_key={...}, action_key={...},
               claude_next_key={...}, open_selection_key=false },
  paths    = { scan_roots={}, pinned={}, trusted_paths={}, markers=nil },
  features = { wt_profiles=false, claude_indicators=false, apply_style=false },
  project_picker = { sort='smart' },
  editors  = { editor_cmd={'code','%s'}, default_cmd=nil, claude_cmd={'claude'} },
  style    = {},   -- forwarded
  claude   = {},   -- forwarded
}
```
Requires (C)'s `merge_defaults` to recurse one level. Backward-compat shim during migration is straightforward (alias old flat keys to nested locations).
**Effort:** Small (after C). **Impact:** Medium — discoverability.

### E. Extract `M.palette_entries` into `lua/palette.lua`

Currently in init.lua (~40 lines), reaches into pickers and projects. Pure consumer of those modules; doesn't belong in init.
**Effort:** Small. **Impact:** Medium.

### F. Move `actions.resolve_editor_cmd` to `util` and pass `opts` explicitly

`actions.lua:38-46` does a lazy `require('init')` to read `editor_cmd` from current opts. This is a soft circular dependency — fine today, fragile if anything reorganises. Make it a pure util that takes `(override, opts)`.
**Effort:** Small. **Impact:** Medium — explicit dataflow.

### G. Consolidate editor launch through `actions.open_in_editor`

`pickers.lua:488-503` (`run_open_selection`) duplicates the format-cmd → platform-launch-wrap → background_child_process pipeline that `actions.open_in_editor` already implements. Diverges in one detail (the `--goto` special case for VS Code). Fold the special case into a small `open_in_editor` extension that accepts an optional line/col pair.
**Effort:** Small. **Impact:** Medium — single editor-spawn path.

## Low-priority / nits

- **`init.lua` event-handler plumbing (`init.lua:251-274`)** — three `wezterm.on` registrations follow the same shape (`function(window, pane) pickers.run_X(window, pane, M.opts()) end`). A trivial `register_dispatch(name, run_fn)` helper would shave ~15 lines but adds an indirection layer. Bikeshed; defer until there are 5+ events.

- **`actions.lua:30-36` (`cmd_to_string`)** — duplicates logic that's almost in `util.format_cmd` modulo concat-vs-array output. Either delete `cmd_to_string` and have callers do `table.concat(util.format_cmd(...), ' ')`, or push `cmd_to_string` into util. Tiny.

- **`pickers.lua` `PICKER_COLOR` (`pickers.lua:225-231`)** — hardcoded hex palette, not configurable via opts (unlike `claude.status_color`). Move to a `style.picker_colors` group when it comes up. Defer.

- **`claude.lua` redundant `tostring()` in `lower()` helper (line 56)** — tolerates non-string patterns silently. An `assert(type(pat)=='string')` at registration time would catch typos earlier. Tiny.

- **`projects.lua:63` opts signature uses `\0` separator** — fragile if any path contained a literal null byte (it never does). Cosmetic.

- **`pickers.lua:288` (and twin in action picker)** — choice ID is `tostring(i)` then `tonumber(id)` to look up. The string round-trip is wezterm's API requirement — InputSelector ids are strings — so this is unavoidable. **False positive.**

- **`include.lua:46`** — `local termtools = require('init')` then immediate use. The local is fine; renaming would not improve it. **False positive.**

- **`util.is_windows` / `util.is_macos` re-exports** — kept intentionally for backward compatibility with the platform refactor; many callers still use them. **Not removable without a sweep; leave.**

- **`pickers.M.pane_cwd` exported** — intentional; `claude.lua` uses it via `require('pickers').pane_cwd`. **Not unused.**

- **Late event registration in style's `apply_tab_title_format`** — `style.apply()` is called once per `init.apply()`, which is once per config reload. Each reload creates a new Lua state, so registrations don't stack across reloads. Within a single state, `apply()` runs once. **Filed as: false positive.**

## Items that look like duplication but aren't worth unifying

- **Argv-pattern matching in `claude.is_claude_pane` and `pickers.looks_like_vscode`** — semantically different (one searches a pattern list, the other special-cases two known executables). A general `argv_contains(argv, patterns)` helper would over-abstract.

- **Module-level caching across `projects`, `claude`, `pickers`** — three distinct lifetimes (process-bound, single-config-reload, persistent via `wezterm.GLOBAL`). Unifying behind a generic memoizer would obscure semantics.

- **Three picker-scaffolding loops (project, action, claude session)** — they look similar (gather → sort → format → InputSelector → callback) but each has materially different sort/format/dispatch logic. A `util.input_selector(spec)` is the right shape *eventually* (when there are 4+ pickers), but designing the DSL now would over-abstract for three.

## Recommended order of attack

When/if we pick up this work:

1. **(B) `util.foreach_pane`** — smallest, lowest risk, deletes ~50 lines of duplication. Independent of everything else.
2. **(C) `util.merge_defaults`** — small, unblocks (D). Touches three modules cleanly.
3. **(F) move `resolve_editor_cmd` to util** — small, removes a soft cycle. Independent.
4. **(G) consolidate editor launch** — small, builds on (F).
5. **(A) split `pickers.lua`** — medium effort. Best done after (B) since the new shared walker module reduces duplication that the split would otherwise carry into each sub-module.
6. **(D) nest DEFAULTS** — depends on (C); ergonomic-only, do when convenient.
7. **(E) extract palette.lua** — small, do alongside or after (A).

(1)-(4) are all small and independent — could land in one sitting. (A) and (D) are the meatier structural moves.

## Items closed without action

The bugs flagged by the quality reviewer are either intentional design (the waiting/stuck glyph collapse) or already defensive (the action-picker nil-cwd path bails before any nil deref). The codebase has no genuine pre-existing bugs surfaced by this review.
