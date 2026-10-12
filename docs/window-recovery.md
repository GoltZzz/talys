# Window recovery

Talys saves the last visible frame before parking a workspace or scratchpad window, or beginning a scrolling animation that moves a column out of view. The atomic journal lives at `~/.config/talys/window-recovery.json`. Window identity combines the app PID, app launch time, and WindowServer window ID; titles are not used to match windows. Apps without an AppKit launch date (including Docker Desktop helper processes) use the kernel process start time instead. The journal records which time source to check during recovery; older journals remain readable.

If identity lookup or journal writing fails, Talys leaves that window visible. Logs identify the app/PID and whether the failure was a missing process timestamp, unavailable window identity API, failed window ID lookup, invalid frame, or unavailable journal. Identity lookup uses the dynamically resolved private macOS `_AXUIElementGetWindow` function. Its availability and behavior need validation on each supported macOS version.

## Behavior

- **Disable Tiling / Reveal All Windows:** stop animations, recover recorded windows, and leave tiling disabled. Reveal All Windows is available in both the launcher and bar menu.
- **Normal quit:** disable tiling and attempt recovery, allowing delayed retries before completing quit. Failed recovery stays recorded for the next launch or rescue command.
- **Interrupted session:** recover before initial window adoption; start with tiling disabled. Enable Tiling resumes normal rules and workspace behavior. Recovered scratchpad windows become ordinary windows.
- **Standalone rescue:** quit Talys, then run `./Talys.app/Contents/MacOS/talys --recover-windows`. Requires Accessibility access; never starts tiling. Exit status 1 indicates a lock, permission, journal, or unresolved-window problem.
- **Sleep / screen lock:** suspend tiling and stale-window cleanup while the desktop is unavailable. Temporary Accessibility failures never establish that a window has closed.
- **Window identity / disappearance events:** match refreshed Accessibility handles by PID and WindowServer ID during lookup and adoption, preserving existing membership. Window-destroyed notifications are deferred while suspended, away from the home Space, or within the wake grace period. Otherwise, a successful app-window query must confirm absence; a matching live window refreshes the tracked handle instead.
- **Display changes / wake / unlock:** preserve workspace and scratchpad membership, refresh tracked Accessibility handles by WindowServer ID, and retry recovery after 1.5, 3, 6, 12, and 20 seconds. Hidden windows are reparked while tiling runs. When disabled, retry pending recovery against current display geometry. Stale cleanup resumes after a 30-second grace period; removing an invalid handle requires three consecutive successful app-window queries confirming it is absent.

Recovery restores saved frames within the current usable display. If an app insists on a minimum size larger than that display, the title bar is kept reachable. Manually minimized windows are repositioned without unminimizing them. Closed windows of a live app or windows unavailable on another macOS Space can remain pending; return to that Space and retry. Records from ended app processes are discarded. A corrupt journal is preserved and prevents new parking rather than being silently replaced.

Only one Talys app or recovery command may run at a time. The lock is released by macOS when the process exits, including force quit. System settings recovery remains a separate `--restore-shortcuts` operation.

## Automated validation

Run `swift test`. Tests use temporary files and simulated recovery outcomes, without launching Talys or moving desktop windows. They cover saved-frame reload, PID reuse, partial failures and retries, failed persistence, corrupt data preservation, and changed display geometry.

These tests do not validate macOS Accessibility calls, private window identity lookup, native Spaces, or timing with real apps.

## Manual acceptance checklist

Record the Talys commit/build, macOS version, display geometry, and apps tested. Use a browser, terminal, Finder, and an app with a minimum window size. Keep a copy of any important work before exercising force quit.

- [ ] Put windows on several Talys workspaces, hide a scratchpad window, and scroll a column out of view. Disable Tiling. Every Talys-hidden window returns to its last visible frame, with its title bar reachable.
- [ ] Repeat with Reveal All Windows from the launcher and from the bar. Tiling remains disabled; windows stay visible. Enable Tiling again and verify recovered scratchpad windows are adopted normally.
- [ ] Disable during a scrolling animation. Verify the column returns and no delayed animation parks it again.
- [ ] Quit normally with hidden windows. Verify recovery completes before exit, and restarting after successful recovery enables tiling normally.
- [ ] Force quit with workspace, scratchpad, and scrolling windows hidden. Relaunch. Windows return, and tiling starts disabled.
- [ ] Force quit during a workspace switch or scrolling animation. Relaunch. No window remains stranded.
- [ ] Repeat force quit, then run `--recover-windows` instead of relaunching. Verify windows return and no Talys UI or tiling starts.
- [ ] Run the rescue command while Talys is running. It refuses to run and does not move windows.
- [ ] With windows parked, sleep/wake and close/reopen the lid. Check workspace and scratchpad recovery.
- [ ] Lock with Control-Command-Q, unlock, and verify the same workspace assignments and scratchpad state. Repeat with lid closure on the built-in display; wait at least 30 seconds and verify cleanup does not erase living windows.
- [ ] After unlock, activate existing windows and verify no duplicate workspace entries appear. Close a window during the wake grace period and verify it is eventually removed by stale cleanup; after the grace period, closing a window updates the layout normally.
- [ ] Park windows, force quit, disconnect the display hosting the parking corner, then recover on the remaining display. Window title bars are reachable.
- [ ] Test recovery while away from the original macOS Space, then return and retry. Unavailable windows retain their recovery records.
- [ ] Close one recorded window, leave another with the same title open, and recover. Verify recovery does not mistake the second window for the closed one.
- [ ] Minimize a parked window through its app, then recover. It stays minimized; unminimizing reveals it at a usable frame.
- [ ] Verify Spotlight, Mission Control shortcuts, and menu bar restoration on normal quit and separately through `--restore-shortcuts` after force quit.

Do not mark release-readiness recovery blockers complete until the manual checks pass on supported macOS versions.
