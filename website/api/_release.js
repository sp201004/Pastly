// Shared GitHub Releases reader for /api/latest and /download (Vercel serverless, Node 18+, no dependencies).
// Files starting with "_" are not exposed as routes by Vercel.
//
// A DMG is offered only when ALL of these pass:
//   1. the release is published (not a draft) and not marked "pre-release" — pre-releases are reported
//      separately as "experimental" and are never the default download;
//   2. it has exactly one .dmg asset, fully uploaded, with a plausible size;
//   3. every URL (and every redirect hop) points to GitHub's own hosts for this repository;
//   4. its "<dmg name>.sha256" asset is a valid SHA-256 line for exactly that file name;
//   5. the DMG itself, downloaded here, hashes to that same SHA-256 (size and time limited).
// A checksum match only shows the file is the one the publisher posted — it does not show the app is safe.

const crypto = require("crypto");

const REPO_RE = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;
const ASSET_HOSTS = new Set(["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
                             "github-releases.githubusercontent.com"]);
const LIMITS = {
  apiTimeoutMs: 8000,
  checksumMaxBytes: 1024,
  checksumTimeoutMs: 5000,
  dmgMaxBytes: 100 * 1024 * 1024,
  dmgTimeoutMs: 20000,
  maxRedirects: 5,
};

function repoName() {
  const r = (process.env.GITHUB_REPO || "").trim();
  return REPO_RE.test(r) ? r : null;
}

// ---------- URL validation ----------

function parse(u) { try { return new URL(u); } catch { return null; } }
/** Decoded, lower-cased path; "" for malformed escapes (which then fail every check below). */
function lowerPath(u) { try { return decodeURIComponent(u.pathname).toLowerCase(); } catch { return ""; } }

function isReleasePage(u, repo) {
  const x = parse(u);
  return !!x && x.protocol === "https:" && x.hostname === "github.com" && !x.username && !x.password &&
         lowerPath(x).startsWith(`/${repo.toLowerCase()}/releases/`);
}
function isAssetUrl(u, repo) {
  const x = parse(u);
  return !!x && x.protocol === "https:" && x.hostname === "github.com" && !x.username && !x.password &&
         lowerPath(x).startsWith(`/${repo.toLowerCase()}/releases/download/`);
}
function isSourceUrl(u, repo) {
  const x = parse(u);
  if (!x || x.protocol !== "https:" || x.hostname !== "api.github.com" || x.username || x.password) return false;
  const p = lowerPath(x), base = `/repos/${repo.toLowerCase()}/`;
  return p.startsWith(base + "zipball/") || p.startsWith(base + "tarball/");
}

// ---------- Network helpers (timeouts, validated redirects, size limits) ----------

async function withTimeout(ms, fn) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms);
  try { return await fn(ctl.signal); } finally { clearTimeout(timer); }
}

function apiHeaders() {
  const h = { Accept: "application/vnd.github+json", "User-Agent": "pastly-website", "X-GitHub-Api-Version": "2022-11-28" };
  if (process.env.GITHUB_TOKEN) h.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;   // optional: higher rate limit
  return h;
}

class LimitError extends Error {}

/** Follows redirects by hand so every hop can be checked: GitHub's asset hosts only, and on github.com
 *  itself only this repository's release downloads. */
async function fetchAsset(url, signal, repo) {
  let current = url;
  for (let hop = 0; hop <= LIMITS.maxRedirects; hop++) {
    const x = parse(current);
    if (!x || x.protocol !== "https:" || !ASSET_HOSTS.has(x.hostname) || x.username || x.password) throw new LimitError("host");
    if (x.hostname === "github.com" && !isAssetUrl(current, repo)) throw new LimitError("path");
    const r = await fetch(current, { redirect: "manual", signal, headers: { "User-Agent": "pastly-website", Accept: "application/octet-stream" } });
    if (r.status >= 300 && r.status < 400) {
      const loc = r.headers.get("location");
      if (!loc) throw new LimitError("redirect");
      current = new URL(loc, current).toString();
      continue;
    }
    if (!r.ok) throw new LimitError(`status ${r.status}`);
    return r;
  }
  throw new LimitError("redirects");
}

/** Reads a body with a hard byte limit, feeding each chunk to `onChunk`. Returns the byte count. */
async function readLimited(res, maxBytes, onChunk) {
  if (!res.body) throw new LimitError("body");
  const reader = res.body.getReader();
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) { try { await reader.cancel(); } catch {} throw new LimitError("size"); }
    onChunk(value);
  }
  return total;
}

// ---------- Checks ----------

/** The published checksum: "<64 hex>  <file name>" for exactly `dmgName`. */
async function publishedChecksum(asset, dmgName, repo) {
  if (!asset || asset.state !== "uploaded" || !(asset.size > 0) || asset.size > LIMITS.checksumMaxBytes) return { error: "checksum-missing" };
  if (!isAssetUrl(asset.browser_download_url, repo)) return { error: "checksum-url" };
  try {
    const text = await withTimeout(LIMITS.checksumTimeoutMs, async (signal) => {
      const res = await fetchAsset(asset.browser_download_url, signal, repo);
      const parts = [];
      await readLimited(res, LIMITS.checksumMaxBytes, (c) => parts.push(Buffer.from(c)));
      return Buffer.concat(parts).toString("utf8").trim();
    });
    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (lines.length !== 1) return { error: "checksum-invalid" };
    const m = lines[0].match(/^([0-9a-fA-F]{64}) [ *](.+)$/);
    if (!m || m[2].trim() !== dmgName) return { error: "checksum-invalid" };
    return { sha256: m[1].toLowerCase() };
  } catch (e) {
    return { error: e.name === "AbortError" ? "checksum-timeout" : "checksum-unavailable" };
  }
}

