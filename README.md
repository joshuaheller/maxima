# Maxima

A tiny native macOS menu bar app that shows your Claude Code and Codex usage limits at a
glance.

The status item shows, from left to right:

- a small Claude-style sunburst, so Maxima is easy to pick out of the menu bar
- two stacked mini progress bars — **top** the weekly *All models* limit, **bottom**
  the weekly *Fable* limit — without percentage labels. They turn orange as a limit
  approaches and red when critical.
- a vertical gauge for the current **5-hour session**, coloured on a continuous
  green→red scale by how much of the session is used, with the time left until it
  resets shown beside it (e.g. `2h` or `12m`).
- a terminal glyph followed by two Codex bars: **top** the 5-hour limit, **bottom**
  the weekly limit, with compact reset countdowns (e.g. `2h` / `7d`).
  Unavailable windows display `–`; they are never treated as zero usage.

The item follows light and dark mode. If a provider fetch fails it grows a
small warning triangle, while still showing the last known numbers.

Clicking the item opens a popover with Claude and Codex limits, each with its
exact local reset time and percentage, plus a
"Refresh now" and "Quit" button.

Usage is refreshed on launch, every 5 minutes (1 minute after a failure), on wake
from sleep, and on demand. A local notification fires the first time a *weekly*
limit crosses into warning, and again at critical — at most once per severity per
reset window.

## Requirements

- macOS 14 or later, Apple silicon
- Claude Code installed and signed in (see [Credentials](#credentials) below)
- For Codex limits: Codex desktop or CLI installed and signed in with ChatGPT.
  Maxima calls the local `codex app-server` method `account/rateLimits/read`.
  Codex manages its own credentials; Maxima does not read or store Codex tokens.
  Account-wide limits are selected by their actual duration; model-specific
  buckets (such as Spark) are not substituted for missing account-wide limits.
  Reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server).

## Install

Download the latest `Maxima-<version>.dmg` from the
[releases page](../../releases), open it, and drag **Maxima** to Applications.

Release builds are signed with a Developer ID certificate and notarized by Apple,
so they open without a Gatekeeper warning. Each release also carries a
`checksums.txt` if you want to verify the download:

```sh
shasum -a 256 -c checksums.txt
```

Launch-at-login is registered automatically (via `SMAppService`) on the first run
of a copy that lives in `/Applications`. macOS may ask you to approve it under
System Settings › General › Login Items.

## Credentials

There is no separate sign-in. Maxima reuses the OAuth access token that Claude
Code already stores in your login keychain, under the generic-password item
`Claude Code-credentials`.

How that token is handled is a fixed contract, not an implementation detail:

- **The refresh token is never touched.** Only the access token is read.
- **Nothing is ever written back.** The keychain item belongs to Claude Code,
  which rotates it, so it is re-read on *every* fetch and never modified.
- **The token never leaves your machine** except as the `Authorization` header on
  a single `GET` to `api.anthropic.com`. It is never logged or persisted.
- **No retry storms.** Failures back off rather than hammering the endpoint.

These rules are binding on contributions too — see [CONTRIBUTING.md](CONTRIBUTING.md).

The read goes through a `/usr/bin/security find-generic-password` subprocess
rather than `SecItemCopyMatching`. This is deliberate: `SecItemCopyMatching` from
an ad-hoc-signed app triggers a blocking keychain permission dialog every time the
binary's identity changes (i.e. on every local rebuild), whereas the `security`
tool reads it without prompting. `SecItemCopyMatching` remains as a fallback if
the subprocess fails.

If the token has expired, is empty, or the API rejects it, the popover says so —
opening Claude Code once (signing in again if needed) refreshes it.

When the token has *expired*, Maxima also tries to fix it automatically: it runs
`claude -p` once in the background, which makes Claude Code refresh and re-store the
token on start-up, then re-reads. This happens at most once per failure episode, and
only if the `claude` CLI is on your `PATH`; otherwise the manual hint stays. Maxima
itself still never touches the refresh token or writes to the keychain — Claude Code
does. (The headless `.build/release/Maxima --nudge-once` runs just this step.)

## Build from source

```sh
./build.sh            # builds build/Maxima.app
./build.sh install    # also replaces /Applications/Maxima.app and launches it
./build.sh dmg        # also packages dist/Maxima-<version>.dmg
```

Local builds are ad-hoc signed by default. To use a stable identity, create a
self-signed code-signing certificate in Keychain Access and pass it through:

```sh
SIGN_ID="My Self-Signed Cert" ./build.sh install
```

`VERSION=1.2.3` stamps the bundle version; leave it unset and the committed
`Info.plist` value is used.

The app is deliberately **not sandboxed** and ships no entitlements — it needs to
spawn `/usr/bin/security` and reach the login keychain.

## Development

```sh
swift build && swift test
```

CI runs the same on every push and pull request.

Headless debug hooks on the built binary:

```sh
.build/release/Maxima --fetch-once            # print live limits, no UI
.build/release/Maxima --render-test /tmp/out  # write status bar PNGs for each state
```

`MAXIMA_FAKE_PERCENTS="85,97,50"` (all, Fable, session) overrides the parsed
percentages after a fetch, for checking colours and notifications.

## Releasing

Releases are cut by pushing a tag. Nothing else triggers a build.

```sh
git tag -a v1.2.3 -m "v1.2.3"
git push origin v1.2.3
```

The release workflow then runs the tests, builds and signs the app, packages the
DMG, submits it to Apple for notarization, staples the ticket, generates
checksums, and publishes a GitHub Release with notes derived from the commits
since the previous tag. Tags follow [semver](https://semver.org/) and the tag
drives `CFBundleShortVersionString`, so `v1.2.3` ships as version `1.2.3`.

If a release fails, delete the tag (locally and on the remote), fix the problem,
and tag again — the workflow is safe to re-run.

### Required repository secrets

Signing and notarization need six secrets. They belong to the **`release`
environment** (*Settings › Environments › release › Environment secrets*), not to
the repository, so a workflow running on a branch cannot reach the signing key.

Configure that environment with *Deployment branches and tags → Selected branches
and tags → Tag rule `v*`*, and optionally a required reviewer, so a release pauses
for approval before anything is signed.

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate and private key, exported as `.p12` and base64-encoded |
| `P12_PASSWORD` | The export password for that `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string; used for the throwaway keychain on the runner |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `NOTARY_KEY_P8` | The `AuthKey_*.p8` API key file, base64-encoded |

No team ID is needed: `notarytool` authenticates with the API key triple, and
`codesign` takes the team from the certificate itself.

The certificate is imported into a temporary keychain that is deleted at the end
of the run, and the notary key is written to the runner's temp directory and
removed in the same cleanup step.

## Licence

[MIT](LICENSE) — Copyright © 2026 aucentiq solutions GmbH.

## Trademarks

Not affiliated with, endorsed by, or sponsored by Anthropic. Claude and Claude
Code are trademarks of Anthropic PBC. Maxima reads usage data for your own Claude
Code installation, using credentials that are already on your machine.
