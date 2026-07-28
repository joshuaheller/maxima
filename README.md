# Claude Usage

A tiny native macOS menu bar app that shows your Claude usage limits at a glance.

The status item always displays two stacked mini progress bars:

- **top** — the weekly *All models* limit
- **bottom** — the weekly *Fable* limit

Both are drawn as template images (so they follow light/dark mode and menu bar
tinting) until something needs attention: warning bars turn orange, critical bars
turn red. If the data goes stale the item dims and grows a small warning triangle,
while still showing the last known numbers.

Clicking the item opens a popover with all three limits — All models, Fable, and
the current 5-hour session — each with its reset time and percentage, plus a
"Refresh now" and "Quit" button.

Usage is refreshed on launch, every 5 minutes (1 minute after a failure), on wake
from sleep, and on demand. A local notification fires the first time a *weekly*
limit crosses into warning, and again at critical — at most once per severity per
reset window.

## Requirements

- macOS 14 or later, Apple silicon
- Claude Code installed and signed in (see the Keychain note below)

## Build

```sh
./build.sh            # builds build/Claude Usage.app
./build.sh install    # also replaces /Applications/Claude Usage.app and launches it
```

The bundle is ad-hoc signed by default. To use a stable identity, create a
self-signed code-signing certificate in Keychain Access and pass it through:

```sh
SIGN_ID="My Self-Signed Cert" ./build.sh install
```

The app is deliberately **not sandboxed** and ships no entitlements — it needs to
spawn `/usr/bin/security` and reach the login keychain.

Launch-at-login is registered automatically (via `SMAppService`) on the first run
of a copy that lives in `/Applications`. macOS may ask you to approve it under
System Settings › General › Login Items.

## The Keychain note

There is no separate sign-in. The app reuses the OAuth access token that Claude
Code already stores in your login keychain, under the generic-password item
`Claude Code-credentials`.

That access is **strictly read-only**:

- the item is re-read on *every* fetch, because Claude Code rotates the token
- nothing is ever written back
- the refresh token is never touched

The read goes through a `/usr/bin/security find-generic-password` subprocess
rather than `SecItemCopyMatching`. This is deliberate: `SecItemCopyMatching` from
an ad-hoc-signed app triggers a blocking keychain permission dialog every time the
binary's identity changes (i.e. on every rebuild), whereas the `security` tool
reads it without prompting. `SecItemCopyMatching` remains as a fallback if the
subprocess fails.

If the token has expired, or the API rejects it, the popover says so — opening
Claude Code once refreshes it.

## Development

```sh
swift build && swift test
```

Headless debug hooks on the built binary:

```sh
.build/release/ClaudeUsage --fetch-once            # print live limits, no UI
.build/release/ClaudeUsage --render-test /tmp/out  # write status bar PNGs for each state
```

`CLAUDE_USAGE_FAKE_PERCENTS="85,97,50"` (all, Fable, session) overrides the parsed
percentages after a fetch, for checking colours and notifications.
