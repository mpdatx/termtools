# 13 — `wezterm.format`, `wezterm.color`, and color schemes

How to put styled text anywhere wezterm accepts a label, how to do color math at runtime, and how to pick / override / synthesize the colors the terminal renders with.

## Overview

Three loosely-related surfaces share this file because they almost always show up together:

- **`wezterm.format(items)`** is wezterm's "rich-string builder". Anywhere wezterm accepts a label that supports styling — tab titles, the right-status segment, `InputSelector` choice rows, prompt input prefixes — you build an array of `FormatItem`s and call `wezterm.format` once. The return value is a plain Lua string with embedded ANSI/SGR escape sequences; concatenating those strings works, but it's cleaner to build a single FormatItem array and format it once.
- **`wezterm.color`** is the runtime side of color: parse hex / `rgb()` / named CSS strings into a `Color` userdata, do HSLA math, generate gradients, query the active scheme, import schemes from disk. This is where you reach when you want a dim variant of an existing scheme color, a contrast-checked accent, or N evenly-spaced gradient stops for a tab bar.
- **Color schemes** are tables of named colors that wezterm bakes into `config.colors` at config time. Pick a built-in by name with `config.color_scheme`, register your own under `config.color_schemes`, or override individual fields directly via `config.colors`. The three are layered, not parallel — see precedence below.

This file is the API tour. Where the styled output ends up — `format-tab-title`, `update-right-status`, `format-window-title` — lives in [14-tab-bar-and-status.md](14-tab-bar-and-status.md). Where it lights up the picker UI lives in [11-pickers.md](11-pickers.md).

## Key APIs

### `wezterm.format(items)`

`items` is an array. Each entry is one of:

```lua
{ Text = 'plain string' }                                     -- literal text
{ Foreground = { Color = '#hex' } }                           -- foreground rgb
{ Foreground = { Color = 'CSSName' } }                        -- foreground named CSS color
{ Foreground = { AnsiColor = 'Maroon' } }                     -- one of 16 ANSI names
{ Background = { Color = '#hex' } }                           -- as Foreground
{ Attribute = { Italic = true } }                             -- italic on/off
{ Attribute = { Intensity = 'Bold' | 'Half' | 'Normal' } }    -- bold / half / reset
{ Attribute = { Underline = 'None' | 'Single' | 'Double'      -- underline style
                | 'Curly' | 'Dotted' | 'Dashed' } }
'ResetAttributes'                                             -- BARE STRING — clears state
```

ANSI named colors (the 16 standard ones): `Black`, `Maroon`, `Green`, `Olive`, `Navy`, `Purple`, `Teal`, `Silver` (the 8 standard) and `Grey`, `Red`, `Lime`, `Yellow`, `Blue`, `Fuchsia`, `Aqua`, `White` (the 8 brights). You can also use a number 0–15 as `AnsiColor = 7`.

Returns a plain string. You can concatenate it with other strings, but each `wezterm.format` call emits its own opening/closing escape sequences, so building one big array and formatting once is cheaper and easier to reason about.

### `wezterm.color.parse(s)`

Accepts:

- `'#aabbcc'` / `'#abc'` — hex with leading `#`
- `'aabbcc'` — hex without leading `#`
- `'rgb(...)'` / `'rgba(...)'` / `'hsl(...)'` / `'hsla(...)'` — CSS functional
- CSS named colors: `'navy'`, `'darkslategray'`, etc.

Returns a `Color` userdata. The userdata is **immutable**: every transform method returns a new `Color`.

### `Color` object methods

Chainable; each returns a new `Color`:

- `:lighten(f)` / `:darken(f)` — lab-space luminance shift, `f` ∈ [0, 1].
- `:lighten_fixed(f)` / `:darken_fixed(f)` — fixed-amount HSL `L` shift.
- `:saturate(f)` / `:desaturate(f)` — HSL saturation shift, lab-space.
- `:saturate_fixed(f)` / `:desaturate_fixed(f)` — fixed-amount HSL `S` shift.
- `:adjust_hue_fixed(deg)` / `:adjust_hue_fixed_ryb(deg)` — rotate hue in HSL or RYB space.
- `:complement()` / `:complement_ryb()` / `:triad()` / `:square()` — harmony helpers (return arrays for triad/square).
- `:contrast_ratio(other)` — WCAG-style contrast number (≥ 4.5 = AA body text).
- `:delta_e(other)` — perceptual distance (CIE 2000).
- `:hsla()` / `:laba()` / `:linear_rgba()` / `:srgb_u8()` — destructure to component tuples.

### `wezterm.color.from_hsla(h, s, l, a)`

