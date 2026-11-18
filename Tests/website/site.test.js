// Static checks for the website and its Vercel configuration. No network.
// Run from the repository root:  node Tests/website/site.test.js
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const SITE = path.join(__dirname, "..", "..", "website");
const html = fs.readFileSync(path.join(SITE, "index.html"), "utf8");
const vercel = JSON.parse(fs.readFileSync(path.join(SITE, "vercel.json"), "utf8"));
let failures = 0, total = 0;
function report(ok, label, detail = "") {
  total++; if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  — " + detail : ""}`);
}

const header = (name) => vercel.headers.flatMap((h) => h.headers).find((h) => h.key === name)?.value || "";

// Every inline <script> (without src, and not a JSON data block) must be allowed by its hash in the CSP.
const csp = header("Content-Security-Policy");
const inline = [...html.matchAll(/<script(?![^>]*\bsrc=)(?![^>]*application\/ld\+json)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
for (const code of inline) {
  const hash = "'sha256-" + crypto.createHash("sha256").update(code, "utf8").digest("base64") + "'";
  report(csp.includes(hash), "inline script is allowed by the CSP hash", hash);
}
report(/default-src 'self'/.test(csp) && /frame-ancestors 'none'/.test(csp) && /object-src 'none'/.test(csp), "CSP restricts defaults, framing and plugins");
report(/connect-src 'self' https:\/\/api\.github\.com/.test(csp), "CSP allows only this site and api.github.com for requests");
report(header("X-Content-Type-Options") === "nosniff" && header("X-Frame-Options") === "DENY" && !!header("Referrer-Policy"), "security headers present");

// Routes and functions.
report(vercel.rewrites?.some((r) => r.source === "/download" && r.destination === "/api/download"), "/download is rewritten to /api/download");
for (const f of Object.keys(vercel.functions || {})) report(fs.existsSync(path.join(SITE, f)), `function file exists: ${f}`);
for (const f of ["api/latest.js", "api/download.js", "api/_release.js"]) report(fs.existsSync(path.join(SITE, f)), `API file exists: ${f}`);

// Every local link and image in the page exists; every in-page anchor has a target.
const refs = [...html.matchAll(/\b(?:src|href|srcset)="([^"#?][^"]*)"/g)].map((m) => m[1].split(/\s+/)[0])
  .filter((u) => !/^(https?:|mailto:|data:|\/download$|\/api\/)/.test(u));
const missing = refs.filter((u) => !fs.existsSync(path.join(SITE, u.replace(/^\//, ""))));
report(missing.length === 0, `all ${refs.length} local files referenced by index.html exist`, missing.join(", "));
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
const anchors = [...html.matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
const broken = anchors.filter((a) => !ids.has(a));
report(broken.length === 0, `all ${anchors.length} in-page links have a target`, broken.join(", "));
const jsAnchors = [...fs.readFileSync(path.join(SITE, "main.js"), "utf8").matchAll(/href="#([a-z][\w-]*)"/g)].map((m) => m[1]);
const brokenJs = [...new Set(jsAnchors)].filter((a) => !ids.has(a));
report(jsAnchors.length > 0 && brokenJs.length === 0, `in-page links created by main.js have a target (${[...new Set(jsAnchors)].join(", ")})`, brokenJs.join(", "));

// No hardcoded release: versions and download links come from /api/latest.
report(!/data-repo="/.test(html) && !/softwareVersion/.test(html), "no hardcoded repository or version in index.html");
report(!/releases\/download\//.test(html), "no hardcoded DMG link in index.html");

console.log(failures ? `\n${failures} of ${total} FAILED` : `\nall ${total} checks passed`);
process.exit(failures ? 1 : 0);
