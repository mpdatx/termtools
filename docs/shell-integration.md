# Shell integration

termtools needs to know each pane's *current* working directory to resolve project roots, find a project's existing tab, and target file-open actions. There are two channels through which WezTerm can learn that:

- **OSC 7** — an escape sequence the shell emits on every prompt, telling WezTerm where the shell is. Universal, works across local panes and panes inside a mux/SSH-multiplex domain.
- **`pane:get_foreground_process_info().cwd`** — OS-level introspection of the foreground process's working directory. Available for **local** panes; **not reliably transmitted** over the WezTerm mux protocol, so panes living in a `unix_domains` / `tls_clients` / `ssh_domains` domain often see it as `nil` even when the mux is on the same machine.

`util.pane_cwd` tries both. If your panes are local **and** your shell emits OSC 7, you don't need to do anything — termtools resolves CWDs out of the box. The case that breaks is **mux-attached panes running a shell that doesn't emit OSC 7** — most commonly bare PowerShell or cmd.exe. Symptom: the action picker fails silently or only shows a "Could not determine current directory" toast; the command palette shows the picker shortcuts but no `termtools [<project>]: <action>` rows.

The fix is to make your shell emit OSC 7 on every prompt change.

## PowerShell

Add to your PowerShell profile (find its path with `$PROFILE`; create the file if it doesn't exist):

```powershell
function prompt {
  $cwd = $PWD.Path -replace '\\','/'
  $hostName = [System.Net.Dns]::GetHostName()
  $esc = [char]27
  Write-Host "$esc]7;file://$hostName$cwd$esc\" -NoNewline

  # then your normal prompt — preserve whatever you had here. The default is:
  "PS $($PWD.Path)> "
}
```

Restart your shell (or `. $PROFILE` to reload) and the next `cd` will refresh the OSC 7 cache wezterm reads. termtools will pick the new CWD up immediately.

If you also want OSC 133 prompt markers (for WezTerm's semantic-zone selection — useful for "select last command output" gestures), see WezTerm's official integration at <https://wezterm.org/shell-integration.html#powershell-integration>. The minimal snippet above is all termtools strictly needs.

## cmd.exe

cmd has no real way to emit OSC 7 from its prompt — `PROMPT` doesn't support arbitrary command execution per prompt. Practical paths:

- **Switch to PowerShell** (recommended). All modern Windows ships with both; cmd is largely a compatibility shim at this point.
- **Use a wrapper** like ConEmu/Cmder that emits OSC 9;9 on cd. WezTerm understands OSC 9;9 as well, so this works equivalently to OSC 7.

## bash

Add to `~/.bashrc`:

```bash
__wezterm_set_cwd() {
  printf '\033]7;file://%s%s\033\\' "$HOSTNAME" "$PWD"
}
case ":$PROMPT_COMMAND:" in
  *:__wezterm_set_cwd:*) ;;
  *) PROMPT_COMMAND="__wezterm_set_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac
```

WezTerm's official integration (which also does OSC 133 prompt markers) lives at <https://wezterm.org/shell-integration.html> — `~/.config/wezterm/shell-integration.bash`, source it from `.bashrc`.

## zsh

Add to `~/.zshrc`:

```zsh
function __wezterm_set_cwd() {
  printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD"
}
typeset -ag precmd_functions
if [[ -z ${precmd_functions[(r)__wezterm_set_cwd]} ]]; then
  precmd_functions+=(__wezterm_set_cwd)
fi
```

Or use WezTerm's full integration script (same URL as bash, with OSC 133 prompt markers).

## fish

Add to `~/.config/fish/config.fish`:

```fish
function __wezterm_set_cwd --on-event fish_prompt
  printf '\033]7;file://%s%s\033\\' (hostname) "$PWD"
end
```

## Verifying it works

After restarting your shell, `cd` somewhere and check that termtools sees the change:

1. Open the WezTerm command palette (`Ctrl+Shift+P`) and type `termtools`. If you see per-action rows like `termtools [<project>]: Open TODO.md`, OSC 7 is reaching wezterm and termtools is resolving the root correctly.
2. Press the action picker hotkey (`Ctrl+Shift+A` by default). The modal should open with project-scoped actions, no "Could not determine current directory" toast.

If you want to see the raw value WezTerm has cached, the `lua/util.lua` `M.pane_cwd` function already does this — drop a temporary `wezterm.log_info` near its top to print what each method returns, reload, trigger a picker, then check the wezterm log:

- macOS / Linux: `~/.local/share/wezterm/wezterm-gui-*.log`
- Windows: `%USERPROFILE%\.local\share\wezterm\wezterm-gui-*.log`

## Why mux panes need this more than local panes

For **local panes**, WezTerm has procinfo as a backstop — even when the shell doesn't emit OSC 7, `pane:get_foreground_process_info().cwd` returns the live CWD via PEB introspection (Windows) or `/proc` (Linux). termtools' `util.pane_cwd` prefers procinfo for that reason; it tracks `cd` immediately, even on shells with no integration.

For **mux/SSH panes**, the GUI client has no PID it can introspect on the local kernel — the shell process lives on the mux server. WezTerm's mux protocol carries pty bytes and OSC sequences, but procinfo doesn't always travel through. So OSC 7 becomes the *only* signal of "where is this shell really". A shell that doesn't emit OSC 7 inside a mux pane is invisible to wezterm, and therefore invisible to termtools.

This is why the PowerShell snippet above is the highest-leverage fix for users who run a `unix_domains` mux server, even on the same machine: it unblocks every termtools picker without any code changes on the wezterm or termtools side.