Build a `Color` from HSLA. `h` ∈ [0, 360], `s`/`l`/`a` ∈ [0, 1].

### `wezterm.color.gradient(spec, n)`

`spec` is a [Gradient](https://wezterm.org/config/lua/config/window_background_gradient.html) table:

```lua
{ preset = 'Rainbow' }                                        -- or Inferno / Magma /
                                                              -- Plasma / Viridis / Turbo
{ colors = { '#001f3f', '#0074d9', '#7fdbff' } }              -- explicit stops
{ orientation = { Linear = { angle = 90 } } }                 -- optional
```

Returns an array of `n` `Color` objects spaced evenly along the gradient.

### Discovery

- `wezterm.color.get_default_colors()` — the active scheme's color table (same shape as `config.colors`).
- `wezterm.color.get_builtin_schemes()` — `{ ['Tokyo Night'] = { ... }, ... }`. ~750 entries.
- `wezterm.color.load_scheme(path)` / `:load_base16_scheme(path)` / `:load_terminal_sexy_scheme(path)` — import from disk.
- `wezterm.color.save_scheme(scheme, name, path)` — write a scheme to a TOML file.
- `wezterm.color.extract_colors_from_image(path)` — sample dominant colors from an image.

### Color-scheme config keys

```lua
config.color_scheme = 'Tokyo Night'                           -- pick by name
config.color_schemes = {                                      -- register custom names
  ['My Theme'] = { foreground = '#...', background = '#...', ansi = {...}, ... },
}
config.colors = { foreground = '#...', tab_bar = { ... } }    -- override (see precedence)
```

`config.color_scheme` selects a base. Anything you set in `config.colors` then layers on top, key by key. The two are *not* mutually exclusive — they compose. Custom schemes registered in `config.color_schemes` are referenced by their string key in `config.color_scheme`.

`config.colors` shape (the keys you'll touch most often):

```lua
config.colors = {
  foreground   = '#cccccc',
  background   = '#0d0d0d',
  cursor_bg    = '#52ad70',
  cursor_fg    = '#0d0d0d',
  cursor_border = '#52ad70',
  selection_bg = '#3b3a32',
  selection_fg = '#cccccc',
  ansi    = { '#000', '#a00', ... },                          -- 8 entries: black..white
  brights = { '#666', '#f55', ... },                          -- 8 entries: bright black..white
  tab_bar = {
    background = '#0d0d0d',
    active_tab         = { bg_color = '#1f1f1f', fg_color = '#cccccc' },
    inactive_tab       = { bg_color = '#0d0d0d', fg_color = '#666666' },
    inactive_tab_hover = { bg_color = '#1a1a1a', fg_color = '#cccccc' },
    new_tab            = { bg_color = '#0d0d0d', fg_color = '#666666' },
  },
}
```

## Examples

### Dim / italic styling for advisory entries — `lua/pickers/action.lua:127`

The action picker classifies entries as enabled / dimmed / disabled (see `lua/pickers/action.lua:45`). Both dimmed and disabled rows render in italic grey so the user can visually skip them without reading. The comment at `lua/pickers/action.lua:124` explains the explicit hex grey:

```lua
-- Italic + an explicit hex grey so the row stays legible on dark
-- schemes. Half-intensity stacked on Solarized's Grey (~#586e75) drops
-- it to ~#2c3a3e, which is invisible against base03 (#002b36).
display = wezterm.format {
  { Attribute = { Italic = true } },
  { Foreground = { Color = '#93a1a1' } },
  { Text = plain },
  'ResetAttributes',
}
```

The `'ResetAttributes'` at the end matters: without it, the italic + grey state can leak into adjacent UI that the same string happens to be concatenated into. Always close styled spans.

### Composing per-segment styling — `lua/pickers/project.lua:128`

The project picker decorates each row with a marker (open/closed), the project name (highlighted if MRU), the path, and an open-tab count. Each segment gets its own `Foreground`. Styling segments come first, the `Text` they apply to comes after, and a `'ResetAttributes'` marks the end of a styled span:

```lua
local PICKER_COLOR = {
  marker_open   = '#86efac', -- soft green
  marker_closed = '#586e75', -- solarized base01 (dim)
  name_mru      = '#fbbf24', -- amber, calls out the recently-used row
  path          = '#93a1a1', -- solarized base1 (muted)
  count         = '#586e75',
}

local fmt = {
  { Foreground = { Color = marker_color } },
  { Text = marker .. '  ' },
}
if is_mru then
  fmt[#fmt + 1] = { Foreground = { Color = PICKER_COLOR.name_mru } }
else
  fmt[#fmt + 1] = 'ResetAttributes'
end
fmt[#fmt + 1] = { Text = string.format('%-' .. name_w .. 's', entry.name) }
fmt[#fmt + 1] = 'ResetAttributes'
fmt[#fmt + 1] = { Foreground = { Color = PICKER_COLOR.path } }
fmt[#fmt + 1] = { Text = '  ' .. entry.path }
-- ... count_str, final ResetAttributes ...
return wezterm.format(fmt)
```

Two patterns to copy:

1. Build the table imperatively, append entries, format once at the end. This composes cleanly with conditional segments (the `is_mru` branch above).
2. Hoist the palette into a `PICKER_COLOR` table at module scope. Re-reading hex strings in the hot path is fine, but a centralised table is the only place to tweak when the scheme changes underneath you.

### Color-scheme application at config time — `lua/style.lua:30`

termtools picks a built-in by name and lets users override it through `setup({ style = { color_scheme = '...' } })`:

```lua
-- Solarized Dark — wezterm bundles it under 'Builtin Solarized Dark'.
-- Other useful values: 'Catppuccin Mocha', 'Tokyo Night', 'Nord (base16)'.
color_scheme = 'Builtin Solarized Dark',
```

Applied at `lua/style.lua:121` with a single assignment — wezterm handles the rest:

```lua
if s.color_scheme then config.color_scheme = s.color_scheme end
```

### Right-status with mixed colored segments

A typical pattern for `update-right-status` (the surface itself is in [14-tab-bar-and-status.md](14-tab-bar-and-status.md)):

```lua
wezterm.on('update-right-status', function(window, _pane)
  local workspace = window:active_workspace()
  local time = wezterm.strftime('%H:%M')
  window:set_right_status(wezterm.format {
    { Foreground = { Color = '#93a1a1' } },
    { Text = workspace },
    'ResetAttributes',
    { Foreground = { Color = '#586e75' } },
    { Text = '  │  ' },
    { Foreground = { AnsiColor = 'Yellow' } },
    { Text = time .. ' ' },
    'ResetAttributes',
  })
end)
```

### Synthesising a dim color from a scheme color

Use `wezterm.color.parse` plus a transform when you want the dim version of an active-scheme color rather than a hard-coded hex:

```lua
local base = wezterm.color.parse('#586e75')        -- Solarized base01
local dim  = base:darken(0.5)                      -- new Color, half luminance
local fg   = '#' .. table.concat({ dim:srgb_u8() }, '_')   -- back to hex if needed
```

Or read the active scheme's background and derive from there:

```lua
local scheme = wezterm.color.get_default_colors()
local accent = wezterm.color.parse(scheme.background):lighten(0.15):saturate(0.2)
```

The `lua/pickers/action.lua` block above hard-codes `#93a1a1` instead of deriving it because the dim row needs to stay legible across whichever scheme the user picks; see the gotcha below.

### Tab-bar gradient via `wezterm.color.gradient`

Generate N stops for a tab bar where each tab fades through a palette:

```lua
local stops = wezterm.color.gradient(
  { preset = 'Viridis' },
  #tabs                                            -- one color per tab
)
-- stops[1] .. stops[#tabs] are Color objects; stringify with srgb_u8.
```

Pair with a `format-tab-title` handler that closes over `tabs[i]` to pick the right stop.

### Custom scheme registered, then selected by name

```lua
config.color_schemes = {
  ['Termtools Mono'] = {
    foreground = '#d4d4d4',
    background = '#0a0a0a',
    cursor_bg  = '#d4d4d4',
    ansi       = { '#000', '#666', '#888', '#aaa', '#ccc', '#ddd', '#eee', '#fff' },
    brights    = { '#444', '#777', '#999', '#bbb', '#ccc', '#ddd', '#eee', '#fff' },
  },
}
config.color_scheme = 'Termtools Mono'
```

### Light/dark adaptation via `wezterm.gui.get_appearance`

```lua
local appearance = wezterm.gui.get_appearance()    -- 'Light' / 'Dark' (+ HighContrast)
config.color_scheme = appearance:find('Dark')
  and 'Builtin Solarized Dark'
  or  'Builtin Solarized Light'
```

`get_appearance()` only works in the GUI process; gate with `pcall` if your config might also be loaded headlessly. See [02-modules.md](02-modules.md) on the GUI/mux split.

## Gotchas

- **`'ResetAttributes'` is a bare string.** Not `{ ResetAttributes = ... }`, not `{ Attribute = { Reset = true } }`. The literal string `'ResetAttributes'` goes directly into the FormatItem array. Wrapping it in a table silently produces nothing useful.
- **`Foreground` / `Background` need the inner `Color =` wrapper.** Write `{ Foreground = { Color = '#hex' } }`, not `{ Foreground = '#hex' }`. The same nesting holds for `AnsiColor`: `{ Foreground = { AnsiColor = 'Maroon' } }`.
- **Attribute values are tagged, not bare.** `{ Attribute = { Intensity = 'Bold' } }`, never `{ Attribute = 'Bold' }`. Same for `Italic = true` (boolean) and `Underline = 'Single'` (enum string). Underline accepts `'None'`, `'Single'`, `'Double'`, `'Curly'`, `'Dotted'`, `'Dashed'`.
- **Half-intensity stacked on dark backgrounds disappears.** `lua/pickers/action.lua:124` documents this: applying `Intensity = 'Half'` to a Solarized base01 grey (`~#586e75`) drops the rendered color to ~`#2c3a3e`, which is essentially invisible against `base03` (`#002b36`). Use italic plus an explicit hex foreground (e.g. `#93a1a1`) for advisory rows so you stay above the visibility floor regardless of scheme. If you want dimming that scales with the active scheme, use `wezterm.color.parse(scheme.foreground):darken(0.4)` and ship the result as a hex string.
- **`wezterm.format` returns a string with embedded escapes.** Concatenating two formatted strings works, but it's wasteful (each emits its own SGR opener/closer) and fragile (forgotten `ResetAttributes` in the first leaks into the second). Build one big FormatItem array and call `wezterm.format` once.
- **`Color` userdata is immutable.** `c:darken(0.5)` returns a new `Color`; the original is unchanged. Code like `local c = wezterm.color.parse('#aaa'); c:darken(0.5); use(c)` does nothing — bind the result.
- **`config.color_scheme` and `config.colors` compose, not conflict.** `color_scheme` selects a base; anything you also set in `colors` overrides those specific keys. So `color_scheme = 'Tokyo Night'; colors = { tab_bar = { ... } }` keeps Tokyo Night for everything *except* the tab bar. The upstream docs say "color_scheme takes absolute precedence" — that means it's evaluated first, *not* that it blocks `colors`.
- **Custom schemes need an exact name match.** A typo in `config.color_scheme = 'Termtolos Mono'` silently falls back to wezterm's default — there's no error, no log line, nothing in `wezterm-gui --version` either. Verify by checking `wezterm.color.get_builtin_schemes()` (built-ins) or echoing `config.color_schemes` (custom) at config time.
- **`config.color_scheme` reload usually works; mid-session `config.colors` mutation is iffy.** Changing the scheme via a config reload is reliable. Mutating `config.colors` in place from a callback can require a window redraw to take effect; behaviour drifted across wezterm versions historically. If you need to react to runtime conditions, prefer "pick a different `color_scheme` in the config chunk based on a `wezterm.GLOBAL` flag, then reload" over in-place mutation.
- **`wezterm.color.parse` accepts hex without `#`.** Both `parse('#aabbcc')` and `parse('aabbcc')` work; `parse('rgb(170, 187, 204)')` also works; CSS named colors (`'navy'`) work. It's lenient — but if you concatenate user input, validate or `pcall` because malformed input throws.
- **`wezterm.color.gradient` returns Color userdata, not strings.** Stringify with `'#' .. ...` from `:srgb_u8()` (or pass the Color directly to anything that accepts a Color).
- **`AnsiColor` numbers are 0–15, *not* 0–255.** 0–7 = standard ANSI, 8–15 = brights. Pass an integer or one of the 16 capitalised names (`'Maroon'`, `'Lime'`, `'Aqua'`, …). 256-color is not a thing in `FormatItem`; use `Color = '#hex'` if you want anything outside the 16-color palette.
- **`wezterm.gui.get_appearance()` fails outside the GUI.** Gate with `pcall(require, 'wezterm.gui')` checks or run it inside an event handler that only fires in the GUI process. See [02-modules.md](02-modules.md).

## See also

- [02-modules.md](02-modules.md) — `wezterm.color` lives in the module catalogue; quick reference of methods.
- [11-pickers.md](11-pickers.md) — `InputSelector` choices accept `wezterm.format` output as `label`. The action and project pickers in `lua/pickers/` are the largest in-tree consumers.
- [14-tab-bar-and-status.md](14-tab-bar-and-status.md) — `format-tab-title`, `format-window-title`, `update-right-status`. These are where styled strings actually surface.
- [17-palette.md](17-palette.md) — `PaletteEntry` rows can also use `wezterm.format` for their `brief` / `doc` fields.
