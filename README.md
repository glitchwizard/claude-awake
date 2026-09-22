# claude-awake

Keep a MacBook awake with the lid closed while a [Claude](https://claude.ai) session is actually working, and let it sleep normally the moment you switch it off. Ships as a menu bar app, with a shell CLI for terminal use.

## Why

`caffeinate` (which Claude Code already runs for you) stops idle sleep, but macOS still forces sleep the moment the lid closes. The only thing that overrides a lid-close sleep is the root-only power setting `pmset -a disablesleep 1` — the same switch Amphetamine's "Closed-Display Mode" flips. Amphetamine can watch GUI apps but not terminal processes, so it cannot tell whether a Claude session is mid-task. `claude-awake` can, and it releases the switch when the work finishes so a laptop shut in a bag does not stay on and hot.

## The menu bar app

```sh
git clone https://github.com/glitchwizard/claude-awake.git
cd claude-awake
./build.sh --install        # builds, then copies to ~/Applications
open ~/Applications/ClaudeAwake.app
```

A bolt appears in the menu bar. Click it for the toggles:

| Icon | Meaning |
|---|---|
| bolt, struck through | Off. Lid close sleeps the Mac normally. |
| bolt, outline | Armed, but no Claude session is working, so sleep is allowed. |
| bolt, filled | Preventing sleep right now. |
| warning triangle | Setup is unfinished; the app cannot change the setting. |

Menu items:

- **Keep awake while Claude runs** — the main toggle. On, the Mac stays awake with the lid shut whenever a Claude session is working, and sleeps again about a minute after the last one ends. Off, the Mac behaves exactly as if this app were not installed.
- **Keep awake until I turn it off** — ignores session detection and holds the Mac awake.
- **Count the Claude app just being open** — off by default. See below.
- **Open at login**, **Open Log**, **Quit**. Quitting always re-enables sleep.

The first two lines of the menu always show the current state and what was detected on the last poll, so you can confirm it before shutting the lid.

### One-time setup

Changing lid-close sleep needs root, so the app uses a sudoers rule limited to that single setting. The menu offers **Finish setup: copy the sudo command** until it is in place; paste it into Terminal:

```sh
printf '%s\n' "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" \
  | sudo tee /etc/sudoers.d/claude-awake >/dev/null && sudo chmod 0440 /etc/sudoers.d/claude-awake && sudo visudo -c -f /etc/sudoers.d/claude-awake
```

Until then the app is harmless: it logs an error and leaves your power settings alone.

## What counts as a Claude session

Any process that is the `claude` binary (Homebrew or npm), the VS Code extension's bundled `native-binary/claude`, or a `bg-pty-host` child, which is how the desktop app runs local Claude Code sessions.

The desktop app merely being open does **not** count by default. It tends to run all day, so counting it would pin the switch on permanently and defeat the auto-release. Its actual working sessions are still caught. Turn on **Count the Claude app just being open** if you want the app's presence alone to hold the Mac awake.

## The CLI

`claude-awake` is a standalone bash script for the same switch, useful over SSH or in scripts. Symlink it onto your PATH:

```sh
ln -s "$PWD/claude-awake" ~/.local/bin/claude-awake
```

| Command | What it does |
|---|---|
| `claude-awake status` | Switch state, whether a Claude CLI is running, sudoers and agent health |
| `claude-awake on` | Hold the Mac awake until `off` |
| `claude-awake off` | Release the hold and re-enable sleep now |
| `claude-awake install` | Write and load a LaunchAgent that polls without the menu bar app |
| `claude-awake uninstall` | Unload the agent, re-enable sleep, remove the plist |

The CLI and the app share their state under `~/.local/state/claude-awake`, so `on` and `off` are reflected in the menu.

## Only one owner of the switch

Two pollers racing over `pmset` is the one state that actually misbehaves, so both sides check for each other:

- `claude-awake install` refuses when the menu bar app is running, when a daemon already holds the PID lock, when the LaunchAgent is already loaded, or when an existing plist runs a different copy of the script. It names what it found and offers the three ways out. `--force` overrides it.
- `claude-awake daemon` takes a PID lock and exits immediately if the app or another daemon owns the switch. It installs its cleanup handler only after the lock is its own, so an exit taken because someone else is in charge can never turn off their wake lock. A stale, recycled, or malformed PID file is ignored rather than blocking every future install.
- The app shows a conflict line and a warning icon when it finds a daemon or a loaded LaunchAgent.
- `claude-awake uninstall` will not pointlessly re-enable sleep while the app is running, since the app would just re-apply its own setting. It removes the LaunchAgent and says so.

## Caveats

- With the switch on, a closed MacBook is fully awake: it drains the battery and gets warm in a bag. Plug in for long runs.
- The sudoers rule is scoped to exactly two commands, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`.
- Quitting the app, or killing the CLI daemon, re-enables sleep unless a manual hold is set.
- The app is ad-hoc signed by `build.sh`, which is enough for a local build. Without a signature macOS refuses login-item registration.
- Tested on macOS 26 (Apple Silicon), Swift 6.3. The `disablesleep` key is undocumented by Apple; if it disappears the tool logs an error rather than failing silently.

## License

MIT
