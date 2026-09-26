# Security Policy

Talys runs with **Accessibility** access so it can move and resize windows, catch hotkeys, and read window titles. That's a lot of trust to give an app, so security reports are taken seriously.

## Supported versions

Talys is early-stage and has no versioned releases yet. Only the latest commit on `main` is supported. Please check that a problem still happens there before reporting it.

## Reporting a vulnerability

**Please don't open a public issue for security problems.**

Report them privately through GitHub instead: go to the [Security tab](https://github.com/GoltZzz/talys/security) and click **Report a vulnerability**.

Helpful things to include:

- What the problem is and what an attacker could do with it
- Steps to reproduce, or a proof of concept
- Your macOS version and the Talys commit you tested

You should hear back within a week. Once the issue is confirmed, a fix will go out as soon as possible, and you'll be credited in the fix unless you'd rather not be.

## What Talys does and doesn't do

To help you judge what counts as a security issue:

- Talys asks only for Accessibility permission. It does not need SIP disabled and does not inject code into other apps.
- Talys makes no network requests.
- Talys changes a few macOS settings while it runs (the Spotlight shortcut, menu bar auto-hide, Mission Control shortcuts) and puts them back when it quits. After a force quit, run `talys --restore-shortcuts`.
- Configuration lives in a single local TOML file.

If Talys does anything beyond this list, such as reaching the network, touching other settings, or keeping data it shouldn't, please report it.
