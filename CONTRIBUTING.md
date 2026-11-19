# Contributing to Pastly

Thanks for your interest in Pastly! Bug reports, fixes, features, documentation and design feedback are all welcome — whether it's your first open-source contribution or your hundredth.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** or **suggest a feature** with the [issue templates](https://github.com/sp201004/Pastly/issues/new/choose).
- **Fix something.** Issues labeled `good first issue` or `help wanted` are good starting points.
- **Improve the docs or website** (`README.md`, `FEATURES.md`, `website/`).
- **Report a security problem** privately — see [SECURITY.md](SECURITY.md). Please don't open a public issue for it.

For larger changes (new features, UI changes, refactors), open an issue first so we can agree on the approach before you invest time in it.

## Development environment

You need:

- An **Apple silicon** Mac with **macOS 14 Sonoma** or newer.
- Apple's **Command Line Tools** with **Swift 5.10+** — `xcode-select --install`. Full Xcode is optional.
- No other dependencies: Pastly uses only Apple's frameworks, and the build needs no package downloads, environment variables or secrets.

```bash
git clone https://github.com/<your-fork>/Pastly.git
cd Pastly
swift build && .build/debug/Pastly --self-test
```

### Keep the Accessibility permission while developing

Pasting into other apps needs Accessibility permission. Ad-hoc signed builds look like a new app to macOS on every rebuild, so the permission gets lost. Create a local, self-signed identity once:

```bash
./Scripts/create-signing-identity.sh   # once: asks for a keychain password, creates .signing/ (git-ignored — never commit it)
./Scripts/build.sh --install           # asks for that password to unlock the keychain (or set PASTLY_SIGNING_PASSWORD)
```

The new keychain is appended to your keychain search list, where codesign looks for identities; your other keychains stay as they are. The password isn't stored anywhere unless you choose to keep it in your login keychain (the script prints the command).

Then allow Pastly once in System Settings → Privacy & Security → Accessibility.

> **Your own clipboard history is real data.** A development build uses the same data folder as an installed Pastly (`~/Library/Application Support/Pastly`). For experiments, use demo mode (below), or back up first in Settings → Backup.

## Project architecture

```
Sources/Pastly/
├── App/   main.swift (command-line hooks), AppDelegate (menu bar, hotkeys, launch),
│          SelfTest (logic checks), E2ETest (real-app checks), Screenshots (+ demo data)
├── Core/  ClipboardCore (ClipboardMonitor, PasteService, self-write guard), ClipItemParser,
│          ContentHasher, CaptureFilter (exclusion rules), MediaSupport, PasteQueue, Preferences,
│          Services (hotkeys, login item, OCR, onboarding), SettingsServices (sensitive-content
│          detection, file permissions, auto backup, update check), LegacyMigration (imports data from earlier installations)
├── Data/  Models (ClipItem, SmartList/SmartRule, CodeDetector), Database (SQLite), ClipStore,
│          ImageStore, BackupService
└── UI/    PanelController (window, keyboard, AppKit drag source), PanelView, ItemViews (rows,
           preview, drag cards, media, editor), Feedback, SettingsView, SettingsTabs
```

A few design rules that keep Pastly predictable — please preserve them:

- **One paste format.** `Preferences.pastePlainByDefault` is the single source of truth, read at paste time by every path (Paste button, ↩, ⌘V, double-click, ⌘1–9, drag and drop, menu bar Recent Clips). Don't add per-view copies of it. Stored clips are never converted.
- **History order.** Only a genuinely new copy (`ClipStore.ingest`) moves a clip to the top. Pasting or selecting a clip only counts a use.
- **Self-writes.** Pastly's own clipboard writes are tagged and registered so they're never captured again.
- **Preview opens on purpose only** — a click (in Preview mode) or Space. There's no hover preview.
- **Selection is blue** (`ClipRow.selection*`).
- **Settings window is a fixed size** (600×572) with an in-window `NSSegmentedControl` tab bar, not a SwiftUI `TabView`.
- **Stored identifiers.** Don't change the content-hash identifiers (see `ClipType.canonicalUTI`) or the on-disk data format without a migration — users' existing history depends on them.

## Build

```bash
swift build                     # debug → .build/debug/Pastly
./Scripts/build.sh              # release app → build/Pastly.app
./Scripts/build.sh --install    # build and copy to /Applications
./Scripts/release.sh            # build/Pastly-v<version>.dmg + .sha256, verified, with a release report
```

Builds must finish with **no warnings**.

## Tests

**Logic checks** — required for every pull request:

```bash
swift build && .build/debug/Pastly --self-test
```

They cover capture, deduplication, exclusions, history order, paste modes, Smart Lists, backups and data migration, using private pasteboards and temporary folders. Your clipboard and history aren't touched. Add or update checks in `Sources/Pastly/App/SelfTest.swift` for any logic you change.

**Real-app checks** — run these when you touch pasting, selection, drag and drop or the panel. They drive the signed app with real mouse and keyboard events, need the Accessibility permission, use TextEdit, and add and then remove their own test clips:

```bash
./Scripts/build.sh
open -n build/Pastly.app --args --ax-status /tmp/ax.txt            # is Accessibility granted?
open -n build/Pastly.app --args --e2e /tmp/e2e.txt                 # paste, select, ⌘V, double-click, paste modes, drops
open -n build/Pastly.app --args --e2e-dragsource /tmp/ds.txt       # the dragged clip is always the one grabbed
open -n build/Pastly.app --args --e2e-finder /tmp/finder.txt       # real ⌘C in Finder for images, PDF, video, audio
```

