// GET /download → the latest STABLE DMG, only when every integrity check passed (see _release.js);
// otherwise the download section. Never a pre-release, draft, unchecked or mismatching file.
const { latest } = require("./_release");

module.exports = async (req, res) => {
  let target = "/#download";
  try {
    const { stable } = await latest();
    if (stable && stable.dmg && stable.dmg.integrity === "passed") target = stable.dmg.url;
  } catch { /* fall back to the download section */ }
  res.setHeader("Cache-Control", target === "/#download" ? "public, s-maxage=60" : "public, s-maxage=300, stale-while-revalidate=3600");
  res.statusCode = 302;
  res.setHeader("Location", target);
  res.end();
};
