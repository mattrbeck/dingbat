# Announcements and required updates

dingbat has three levers for reaching players after a build has shipped:

| Lever | Reaches | Edited by |
|---|---|---|
| `web/status.json` → `announcements` | web and iOS builds that have this code | a commit to main (Pages deploys it) |
| `web/status.json` → `required` | the same builds | a commit to main |
| the signaling server's `SIGNAL_MIN_CLIENT` | **every** build that links online, including ones from before this existed | an env var on the droplet |

Desktop has no HTTPS client and no online link, so it gets none of these yet.
Desktop builds are only the ones people download from Releases.

## status.json

Served at `https://dingbat.gg/status.json`. Clients fetch it past every cache
at launch, and again when the app comes back to the front, at most once an
hour. Any failure (offline, a 404, bad JSON) means "nothing to say". A broken
file can't stop anyone playing. Both lists take any number of entries.

### Editing and checking it

- **Post something:** `tools/status/edit` (from a checkout of main). It
  opens the editor on the current `web/status.json`.
  - Draft entries: toast / banner, web / iOS, link, window, only older or
    only newer builds, with a build time looked up from a commit sha.
  - Start from a template (maintenance window, bug in older builds, new
    feature). Its `[placeholders]` fail the checks until filled in.
  - Preview per device, and check live.
  - **Who sees this:** pick a platform, a build (a time, a commit, or a
    development build) and a date, and see what that player gets and why
    not. It uses the rules the web app uses; a web test holds the two to
    each other.
  - **Remove expired** clears entries whose `until` has passed.

  Save writes the file. Done (or Enter in the terminal) checks it again, shows the diff and
  asks before committing `web/status.json` alone and pushing. It then waits
  until dingbat.gg serves the new file: the deploy takes about a minute, the
  CDN up to ten more. Options: `--no-push`, `--no-open`, `--port N`.
- The editor also opens on its own (`tools/status/editor.html` from any
  static server of the repo root): in Chrome, Save goes through a file
  picker; elsewhere, Download or Copy JSON.
- **Check:** `node tools/status/validate.mjs [file]`. The web tests and the
  Pages deploy run it, so a bad file fails CI and never deploys. The rules
  live in `tools/status/rules.mjs`:
  - unknown keys (a typo like `untill` would otherwise be ignored);
  - times must be exactly `2026-11-16T19:51:20Z`;
  - duplicate ids, unknown places or platforms, non-https links;
  - a window that never opens;
  - an iOS required update with no link (the player would have no way out).

  Warnings: long text, a closed window, a future iOS `minBuild` (it blocks
  every current iOS build at once).
- Times: one form only. Web's date parser takes many forms (a bare date, no
  zone, milliseconds) that iOS reads as no date at all, so a loose time would
  mean an `until` that never ends on iOS.

```json
{
  "announcements": [
    {
      "id": "2026-11-signal-maintenance",
      "text": "Online link is down for maintenance tonight, 9-10pm UTC.",
      "show": ["toast", "banner"],
      "url": "https://github.com/mattrbeck/dingbat/discussions/1",
      "label": "Read more",
      "platforms": ["web", "ios"],
      "from": "2026-11-16T00:00:00Z",
      "until": "2026-11-17T00:00:00Z"
    },
    {
      "id": "2026-11-save-bug",
      "text": "Builds from before 10 November can lose saves. Update from Settings.",
      "show": ["banner"],
      "builtBefore": "2026-11-10T00:00:00Z"
    }
  ],
  "required": [
    { "platforms": ["web"], "minBuild": "2026-11-16T19:51:20Z",
      "message": "This build can lose saves when the tab closes. The update fixes it." },
    { "platforms": ["ios"], "minBuild": "2026-11-16T19:51:20Z",
      "message": "This build can lose saves. The update fixes it.",
      "url": "https://apps.apple.com/app/id…" }
  ]
}
```

### Announcements

Everything except `id` and `text` is optional:

