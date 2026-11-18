// GET /api/latest → release metadata for the download section (cached at the edge).
// A DMG appears only after every check in _release.js passed; failures never offer an installer.
const { latest } = require("./_release");

module.exports = async (req, res) => {
  let data;
  try { data = await latest(); } catch { data = { status: "unavailable", repo: null, notarized: false, stable: null, experimental: null }; }
  const healthy = data.status === "ok" || data.status === "no-release";
  res.setHeader("Cache-Control", healthy ? "public, s-maxage=300, stale-while-revalidate=3600" : "public, s-maxage=60");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.status(healthy || data.status === "not-configured" || data.status === "no-repository" ? 200 : 503).json(data);
};
