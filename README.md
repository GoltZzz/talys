<p align="center">
  <img src="Resources/logo.svg" width="96" alt="Talys logo: a cracked egg">
</p>

<h1 align="center">Talys</h1>

<p align="center"><em>A keyboard-driven tiling window manager for macOS, inspired by Hyprland and PewDiePie.</em></p>

---

## What is Talys?

macOS leaves window layout to you: dragging, resizing, and hunting through overlapping windows. Talys does it for you. Every window you open goes into a clean, gapped layout, and you move between windows, workspaces and apps without touching the mouse.

It's meant to feel like a Linux tiling setup such as Hyprland, while running as a native macOS app.

## What it does

- **Automatic tiling.** The default Smart layout tries every way to arrange your windows and picks the one that suits each best: terminals get tall columns, browsers don't stretch past a useful width, and nothing shrinks below the size its app needs. You can also switch to dwindle, master-stack, scrolling or monocle.
- **Keyboard first.** Move focus, swap windows, resize splits, float and fullscreen, all from home-row keys.
- **Workspaces.** Nine virtual workspaces that replace macOS desktops (Spaces), with per-app rules that send apps to their own workspace.
- **Built-in status bar.** A themed bar at the top of the screen shows your workspaces, the time, battery, Wi-Fi and volume. On first launch Talys asks whether to use it in place of the macOS menu bar, which it then hides and covers while Talys runs.
- **Launcher.** Fuzzy-search your apps and Talys commands. It can take over `Cmd + Space` from Spotlight.
- **Scratchpad.** Hide windows out of the way and bring them back over whatever workspace you're on.
- **Active window borders.** Borders with rounded corners and a gradient show which window has focus, with smooth animations.
- **Themes.** Catppuccin Mocha, Tokyo Night, Gruvbox, Rosé Pine and Nord are built in, or you can write your own. A theme recolors the bar, the launcher and the borders immediately.
- **One config file.** Everything lives in a single TOML file that Talys reloads while it runs.
- **Settings window.** Edit the config without touching TOML: click a shortcut and press new keys to rebind it. Changes apply instantly and your comments in the file are kept. Open it with `mod + shift + ,`, "Settings" in the launcher, or "Settings…" in the bar menu.
- **Puts things back.** Any macOS setting Talys changes (Spotlight shortcut, menu bar, Mission Control keys) is restored when you quit.

## How it's built

The layout engine is written in **Zig**. It does pure math with no macOS code, which keeps it fast and portable. The **Swift** layer is the native macOS side: it watches your windows, catches hotkeys, and draws the bar, launcher and borders.

## Build and launch

Building requires macOS 14 or newer, Swift 6, and Zig **0.17.0**. The build checks the Zig version; see the [toolchain requirements](CONTRIBUTING.md#requirements).

From the repository directory:

```bash
make run                    # Build, sign, and launch Talys
make build                  # Build the app without launching it
open ./Talys.app            # Launch the existing build without rebuilding
./Talys.app/Contents/MacOS/talys  # Run the existing build in the foreground
```

Choose one launch command at a time. Grant Talys Accessibility access on first launch. For tests, build targets, login startup, and recovery commands, see [Contributing](CONTRIBUTING.md#build-and-run).

## Troubleshooting / FAQ

**Talys isn't moving any windows.**
Talys needs Accessibility access. Open **System Settings → Privacy & Security → Accessibility**, turn on **Talys**, then relaunch it.

**The bar says PAUSED.**
Talys only runs on the macOS desktop it was started on. It pauses on other desktops and in native fullscreen apps, and resumes when you come back. For fullscreen, use Talys's own fullscreen toggle instead.

**Should I keep several macOS desktops?**
No. Talys workspaces take their place. If you have more than one desktop, Talys will offer once to open Mission Control so you can remove them. It never removes them itself.

**A shortcut does something else.**
If a macOS shortcut (such as a Mission Control one) uses the same keys as a Talys binding, Talys asks once whether to turn it off while Talys runs. It's turned back on when Talys quits.

**My menu bar or Spotlight shortcut changed.**
If you chose the Talys bar, Talys sets the macOS menu bar to hide automatically while it runs, and it can take over `Cmd + Space`. Both go back to how they were when you quit. If you change the menu bar setting in System Settings while Talys runs, Talys keeps your change. After a force quit, run `talys --restore-shortcuts` to put them back. To switch, set `menu_bar` under `[bar]` in the config to `"talys"` or `"macos"`, or use "Use Talys Bar" / "Restore macOS Menu Bar" in the launcher. Set it to `"ask"` to see the prompt again.

**A window is hidden or Talys was force quit.**
Use **Reveal All Windows** in the Talys bar menu or launcher. It restores Talys-hidden windows to their last visible position and size, adjusted to fit the current display, and disables tiling until you enable it again. Recovered scratchpad windows become ordinary windows when tiling resumes. After an interrupted session, Talys automatically attempts recovery and starts with tiling disabled.

To recover without starting the window manager, quit any running Talys instance and run:

```bash
./Talys.app/Contents/MacOS/talys --recover-windows
```

The command needs Accessibility access. It exits with status 1 if recovery is incomplete; return to the macOS desktop containing those windows and retry. Records remain in `~/.config/talys/window-recovery.json` until recovery is confirmed or the owning app process has ended. The journal covers windows hidden by this version of Talys; it cannot restore frames that an older version never recorded. Manually minimized windows stay minimized. System settings can be restored separately with `--restore-shortcuts`.

## Status & Roadmap

Talys is an early-stage personal project. It's usable every day on a single display, and rough edges are expected.

- [x] Smart (constraint-based), dwindle, master-stack and monocle layouts
- [x] Workspaces, window rules, scratchpad
- [x] Status bar, launcher, borders, themes
- [ ] Multi-monitor support
- [ ] Prebuilt, signed releases on GitHub
- [ ] Homebrew install
