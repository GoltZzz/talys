# Talys

A custom tiling window manager for macOS inspired by Hyprland and Omarchy.

Talys pairs a high-performance **Zig** tiling engine (pure computation, no OS dependencies) with a native **Swift** macOS platform integration layer (Accessibility APIs, CGEvent global taps, AXObservers, and LaunchAgent lifecycle).

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│                   Swift Layer                          │
│                                                        │
│  • CGEvent tap (global hotkey capture)                 │
│  • AXUIElement / Accessibility API (window control)    │
│  • AXObserver & NSWorkspace (reactive auto-tiling)     │
│  • FloatingBarPanel & SwiftUI Omarchy Bar Overlay      │
│  • SystemMetrics (IOKit battery, CoreWLAN, CoreAudio)  │
│  • TalysDesktopState (@Observable shared state)        │
│  • TOML config parser & hot-reload                     │
│  • App lifecycle & LaunchAgent daemon                  │
│                                                        │
│         calls via C ABI (zero overhead) ↕              │
├────────────────────────────────────────────────────────┤
│                    Zig Layer                           │
│                                                        │
│  • BSP tree & Dwindle auto-splitting                   │
│  • Master-Stack & Monocle layout modes                 │
│  • Geometric directional focus & swap                  │
│  • Inner & outer gap calculation                       │
│  • Floating window & fullscreen tracking               │
│  • Pure computation. No platform deps. Portable.       │
└────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
talys/
├── Makefile                          # Unified build pipeline
├── Package.swift                     # Swift Package Manager manifest
├── Resources/
│   ├── Info.plist                    # App bundle metadata (LSUIElement=true)
│   └── com.talys.wm.plist            # User LaunchAgent definition
├── zig-engine/
│   ├── build.zig                     # Zig build script (produces static C lib & tests)
│   └── src/
│       ├── root.zig                  # Root export file
│       ├── bsp.zig                   # Binary Space Partitioning tree & dwindle math
│       ├── tiling.zig                # Layout computation & C ABI exports
│       └── geometry.zig              # Rect & gap inset math
└── Sources/
    ├── CTalysEngine/                 # C bridge
    │   ├── shim.c                    # SPM C-target shim
    │   └── include/
    │       ├── module.modulemap      # Clang module definition
    │       └── talys_engine.h        # C declarations
    └── Talys/
        ├── main.swift                # App entry point & NSApplication lifecycle
        ├── Accessibility.swift       # AXUIElement window manipulation & queries
        ├── KeyboardManager.swift     # CGEvent global hotkey tap & dispatch table
        ├── TilingController.swift    # Central coordinator between Swift & Zig
        ├── WindowObserver.swift      # AXObserver for window creation/destruction/focus
        ├── AppLifecycleObserver.swift# NSWorkspace observer for app launch/terminate
        ├── Config.swift              # TOML config loader (~/.config/talys/config.toml)
        ├── TalysDesktopState.swift   # Observable state for workspaces and metrics
        ├── SystemMetrics.swift       # Native hardware & temporal monitors
        ├── FloatingBarPanel.swift    # Non-activating floating NSPanel overlay
        ├── OmarchyBarView.swift      # SwiftUI themed status bar view
        ├── BarController.swift       # Overlay controller and brand menu manager
        ├── Theme.swift               # Built-in palettes, custom theme loading, ThemeManager
        ├── Launcher.swift            # Fuzzy app + command launcher panel
        ├── BorderController.swift    # Active window border overlay
        └── ShellRunner.swift         # Detached shell execution for exec binds
