// Pastly website: GitHub links & live release info, navigation, reveal, settings tour, playground.
(function () {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- GitHub repository (from the release API, never hardcoded) ---------- */
  // /api/latest reports the repository set in Vercel (GITHUB_REPO). Until then — e.g. a local preview —
  // the GitHub links keep pointing at sections of this page.
  const REPO_RE = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;
  let repo = null;

  function applyRepo(name) {
    if (typeof name !== "string" || !REPO_RE.test(name)) return;
    repo = name;
    const gh = "https://github.com/" + repo;
    const links = {
      repo: gh, releases: gh + "/releases", issues: gh + "/issues", docs: gh + "#readme",
      license: gh + "/blob/main/LICENSE", contributing: gh + "/blob/main/CONTRIBUTING.md", changelog: gh + "/blob/main/CHANGELOG.md",
      security: gh + "/security/policy",
    };
    $$("[data-link]").forEach((a) => {
      const href = links[a.dataset.link];
      if (!href) return;
      a.href = href; a.target = "_blank"; a.rel = "noopener";
    });
    $$("[data-repo-text]").forEach((el) => (el.textContent = repo));
    fetch(`https://api.github.com/repos/${repo}`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((info) => {
        const el = $("[data-repo-stats]");
        if (el && Number.isFinite(info.stargazers_count)) el.textContent = `★ ${info.stargazers_count.toLocaleString()} on GitHub →`;
      })
      .catch(() => {});
  }

  // Second line of defense behind the server: HTTPS URLs on GitHub for this repository only.
  function safeUrl(u, kind) {
    if (!repo || typeof u !== "string") return null;
    let x;
    try { x = new URL(u); } catch { return null; }
    if (x.protocol !== "https:" || x.username || x.password) return null;
    let path;
    try { path = decodeURIComponent(x.pathname).toLowerCase(); } catch { return null; }
    const r = repo.toLowerCase();
    const ok =
      kind === "asset" ? x.hostname === "github.com" && path.startsWith(`/${r}/releases/download/`) :
      kind === "release" ? x.hostname === "github.com" && path.startsWith(`/${r}/releases/`) :
      kind === "source" ? x.hostname === "api.github.com" &&
                          (path.startsWith(`/repos/${r}/zipball/`) || path.startsWith(`/repos/${r}/tarball/`)) :
      false;
    return ok ? x.toString() : null;
  }

  /** A DMG the server checked (published checksum + its own hash), re-validated here. */
  function checkedDmg(d) {
    if (!d || d.integrity !== "passed") return null;
    if (typeof d.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(d.sha256)) return null;
    if (!Number.isSafeInteger(d.size) || d.size <= 0) return null;
    if (typeof d.name !== "string" || !/\.dmg$/i.test(d.name)) return null;
    const url = safeUrl(d.url, "asset");
    return url ? { name: d.name, size: d.size, sha256: d.sha256, url } : null;
  }

  /* ---------- Download section (release info from /api/latest) ---------- */
  // A DMG is shown only when the server's two checks passed (published SHA-256 + its own hash of the
  // file) and checkedDmg() agrees. Any failure — including no API on a local preview — offers no installer.
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const fmtSize = (b) => (b > 1e6 ? (b / 1e6).toFixed(1) + " MB" : Math.round(b / 1e3) + " KB");
  function fmtDate(d) {
    const t = d ? new Date(d) : null;
    return t && !isNaN(t) ? t.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : "";
  }

  const release = $("#release");
  const installDmg = $("#install-dmg"), installSource = $("#install-source");
  let notarized = false;

  const MESSAGES = {
    "not-configured": "Release information isn't available on this page yet.",
    "no-repository": "The project's repository isn't public yet.",
    "no-release": "No stable release has been published yet.",
    "rate-limited": "Release details are temporarily unavailable, so no installer is offered right now.",
    "unavailable": "Release details are temporarily unavailable, so no installer is offered right now.",
  };

  function showInstallSteps(dmgOffered) {
    if (installDmg) installDmg.hidden = !dmgOffered;
    if (installSource) installSource.hidden = dmgOffered;
  }
  function setRelease(html) {
    release.innerHTML = html;
    release.removeAttribute("aria-busy");
  }
  function releasesButton() {
    return repo ? `<a class="btn btn-ghost btn-small" href="${esc("https://github.com/" + repo + "/releases")}" target="_blank" rel="noopener">Releases page</a>` : "";
  }
  function pageButton(r) {
    const page = safeUrl(r.url, "release");
    return page ? `<a class="btn btn-ghost btn-small" href="${esc(page)}" target="_blank" rel="noopener">Release page</a>` : "";
  }
  function notesBlock(r) {
    return typeof r.notes === "string" && r.notes.trim()
      ? `<details class="release-notes"><summary>Release notes</summary><pre>${esc(r.notes.slice(0, 4000))}</pre></details>` : "";
  }
  function notarizedNote() {
    return notarized ? "" :
      `<p class="release-warning">Not notarized by Apple yet. On first launch macOS asks you to confirm it — see the installation steps.</p>`;
  }
  function checksumBlock(d, id) {
    return `<div class="sha">
         <p class="integrity">SHA-256 integrity check passed</p>
         <div class="sha-row"><code id="${id}">${esc(d.sha256)}</code>
           <button class="sha-copy" type="button" data-copy-sha="${id}" aria-label="Copy SHA-256 checksum">Copy</button></div>
         <p class="fine">This confirms the file matches the checksum the project published. It doesn't prove the app is safe.</p>
         <span class="sr-only" role="status" aria-live="polite"></span>
       </div>`;
  }

  function showNoRelease(reason) {
    showInstallSteps(false);
    setRelease(
      `<h3>No prebuilt download yet</h3>
       <p>${esc(reason)} You can build Pastly from source in a couple of minutes.</p>
       <div class="cta-row"><a class="btn btn-primary btn-small" href="#build-cmd">Build from source</a>${releasesButton()}</div>`);
  }

  function showStable(r, d) {
    showInstallSteps(true);
    const date = fmtDate(r.date);
    setRelease(
      `<h3>Pastly ${esc(r.version)}</h3>
       <p>${date ? "Released " + esc(date) + " · " : ""}${esc(d.name)} · ${fmtSize(d.size)} · Apple silicon, macOS 14 or newer</p>
       ${notarizedNote()}
       <div class="cta-row">
         <a class="btn btn-primary btn-small" href="${esc(d.url)}">Download ${esc(d.name)}</a>${pageButton(r)}
       </div>
       ${checksumBlock(d, "dmg-sha")}${notesBlock(r)}`);
    $$('[data-link="download"]').forEach((a) => (a.href = d.url));
    $$("[data-dmg-name]").forEach((el) => (el.textContent = d.name));   // e.g. Pastly-v0.7.1.dmg in the install steps
  }

  function showSourceOnly(r, dmgFailedCheck) {
    showInstallSteps(false);
    const date = fmtDate(r.date);
    const zip = safeUrl(r.source && r.source.zip, "source");
    const why = dmgFailedCheck
      ? "A prebuilt app is listed for this release, but it didn't pass the integrity check here, so it isn't offered."
      : "There's no prebuilt app for this release.";
    setRelease(
      `<h3>Pastly ${esc(r.version)} — source release</h3>
       <p>${date ? "Released " + esc(date) + ". " : ""}${why} Build it from source in a couple of minutes.</p>
       <div class="cta-row">
         <a class="btn btn-primary btn-small" href="#build-cmd">Build from source</a>
         ${zip ? `<a class="btn btn-ghost btn-small" href="${esc(zip)}">Source code (.zip)</a>` : ""}${pageButton(r)}
       </div>${notesBlock(r)}`);
  }

  // Pre-releases get their own card under the main one and never change the Download buttons.
  function addExperimental(r, d) {
    const el = document.createElement("div");
    el.className = "release release-experimental";
    el.setAttribute("role", "note");
    el.setAttribute("aria-label", "Experimental pre-release build");
    el.innerHTML =
      `<p class="release-tag">Experimental pre-release</p>
       <h3>Pastly ${esc(r.version)}</h3>
       <p class="release-warning"><strong>Not a stable release${notarized ? "" : " and not notarized by Apple"}.</strong>
         It may have bugs. Only use it if you trust this project.</p>
       <div class="cta-row">
         <a class="btn btn-ghost btn-small" href="${esc(d.url)}">Download experimental ${esc(d.name)}</a>${pageButton(r)}
       </div>
       ${checksumBlock(d, "experimental-sha")}`;
    release.after(el);
  }

  // Copy buttons inside the release cards (created after the page loaded).
  const downloadSection = $("#download");
  if (downloadSection) {
    downloadSection.addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-copy-sha]");
      if (!btn) return;
      const code = document.getElementById(btn.dataset.copySha);
      const status = btn.closest(".sha")?.querySelector("[role=status]");
      try {
        await navigator.clipboard.writeText(code.textContent);
        btn.textContent = "Copied";
        if (status) status.textContent = "Checksum copied to the clipboard";
      } catch {
        btn.textContent = "Press ⌘C";
      }
      setTimeout(() => { btn.textContent = "Copy"; if (status) status.textContent = ""; }, 1600);
    });
  }

  fetch("/api/latest", { headers: { Accept: "application/json" } })
    .then((r) => r.json())
    .then((data) => {
      if (!data || typeof data !== "object") throw new Error("unexpected response");
      applyRepo(data.repo);
      notarized = data.notarized === true;
      const st = data.stable && typeof data.stable === "object" ? data.stable : null;
      const dmg = st ? checkedDmg(st.dmg) : null;
      if (st && dmg) showStable(st, dmg);
      else if (st && data.status === "ok") showSourceOnly(st, typeof st.dmgCheck === "string" && st.dmgCheck !== "no-dmg");
      else showNoRelease(MESSAGES[data.status] || MESSAGES.unavailable);
      const ex = data.experimental && typeof data.experimental === "object" ? data.experimental : null;
      const exDmg = ex && ex.prerelease === true ? checkedDmg(ex.dmg) : null;
      if (exDmg) addExperimental(ex, exDmg);
    })
    .catch(() => showNoRelease(MESSAGES["not-configured"]));

  /* ---------- Navigation ---------- */
  const nav = $(".nav"), toggle = $(".nav-toggle"), navLinks = $("#nav-links");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true }); onScroll();
  toggle.addEventListener("click", () => {
    const open = navLinks.classList.toggle("open");
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
  });
  navLinks.addEventListener("click", (e) => { if (e.target.closest("a")) { navLinks.classList.remove("open"); toggle.setAttribute("aria-expanded", "false"); } });
  if ("IntersectionObserver" in window) {
    const map = new Map($$("#nav-links a").map((a) => [a.getAttribute("href").slice(1), a]));
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (e.isIntersecting) { $$("#nav-links a").forEach((a) => a.classList.remove("active")); map.get(e.target.id)?.classList.add("active"); }
    }), { rootMargin: "-45% 0px -50% 0px" });
    map.forEach((_, id) => { const s = document.getElementById(id); if (s) io.observe(s); });
  }

  /* ---------- Reveal on scroll ---------- */
  const items = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) items.forEach((el) => el.classList.add("in"));
  else {
    items.forEach((el) => { if (el.getBoundingClientRect().top < innerHeight) el.classList.add("in"); });
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } }),
      { rootMargin: "0px 0px -8% 0px", threshold: 0.06 });
    items.forEach((el) => io.observe(el));
  }

  /* ---------- Copy button ---------- */
  $$("[data-copy]").forEach((btn) => btn.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(document.getElementById(btn.dataset.copy).innerText); btn.textContent = "Copied"; }
    catch { btn.textContent = "Press ⌘C"; }
    setTimeout(() => (btn.textContent = "Copy"), 1600);
  }));

  /* ---------- Settings tour ---------- */
  const tabs = $$(".tour-tabs [role=tab]"), img = $("#tour-img"), dark = $("#tour-dark");
  tabs.forEach((t) => { const i = new Image(); i.src = `img/settings-${t.dataset.tab}-light.webp`; });
  function selectTab(t) {
    tabs.forEach((x) => x.setAttribute("aria-selected", String(x === t)));
    const name = t.dataset.tab;
    img.classList.add("swap");
    setTimeout(() => {
      img.src = `img/settings-${name}-light.webp`;
      dark.srcset = `img/settings-${name}-dark.webp`;
      img.alt = `Pastly Settings, ${t.querySelector("b").textContent} section.`;
      img.onload = () => img.classList.remove("swap");
      if (img.complete) img.classList.remove("swap");
    }, reduce ? 0 : 160);
  }
  tabs.forEach((t, i) => {
    t.addEventListener("click", () => selectTab(t));
    t.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowDown" || e.key === "ArrowRight" ? 1 : e.key === "ArrowUp" || e.key === "ArrowLeft" ? -1 : 0;
      if (!d) return;
      e.preventDefault(); const n = tabs[(i + d + tabs.length) % tabs.length]; n.focus(); selectTab(n);
    });
  });

  /* ---------- Playground ---------- */
  const seed = [
    { kind: "text", text: "Release notes draft: drag cards now show the whole clip, and Finder images get real thumbnails.", app: "Notes", ago: "now" },
    { kind: "text", text: "Book club pick for March: The Left Hand of Darkness", app: "Messages", ago: "4m" },
    { kind: "color", text: "#22C55E", app: "Safari", ago: "15m" },
    { kind: "code", text: "git commit -m \"Show the whole clip while dragging\"", app: "Terminal", ago: "22m" },
    { kind: "link", text: "https://www.swift.org/getting-started/", app: "Safari", ago: "1h" },
    { kind: "color", text: "#F97316", app: "Safari", ago: "1h" },
    { kind: "code", text: "SELECT name, plan FROM customers WHERE active = 1;", app: "TablePlus", ago: "2h" },
    { kind: "text", text: "Pasta night: 400 g spaghetti, 3 garlic cloves, chili flakes, lemon zest, parmesan", app: "Notes", ago: "4h" },
    { kind: "text", text: "© 2026 Pastly contributors — released under the MIT License", app: "TextEdit", ago: "7h", pinned: true },
  ].map((c, i) => ({ ...c, id: i + 1 }));
  let clips = seed.slice();
  const pgTabs = [{ id: "all", label: "History" }, { id: "pinned", label: "Pinned" }, { id: "text", label: "Text" },
                  { id: "link", label: "Links" }, { id: "color", label: "Colors" }, { id: "code", label: "Code" }];
  const icon = { text: "≡", link: "↗", code: "</>", color: "" };
  const app = $("#pg-app"), list = $("#pg-list"), tabBar = $("#pg-tabs"), query = $("#pg-query");
  const count = $("#pg-count"), note = $("#pg-note"), preview = $("#pg-preview"), toast = $("#pg-toast");
  let tab = "all", cursor = 0, selected = new Set(), visible = [], previewOpen = false, undo = null, toastTimer;

  function filter() {
    const q = query.value.trim().toLowerCase();
    visible = clips.filter((c) => (tab === "all" || (tab === "pinned" ? c.pinned : c.kind === tab)) &&
      (!q || c.text.toLowerCase().includes(q) || c.app.toLowerCase().includes(q)));
    cursor = Math.min(cursor, Math.max(0, visible.length - 1));
    selected = new Set([...selected].filter((id) => visible.some((c) => c.id === id)));
    if (!selected.size && visible[cursor]) selected.add(visible[cursor].id);
  }
  function renderTabs() {
    tabBar.innerHTML = "";
    pgTabs.forEach((t) => {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "tab"); b.setAttribute("aria-selected", String(t.id === tab)); b.textContent = t.label;
      b.addEventListener("click", () => { tab = t.id; cursor = 0; selected.clear(); render(); app.focus({ preventScroll: true }); });
      tabBar.appendChild(b);
    });
  }
  function render() {
    filter(); renderTabs(); list.innerHTML = "";
    if (!visible.length) { const li = document.createElement("li"); li.className = "pg-empty"; li.textContent = "No matching clips"; list.appendChild(li); }
    visible.forEach((c, i) => {
      const li = document.createElement("li");
      li.setAttribute("role", "option"); li.setAttribute("aria-selected", String(selected.has(c.id)));
      if (c.kind === "code") li.classList.add("code");
      const ic = document.createElement("span"); ic.className = "ic";
      if (c.kind === "color") ic.style.background = c.text; else ic.textContent = icon[c.kind];
      const t = document.createElement("span"); t.className = "t"; t.textContent = (c.pinned ? "📌 " : "") + c.text;
      const m = document.createElement("span"); m.className = "m"; m.textContent = c.ago + (i < 9 ? "  ⌘" + (i + 1) : "");
      li.append(ic, t, m);
      li.addEventListener("click", (e) => {
        if (e.metaKey || e.ctrlKey) { selected.has(c.id) ? selected.delete(c.id) : selected.add(c.id); cursor = i; }
        else if (e.shiftKey) { const a = Math.min(cursor, i), b = Math.max(cursor, i); selected = new Set(visible.slice(a, b + 1).map((x) => x.id)); }
        else if (e.detail === 2) { cursor = i; selected = new Set([c.id]); paste(); return; }
        else { const same = selected.size === 1 && selected.has(c.id) && previewOpen; cursor = i; selected = new Set([c.id]); previewOpen = !same; }
        render(); app.focus({ preventScroll: true });
      });
      list.appendChild(li);
    });
    count.textContent = selected.size > 1 ? `${selected.size} of ${visible.length} selected` : `${visible.length} clip${visible.length === 1 ? "" : "s"}`;
    list.children[cursor]?.scrollIntoView({ block: "nearest" });
    renderPreview();
  }
  function renderPreview() {
    const c = visible[cursor];
    if (!previewOpen || !c) { preview.hidden = true; return; }
    preview.hidden = false;
    const body = c.kind === "color" ? `<div class="swatch-lg" style="background:${c.text}"></div>`
      : `<pre class="${c.kind === "code" ? "code" : ""}"></pre>`;
    preview.innerHTML = `<h4>${{ text: "Text", link: "Link", code: "Code", color: "Color" }[c.kind]}</h4>${body}
      <dl><dt>App</dt><dd></dd><dt>Length</dt><dd>${c.text.length} characters</dd><dt>Copied</dt><dd>${c.ago === "now" ? "just now" : c.ago + " ago"}</dd></dl>`;
    const pre = preview.querySelector("pre"); if (pre) pre.textContent = c.text;
    preview.querySelector("dd").textContent = c.app;
  }
  function chosen() { return visible.filter((c) => selected.has(c.id)); }
  function paste() {
    const items = chosen(); if (!items.length) return;
    note.querySelector(".placeholder")?.remove();
    items.forEach((c) => {
      const p = document.createElement("p");
      if (c.kind === "code") p.className = "code";
      if (c.kind === "color") { const s = document.createElement("span"); s.className = "sw"; s.style.background = c.text; p.appendChild(s); }
      p.appendChild(document.createTextNode(c.text)); note.appendChild(p);
    });
    note.scrollTop = note.scrollHeight;
    showToast(items.length > 1 ? `Pasted ${items.length} clips` : "Pasted");
  }
  function remove() {
    const items = chosen(); if (!items.length) return;
    undo = clips.slice();
    clips = clips.filter((c) => !selected.has(c.id)); selected.clear(); previewOpen = false; render();
    showToast(`${items.length} deleted`, true);
  }
  function showToast(text, withUndo) {
    toast.innerHTML = ""; toast.append(document.createTextNode(text));
    if (withUndo) {
      const b = document.createElement("button"); b.textContent = "Undo";
      b.addEventListener("click", () => { if (undo) { clips = undo; undo = null; render(); showToast("Restored"); } });
      toast.appendChild(b);
    }
    toast.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(() => toast.classList.remove("show"), withUndo ? 4000 : 1400);
  }
  app.addEventListener("keydown", (e) => {
    const inSearch = document.activeElement === query, cmd = e.metaKey || e.ctrlKey;
    const move = (to) => { cursor = Math.max(0, Math.min(visible.length - 1, to)); if (!e.shiftKey) selected = new Set(); if (visible[cursor]) selected.add(visible[cursor].id); render(); e.preventDefault(); };
    if (e.key === "ArrowDown") move(cursor + 1);
    else if (e.key === "ArrowUp") move(cursor - 1);
    else if (e.key === "Enter") { paste(); e.preventDefault(); }
    else if (e.key === " " && !query.value) { previewOpen = !previewOpen; renderPreview(); e.preventDefault(); }
    else if (e.key === "Escape") { if (previewOpen) { previewOpen = false; renderPreview(); } else { query.value = ""; render(); } }
    else if (cmd && e.key.toLowerCase() === "a" && (!inSearch || !query.value)) { selected = new Set(visible.map((c) => c.id)); render(); e.preventDefault(); }
    else if ((e.key === "Backspace" || e.key === "Delete") && (!query.value || selected.size > 1)) { remove(); e.preventDefault(); }
    else if (cmd && e.key.toLowerCase() === "z" && undo) { clips = undo; undo = null; render(); showToast("Restored"); e.preventDefault(); }
    else if (e.key === "Tab") { const i = pgTabs.findIndex((t) => t.id === tab); tab = pgTabs[(i + (e.shiftKey ? pgTabs.length - 1 : 1)) % pgTabs.length].id; cursor = 0; selected.clear(); render(); e.preventDefault(); }
    else if (cmd && /^[1-9]$/.test(e.key)) { const n = +e.key - 1; if (n < visible.length) { cursor = n; selected = new Set([visible[n].id]); render(); paste(); e.preventDefault(); } }
  });
  query.addEventListener("input", () => { cursor = 0; selected.clear(); render(); });
  app.tabIndex = 0;
  render();
})();
