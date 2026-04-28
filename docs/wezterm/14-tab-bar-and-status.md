# 14 — Tab bar, window title, and status

The strips of text wezterm draws around your panes — tab labels along the bar, the OS window title, and the left/right status zones on the same bar — are all driven by the same trio of events. This file covers the three of them as one surface; for the underlying mechanics see [10-events.md](10-events.md), and for the styled-string format see [13-format-and-colors.md](13-format-and-colors.md).

## Overview

There are three customisation points, each with a dedicated event:

| Surface | Event | What it returns |
| ------- | ----- | --------------- |
| **Per-tab label** in the tab bar | `format-tab-title` | a string, or a `FormatItem[]` array |
| **OS window title** (and `tab_title` fallback inside termtools) | `format-window-title` | a string |
| **Left / right status strips** on the tab bar | `update-status` (modern) or `update-right-status` (legacy) | nothing — the handler instead calls `window:set_left_status` / `window:set_right_status` |

The two `format-*` events are **pull-style**: wezterm calls your handler whenever it needs to render the title and uses your return value. The status events are **push-style**: wezterm calls your handler on a tick and you push a string into the window.

All three events fire on the GUI thread — they have to be cheap. None of them can call `wezterm.run_child_process` (it errors with "attempt to yield from outside a coroutine"). For anything slow, defer with `wezterm.time.call_after` or `wezterm.background_child_process`; see [12-state-and-timing.md](12-state-and-timing.md).

## Key APIs

### `wezterm.on('format-tab-title', fn)` — [docs](https://wezterm.org/config/lua/window-events/format-tab-title.html)

```lua
function(tab, all_tabs, all_panes, config, hover, max_width)
  return ' my tab '   -- or a FormatItem[] table
end
```

- `tab` — `TabInformation` for the tab being rendered.
- `all_tabs` — array of `TabInformation` for every tab in the window.
- `all_panes` — array of `PaneInformation` for panes in the **active** tab (not the tab being rendered).
- `config` — the effective config table.
- `hover` — boolean; true while the mouse is over this tab.
- `max_width` — integer, the visible budget **in cells** (retro tab-bar metric). You're responsible for truncating; wezterm will chop the end if you overshoot.

Return either a plain string or a `FormatItem[]` (same shape as `wezterm.format`). Returning the array directly is fine — wezterm runs `wezterm.format` for you. **Only the first registered handler runs**; see Gotchas.

### `wezterm.on('format-window-title', fn)` — [docs](https://wezterm.org/config/lua/window-events/format-window-title.html)

```lua
function(tab, pane, all_tabs, all_panes, config) return 'my window' end
```

Like `format-tab-title` but for the OS window-title bar. Same first-handler-wins rule. Must return a **string** (not a `FormatItem[]` — the OS title bar is plain text). Non-string returns silently fall back to the default.

### `wezterm.on('update-status', fn)` — [docs](https://wezterm.org/config/lua/window-events/update-status.html)

```lua
function(window, pane) ... end
```

Fires periodically on each window. The cadence is `config.status_update_interval` ms (default 1000). The runtime never overlaps a previous call with the next one — if your handler takes longer than the interval, the next call waits until the configured interval has elapsed *after* completion. Inside the handler call `window:set_left_status(...)` and/or `window:set_right_status(...)`; both surfaces are updatable from one event.

### `wezterm.on('update-right-status', fn)` — [docs](https://wezterm.org/config/lua/window-events/update-right-status.html)

The older single-purpose event. Deprecated since 20220903 in favour of `update-status`; still works. Same `(window, pane)` signature, same cadence. Use `update-status` in new code; it can drive both sides from one tick.

### `window:set_left_status(s)` / `window:set_right_status(s)` — [left](https://wezterm.org/config/lua/window/set_left_status.html) / [right](https://wezterm.org/config/lua/window/set_right_status.html)

Both take a **string** — either a plain string or the result of `wezterm.format { ... }` (which is a string-with-escapes). The status zones are per **window**, not per tab; the tab bar shows one strip on each side total. Right is clipped from the left edge if it overruns; left expands as needed and is not implicitly clipped.