// Results by asset identity, so each DMG is downloaded and hashed once per warm instance.
const hashCache = new Map();

/** Downloads the DMG and hashes it; the byte count must match GitHub's size. */
async function actualDmgHash(asset, repo) {
  const key = `${repo}|${asset.id}|${asset.updated_at}|${asset.size}`;
  if (hashCache.has(key)) return hashCache.get(key);
  let result;
  try {
    result = await withTimeout(LIMITS.dmgTimeoutMs, async (signal) => {
      const res = await fetchAsset(asset.browser_download_url, signal, repo);
      const hash = crypto.createHash("sha256");
      const n = await readLimited(res, LIMITS.dmgMaxBytes, (c) => hash.update(c));
      if (n !== asset.size) return { error: "size-mismatch" };
      return { sha256: hash.digest("hex") };
    });
  } catch (e) {
    result = { error: e.name === "AbortError" ? "hash-timeout" : e instanceof LimitError && e.message === "size" ? "too-large" : "hash-unavailable" };
  }
  if (result.sha256 || result.error === "size-mismatch") {         // cache definite answers, not transient failures
    if (hashCache.size > 50) hashCache.clear();
    hashCache.set(key, result);
  }
  return result;
}

/** Selects and checks the DMG of a release. Returns { dmg } on success or { dmgCheck: reason }. */
async function checkDmg(rel, repo) {
  const assets = Array.isArray(rel.assets) ? rel.assets : [];
  const dmgs = assets.filter((a) => typeof a.name === "string" && /\.dmg$/i.test(a.name));
  if (dmgs.length === 0) return { dmgCheck: "no-dmg" };
  if (dmgs.length > 1) return { dmgCheck: "ambiguous" };
  const dmg = dmgs[0];
  if (dmg.state !== "uploaded") return { dmgCheck: "not-uploaded" };
  if (!Number.isSafeInteger(dmg.size) || dmg.size <= 0) return { dmgCheck: "invalid-size" };
  if (dmg.size > LIMITS.dmgMaxBytes) return { dmgCheck: "too-large" };
  if (!isAssetUrl(dmg.browser_download_url, repo)) return { dmgCheck: "untrusted-url" };

  const published = await publishedChecksum(assets.find((a) => a.name === dmg.name + ".sha256"), dmg.name, repo);
  if (published.error) return { dmgCheck: published.error };
  const actual = await actualDmgHash(dmg, repo);
  if (actual.error) return { dmgCheck: actual.error };
  if (actual.sha256 !== published.sha256) return { dmgCheck: "hash-mismatch" };
  return { dmg: { name: dmg.name, size: dmg.size, url: dmg.browser_download_url, sha256: published.sha256, integrity: "passed" } };
}

function summarize(rel, repo) {
  const source = {};
  if (isSourceUrl(rel.zipball_url, repo)) source.zip = rel.zipball_url;
  if (isSourceUrl(rel.tarball_url, repo)) source.tar = rel.tarball_url;
  return {
    version: String(rel.tag_name || "").slice(0, 64),
    name: String(rel.name || rel.tag_name || "").slice(0, 200),
    date: rel.published_at || null,
    url: isReleasePage(rel.html_url, repo) ? rel.html_url : null,
    notes: String(rel.body || "").slice(0, 20000),
    prerelease: !!rel.prerelease,
    source,
  };
}

async function latest() {
  const repo = repoName();
  const notarized = process.env.PASTLY_NOTARIZED === "true";   // set only once builds are Developer ID signed + notarized
  if (!repo) return { status: "not-configured", repo: null, notarized, stable: null, experimental: null };

  let list;
  try {
    list = await withTimeout(LIMITS.apiTimeoutMs, async (signal) => {
      const r = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, { headers: apiHeaders(), signal });
      if (r.status === 404) return { status: "no-repository" };
      if (r.status === 403 || r.status === 429) {
        const remaining = r.headers.get("x-ratelimit-remaining");
        return { status: remaining === "0" || r.status === 429 ? "rate-limited" : "unavailable" };
      }
      if (!r.ok) return { status: "unavailable" };
      return { releases: await r.json() };
    });
  } catch {
    list = { status: "unavailable" };
  }
  if (!list.releases) return { status: list.status, repo, notarized, stable: null, experimental: null };

  const releases = (Array.isArray(list.releases) ? list.releases : []).filter((r) => r && !r.draft);
  const stableRel = releases.find((r) => !r.prerelease);
  const preRel = releases.find((r) => r.prerelease);

  let stable = null;
  if (stableRel) {
    const c = await checkDmg(stableRel, repo);
    stable = { ...summarize(stableRel, repo), dmg: c.dmg || null, dmgCheck: c.dmg ? "passed" : c.dmgCheck };
  }
  let experimental = null;
  if (preRel && (!stableRel || new Date(preRel.published_at) > new Date(stableRel.published_at))) {
    const c = await checkDmg(preRel, repo);
    if (c.dmg) experimental = { ...summarize(preRel, repo), dmg: c.dmg, dmgCheck: "passed" };
  }
  return { status: releases.length ? "ok" : "no-release", repo, notarized, stable, experimental };
}

module.exports = { latest, isAssetUrl, isReleasePage, isSourceUrl, LIMITS, _hashCache: hashCache };
