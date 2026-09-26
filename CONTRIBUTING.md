# Contributing to Talys

Thanks for wanting to help! Talys is an early-stage project and there's plenty to do, whether that's fixing a bug, adding a layout, writing a theme, or improving the docs. Contributions of every size are welcome.

## Getting started

### Requirements

- macOS 14 (Sonoma) or newer
- [Zig](https://ziglang.org/download/) 0.16
- Swift 6 (comes with Xcode 16 or the Xcode Command Line Tools)

### Build and run

```bash
git clone https://github.com/GoltZzz/talys.git
cd talys
make run
```

`make run` builds the Zig engine, builds the Swift app, assembles and ad-hoc signs `Talys.app`, then starts it. Other targets:

| Command | What it does |
|---|---|
| `make build` | Build `Talys.app` without running it |
| `make zig` | Build only the Zig engine into `Sources/CTalysEngine/libtalys_engine.a` |
| `make clean` | Remove all build output |
| `make icon` | Regenerate the app icon and `Resources/logo.svg` from `TalysLogo.swift` |

On first launch, grant Talys **Accessibility** access in System Settings → Privacy & Security → Accessibility. Because each build is ad-hoc signed, macOS may ask again after a rebuild. If windows stop moving, toggle Talys off and on in that list.

If Talys crashes or you force quit it, run `./Talys.app/Contents/MacOS/talys --restore-shortcuts` to give back the Spotlight and Mission Control shortcuts it took over.

## How the code is laid out

Talys has two halves:

- **`zig-engine/`**: the layout engine. Pure math with no macOS code: it takes window sizes and hints and returns frames. Layouts live in `src/` (`smart.zig`, `bsp.zig`, `scroll.zig`, `tiling.zig`), with workspaces in `workspace.zig` and size constraints in `constraints.zig`.
- **`Sources/Talys/`**: the native macOS side in Swift. It watches windows through the Accessibility API, catches hotkeys, and draws the bar, launcher, borders and settings window. Good entry points:
  - `TilingController.swift`: connects window events to the engine and applies the frames it returns
  - `KeyboardManager.swift` and `Config.swift`: keybindings and the TOML config
  - `TalysBarView.swift`, `BarController.swift`: the status bar (`AudioController.swift` and `WiFiController.swift` feed it)
  - `Settings*.swift`: the settings window
  - `Theme.swift`: built-in themes and loading custom ones

The Swift side calls the engine through the C header in `Sources/CTalysEngine/include/`.

## Testing

Run the engine's unit tests before opening a PR that touches `zig-engine/`:

```bash
cd zig-engine && zig build test
```

Add tests next to the code you change. The existing `test` blocks in `constraints.zig` are a good model.

The Swift side has no automated tests yet, so please test your change by hand with `make run`. Try it with a few apps open (a terminal, a browser, something with a minimum window size) and switch workspaces. Talys writes its log to `~/Library/Logs/Talys.log`, which is the first place to look when something misbehaves.

## Ideas for where to help

- **Multi-monitor support**: the biggest missing feature on the [roadmap](README.md#status--roadmap)
- **Signed, prebuilt releases** and a Homebrew cask, so people can install without building
- **Themes**: add one to `Theme.swift`, or share a custom `~/.config/talys/themes/<name>.toml`
- **Tests** for the Zig layouts, especially `smart.zig` and `bsp.zig`
- **Bug reports** from apps that don't tile well
- **Docs**: README fixes, config examples, screenshots

Look for issues labelled `good first issue` if you want somewhere small to start. If you plan a bigger change, open an issue first so we can agree on the approach before you put in the work.

## Reporting bugs

Please include:

- Your macOS version and Mac model
- What you did, what you expected, and what happened
- The apps involved, if a specific window misbehaves
- The relevant part of `~/Library/Logs/Talys.log`
- Your `~/.config/talys/config.toml`, if you've changed it

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each PR focused on one change.
3. Match the style of the surrounding code, and keep the engine free of macOS-specific code.
4. Run `zig build test` if you touched the engine, and try the app with `make run`.
5. Describe what changed and how you tested it. A screenshot or short screen recording helps a lot for anything visual.

Commit messages follow a simple prefix style: `Fix: ...` for bug fixes and `Update: ...` for new features and changes.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
