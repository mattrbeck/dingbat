// The rules for web/status.json (docs/dev/announcements.md), shared by the
// validator (validate.mjs: CI and the Pages deploy) and the editor
// (editor.html). Errors are what a client would misread or ignore without a
// word; warnings are legal but likely not what was meant.

export const PLATFORMS = ["web", "ios"];
export const SHOWS = ["toast", "banner"];
// One form only: web's Date.parse takes many more (a bare date, a missing
// zone read as local time, milliseconds), iOS's ISO8601DateFormatter takes
// none of those, and an unread date is silently no date: an until that never
// ends, a minBuild that never applies.
export const TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
export const ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ANN_KEYS = ["id", "text", "show", "url", "label", "platforms", "from", "until", "builtBefore", "builtAfter"];
const REQ_KEYS = ["platforms", "minBuild", "message", "url"];
// Past this a toast wraps to three lines on a phone, a banner to four.
export const TEXT_SOFT_MAX = 140;
export const LABEL_MAX = 24;
// A template's [placeholder] left in the text.
const PLACEHOLDER = /\[[^\]\n]{1,40}\]/;

const isObj = (v) => !!v && typeof v === "object" && !Array.isArray(v);

export const validate = (doc, now = Date.now()) => {
  const errors = [];
  const warnings = [];
  const err = (path, msg) => errors.push({ path, msg });
  const warn = (path, msg) => warnings.push({ path, msg });

  if (!isObj(doc)) {
    err("", "must be a JSON object");
    return { errors, warnings };
  }
  for (const k of Object.keys(doc)) {
    if (k !== "announcements" && k !== "required") err(k, `unknown key "${k}" (clients ignore it)`);
  }

  const time = (path, v) => {
    if (typeof v !== "string" || !TIME.test(v) || Number.isNaN(Date.parse(v))) {
      err(path, `must be a UTC time like 2026-11-16T19:51:20Z (got ${JSON.stringify(v)})`);
      return NaN;
    }
    return Date.parse(v);
  };
  const keys = (path, o, allowed) => {
    for (const k of Object.keys(o)) {
      if (!allowed.includes(k)) err(`${path}.${k}`, `unknown key "${k}"; allowed: ${allowed.join(", ")}`);
    }
  };
  const list = (path, v, allowed, what) => {
    if (!Array.isArray(v) || !v.length) { err(path, `must be a non-empty list of ${allowed.join(" / ")}`); return; }
    for (const x of v) if (!allowed.includes(x)) err(path, `unknown ${what} ${JSON.stringify(x)}; known: ${allowed.join(", ")}`);
    if (new Set(v).size !== v.length) warn(path, "lists the same value twice");
  };
  const httpsUrl = (path, v, alsoAppStore = false) => {
    let u = null;
    try { u = new URL(v); } catch {}
    const ok = !!u && (u.protocol === "https:" || (alsoAppStore && u.protocol === "itms-apps:"));
    if (!ok) err(path, alsoAppStore ? "must be an https:// or itms-apps:// link" : "must be an https:// link (others are dropped)");
  };

  const anns = doc.announcements ?? [];
  if (!Array.isArray(anns)) err("announcements", "must be a list");
  else {
    const ids = new Set();
    anns.forEach((a, i) => {
      const p = `announcements[${i}]`;
      if (!isObj(a)) { err(p, "must be an object"); return; }
      keys(p, a, ANN_KEYS);
      if (typeof a.id !== "string" || !ID.test(a.id)) err(`${p}.id`, "must be 1-64 letters, digits, . _ - (what seen/dismissed remember)");
      else if (ids.has(a.id)) err(`${p}.id`, `"${a.id}" is used twice: the second would never show`);
      else ids.add(a.id);
      if (typeof a.text !== "string" || !a.text.trim()) err(`${p}.text`, "must be non-empty text");
      else if (PLACEHOLDER.test(a.text)) err(`${p}.text`, `still has a placeholder: ${a.text.match(PLACEHOLDER)[0]}`);
      else if (a.text.length > TEXT_SOFT_MAX) warn(`${p}.text`, `${a.text.length} characters: long for a toast or banner (aim under ${TEXT_SOFT_MAX})`);
      if (a.show !== undefined) list(`${p}.show`, a.show, SHOWS, "place");
      if (a.platforms !== undefined) list(`${p}.platforms`, a.platforms, PLATFORMS, "platform");
      if (a.url !== undefined) httpsUrl(`${p}.url`, a.url);
      if (a.label !== undefined) {
        if (typeof a.label !== "string" || !a.label.trim()) err(`${p}.label`, "must be non-empty text");
        else if (a.label.length > LABEL_MAX) warn(`${p}.label`, `long for a button (aim under ${LABEL_MAX})`);
        if (a.url === undefined) warn(`${p}.label`, "has no url, so nothing shows it");
      }
      const from = a.from === undefined ? NaN : time(`${p}.from`, a.from);
      const until = a.until === undefined ? NaN : time(`${p}.until`, a.until);
      const before = a.builtBefore === undefined ? NaN : time(`${p}.builtBefore`, a.builtBefore);
      const after = a.builtAfter === undefined ? NaN : time(`${p}.builtAfter`, a.builtAfter);
      if (after >= before) err(`${p}.builtAfter`, "is not before builtBefore: no build is in between, so nobody sees it");
      if (from >= until) err(`${p}.until`, "is not after from: it never shows");
      if (until <= now) warn(`${p}.until`, "is past: nobody sees it any more; remove it");
    });
  }

  const reqs = doc.required ?? [];
  if (!Array.isArray(reqs)) err("required", "must be a list");
  else {
    const seen = new Map();
    reqs.forEach((r, i) => {
      const p = `required[${i}]`;
      if (!isObj(r)) { err(p, "must be an object"); return; }
      keys(p, r, REQ_KEYS);
      const min = time(`${p}.minBuild`, r.minBuild);
      if (r.platforms !== undefined) list(`${p}.platforms`, r.platforms, PLATFORMS, "platform");
      if (r.message !== undefined && (typeof r.message !== "string" || !r.message.trim())) err(`${p}.message`, "must be non-empty text");
      if (r.url !== undefined) httpsUrl(`${p}.url`, r.url, true);
      const plats = Array.isArray(r.platforms) ? r.platforms : PLATFORMS;
      // iOS can't update itself: the url is its only way out of the screen.
      if (plats.includes("ios") && r.url === undefined) {
        err(`${p}.url`, "iOS needs the App Store or TestFlight link: without it the screen has no button and no way out");
      }
      if (plats.includes("ios") && min > now) {
        warn(`${p}.minBuild`, "is in the future: iOS blocks every current build at once (web waits for a deploy that meets it)");
      }
      for (const pl of plats) {
        if (seen.has(pl)) warn(`${p}`, `a second ${pl} entry: only the first that applies is used (required[${seen.get(pl)}])`);
        else seen.set(pl, i);
      }
    });
  }
  return { errors, warnings };
};

