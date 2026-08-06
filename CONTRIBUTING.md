# Contributing

Thanks for taking an interest. This is a small, deliberately boring app, and the
bar for merging is mostly "does it keep the app small and boring".

## Licensing of contributions

By submitting a contribution you agree that:

- your contribution is licensed under the [MIT License](LICENSE), the same terms
  as the rest of the project, and
- you grant aucentiq solutions GmbH a non-exclusive, transferable, sublicensable,
  worldwide and royalty-free right to use your contribution, including the right
  to distribute it under other license terms.

This second point exists so the project can change license or be redistributed
later without having to track down every past contributor. It does not take any
rights away from you: you keep the copyright in your work and may use it however
you like.

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by` line, which you get with:

```sh
git commit -s -m "fix: …"
```

That line certifies the [Developer Certificate of Origin 1.1](https://developercertificate.org/):
in short, that you wrote the patch or otherwise have the right to submit it under
the project's license.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`,
`docs:`, `refactor:`, `chore:`, optionally scoped (`fix(keychain): …`). Release
notes are generated from these, so a clear subject line ends up in front of users.

## The credential rule

The app reads one thing it does not own: the OAuth access token that Claude Code
stores in your login keychain. Everything about how it touches that token is a
deliberate constraint, not an implementation detail:

- **The refresh token is never touched.** Only `accessToken` is read out of the
  credential blob.
- **Nothing is ever written back.** The keychain item belongs to Claude Code,
  which rotates it; this app re-reads it on every fetch and never modifies it.
- **The token never leaves the machine** except as the `Authorization` header on
  the single request to `api.anthropic.com`, and it is never logged, persisted,
  or written to disk.
- **No retry storms.** A rejected or failing request backs off; it does not
  hammer the endpoint.

Pull requests that relax any of these will not be merged, however convenient the
feature. If you think one of them has to give, open an issue first and let's talk
about it before you write the code.

## Before you open a PR

```sh
swift build && swift test
```

CI runs the same thing on every push and pull request. Please keep the tests
green, and add coverage for parsing or state-machine changes — those are the
parts where a regression is silent.

## Scope

Things that fit: correctness fixes, better handling of API responses, appearance
and accessibility work in the menu bar and popover, tests.

Things that probably don't: telemetry or analytics of any kind, bundled
dependencies, anything that writes to the keychain, and features that turn a
one-purpose menu bar item into a dashboard.
