# Releasing Pastly

How a release is built, signed and published, what the current signing does and doesn't do, and the plan for
notarization once an Apple Developer Program membership is available.

## Signing today: transparent limits

Pastly releases are **not notarized by Apple** and **not signed with a Developer ID certificate**. Both require a
paid Apple Developer Program membership, which the project doesn't have.

| | Current releases |
|---|---|
| App signature | Self-signed local certificate (`Scripts/create-signing-identity.sh`), or ad-hoc (`codesign -s -`) when built by someone without it. No Team ID, no hardened runtime |
| DMG signature | None |
| Notarization | None, and no ticket is stapled |
| Gatekeeper (`spctl`) | **Rejected.** macOS blocks the first launch until the user approves it |
| Integrity | Every DMG ships with `Pastly.dmg.sha256`. The website offers a DMG only after the published checksum and its own SHA-256 of the file agree |

A self-signed or ad-hoc signature proves only that the app wasn't changed after it was signed. It says nothing
about who signed it, and Apple hasn't scanned it. A matching SHA-256 proves only that the download is the file the
project published, not that the app is safe. The README, the DMG's setup guide and the website say this plainly. They
never call a build notarized, "verified by Apple" or "Gatekeeper-approved".

**What users do once (first launch):**

1. Drag Pastly to Applications and open it. macOS says it can't verify the app. Click **Done** (not *Move to Trash*).
2. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the
   message about Pastly. Confirm with Touch ID or the login password.
3. Open Pastly again and choose **Open**. macOS remembers the choice.

On macOS 14 the Control-click → **Open** shortcut also works. Gatekeeper stays on for everything else.

**Never** (in scripts, docs, CI or support answers): disable Gatekeeper (`spctl --master-disable`), strip quarantine
as part of a build or install script, present the self-signed certificate as a Developer ID, or set `PASTLY_NOTARIZED`
for a build that isn't notarized.

**Accessibility across updates.** macOS ties the Accessibility permission to the signature. Releases signed with the
same local certificate keep the permission when users update. An ad-hoc build, or a change of certificate, makes
macOS ask again (users remove Pastly from the Accessibility list with **–** and add it again). Sign every release with
the same certificate, and keep `.signing/` backed up and private: it's git-ignored and must never be committed.

## Making a release

1. **Version.** Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. **Changelog.** Add a section to `CHANGELOG.md`. The release notes are copied from it.
3. **Tests.**
   ```bash
   swift build && .build/debug/Pastly --self-test
   node Tests/website/release-api.test.js && node Tests/website/site.test.js
   ```
   Then run the real-app checks in [CONTRIBUTING.md](CONTRIBUTING.md#tests) for paste and drag changes.
4. **Build.** `./Scripts/release.sh` creates `build/Pastly.dmg` and `build/Pastly.dmg.sha256`, mounts the DMG and
   checks it. Among the checks: signature intact, app identical to the build, checksum matches, and no clipboard
   history, database or backup inside. It then prints a report on architecture, minimum macOS, signature,
   notarization and Gatekeeper. Every check must pass.
5. **Fresh-install check.** On a Mac (or user account) that has never run Pastly, install from the DMG. The
   history must start empty, with only the built-in *Today* and *This Week* Smart Lists, in
   `~/Library/Application Support/Pastly`.
6. **Tag and publish.** Commit, tag `vX.Y.Z`, push, then create the GitHub release:
   - Tag `vX.Y.Z`, title `Pastly X.Y.Z`. For the notes, paste the output of `./Scripts/release-notes.sh`: the
     changelog section, the first-launch steps, the actual signing status and the checksum.
   - Attach **both** `Pastly.dmg` and `Pastly.dmg.sha256`, unrenamed (the checksum line names the file).
   - Leave *Set as a pre-release* off for a stable release. Turn it on for experimental builds: the website then
     lists them separately and never makes them the default download.
7. **Verify.** Within about 5 minutes the website shows the new version. Check `/api/latest` (`"integrity":
   "passed"`), click **Download**, compare `shasum -a 256 Pastly.dmg` with the page, and open the app once on a
   second Mac.

## Plan: Developer ID signing and notarization (needs a membership)

Nothing below should be done until someone decides to enroll in the Apple Developer Program (a paid, yearly
membership). The scripts are already prepared for it, so no code changes are needed.

1. **Enroll** in the Apple Developer Program with the account that will own the releases.
2. **Certificate.** In Xcode (Settings → Accounts → Manage Certificates) or at developer.apple.com, create a
   **Developer ID Application** certificate and install it in the login keychain. Export a `.p12` backup and store
   it offline. Never commit it (`*.p12` is git-ignored).
3. **Notarization credentials.** Create an app-specific password for the Apple ID (or an App Store Connect API
   key), then store them once in the keychain:
   ```bash
   xcrun notarytool store-credentials pastly-notary --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
   ```
4. **Build.** `./Scripts/release.sh` detects the certificate and the `pastly-notary` profile. It then:
   - signs the app with the hardened runtime and a secure timestamp (Pastly needs no extra entitlements; tested);
   - notarizes and staples the app;
   - builds, signs, notarizes and staples the DMG.
   
   The report must show `Notarized: yes (stapled: yes)` and the Gatekeeper lines must say
   `accepted, source=Notarized Developer ID`.
5. **Check on a clean Mac**: the first launch shows only the normal "downloaded from the internet" prompt, with no
   Open Anyway.
6. **Update the docs and website together**, in the same release:
   - set `PASTLY_NOTARIZED=true` in Vercel, which removes the "not notarized" notes from the download section;
   - README → Installation and Troubleshooting;
   - `Resources/DMG-ReadMe.txt`;
   - the website's install steps and FAQ;
   - FEATURES.md and README roadmap entries.
7. **Tell users** in the release notes that the signature changed. macOS will ask once more for Accessibility (remove
   Pastly from the list with **–** and add it again).

Keep the local self-signed certificate until the first notarized release is out. Then development builds can keep
using it, while releases use Developer ID.