- `show`: where it appears. Either or both of:
  - `"toast"`: passing news, once per device: 8 s, or 12 s with its link as
    the toast's action. One shows per check (launch, then hourly) and the rest
    follow at later checks, so the app's own launch offers (Resume) are never
    pushed out of the three-toast stack.
  - `"banner"`: a card at the top of the home screen, until the player
    dismisses it or `until` passes. Every banner shows at once, and the last
    check's banners are kept on the device so they are there at launch,
    offline too, instead of appearing a moment later.

  Leave it out (or name only places a build doesn't know) and it's a toast.
  Use banners for anything that must be seen, or when you post several at a
  time.
- `id`: what "seen" and "dismissed" remember. Change the id to show the same
  text again.
- `url`: must be https. It adds a button labelled `label` (default "Read more").
- `platforms`: `web`, `ios`. Leave it out to reach every platform.
- `from` / `until`: the window in which it shows.
- `builtBefore`: only builds older than this see it, e.g. "your version has a
  bug, update". A development build never matches.
- `builtAfter`: only builds from this one on see it, e.g. "New: …" for a
  feature, heard only by those who have it. A development build counts as
  newer than every release, so it always matches.

### Build times

`minBuild`, `builtBefore` and `builtAfter` compare **build times**. A build time is the UTC
commit time of the commit the build came from:

- web: deploy-pages.yml stamps it into `index.html`
  (`<meta name="dingbat-build-time">`) and `build-id.txt`
  (`<hash> <version> <time>`). A deploy that doesn't change the app keeps the
  live version and its time.
- iOS: project.yml's "Stamp the commit" script writes `DingbatBuildTime`
  into Info.plist.
- Development builds have none, and are never required to update.

The time for a commit is
`TZ=UTC git show -s --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd <sha>`.
Set `minBuild` to the time of the first commit that has the fix.

### Required updates

Each entry has `minBuild`, and optionally `platforms`, `message` and `url`
(iOS). A build older than `minBuild` shows "Update Required" with no way out
but **Update**: a card on web, the whole screen on iOS. A game in progress is
paused, then saved before the update. A link session in progress is never
interrupted; the card waits for the next check.

Required updates are for the whole app. A break that only touches link play
needs no entry: the signaling server's minimum client (below) turns old
builds away at the moment they try to link, every build back to before this
existed. Same-device link (2P, two tabs) runs one build on both sides and
can't break that way.

**Web**: a requirement blocks only when this build is older than `minBuild`,
**and** the live build meets it, **and** the live build can be fetched
(`build-id.txt`, `sw.js` and `version.txt` agree). So a `minBuild` ahead of
every deploy, or a deploy still on its way through the CDN, blocks no one.

**iOS**: the app can't see whether a newer build is out. Only add an iOS
entry once the build that meets it is live on the App Store or TestFlight.
`url` is where the Update button goes (an App Store link, or the TestFlight
invite).

Remove an entry once it has done its job. It does nothing to newer builds,
but nobody needs it either.

## The signaling server's minimum client

Every rendezvous now carries `"v": <protocol level>`: `SIGNAL_PROTOCOL` in
web/netplay.js and `NetLink.signalProtocol` on iOS, both 1. Builds from before
this send none (level 0). The server turns away any level below
`SIGNAL_MIN_CLIENT` (default 0, which serves everyone) with

```json
{"t":"error","msg":"This version of dingbat can't link online any more. Update dingbat, then try again.","code":"update"}
```

Every shipped build already shows an error's `msg` as the link failure, so
this works on builds from before this change too. Newer builds also look for
the update: on web the Update button appears; on iOS the app checks
status.json again. A session redialing after a drop ends instead of retrying.

To make an incompatible link change:

1. Bump `SIGNAL_PROTOCOL` / `signalProtocol` in the change that needs it, and
   ship those clients.
2. Deploy the new server with `SIGNAL_MIN_CLIENT=<new level>` in its
   environment (both server.js and server.nim read it). Older builds trying to
   link online are told to update, in the link screen, and newer ones also
   show the Update button.
3. Optionally post a banner with `builtBefore` set to the change's build time,
   so those players hear about it before they try.

Not covered: two builds whose peer-to-peer link protocol differs, paired by
the manual code exchange (no server). The peers don't compare versions today,
and a mismatched pair fails late ("are you both on the same emulator
build?"). The fix for that is a version check in the peers' own handshake.

## Costs and limits

- An edit to status.json is a commit to main and a full Pages deploy. It is
  left out of the version hash, so it never offers anyone an Update. Pages'
  CDN can serve the old file for up to 10 minutes after the deploy.
- Every version move now changes `index.html` (the build-time meta), so every
  update downloads it again: about 21 KB gzip.
- The first deploy after this lands moves the version once, because the live
  `build-id.txt` has no build time yet.