```

---

## Prerequisites

- macOS 14.0+ (Apple Silicon arm64)
- **Xcode 16+ / Command Line Tools** (`swift --version` >= 6.0)
- **Zig 0.14+** (`zig version` >= 0.14.0)

---

## Getting Started

### 1. Build

```bash
make build
```

This compiles:
1. The Zig static library (`libtalys_engine.a`) in `zig-engine/`
2. Normalizes Mach-O alignment for Apple's linker
3. Builds the Swift release binary
4. Assembles and signs `Talys.app`

### 2. Run

```bash
make run
```

On first launch:
- macOS will display a prompt requesting **Accessibility** permissions.
- Open **System Settings > Privacy & Security > Accessibility** and toggle `Talys` ON.
- Re-run `make run` to start the daemon.

---

## Default Hotkeys

`Mod` is `Alt` by default — change it with `[general] mod = "..."` (`alt`, `cmd`, `ctrl`, `hyper`, `meh`, or a combo like `ctrl+alt+cmd`).

| Keybind | Action | Description |
|---------|--------|-------------|
| `Mod + Space` | Launcher | Fuzzy search apps and Talys commands (themes, reload, retile…) |
| `Mod + Return` | Terminal | Default `[[bind]]` exec entry (opens a Terminal window) |
| `Mod + H/J/K/L` | Focus | Move focus to nearest window left/down/up/right |
| `Mod + Shift + H/J/K/L` | Swap | Swap focused window with its neighbor |
| `Mod + V` | Toggle Float | Toggle focused window between tiled and floating |
| `Mod + Q` | Close Window | Close the focused window |
| `Mod + R` | Retile All | Re-query all standard windows and recompute layout |
| `Mod + [` / `Mod + ]` | Resize Split | Shrink / grow split ratio of focused window (±5%) |
| `Mod + F` | Toggle Fullscreen | Monocle mode for focused window |
| `Mod + Tab` | Cycle Layout | Cycle between Dwindle → Master-Stack → Monocle |
| `Mod + S` | Toggle Scratchpad | Show/hide stashed windows centered over any workspace |
| `Mod + Shift + S` | Move to Scratchpad | Stash focused window (or pull it back out if already stashed) |
| `Mod + Shift + T` | Cycle Theme | Switch to the next theme (persisted to config) |
| `Mod + 1..9` | Switch Workspace | Switch to virtual workspace 1..9 |
| `Mod + Shift + 1..9` | Move to Workspace | Move focused window to workspace 1..9 |

Any action you leave out of `[keybindings]` keeps its default. If two binds claim the same keys, the one you wrote explicitly wins and a warning is logged.

---

## Configuration (`~/.config/talys/config.toml`)

Talys creates `~/.config/talys/config.toml` on first launch. Every key is optional; missing keys and sections fall back to defaults.

```toml
[general]
layout = "dwindle"          # "dwindle", "master_stack", "monocle"
mod = "alt"                 # modifier substituted for "mod" in binds
theme = "catppuccin_mocha"  # catppuccin_mocha, tokyo_night, gruvbox, rose_pine, nord, or a custom theme

[gaps]
inner = 8.0
outer = 10.0

[borders]                   # Hyprland-style active window border
enabled = true
width = 2.0
radius = 12.0
gradient = true             # accent → secondary gradient

[animations]
enabled = true
duration_ms = 180.0

[keybindings]
focus_left = "mod+h"
launcher = "mod+space"
toggle_float = "mod+v"
# ...see the generated file for every action

# Shell command binds (run via /bin/sh, Homebrew paths on PATH)
[[bind]]
keys = "mod+return"
exec = "open -na Ghostty"

[[bind]]
keys = "mod+b"
exec = "open -a Safari"

[[window_rules]]
app = "Spotify"
workspace = 3
```

Check a config without starting the window manager:

```bash
.build/release/talys --check-config ~/.config/talys/config.toml
```

### Themes

Built-in: `catppuccin_mocha`, `tokyo_night`, `gruvbox`, `rose_pine`, `nord`. Themes recolor the bar, the launcher and window borders live. Switch from the launcher (`Theme: …`), the TALYS menu → Themes, or `Mod + Shift + T`. The choice is written back to `config.toml`.

Custom themes go in `~/.config/talys/themes/<name>.toml`. Any key you omit is inherited from `extends`:

```toml
extends = "tokyo_night"
display_name = "My Theme"
accent = "#ff79c6"
secondary = "#8be9fd"
border_active = "#ff79c6"     # optional, defaults to accent
border_active_2 = "#8be9fd"   # optional, defaults to secondary
# also: base, mantle, crust, surface0, surface1, overlay0, text, subtext0, green, red, yellow, border_inactive
```

---

## Running as a Background Daemon

To start Talys automatically at login as a user LaunchAgent:

```bash
make install-agent
```

To stop and remove:

```bash
make uninstall-agent
```

---

## Running Unit Tests

```bash
cd zig-engine && zig build test
```
