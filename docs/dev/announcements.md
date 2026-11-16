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
file can't stop anyone playing.

```json
{
  "announcements": [
    {
      "id": "2026-11-signal-maintenance",
      "text": "Online link is down for maintenance tonight, 9-10pm UTC.",
      "url": "https://github.com/mattrbeck/dingbat/discussions/1",
      "label": "Read more",
      "platforms": ["web", "ios"],
      "from": "2026-11-16T00:00:00Z",
      "until": "2026-11-17T00:00:00Z",
      "builtBefore": "2026-11-10T00:00:00Z"
    }
  ],
  "required": {
    "web": { "minBuild": "2026-11-16T19:51:20Z", "message": "This build can lose saves. The update fixes it." },
    "ios": { "minBuild": "2026-11-16T19:51:20Z", "message": "…", "url": "https://apps.apple.com/app/id…" }
  }
}
```

Announcement fields. Everything except `id` and `text` is optional:

- `id`: shown once per device. Change the id to show the same text again.
- `url`: must be https. It adds a button labelled `label` (default "Read more").
- `platforms`: `web`, `ios`. Leave it out to reach every platform.
- `from` / `until`: the window in which it shows.
- `builtBefore`: only builds older than this see it, e.g. "your version has a
  bug, update". A development build never matches.

The web build shows announcements as a 30 s toast, at most two per check. iOS
shows them as an alert, one after another.

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

**Web**: blocks only when this build is older than `minBuild` **and** the
live build meets it **and** the live build can be fetched (`build-id.txt`,
`sw.js` and `version.txt` agree). So a `minBuild` ahead of every deploy, or a
deploy still on its way through the CDN, blocks no one. The card ("Update
dingbat to keep playing" plus `message`) has no way out but **Update now**. A
game in progress is paused, then saved before the reload. A link session
holds the card off until the next check, so a friend's game isn't cut off
mid-session.

**iOS**: the app can't see whether a newer build is out. Only set
`required.ios` once the build that meets it is live on the App Store or
TestFlight. `url` is where the Update button goes (an App Store link, or the
TestFlight invite). The app pauses and saves the game, closes any sheet, and
covers the whole screen.

Remove a `required` entry once it has done its job. It does nothing to newer
builds, but nobody needs it either.

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

To make an incompatible server change:

1. Bump `SIGNAL_PROTOCOL` / `signalProtocol` in the change that needs the new
   server, and ship those clients.
2. Deploy the new server with `SIGNAL_MIN_CLIENT=<new level>` in its
   environment (both server.js and server.nim read it).
3. Optionally add `required` entries to status.json, so players hear about
   it at launch instead of at their next link attempt.

## Costs and limits

- An edit to status.json is a commit to main and a full Pages deploy. It is
  left out of the version hash, so it never offers anyone an Update. Pages'
  CDN can serve the old file for up to 10 minutes after the deploy.
- Every version move now changes `index.html` (the build-time meta), so every
  update downloads it again: about 21 KB gzip.
- The first deploy after this lands moves the version once, because the live
  `build-id.txt` has no build time yet.
