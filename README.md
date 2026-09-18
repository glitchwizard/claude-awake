# claude-awake

Keep a MacBook awake with the lid closed while [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI sessions are running, and let it sleep again when they finish.

## Why

`caffeinate` (which Claude Code already runs for you) stops idle sleep, but macOS still forces sleep the moment the lid closes. The only thing that overrides a lid-close sleep is the root-only power setting `pmset -a disablesleep 1`. That is the same switch Amphetamine's "Closed-Display Mode" flips. `claude-awake` flips it on while any Claude Code CLI process is alive and back off about 90 seconds after the last one exits, so a laptop shut in a bag does not stay on and hot forever.

## Install

```sh
git clone https://github.com/glitchwizard/claude-awake.git
ln -s "$PWD/claude-awake/claude-awake" ~/.local/bin/claude-awake   # or anywhere on your PATH

# one-time: let the tool flip the switch without a password prompt
printf '%s\n' "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" \
  | sudo tee /etc/sudoers.d/claude-awake >/dev/null && sudo chmod 0440 /etc/sudoers.d/claude-awake && sudo visudo -c -f /etc/sudoers.d/claude-awake

claude-awake install
```

`install` writes a LaunchAgent (`~/Library/LaunchAgents/com.glitchwizard.claude-awake.plist`) that runs the poll loop at login and logs to `~/Library/Logs/claude-awake.log`.

## Usage

| Command | What it does |
|---|---|
| `claude-awake status` | Switch state, whether a Claude CLI is running, sudoers and agent health |
| `claude-awake on` | Hold the machine awake until `off`, regardless of Claude processes |
| `claude-awake off` | Release the hold and re-enable sleep now |
| `claude-awake install` | Write and load the LaunchAgent |
| `claude-awake uninstall` | Unload the agent, re-enable sleep, remove the plist |

## What counts as "Claude Code running"

Any process whose command line is the `claude` binary (Homebrew or npm), the VS Code extension's bundled `native-binary/claude`, or a `bg-pty-host` child. The Claude desktop app is deliberately ignored.

## Caveats

- With the switch on, a closed MacBook is fully awake: it drains the battery and gets warm in a bag. Plug in for long runs.
- The sudoers rule is scoped to exactly two commands, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`.
- If the daemon is killed, its exit trap re-enables sleep unless a manual hold is set.
- Tested on macOS 26 (Apple Silicon). The `disablesleep` key is undocumented by Apple; if it disappears the tool logs an error rather than failing silently.

## License

MIT