### `TabInformation` fields — [docs](https://wezterm.org/config/lua/TabInformation.html)

`tab_id`, `tab_index` (0-based), `is_active`, `active_pane`, `window_id`, `window_title`, `tab_title`. `is_last_active` is nightly-only. `tab.panes` is the list of `PaneInformation` for panes in *this* tab (used in termtools' tab-title handler for the multi-pane "find a Claude pane regardless of focus" walk).

### `PaneInformation` fields — [docs](https://wezterm.org/config/lua/PaneInformation.html)

Snapshotted (cheap): `pane_id`, `pane_index`, `is_active`, `is_zoomed`, `left`, `top`, `width`, `height`, `pixel_width`, `pixel_height`, `title`, `user_vars`. Computed on access (potentially expensive — touch lazily): `foreground_process_name`, `current_working_dir` (Url userdata or string — same gotcha as `pane:get_current_working_dir`), `has_unseen_output`, `domain_name`, `tty_name`.

## Examples

### Tab title with a Claude indicator glyph

`lua/style.lua:79-110` — the termtools default tab-title format:

```lua
wezterm.on('format-tab-title', function(tab, _tabs, _panes, _conf, _hover, max_width)
  local termtools = package.loaded['init']
  local glyph_of = termtools and termtools.claude_glyph_for_pane

  -- If any pane in the tab is a Claude session, that pane wins for both
  -- title and glyph regardless of focus.
  local representative = tab.active_pane
  if glyph_of and tab.panes then
    for _, p in ipairs(tab.panes) do
      if glyph_of(p.pane_id) then representative = p; break end
    end
  end

  local idx   = tab.tab_index + 1
  local title = (representative.title or '')
    :gsub('^Administrator: ', '')
    :gsub('^\xE2[\x80-\xBF][\x80-\xBF]%s*', '')   -- strip leading dingbat
  if title == '' then title = 'shell' end

  local glyph      = glyph_of and glyph_of(representative.pane_id)
  local glyph_part = glyph and (glyph .. ' ') or ''
  local label      = string.format(' %d ▏ %s%s ', idx, glyph_part, title)
  if #label > max_width then
    label = label:sub(1, max_width - 1) .. '… '
  end
  return label
end)
```

Three things worth pointing out:

1. **`tab.panes`** is used to find a "representative" pane that's not the active one. The `all_panes` argument to the handler covers only the *active* tab's panes — for per-tab pane access you read off the `tab` argument.
2. **`termtools.claude_glyph_for_pane`** (`lua/init.lua:225`) is a public lookup that returns `nil` when claude indicators are off or the pane isn't a Claude session, so the handler degrades cleanly when the feature is disabled.
3. **Truncation** is manual: `#label > max_width` measures bytes, which is a slight over-estimate for multi-byte UTF-8 — the resulting label fits but wastes cells when the title is heavily glyphed. For most cases that's good enough; for tight budgets, `wezterm.column_width(label)` is the right metric.

### Window title showing project + tab count

```lua
wezterm.on('format-window-title', function(_tab, _pane, tabs, _panes, _conf)
  local ws = wezterm.mux.get_active_workspace() or 'default'
  return string.format('%s — %d tab%s', ws, #tabs, #tabs == 1 and '' or 's')
end)
```

Returns a plain string; the OS title bar doesn't render colour or attributes. Reading `wezterm.mux.get_active_workspace()` inside the handler is fine — the call is cheap and the value can change between renders.

### Right-status: workspace + clock

```lua
wezterm.on('update-status', function(window, _pane)
  local ws  = window:active_workspace()
  local now = os.date('%H:%M')
  window:set_right_status(wezterm.format {
    { Foreground = { Color = '#7aa2f7' } },
    { Text = ' ' .. ws .. ' ' },
    { Foreground = { Color = '#586e75' } },
    { Text = '▏' },
    { Foreground = { Color = '#9ece6a' } },
    { Text = ' ' .. now .. ' ' },
    'ResetAttributes',
  })
end)
```

Two takeaways for status work generally: `wezterm.format` is the right composition surface (see [13-format-and-colors.md](13-format-and-colors.md)), and you call `set_*_status` *inside* the event — the event itself doesn't care about the return value.

### termtools' Claude status indicator

`lua/claude.lua:304-325` — the full status-bar handler. The interesting part is the dispatch shape:

```lua
config.status_update_interval = opts.poll_interval_ms

wezterm.on('update-status', function(window, _pane)
  M.scan()
  local pos = opts.status_position or 'left'
  local fmt = opts.show_status_bar and summary_format() or nil
  local rendered = fmt and wezterm.format(fmt) or ''
  if pos == 'left' or pos == 'both' then
    window:set_left_status(rendered)
  else
    window:set_left_status('')          -- clear the side we're not using
  end
  if pos == 'right' or pos == 'both' then
    window:set_right_status(rendered)
  else
    window:set_right_status('')
  end
end)
```

A few patterns worth lifting:

- **`set_*_status('')` is the way to clear a side.** There is no `unset` API. If a previous handler set left and you've moved to right, clearing left is on you.
- **`summary_format()` returns a `FormatItem[]`** (`lua/claude.lua:142-163`); the handler itself calls `wezterm.format(...)` on it once. You could also pass the `FormatItem[]` directly to `set_left_status` since it's expected to be a string — but `wezterm.format` is the supported converter.
- **`status_update_interval` is set on the config object,** not at registration — the event reads it on every tick. termtools defaults to 2000 ms (`lua/claude.lua:18`); the upstream default is 1000 ms.

### Faster-than-poll updates

`update-status` is the right tick for ambient state. If you need updates triggered by a specific event (e.g. user hits a key, a child process finishes), update the status immediately and let the next tick be a no-op:

```lua
local function refresh_now(window)
  window:set_right_status(wezterm.format(my_state_format()))
end

wezterm.on('window-focus-changed', function(window, _pane)
  refresh_now(window)                 -- refresh on focus
end)

wezterm.on('update-status', function(window, _pane)
  refresh_now(window)                 -- refresh on every tick
end)
```

Both handlers compute the same render; the focus-changed call just shaves up to `status_update_interval` ms off the latency. There's no penalty for redundant `set_*_status` calls — they're idempotent.

## Gotchas

### `format-tab-title` and `format-window-title` are first-handler-wins

Most events run all registered handlers in registration order (see [10-events.md](10-events.md)). These two do not — wezterm explicitly states "only the first event will be executed; it doesn't make sense to define multiple instances." So:

- If two modules both call `wezterm.on('format-tab-title', ...)`, the *first one to register* wins forever. The second is silently dead.
- The "first" is by registration order within the GUI process. If you register inside `apply()` and another plugin registered earlier, theirs runs.
- Combined with the doubling rule from [10](10-events.md): a guard flag still matters, because re-registering with the same closure also adds an entry that will silently lose to the original.

The practical contract: there's at most one tab-title format and at most one window-title format. If you want pluggable behaviour, expose your formatter as a function that other modules can call into (termtools does this with `claude_glyph_for_pane`).

### `update-status` fires on a poll, not on changes

The cadence is `config.status_update_interval` (default 1000 ms; termtools sets 2000 ms). It is **not** event-driven — opening a tab or focusing a pane doesn't trigger an extra tick. If you need lower latency for a specific cause (focus change, key press), pair an `update-status` handler with the relevant change-event handler that calls the same render path.

### Each handler invocation must be cheap

`update-status` runs on the GUI thread. A 100 ms handler at 1 Hz means 10% of the GUI thread is yours — visible jitter on resize, scroll, and animation. Anything I/O-shaped should be done by `wezterm.background_child_process` and the result cached in a module-scope table; the handler reads the table. termtools' `M.scan()` walks every pane and calls `pane:get_lines_as_text(40)` on each — fast because procinfo and viewport scan are local syscalls, but at the upper edge of "cheap enough at 2 Hz."

### `set_*_status` is per-window, not per-tab

You cannot have a different right-status for tab A versus tab B. The status strips are window chrome, drawn once per window. The visible value for the active window is whatever was last passed to `set_left_status` / `set_right_status` on that window. If you want per-tab info, encode it in the `format-tab-title` return.

### Returning a `wezterm.format(...)` string from `format-tab-title`

`wezterm.format(items)` returns a single string with embedded escape sequences. `format-tab-title` accepts either a plain string or a `FormatItem[]` array. Both work. **Mixing them is the trap**: if you `wezterm.format` an array, then wrap that result in another `FormatItem[]` (e.g. `{ { Text = wezterm.format(...) } }`), the inner escapes are taken as literal text by the outer format pass and you get garbled output. Pick one shape per call.

### `max_width` is a cell budget, not characters

It's measured in tab-bar cells (retro style). UTF-8 byte length and even Lua string length are over-estimates for emoji/CJK content. Truncating with `s:sub(1, max_width)` works for ASCII labels and breaks for anything else. For correctness use `wezterm.column_width(label) > max_width` and step characters off via `wezterm.split_by_newlines` or a manual codepoint walk; for the ASCII-dominant labels termtools uses, byte-length truncation is adequate (`lua/style.lua:106`).

### `tab.is_active` vs the active workspace are different concepts

`tab.is_active` is true for the active tab in the window the tab belongs to — every window has exactly one active tab. The active workspace (`wezterm.mux.get_active_workspace()`) is a window-set-level concept. A non-focused window's active tab still has `is_active = true`. Don't conflate the two when colouring active tabs.

### `hover` only fires for the tab being rendered

You'll see exactly one tab in the all-tabs list with `hover == true` (or zero, if the mouse isn't over the bar). To render the active+hovered case specially, check `tab.is_active and hover` together — both flags can be true for the same tab.