// --- who sees what: the clients' rules (web index.js announcementApplies /
// enforceRequired, iOS AppStatus), for the editor's check. web/tests
// status-json.test.mjs holds the web copy to this one. `built` is a build's
// time in ms, or null for a development build (newer than everything).

const t = (s) => (typeof s === "string" ? Date.parse(s) : NaN);
const at = (built) => (built == null || Number.isNaN(built) ? Infinity : built);
const names = { web: "web", ios: "iOS" };
const fmt = (s) => s.replace("T", " ").replace(":00Z", " UTC").replace("Z", " UTC");

export const announcementFor = (a, { platform, built, now }) => {
  const b = at(built);
  if (Array.isArray(a.platforms) && a.platforms.length && !a.platforms.includes(platform)) return { shows: false, why: `not for ${names[platform]}` };
  if (t(a.from) > now) return { shows: false, why: `starts ${fmt(a.from)}` };
  if (t(a.until) <= now) return { shows: false, why: `ended ${fmt(a.until)}` };
  if (a.builtBefore !== undefined && !(b < t(a.builtBefore))) return { shows: false, why: `only builds older than ${fmt(a.builtBefore)}` };
  if (a.builtAfter !== undefined && !(b >= t(a.builtAfter))) return { shows: false, why: `only builds from ${fmt(a.builtAfter)} on` };
  const show = (Array.isArray(a.show) && a.show.length ? a.show : ["toast"]).filter((x) => SHOWS.includes(x));
  return { shows: true, why: (show.length ? show : ["toast"]).join(" + ") };
};

export const requiredFor = (r, { platform, built }) => {
  if (Array.isArray(r.platforms) && r.platforms.length && !r.platforms.includes(platform)) return { blocks: false, why: `not for ${names[platform]}` };
  if (!(at(built) < t(r.minBuild))) return { blocks: false, why: built == null ? "a development build is never blocked" : `this build meets ${fmt(r.minBuild)}` };
  return { blocks: true, why: platform === "web" ? "blocked, once a deploy that meets it is live" : "blocked at once" };
};
