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
    { "platforms": ["web"], "minBuild": "2026-11-16T19:51:20Z", "scope": "link",
      "message": "Link cable play changed on 16 November: update to link again." },
    { "platforms": ["ios"], "minBuild": "2026-11-16T19:51:20Z",
      "message": "This build can lose saves. The update fixes it.",
      "url": "https://apps.apple.com/app/id…" }
  ]
}
```

### Announcements

Everything except `id` and `text` is optional:

- `show`: where it appears. Either or both of:
  - `"toast"`: once per device. Web shows it for 30 s; iOS uses its own toast
    stack. Up to three show per check; the rest wait for the next check.
  - `"banner"`: a card at the top of the home screen, until the player
    dismisses it or `until` passes. Every banner shows at once.

  Leave it out (or name only places a build doesn't know) and it's a toast.
  Use banners when you post several at a time.
- `id`: what "seen" and "dismissed" remember. Change the id to show the same
  text again.
- `url`: must be https. It adds a button labelled `label` (default "Read more").
- `platforms`: `web`, `ios`. Leave it out to reach every platform.
- `from` / `until`: the window in which it shows.
- `builtBefore`: only builds older than this see it, e.g. "your version has a
  bug, update". A development build never matches.

### Build times

`minBuild` and `builtBefore` compare **build times**. A build time is the UTC
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

Each entry has `minBuild`, and optionally `platforms`, `message`, `url` (iOS)
and `scope`:

- `"scope": "app"` (the default): a card ("Update Required") with no way out but **Update**.
  A game in progress is paused, then saved before the update.
- `"scope": "link"`: the card ("Link Cable Needs an Update") offers
  **Not now**, once per launch. After that the app runs as usual, but every
  way into the link cable brings the card back instead:
  - web: Connect Link Cable (online and same-browser) and local 2P;
  - iOS: the link sheet and two-player.
- Any other scope is treated as `"app"` by builds that don't know it. A build
  that can't hold just the broken feature holds everything, which errs on the
  safe side. So adding a new scope means older builds block entirely.

If several entries apply, an app-wide one wins over a link one. Neither card
interrupts a link session in progress; it waits for the next check.

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
2. Add a `"scope": "link"` entry to status.json, so players hear about it at
   launch and their local link is held as well.
3. Deploy the new server with `SIGNAL_MIN_CLIENT=<new level>` in its
   environment (both server.js and server.nim read it). This is the backstop
   for builds older than status.json.

## Costs and limits

- An edit to status.json is a commit to main and a full Pages deploy. It is
  left out of the version hash, so it never offers anyone an Update. Pages'
  CDN can serve the old file for up to 10 minutes after the deploy.
- Every version move now changes `index.html` (the build-time meta), so every
  update downloads it again: about 21 KB gzip.
- The first deploy after this lands moves the version once, because the live
  `build-id.txt` has no build time yet.