Performance and smoothness checks run on a copy of a history folder (never your own data):

```bash
swift build -c release
PASTLY_DEMO=1 .build/release/Pastly --benchmark <history-folder>                     # redraw, search, capture and cache timings
PASTLY_DEMO=1 PASTLY_DATA_DIR=<history-folder> build/Pastly.app/Contents/MacOS/Pastly --scroll-probe /tmp/scroll.txt
                                                                                       # scrolls the real list; frame times + main-thread watchdog
```

Wait for the report file, then read it. If Accessibility looks flaky right after launch (0 rows found, "TextEdit window not found"), run the check again before suspecting the code.

The real-app checks run with your normal Pastly profile. They clean up after themselves, but an interrupted run can leave a test clip behind or a setting changed, so make a backup first (**Settings → Backup → Back Up Now**).

**Website checks** — run these when you touch `website/` (Node 18 or newer, no packages to install):

```bash
node Tests/website/release-api.test.js   # release selection, URL checks, checksum verification (offline)
node Tests/website/site.test.js          # CSP hash, security headers, local links and images
```

CI runs the self-test, the release script and both website checks on every pull request.

## Coding conventions

- Swift with 4-space indentation; small, focused types; `// MARK:` sections in longer files.
- Use Apple frameworks only. **No third-party dependencies** without prior discussion.
- Prefer clear names over comments; comment the *why* when behavior is subtle.
- Main-thread UI; heavy work (hashing, images, database) stays off the main thread as it does today.
- User-facing text: short, sentence case, macOS terminology ("System Settings → Privacy & Security").
- Keep changes focused: no drive-by reformatting or unrelated refactors in the same pull request.

## Commit messages

- Use the imperative mood and keep the subject under ~72 characters: `Fix drag source for the last visible row`.
- Optionally prefix the area: `Panel: …`, `Settings: …`, `Docs: …`, `Website: …`.
- Explain *what* and *why* in the body when it isn't obvious; reference issues with `Fixes #123`.
- One logical change per commit where practical.

## Pull requests

1. Fork the repository and create a branch from `main` (`fix/drag-last-row`, `feature/snippets`).
2. Make your change and add or update self-tests.
3. Run `swift build` (no warnings) and `--self-test` (all passing). Run the relevant real-app checks for UI or paste changes.
4. Update `CHANGELOG.md` under an **Unreleased** heading, and `README.md` / `FEATURES.md` if behavior changes.
5. Open a pull request using the template: what changed, why, how you tested it, and screenshots for UI changes.
6. A maintainer reviews it. Please be patient and open to feedback; we may ask for changes.

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).

## Reporting bugs

Use the **Bug report** template and include:

- macOS version and Mac model (Apple silicon chip)
- Pastly version (Settings → About)
- Steps to reproduce, what you expected, and what happened
- Whether Accessibility is granted (System Settings → Privacy & Security → Accessibility)
- Relevant log lines, if any: `log show --last 5m --predicate 'process == "Pastly"'`

## UI and screenshot requirements

- Include **before/after screenshots** for every visible change, in **Light and Dark Mode**.
- Capture **only demo content** — never your own clipboard. Use demo mode with a throwaway data folder:

  ```bash
  PASTLY_DEMO=1 PASTLY_DATA_DIR=/tmp/pastly-demo build/Pastly.app/Contents/MacOS/Pastly --snapshot-panel /tmp/panel
  PASTLY_DEMO=1 PASTLY_DATA_DIR=/tmp/pastly-demo build/Pastly.app/Contents/MacOS/Pastly --snapshot-settings /tmp/settings [--dark]
  swift build && .build/debug/Pastly --render-screenshots /tmp/shots
  ```

  Demo mode uses a separate preferences domain and data folder, so your clips and settings never appear.
- Website images are WebP renders of the real app (see [`website/README.md`](website/README.md)).
- Keep the existing visual language: native controls, blue selection, the brand colors in `website/style.css`.

## Clipboard privacy and security guidelines

A clipboard manager sees passwords, messages, keys and personal data. Every contribution must respect that.

- **Never include real clipboard data** in issues, pull requests, tests, logs, screenshots or fixtures. Use obviously fake examples. Assemble fake secret-like strings at run time in tests (see `SelfTest.swift`) so secret scanners don't flag them.
- **No network access** beyond the existing optional GitHub update check. No telemetry, analytics, crash reporters or remote services.
- **Never log clipboard contents** — log events and counts, not data.
- **Keep data private on disk:** the data folder stays `0700` and its files `0600` (`SecureStorage`).
- **Respect exclusions:** concealed/transient pasteboard types and excluded apps must never be stored.
- **Never commit** signing material (`.signing/`, certificates, keys), `.env` files, databases, logs or build output. The `.gitignore` covers these — don't override it.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Website

The landing page lives in `website/` — plain HTML, CSS and JavaScript with no external fonts, trackers or CDNs, plus two small Vercel functions that read GitHub Releases. See [`website/README.md`](website/README.md) for how downloads work, deployment, previews and screenshots.

Thanks again for helping make Pastly better!
