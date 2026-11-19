# Pastly website

A static page (`index.html`, `style.css`, `main.js`, `img/`) plus two small serverless functions that read
GitHub Releases. No build step, no npm packages, no external fonts, trackers or CDNs.

```
website/
├── index.html, style.css, main.js, img/   the page
├── api/_release.js                        shared release reader and checks (not a route: files starting with "_" aren't)
├── api/latest.js                          GET /api/latest  → release information as JSON
├── api/download.js                        GET /api/download → 302 to the checked DMG (also served at /download)
└── vercel.json                            /download rewrite, security headers, function limits
```

## How downloads work

The page never contains a version number or a download link of its own. On load, `main.js` calls
`/api/latest`, and the function asks GitHub for the repository's releases:

1. **Stable release.** The newest published release that isn't a draft or marked *pre-release*. Older releases are
   never used as a fallback.
2. **DMG checks.** The release must have **exactly one** `.dmg` asset that is fully uploaded, between 1 byte and
   100 MB, with a download URL on `github.com/<repo>/releases/download/…`.
3. **Published checksum.** It must also have `<dmg name>.sha256` containing one line,
   `<64 hex characters>  <dmg name>`. That's the format `./Scripts/release.sh` writes.
4. **Server-side SHA-256.** The function downloads the DMG itself (time-limited, size-limited, every redirect hop
   checked against GitHub's own hosts), hashes it, and compares the hash with the published checksum. The byte count
   must equal the size GitHub reports.
5. **Result.** Only when every check passes does the page show the version, date, size, release notes, the checksum
   ("SHA-256 integrity check passed") and the **Download** button. If anything fails, no installer is offered and
   the page points to building from source instead.

A matching checksum only shows that the file is the one the project published. It does **not** prove the app is safe,
and the page says so.

**Pre-releases** ("Set as a pre-release" on GitHub) appear in a separate *Experimental pre-release* card, only when
they're newer than the stable release and pass the same checks. They never change the main Download buttons or
`/download`.

**`/download`** redirects (302) to the checked stable DMG, or to `/#download` when there isn't one. Link to it from
anywhere: it always follows the latest stable release.

**Caching.** Successful answers are cached at the edge for 5 minutes (`s-maxage=300`, with
`stale-while-revalidate`), errors for 1 minute. Each DMG is hashed once per warm function instance and asset version.
After a new release is published, the site shows it within about 5 minutes, without a redeploy.

**Rate limits.** Without a token, GitHub allows 60 API requests an hour per server IP. Edge caching keeps the site
well below that. Set `GITHUB_TOKEN` for a higher limit. When GitHub is unavailable or rate-limited, the page says
release details are temporarily unavailable and offers no installer.

## Deploy on Vercel

1. Import the repository in Vercel and set **Root Directory** to `website`. Framework preset: *Other*. Leave the
   build and output settings empty.
2. Add the environment variables (Project → Settings → Environment Variables, for Production and Preview):

   | Variable | Required | Value |
   |---|---|---|
   | `GITHUB_REPO` | yes | `owner/name` of the **public** repository, for example `sp201004/Pastly`. Without it, the page shows "No prebuilt download yet". There's no default. |
   | `GITHUB_TOKEN` | no | A fine-grained token with **read-only** access to public repositories (no other permissions). Only raises the API rate limit. |
   | `PASTLY_NOTARIZED` | no | Leave unset. Set to `true` only once releases are Developer ID signed **and** notarized, which removes the "not notarized" note. |

3. Deploy, then check `https://<your-domain>/api/latest` and `https://<your-domain>/download`.

The repository must be public: GitHub's API returns 404 for a private repository, and the page then shows no download.

## Publishing a release the site can offer

```bash
./Scripts/release.sh          # → build/Pastly-v<version>.dmg and its .sha256 (verified), e.g. Pastly-v0.7.1.dmg
```

Create a GitHub release with a tag like `v0.7.0`, paste the release notes, attach **both** `Pastly-vX.Y.Z.dmg` and
`Pastly-vX.Y.Z.dmg.sha256`, and publish it. Don't tick *Set as a pre-release* for a stable release. Renaming the DMG means
regenerating the `.sha256`, because the checksum line must name the file exactly.

## Preview locally

```bash
open website/index.html                       # the page only; release section shows its safe fallback
python3 -m http.server -d website 8000        # same, over http
vercel dev website                            # with the API functions (needs the Vercel CLI and GITHUB_REPO)
```

Add `?static` to the URL to turn off the scroll fade-in (handy for screenshots). Offline tests (from the repository
root, Node 18 or newer): `node Tests/website/release-api.test.js` for the release logic and
`node Tests/website/site.test.js` for the page and Vercel configuration.

## Screenshots (all rendered from the real app with demo data)

```bash
swift build && .build/debug/Pastly --render-screenshots website/img          # list, previews, multi, smart, drag cards
for m in light dark; do                                                             # real Settings window, 7 sections
  PASTLY_DEMO=1 PASTLY_DATA_DIR=/tmp/ps-demo-$m build/Pastly.app/Contents/MacOS/Pastly \
    --snapshot-settings /tmp/set-$m $([ $m = dark ] && echo --dark)
done
# then copy /tmp/set-<mode>-<section>.png to website/img/settings-<section>-<mode>.png and convert to WebP:
for f in website/img/*.png; do cwebp -quiet -q 86 "$f" -o "${f%.png}.webp"; done
```

Demo mode uses a throwaway data folder and preferences domain, so your own clips and settings never appear.

## Privacy

The page sets no cookies and loads nothing from third parties. The only requests leaving the browser are
`/api/latest` (this site) and one call to `api.github.com` for the repository's star count.

`vercel.json` sends a Content-Security-Policy that allows only this site's own files and those two requests. The one
inline `<script>` in `index.html` is allowed by its SHA-256 hash: if you change it, update the hash in `vercel.json`.
`node Tests/website/site.test.js` checks the hash, the security headers and every local link and image.
