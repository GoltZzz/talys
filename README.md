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
│  • NSStatusItem (menu bar icon & controls)             │
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
        └── StatusBarController.swift # macOS menu bar status item
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

| Keybind | Action | Description |
|---------|--------|-------------|
| `Alt + H` | Focus Left | Move focus to nearest window on the left |
| `Alt + J` | Focus Down | Move focus to nearest window below |
| `Alt + K` | Focus Up | Move focus to nearest window above |
| `Alt + L` | Focus Right | Move focus to nearest window on the right |
| `Alt + Shift + H` | Swap Left | Swap focused window with neighbor to the left |
| `Alt + Shift + J` | Swap Down | Swap focused window with neighbor below |
| `Alt + Shift + K` | Swap Up | Swap focused window with neighbor above |
| `Alt + Shift + L` | Swap Right | Swap focused window with neighbor to the right |
| `Alt + Space` | Toggle Float | Toggle focused window between tiled and floating |
| `Alt + Q` | Close Window | Close the focused window |
| `Alt + R` | Retile All | Re-query all standard windows and recompute layout |
| `Alt + [` | Shrink Split | Decrease split ratio of focused window (-5%) |
| `Alt + ]` | Grow Split | Increase split ratio of focused window (+5%) |
| `Alt + F` | Toggle Fullscreen | Monocle mode for focused window |
| `Alt + Tab` | Cycle Layout | Cycle between Dwindle → Master-Stack → Monocle |
| `Alt + 1..9` | Switch Workspace | Switch to virtual workspace 1..9 |
| `Alt + Shift + 1..9` | Move to Workspace | Move focused window to workspace 1..9 |

---

## Configuration (`~/.config/talys/config.toml`)

Talys automatically creates `~/.config/talys/config.toml` with default settings on initial launch:

```toml
[gaps]
inner = 8.0
outer = 10.0

[general]
layout = "dwindle" # Options: "dwindle", "master_stack", "monocle"

[animations]
enabled = true
duration_ms = 180.0

[keybindings]
focus_left = "alt+h"
focus_down = "alt+j"
focus_up = "alt+k"
focus_right = "alt+l"
swap_left = "alt+shift+h"
swap_down = "alt+shift+j"
swap_up = "alt+shift+k"
swap_right = "alt+shift+l"
toggle_float = "alt+space"
close_window = "alt+q"
retile = "alt+r"
resize_shrink = "alt+["
resize_grow = "alt+]"
toggle_fullscreen = "alt+f"
cycle_layout = "alt+tab"

switch_workspace_1 = "alt+1"
switch_workspace_2 = "alt+2"
switch_workspace_3 = "alt+3"
switch_workspace_4 = "alt+4"
switch_workspace_5 = "alt+5"
switch_workspace_6 = "alt+6"
switch_workspace_7 = "alt+7"
switch_workspace_8 = "alt+8"
switch_workspace_9 = "alt+9"

move_to_workspace_1 = "alt+shift+1"
move_to_workspace_2 = "alt+shift+2"
move_to_workspace_3 = "alt+shift+3"
move_to_workspace_4 = "alt+shift+4"
move_to_workspace_5 = "alt+shift+5"
move_to_workspace_6 = "alt+shift+6"
move_to_workspace_7 = "alt+shift+7"
move_to_workspace_8 = "alt+shift+8"
move_to_workspace_9 = "alt+shift+9"
```

You can reload your configuration anytime from the menu bar item or by modifying the file and clicking **Reload Config**.

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
