// Offline tests for the website's release API (website/api). No network: fetch is replaced by simulated GitHub
// responses, and checksum cases use temporary fixture files hashed independently with the system's `shasum`.
// Run from the repository root:  node Tests/website/release-api.test.js   (Node 18 or newer)
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const API = path.join(__dirname, "..", "..", "website", "api");
const R = "owner/Pastly";
const DMG_NAME = "Pastly-v0.7.1.dmg";   // release.sh naming: <App>-v<version>.dmg
const CDN = "https://release-assets.githubusercontent.com/x";
const dl = (n) => `https://github.com/${R}/releases/download/v0.7.0/${n}`;
let failures = 0, total = 0;
function report(ok, label, detail = "") {
  total++; if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  — " + detail : ""}`);
}

/** Loads the API modules fresh, with the given environment and a fake fetch. */
function load(env, fakeFetch) {
  for (const k of Object.keys(require.cache)) if (k.startsWith(API)) delete require.cache[k];
  process.env.GITHUB_REPO = env.repo ?? R;
  process.env.PASTLY_NOTARIZED = env.notarized ?? "";
  global.fetch = async (url, opts) => {
    const r = await fakeFetch(url, opts);
    if (r === undefined) throw new Error("network disabled in tests: " + url);
    return r;
  };
  const mod = require(path.join(API, "_release.js"));
  mod.LIMITS.apiTimeoutMs = 300; mod.LIMITS.checksumTimeoutMs = 300; mod.LIMITS.dmgTimeoutMs = 300;
  return { mod, latestHandler: require(path.join(API, "latest.js")), downloadHandler: require(path.join(API, "download.js")) };
}
function fakeRes() {
  return { headers: {}, statusCode: 0, body: undefined,
    setHeader(k, v) { this.headers[k] = v; return this; }, status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; }, end() { return this; } };
}

// ---------- 1. Release selection, URL validation and failure handling (simulated GitHub) ----------

const DMG = Buffer.alloc(150000, 7);
const GOOD = crypto.createHash("sha256").update(DMG).digest("hex");
const asset = (o) => Object.assign({ id: 1, name: DMG_NAME, state: "uploaded", size: DMG.length, updated_at: "t1", browser_download_url: dl(DMG_NAME) }, o);
const shaAsset = (o) => Object.assign({ id: 2, name: DMG_NAME + ".sha256", state: "uploaded", size: 80, updated_at: "t1", browser_download_url: dl(DMG_NAME + ".sha256") }, o);
const rel = (o) => Object.assign({ tag_name: "v0.7.0", name: "Pastly 0.7.0", published_at: "2026-11-20T10:00:00Z", draft: false, prerelease: false,
  html_url: `https://github.com/${R}/releases/tag/v0.7.0`, body: "<script>alert(1)</script> notes",
  zipball_url: `https://api.github.com/repos/${R}/zipball/v0.7.0`, tarball_url: `https://api.github.com/repos/${R}/tarball/v0.7.0`,
  assets: [asset(), shaAsset()] }, o);

