# Security Policy

Pastly sees everything you copy, so we take security and privacy reports seriously. Thank you for helping keep Pastly users safe.

## Supported versions

Security fixes are made for the **latest release** only. Please check that the issue still exists in the newest version (Settings → About → Check for Updates) before reporting.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Older releases | ❌ — please update |

## Reporting a vulnerability

**Please do not report security vulnerabilities in public issues, discussions or pull requests.**

Report privately through GitHub instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** to open a private security advisory.

Only you and the maintainers can see the report. If private reporting isn't available on the repository yet, open a public issue that says only *"I'd like to report a security issue privately"* — **without any details** — and a maintainer will arrange a private channel.

### What to include

- A description of the issue and its impact (for example: clipboard data stored despite an exclusion rule, data readable by other users, unexpected network access, code execution).
- The Pastly version (Settings → About), macOS version and Mac model.
- Step-by-step instructions to reproduce, and a proof of concept if you have one.
- Any relevant configuration (exclusion rules, privacy settings) and log lines.
- Whether the issue is already known publicly.

**Never include real clipboard contents, passwords or personal data** in a report — use made-up examples.

## How reports are handled

1. **Acknowledgement:** we aim to confirm receipt within 7 days.
2. **Assessment:** we reproduce the issue, assess severity and keep you updated on progress.
3. **Fix:** we develop and test a fix privately and publish a new release.
4. **Disclosure:** once the fix is available, we publish a security advisory and credit you if you'd like.

This is a volunteer-maintained project, so timelines may vary, but we'll keep you informed.

## Why private disclosure matters

Publishing a vulnerability before a fix exists gives attackers a head start while users have no way to protect themselves. A clipboard manager often holds passwords, tokens and private messages, so an exposed flaw can cause real harm. Coordinated disclosure gives us time to ship a fix and lets users update before the details become public.

Please give us a reasonable amount of time to release a fix before sharing details publicly.

## Scope

In scope:

- The Pastly app and its handling of clipboard data, storage, backups, exclusions and permissions.
- The build and release scripts in this repository.
- The project website in `website/`.

Out of scope:

- The first-launch Gatekeeper warning on builds that aren't notarized (this is documented behavior).
- Vulnerabilities in macOS itself — please report those to [Apple](https://security.apple.com).
- Issues that require an already-compromised Mac or user account.

## Security design at a glance

- All data stays on the Mac in `~/Library/Application Support/Pastly` (folder `0700`, files `0600`).
- No accounts, sync, telemetry or analytics. The only network request is an optional GitHub update check that reads the latest release number.
- Concealed and transient pasteboard types used by password managers are never stored; apps, keywords, patterns and content kinds can be excluded.
- No third-party dependencies.
