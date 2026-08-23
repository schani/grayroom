# Grayroom — guidance for Claude

## Follow Lightroom unless there is a good reason not to

Grayroom is a focused subset of Lightroom Classic. Keep Lightroom's idioms, UI
conventions, and keyboard shortcuts unless there is a specific, stated reason to
deviate. When the user describes a feature "like Lightroom", research what
Lightroom actually does (layout, keys, selection semantics, toggle behaviour)
and match it — including details the user did not mention. If the user's
request contradicts Lightroom (e.g. a key that Lightroom assigns to something
else), point it out before implementing.

Examples of idioms to keep: `g`/`d` switch between Library and Develop; `6`–`9`
set the red/yellow/green/blue color labels and pressing the same key again
clears it; `p`/`u`/`x` flag/unflag/reject; the Import dialog's separate
"include" checkbox vs highlight selection; the activity indicator in the
top-left identity plate.

## Engineering

- Headless first: everything in the imaging core must be exercisable from the
  `grayroom` CLI and `swift test` without the GUI (see PLAN.md).
- `swift build && swift test` must pass on a plain terminal. If a build looks
  stale, check the repo root for stray `*.o`/`*.d` files (SwiftPM corruption).
- App self-tests (`GRAYROOM_SELFTEST=...`) must run with `CFFIXED_USER_HOME`
  pointed at a throwaway home so they never touch the real library.
- The SQLite library is the only persistence; there are no sidecars.