function simulated(sc) {
  return (url, opts = {}) => {
    const hang = sc.hang && (sc.hang.startsWith("https://api") ? url.startsWith(sc.hang) : url === sc.hang);
    if (hang) return new Promise((_, reject) => opts.signal.addEventListener("abort", () => { const e = new Error("aborted"); e.name = "AbortError"; reject(e); }));
    if (url.startsWith("https://api.github.com/repos/")) {
      if (sc.api) return new Response("{}", { status: sc.api.status, headers: sc.api.headers || {} });
      return new Response(JSON.stringify(sc.releases), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("https://github.com/")) return new Response(null, { status: 302, headers: { location: sc.redirect || CDN + "?f=" + encodeURIComponent(url) } });
    if (url.startsWith(CDN)) {
      const f = decodeURIComponent(url.split("?f=")[1] || "");
      if (f.endsWith(".sha256")) return new Response(sc.sha ?? `${GOOD}  ${DMG_NAME}\n`, { status: 200 });
      return new Response(sc.dmgBytes ?? DMG, { status: 200 });
    }
    return new Response("not GitHub", { status: 200 });   // any other host — must never be used
  };
}

const cases = [
  // label, scenario, expected status, DMG offered?, expected stable.dmgCheck, experimental listed?
  ["missing GITHUB_REPO", { repo: "" }, "not-configured", false],
  ["malformed GITHUB_REPO", { repo: "owner/Pastly; rm -rf" }, "not-configured", false],
  ["GitHub rate limit (403, remaining 0)", { api: { status: 403, headers: { "x-ratelimit-remaining": "0" } } }, "rate-limited", false],
  ["GitHub 429", { api: { status: 429 } }, "rate-limited", false],
  ["GitHub API unavailable (500)", { api: { status: 500 } }, "unavailable", false],
  ["GitHub API timeout", { hang: "https://api.github.com" }, "unavailable", false],
  ["repository private or missing (404)", { api: { status: 404 } }, "no-repository", false],
  ["no releases", { releases: [] }, "no-release", false],
  ["release without a DMG", { releases: [rel({ assets: [] })] }, "ok", false, "no-dmg"],
  ["multiple DMG assets", { releases: [rel({ assets: [asset(), asset({ id: 9, name: "Pastly-2.dmg", browser_download_url: dl("Pastly-2.dmg") }), shaAsset()] })] }, "ok", false, "ambiguous"],
  ["DMG not fully uploaded", { releases: [rel({ assets: [asset({ state: "starter" }), shaAsset()] })] }, "ok", false, "not-uploaded"],
  ["DMG size 0", { releases: [rel({ assets: [asset({ size: 0 }), shaAsset()] })] }, "ok", false, "invalid-size"],
  ["DMG size not a number", { releases: [rel({ assets: [asset({ size: "big" }), shaAsset()] })] }, "ok", false, "invalid-size"],
  ["DMG over 100 MB", { releases: [rel({ assets: [asset({ size: 200 * 1024 * 1024 }), shaAsset()] })] }, "ok", false, "too-large"],
  ["wrong hostname in DMG URL", { releases: [rel({ assets: [asset({ browser_download_url: "https://evil.example/Pastly.dmg" }), shaAsset()] })] }, "ok", false, "untrusted-url"],
  ["another repository's asset URL", { releases: [rel({ assets: [asset({ browser_download_url: "https://github.com/someone/else/releases/download/v1/Pastly.dmg" }), shaAsset()] })] }, "ok", false, "untrusted-url"],
  ["javascript: DMG URL", { releases: [rel({ assets: [asset({ browser_download_url: "javascript:alert(1)" }), shaAsset()] })] }, "ok", false, "untrusted-url"],
  ["malformed % escape in DMG URL", { releases: [rel({ assets: [asset({ browser_download_url: `https://github.com/${R}/releases/download/v1/%E0%A4%A.dmg` }), shaAsset()] })] }, "ok", false, "untrusted-url"],
  ["redirect to an untrusted host", { releases: [rel({})], redirect: "https://evil.example/payload.dmg" }, "ok", false, "checksum-unavailable"],
  ["github.com redirect outside this repository", { releases: [rel({})], redirect: "https://github.com/someone/else/raw/main/evil.dmg" }, "ok", false, "checksum-unavailable"],
  ["no .sha256 asset", { releases: [rel({ assets: [asset()] })] }, "ok", false, "checksum-missing"],
  ["incorrect published checksum", { releases: [rel({})], sha: `${"b".repeat(64)}  ${DMG_NAME}` }, "ok", false, "hash-mismatch"],
  ["DMG download timeout", { releases: [rel({})], hang: CDN + "?f=" + encodeURIComponent(dl(DMG_NAME)) }, "ok", false, "hash-timeout"],
  ["draft release only", { releases: [rel({ draft: true })] }, "no-release", false],
  ["pre-release only → experimental, never the default", { releases: [rel({ prerelease: true })] }, "ok", false, null, true],
  ["older stable + newer pre-release kept separate", { releases: [rel({ tag_name: "v0.8.0-beta.1", prerelease: true, published_at: "2026-12-01T00:00:00Z" }), rel({})] }, "ok", true, "passed", true],
  ["newer stable hides an older pre-release", { releases: [rel({}), rel({ tag_name: "v0.7.0-beta.1", prerelease: true, published_at: "2026-11-01T00:00:00Z" })] }, "ok", true, "passed", false],
  ["javascript: release page URL is dropped", { releases: [rel({ html_url: "javascript:alert(1)" })] }, "ok", true, "passed"],
  ["valid stable release", { releases: [rel({})] }, "ok", true, "passed"],
  ["legacy generic name Pastly.dmg (as on the published v0.7.0 release) still works", { releases: [rel({ assets: [
    asset({ name: "Pastly.dmg", browser_download_url: dl("Pastly.dmg") }),
    shaAsset({ name: "Pastly.dmg.sha256", browser_download_url: dl("Pastly.dmg.sha256") })] })],
    sha: `${GOOD}  Pastly.dmg\n` }, "ok", true, "passed", undefined, "Pastly.dmg"],
  ["versioned DMG name (Pastly-v0.7.2.dmg + .sha256)", { releases: [rel({ assets: [
    asset({ name: "Pastly-v0.7.2.dmg", browser_download_url: dl("Pastly-v0.7.2.dmg") }),
    shaAsset({ name: "Pastly-v0.7.2.dmg.sha256", browser_download_url: dl("Pastly-v0.7.2.dmg.sha256") })] })],
    sha: `${GOOD}  Pastly-v0.7.2.dmg\n` }, "ok", true, "passed", undefined, "Pastly-v0.7.2.dmg"],
  ["versioned DMG whose checksum names the old generic file", { releases: [rel({ assets: [
    asset({ name: "Pastly-v0.7.2.dmg", browser_download_url: dl("Pastly-v0.7.2.dmg") }),
    shaAsset({ name: "Pastly-v0.7.2.dmg.sha256", browser_download_url: dl("Pastly-v0.7.2.dmg.sha256") })] })] }, "ok", false, "checksum-invalid"],
];

async function releaseCases() {
  console.log("Release selection and validation");
  for (const [label, sc, wantStatus, wantOffered, wantCheck, wantExperimental, dmgName = DMG_NAME] of cases) {
    const { mod, downloadHandler } = load({ repo: sc.repo }, simulated(sc));
    const data = await mod.latest();
    const res = fakeRes(); await downloadHandler({}, res);
    const offered = res.headers.Location !== "/#download";
    const check = data.stable ? data.stable.dmgCheck : null;
    let ok = data.status === wantStatus && offered === wantOffered && (wantCheck === undefined || check === wantCheck)
          && !!data.experimental === !!wantExperimental && res.statusCode === 302;
    if (wantOffered) ok = ok && res.headers.Location === dl(dmgName) && data.stable.dmg.name === dmgName && data.stable.dmg.integrity === "passed" && data.stable.dmg.sha256 === GOOD;
    if (label.startsWith("javascript: release page")) ok = ok && data.stable.url === null;
    if (wantExperimental) ok = ok && data.experimental.prerelease === true && data.experimental.dmg.integrity === "passed";
    report(ok, label, `status=${data.status} check=${check} /download→${offered ? "DMG" : "#download"}${data.experimental ? " +experimental" : ""}`);
  }
}

// ---------- 2. Checksum verification with real files (hashed independently by shasum) ----------

async function fixtureCases() {
  console.log("\nChecksum verification with temporary fixture files");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pastly-release-test-"));
  try {
    const file = (n) => path.join(dir, n);
    fs.writeFileSync(file(DMG_NAME), crypto.randomBytes(3 * 1024 * 1024));
    // The system's own tool computes the expected value: "<hash>  <DMG_NAME>\n" (shasum on macOS, sha256sum on Linux).
    let good;
    try { good = execFileSync("shasum", ["-a", "256", DMG_NAME], { cwd: dir }).toString(); }
    catch { good = execFileSync("sha256sum", [DMG_NAME], { cwd: dir }).toString(); }
    const hash = good.split(" ")[0];
    const tampered = fs.readFileSync(file(DMG_NAME)); tampered[1000] ^= 0xff; fs.writeFileSync(file("tampered.dmg"), tampered);
    fs.writeFileSync(file("truncated.dmg"), fs.readFileSync(file(DMG_NAME)).subarray(0, 3000000));
    const sums = {
      "good.sha256": good, "binary.sha256": `${hash} *${DMG_NAME}\n`, "wronghash.sha256": `${"0".repeat(64)}  ${DMG_NAME}\n`,
      "wrongname.sha256": `${hash}  Other.dmg\n`, "malformed.sha256": "not a checksum\n", "twolines.sha256": good + good,
    };
    for (const [n, t] of Object.entries(sums)) fs.writeFileSync(file(n), t);

    const fixtures = [
      ["correct DMG + shasum's checksum file", DMG_NAME, "good.sha256", "passed"],
      ["correct DMG + binary-mode (*) checksum line", DMG_NAME, "binary.sha256", "passed"],
      ["DMG with one byte changed", "tampered.dmg", "good.sha256", "hash-mismatch"],
      ["DMG shorter than GitHub's stated size", "truncated.dmg", "good.sha256", "size-mismatch", 3 * 1024 * 1024],
      ["wrong published hash", DMG_NAME, "wronghash.sha256", "hash-mismatch"],
      ["checksum names another file", DMG_NAME, "wrongname.sha256", "checksum-invalid"],
      ["malformed checksum file", DMG_NAME, "malformed.sha256", "checksum-invalid"],
      ["checksum file with two lines", DMG_NAME, "twolines.sha256", "checksum-invalid"],
    ];
    for (const [label, dmgFile, shaFile, want, statedSize] of fixtures) {
      const size = (n) => fs.statSync(file(n)).size;
      const { mod } = load({}, (url) => {
        const u = new URL(url);
        if (u.hostname === "api.github.com") return new Response(JSON.stringify([rel({ assets: [
          asset({ size: statedSize ?? size(dmgFile), updated_at: dmgFile }), shaAsset({ size: size(shaFile), updated_at: shaFile })] })]), { status: 200 });
        if (u.hostname === "github.com") return new Response(null, { status: 302, headers: { location: `${CDN}/${path.basename(u.pathname)}` } });
        if (url === `${CDN}/${DMG_NAME}`) return new Response(fs.readFileSync(file(dmgFile)), { status: 200 });
        if (url === `${CDN}/${DMG_NAME}.sha256`) return new Response(fs.readFileSync(file(shaFile)), { status: 200 });
        return undefined;
      });
      const s = (await mod.latest()).stable;
      const ok = s.dmgCheck === want && (want === "passed" ? !!s.dmg && s.dmg.sha256 === hash : !s.dmg);
      report(ok, label, `${s.dmgCheck}${s.dmg ? ", offered" : ", not offered"}`);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ---------- 3. Caching and HTTP handlers ----------

async function cacheAndHandlers() {
  console.log("\nCaching and HTTP responses");
  let dmgFetches = 0;
  const sc = { releases: [rel({})] }, base = simulated(sc);
  const { mod, latestHandler, downloadHandler } = load({}, (url, opts) => {
    if (url.startsWith(CDN) && !decodeURIComponent(url).endsWith(".sha256")) dmgFetches++;
    return base(url, opts);
  });
  const a = await mod.latest(), b = await mod.latest();
  report(a.stable.dmg.integrity === "passed" && b.stable.dmg.integrity === "passed" && dmgFetches === 1,
    "a DMG is downloaded and hashed once per asset version", `${dmgFetches} download(s) for 2 requests`);

  const res = fakeRes(); await latestHandler({}, res);
  report(res.statusCode === 200 && /s-maxage=300/.test(res.headers["Cache-Control"]) && res.headers["X-Content-Type-Options"] === "nosniff"
    && res.body.stable.dmg.integrity === "passed" && res.body.notarized === false,
    "/api/latest: 200, cached 5 min, nosniff, not notarized", res.headers["Cache-Control"]);
  const d = fakeRes(); await downloadHandler({}, d);
  report(d.statusCode === 302 && d.headers.Location === dl(DMG_NAME), "/download: 302 to the checked DMG");

  const down = load({}, simulated({ api: { status: 500 } }));
  const r2 = fakeRes(); await down.latestHandler({}, r2);
  report(r2.statusCode === 503 && /s-maxage=60/.test(r2.headers["Cache-Control"]) && r2.body.stable === null,
    "/api/latest when GitHub fails: 503, cached 1 min, no release", r2.headers["Cache-Control"]);
  const d2 = fakeRes(); await down.downloadHandler({}, d2);
  report(d2.statusCode === 302 && d2.headers.Location === "/#download", "/download when GitHub fails: 302 to /#download");

  const notar = load({ notarized: "true" }, simulated(sc));
  report((await notar.mod.latest()).notarized === true, "PASTLY_NOTARIZED=true is reported (only set it for notarized builds)");
}

(async () => {
  await releaseCases();
  await fixtureCases();
  await cacheAndHandlers();
  console.log(failures ? `\n${failures} of ${total} FAILED` : `\nall ${total} checks passed`);
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
