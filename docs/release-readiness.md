# Talys release readiness

Created: October 12, 2026

This checklist records recommendations from an initial codebase inspection. Items describe work to implement or verify; they are not all confirmed defects. Existing capabilities should be validated before adding replacements.

## Recommended first release

Publish a signed, notarized **single-display public beta**. Prioritize reliable window handling, installation, onboarding, and recovery. Additional layouts and visual features can wait; multi-monitor support can follow in a later release.

The release should let users install Talys, understand its controls, and recover their normal desktop whenever they need to.

## Release blockers

### Distribution

- [ ] Provide a versioned, signed, notarized macOS app download.
- [ ] Verify installation and launch on a Mac outside the development environment.
- [ ] Clearly state supported macOS versions and single-display scope.

### Window and system recovery

- [ ] Verify that normal quit and disabling tiling reveal every managed window.
- [ ] Verify recovery after a crash or force quit while workspace or scratchpad windows are parked.
- [ ] Verify restart recovery after an interrupted workspace transition.
- [ ] Verify sleep/wake, lid closure, and display disconnection do not strand windows.
- [ ] Verify restoration of Spotlight shortcuts, Mission Control shortcuts, and menu bar settings.
- [ ] Document and verify the `talys --restore-shortcuts` recovery command.

### First-launch onboarding

- [ ] Explain why Accessibility access is required and how to grant it.
- [ ] Provide a clear retry or relaunch path after permission is granted.
- [ ] Introduce the default Option modifier and essential shortcuts.
- [ ] Explain that Talys workspaces operate within its home macOS Space and that native fullscreen pauses tiling.
- [ ] Clearly explain the optional menu bar and Spotlight replacements.

### App compatibility

- [ ] Test representative browsers, terminals, editors, Finder, and apps with fixed minimum window sizes.
- [ ] Verify dialogs, sheets, splash screens, and transient windows do not disrupt tiling.
- [ ] Verify focus, resizing, floating, fullscreen, and window closing across those apps.
- [ ] Make app/window exclusions easy to configure and document the existing rule behavior.

### Release validation

- [ ] Run Zig engine tests automatically in CI.
- [ ] Establish a repeatable manual macOS release checklist covering workspaces, scratchpad, layouts, settings, shortcuts, and recovery.
- [ ] Record the tested app version, macOS versions, and relevant compatibility limitations for each release.

## High-priority improvements

### Accessible recovery controls

- [ ] Make pause/disable tiling easy to discover.
- [ ] Provide an obvious way to bring all managed windows back on screen.
- [ ] Make system shortcut and menu bar restoration easy to discover.

Some controls already exist. Review their discoverability before implementing new ones.

### Configuration feedback

- [ ] Surface invalid TOML and invalid settings with actionable error messages.
- [ ] Preserve the last working configuration when a reload fails.
- [ ] Ensure users can diagnose configuration problems without reading logs.
- [ ] Resolve the README's automatic-reload claim: implement file watching or document explicit reload accurately.

### User documentation

- [ ] Add installation, update, and uninstall instructions, including system setting restoration.
- [ ] Add screenshots and a concise shortcut reference.
- [ ] Document supported environments and known limitations.
- [ ] Explain how to report bugs and locate logs.

## Later releases

- [ ] Multi-monitor support with deliberate per-display layout and workspace behavior.
- [ ] Homebrew distribution.
- [ ] Automatic updates.
- [ ] Additional layouts, themes, and visual refinements based on user feedback.

## Implementation areas needing special validation

### Window parking

Hidden workspace and scratchpad windows are parked at a display corner. A wallpaper panel covers the remaining visible portion. Recovery must work when execution stops before a transition completes or display geometry changes.

Relevant code: [`WindowParking.swift`](../Sources/Talys/WindowParking.swift), [`TilingController.swift`](../Sources/Talys/TilingController.swift).

### macOS Space detection

Space detection uses private macOS APIs resolved at runtime. When unavailable, the current fallback leaves Talys unpaused. Validate this fallback deliberately, especially around native fullscreen and switching macOS Spaces.

Relevant code: [`SpaceMonitor.swift`](../Sources/Talys/SpaceMonitor.swift).

### Configuration reload behavior

The inspected paths expose explicit reload actions and immediate application through Settings. Automatic file watching was not identified during the initial inspection. Confirm behavior before updating implementation or documentation.

Relevant code: [`Config.swift`](../Sources/Talys/Config.swift), [`main.swift`](../Sources/Talys/main.swift), [`SettingsModel.swift`](../Sources/Talys/SettingsModel.swift), [`README.md`](../README.md).

## Initial inspection limits

- The app was not launched or exercised interactively.
- Zig tests were attempted but could not run because cache creation failed with `PermissionDenied`; test results remain unverified.
- The repository documents no Swift automated tests yet.
- This checklist is a release planning reference, not a completed security or correctness audit.