### `PaneInformation.current_working_dir` has the same Url-vs-string split

Same handling as `pane:get_current_working_dir()` covered in [04-pane-window-tab.md](04-pane-window-tab.md): older versions return a string, newer versions return a Url userdata with `.file_path`. termtools' `util.pane_cwd` (`lua/util.lua:166`) normalises both, but inside a status handler you're in the GUI-thread fast path — prefer the `PaneInformation` snapshot over calling the live `pane:get_current_working_dir()` if both are available.

### `PaneInformation.user_vars` is not stable identity

User vars (set via OSC 1337 `SetUserVar`) are cleared when the program in the pane exits and respawns. Don't key state on a user-var value across a shell exit; key it on `pane_id`, which survives. (See `claude.lua:117` — termtools state is `pane_id -> entry`, not `user_var -> entry`.)

### Status bar requires a tab bar

`enable_tab_bar = false` removes both the tabs *and* the status strips — there's no way to keep just the status without the bar. If you want the status without per-tab labels, set `hide_tab_bar_if_only_one_tab = false` and accept the single-tab strip.

### `tab_max_width` vs `max_width`

Different concepts:

- `config.tab_max_width` — config key, integer cells. The cap each tab may grow to before being truncated. termtools defaults to 32 (`lua/style.lua:52`).
- `max_width` (handler arg) — runtime budget for *this* tab's render, after wezterm has divided the available bar width across all tabs. Always `<= tab_max_width`. Use this for truncation, not the config key.

### Empty-string clears, but don't return empty from `format-tab-title`

`set_left_status('')` clears the left strip cleanly. Returning `''` from `format-tab-title` does **not** clear the tab — it gives you a zero-width tab that's still clickable but unreadable. Return `' '` (single space) or a meaningful placeholder; the empty case usually means a bug in your formatter.

## See also

- [10-events.md](10-events.md) — `wezterm.on` registration mechanics, event taxonomy, the doubling-on-reload trap.
- [13-format-and-colors.md](13-format-and-colors.md) — `wezterm.format` and `FormatItem` syntax, colour manipulation.
- [04-pane-window-tab.md](04-pane-window-tab.md) — Window methods (`set_left_status` / `set_right_status` / `toast_notification`) and PaneInformation vs Pane object.
- [12-state-and-timing.md](12-state-and-timing.md) — `wezterm.time.call_after` and `wezterm.background_child_process` for deferring work out of synchronous handlers.
