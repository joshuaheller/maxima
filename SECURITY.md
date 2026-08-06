# Security Policy

Maxima reads an OAuth access token out of your login keychain, so credential
handling is the part of this project where a bug matters most. Reports about it
are very welcome.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting instead:
[**Report a vulnerability**](../../security/advisories/new). That opens a private
advisory visible only to you and the maintainer.

If you would rather use email, write to `haak@aucentiq.com` with `[maxima]` in the
subject.

Useful things to include: what you observed, the version (`Maxima.app` →
CFBundleShortVersionString, or the release tag), your macOS version, and a way to
reproduce it if you have one.

This is a small project maintained by one person. Expect an acknowledgement within
a few days rather than within hours. You will be credited in the advisory unless
you would prefer otherwise.

## Supported versions

The latest release on the [releases page](../../releases) is the only supported
version. Fixes ship as a new tagged release; there are no backports.

## Especially in scope

- Anything that causes the access token or the credential blob to be logged,
  persisted, transmitted anywhere other than `api.anthropic.com`, or left readable
  by another user or process.
- Anything that writes to, corrupts, or deletes the `Claude Code-credentials`
  keychain item, which belongs to Claude Code and must be treated as read-only.
- Weaknesses in the release pipeline: signing, notarization, or the published DMG
  not matching what the tagged source builds.

## By design, not vulnerabilities

- **Reading the `Claude Code-credentials` keychain item.** This is the whole point
  of the app, it happens on your machine with your own credentials and your own
  access rights, and the read is strictly one-way. See the credential contract in
  [CONTRIBUTING.md](CONTRIBUTING.md).
- **No sandbox and no entitlements.** The app has to spawn `/usr/bin/security` and
  reach the login keychain, which sandboxing would prevent.
- **Using an undocumented usage endpoint.** `GET /api/oauth/usage` is not a public
  API and may change or stop working without notice. That is a stability caveat,
  not a security issue.
- **Locally built binaries are ad-hoc signed.** Only the DMGs published on the
  releases page are signed with a Developer ID certificate and notarized.
