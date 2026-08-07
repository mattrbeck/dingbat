# Why Google Drive keeps asking to sign in, and what can be done about it

**Status: diagnosed, measured, and partly fixed.** The code changes described in
"What was changed" are in `web/index.js` and covered by `web/tests/driveauth.test.mjs`.
Everything under "Options not taken" is analysis only.

The complaint: *"Is there any way at all to reduce the frequency the sign-ins are
required? It feels constant and it's a very bad UX."*

## The three things that could be happening, and which one is

An expired token, a lost grant and evicted storage all look identical to a user
("it wants me to sign in again") and have nothing in common as bugs. Taken in
turn:

**(a) The access token expiring.** Real, unavoidable, hourly. The GIS token
model issues a ~1h access token and **no refresh token**, by design. Google is
explicit that this is a security decision, not an oversight: *"For improved user
security, this automatic token refresh process is not supported by the Google
Identity Services library"*, and *"for implicit mode, a user gesture is required
to request an access token, even if there was a prior request"*
([migration guide](https://developers.google.com/identity/oauth2/web/guides/migration-to-gis)).
`prompt: ""` suppresses the *consent UI*; it does not suppress the *popup*. The
error codes in the JS reference (`popup_failed_to_open`, `popup_closed`) only
exist because a real `window.open()` happens on every single call.

**(b) The grant being lost, so even `prompt: ""` fails.** Not expected for this
app. `drive.appdata` is classified **non-sensitive**
([Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)),
grants do not expire on their own, and Google documents no expiry for one.
**One exception, and it is the single highest-value thing to check:** an OAuth
consent screen still in **Testing** publishing status expires authorizations
**7 days from consent**. If dingbat's client is in Testing, that alone produces
a weekly full re-consent — complete with the "Google hasn't verified this app"
interstitial. Because the scope is non-sensitive there is no verification review
to pass, so flipping to *In production* is free. **Matt must check this; it
cannot be checked from outside the account.**

**(c) State being evicted, so the app forgets it was signed in.** Ruled out.
- The token and the connected flag live in `syncState` in the **same** IndexedDB
  database as the ROMs and the saves. If eviction were happening, the library
  would vanish too — it doesn't.
- Safari's ITP 7-day cap on script-writable storage **explicitly exempts
  home-screen web apps**: *"The first-party domain of home screen web
  applications is exempt from ITP's 7-day cap on all script-writeable storage"*
  ([WebKit tracking prevention](https://webkit.org/tracking-prevention/)). One
  of Safari's documented auto-grant heuristics for `navigator.storage.persist()`
  is literally whether the site is running as a Home Screen web app
  ([storage policy](https://webkit.org/blog/14403/updates-to-storage-policy/)).

**And a fourth that was worth eliminating: COOP.** `COOP: same-origin` severs
the popup↔opener channel GIS uses and is already known to break sign-in here.
Production is clean — GitHub Pages sends **no COOP header at all**:

```
$ curl -sI https://dingbat.gg/ | grep -i cross-origin
(nothing)
```

So COOP is not contributing in production. (`web/serve.py` sends
`same-origin-allow-popups`, which is also fine.)

**Verdict: (a), amplified by how the app reacted to it.** The session was
technically behaving as designed. What made it *feel* constant was four
things the app itself did on every hourly rollover:

1. **No `login_hint`.** Google's own reference: with `login_hint`, *"account
   selection is skipped"*. Without it, a browser signed in to more than one
   Google account shows **the account chooser on every re-grant**. The app knew
   the email (the scope includes `email`) and never passed it. A perfectly
   healthy silent renewal therefore put a Google account-picker on screen every
   hour — which is indistinguishable from "it made me sign in again".
2. **A token gap was rendered as a sign-out.** `syncActive()` meant "we hold a
   live access token *right now*", and the entire UI keyed off it: the home
   button flipped from **Sync** to **Sign in with Google**, the Drive panel
   offered "Sign in with Google", and the Drive-only tiles stopped being
   offered. A 1-second gap between two perfectly good tokens looked like a
   logout, and the natural response — tap Sign in — bought a *full interactive
   consent popup* where a silent one was already armed.
3. **Doomed popups.** A background 401 (the 3-minute poll, or the pull on
   `visibilitychange` after the phone was asleep) called `gdriveAcquireToken("")`
   with no user activation. It can only be refused, and a refused popup is not
   silent — several browsers answer with a visible "pop-up blocked" bar. Worse,
   the refusal **spent one of the three strikes** that decide whether the grant
   is declared gone.
4. **A race on the recovery tap.** The renewal listener is a *capture-phase*
   window listener, so tapping the Sign-in button fires the silent re-grant a
   beat before the button's own interactive one. Two `requestAccessToken()`
   calls on one GIS client: the second overwrites `callback`, orphaning the
   first popup and leaving its promise unsettled forever.

There was also a silent data bug behind the same conflation: `markUpload` /
`markDelete` / `markGameUpload` all returned early when the token was missing,
so **a save or a deletion made during a token gap was never queued at all**.
Only a manual full sync ever noticed. A deletion in that window was worse than
lost — with no tombstone, the next pull resurrects the game.

## Measurements

`web/tests/helpers.mjs` evaluates the real `web/index.js` in a `node:vm`
context, so this drives the actual app code. The scenario is one ordinary
afternoon: playing, a token rollover, the phone put down for two hours (iOS
freezes the tab, so nothing runs and the token dies), then picking it up again.
A GIS stub models the real contract — every `requestAccessToken()` opens a popup,
it can only succeed with a live gesture, and it shows a chooser when it has no
`login_hint` and the browser holds more than one Google account.

| | popups | refused popups | account choosers | "signed out" moments | dropped uploads |
|---|---|---|---|---|---|
| before, one Google account | 3 | 1 | 0 | 1 | 1 |
| before, two Google accounts | 3 | 1 | **2** | 1 | 1 |
| after, either | **2** | **0** | **0** | **0** | **0** |

The remaining two popups are the irreducible ones: this is the token model, and
each new token costs a window. Both now carry `login_hint` and open and close
with nothing in them.

**Transient activation, measured** (Playwright, `navigator.userActivation.isActive`
sampled through a click handler; WebKit 26.5 and Chromium):

| after… | sync | microtask | `setTimeout(0)` | a 400 ms fetch | 1.2 s | 5.2 s | 10.2 s |
|---|---|---|---|---|---|---|---|
| WebKit | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| Chromium | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |

So an `await` does **not** spend the gesture — elapsed time does, at the 5 s
spec boundary. `gdriveAcquireToken` awaits `loadGisScript()` before GIS opens
its window, and fetching `accounts.google.com/gsi/client` cold on a phone can
eat that entire budget. Hence the boot-time warm-up below. (Popup *blocking*
itself is not measurable under Playwright — automation contexts don't run the
popup blocker — so activation is measured instead, which is the signal the
blocker consults.)

## What was changed

All of it stays inside the existing token model. Nothing weakens the security
posture: still the same 1-hour, `drive.appdata`-scoped token, still stored only
in this origin's IndexedDB, still no long-lived credential anywhere.

- **Every re-grant names the account.** The email is persisted as
  `syncState.email` and passed as `login_hint` on every renewal, so the account
  chooser is skipped. The *first* connection deliberately sends no hint (the
  user picks), and signing out forgets it (so the next sign-in is free to choose
  a different account). An email address is not a credential; it goes nowhere
  except back to Google, which already knows it.
- **`driveLinked()` split from `syncActive()`.** `driveLinked()` = the user has
  connected Drive (survives expiry, reloads, being offline) and now drives the
  UI and the upload queue. `syncActive()` = we hold a live token, and now only
  gates actual network work. A token gap is therefore invisible: the library
  keeps its Drive games, the Sync button stays a Sync button, and **changes keep
  queueing** so nothing made during a gap is lost.
- **Lazy re-auth at the points that need Drive.** `ensureDriveSignedIn()` tries
  the hinted silent re-grant first and only falls back to the full consent flow
  if the grant is really gone. Sync, "Sync now", downloading a Drive-only game
  and "Remove from device" all route through it — so the popup, when it is
  needed at all, happens on a tap the user *meant*, doing the thing they asked
  for.
- **No popup without activation.** `hasUserActivation()` gates the re-grant, so
  the background poll never opens a window that can only be refused, and a
  doomed attempt can no longer spend a strike from the renewal budget.
- **One token request at a time.** Overlapping calls share the in-flight promise,
  killing the capture-phase race.
- **GIS warmed at boot for linked accounts only.** Takes the script fetch off
  the gesture path and out of the 5 s activation budget. Signed-out users still
  never touch Google's servers.
- **A quiet "Paused" state** replaces pretending to sync: shown only when the
  token is gone *and* the retry budget is spent *and* there is queued work, with
  the wording "Tap Sync to reconnect to Google Drive — your changes are saved".
  Non-modal, one word, nothing lost.

## What still needs Matt, on a real account

The Playwright/`node:vm` work above deliberately never touches a real Google
account. These need him:

1. **Check the consent screen's publishing status** — Cloud Console → Google
   Auth Platform → Audience. If it says **Testing**, publish to **In
   production**. `drive.appdata` + `email` are non-sensitive, so there is no
   review to wait for. If it *was* in Testing, that was a weekly forced
   re-consent on top of everything above and this is the biggest single win
   available.
2. **Count the Google accounts signed in** in the browser/PWA that misbehaves
   (`myaccount.google.com` → the avatar). If it is more than one, the
   `login_hint` change should be immediately, obviously better.
3. **Confirm whether the bad case is the installed home-screen PWA, Safari, or
   both.** This decides whether the redirect option below is worth building —
   see the next section; it is the one thing the fixes above cannot help.
4. Sanity-check on the real thing: sign in, play an hour, confirm the rollover
   is a flash and not a chooser; then leave it overnight and confirm it comes
   back without a sign-in prompt.

## Options not taken, with what they cost

Ranked by value per unit of risk.

**1. Publish the OAuth app (if it is in Testing).** Zero code, minutes of work,
potentially removes a 7-day re-consent cycle. Do this first. No downside: the
scope is non-sensitive.
*Risk: none.*

**2. Full-page redirect OAuth instead of a popup.** The one remaining structural
problem is iOS, and it is not fixable inside the popup model. An installed
home-screen web app has **its own cookie jar, separate from Safari's** (Apple,
WWDC23: *"separate cookies and storage from the browser"*), so the Google
session established in Safari is invisible inside the PWA — every fresh install
means a real sign-in there, and `prompt: ""` has no session to be silent about.
On top of that, `window.opener` is reported null for OAuth popups from iOS 17.5
onward ([Apple Developer Forums 759487](https://developer.apple.com/forums/thread/759487)),
which severs the channel GIS uses to hand the token back — the "it opened, I
signed in, nothing happened" loop. The documented-by-practice workaround is a
top-level redirect: navigate to Google, come back to a URL in scope with the
token in the fragment. It even enables a genuinely *invisible* renewal at boot
(`prompt=none` bounces straight back with a fresh token and no UI at all).
*Cost:* GIS's token client is popup-only, so this means hand-rolling the
implicit redirect flow; a redirect URI must be registered; the page reloads, so
it is only safe at boot or from an explicit action, never mid-game.
*Risk:* Google now says of the raw implicit flow: *"strongly discouraged... the
page is maintained only for legacy support"*, and a token in a URL fragment is a
token in history. Mitigable (clear `location.hash` immediately) but it is a real
step away from the recommended path. **Worth building only if Matt confirms the
installed PWA is where the pain is.**

**3. Authorization-code flow with a backend — the only route to a refresh
token.** Google requires `client_secret` at the token endpoint for the "Web
application" client type **even with PKCE** (confirmed by Google staff on the
Cloud Community forum, and by direct test), and the "Desktop app" client type
that does allow PKCE-only cannot register an `https://` redirect URI. So there
is no no-backend path to a refresh token. dingbat *does* already ship a server
(`web/signaling/server.nim`), so the infrastructure exists.
*Cost:* Drive stops being a client-only feature. Anyone self-hosting needs the
server AND their own Google client secret; the offline/LAN story gets worse; the
server becomes a thing that must stay up for saves to sync.
*Risk — the important one:* the server would hold a **client secret** and either
long-lived **refresh tokens** or the ability to mint access tokens for every
user. That is a fundamentally different security posture from today, where the
worst case is a 1-hour token scoped to one app folder. A zero-dependency
signaling relay for game traffic and a credential store are not the same kind of
service, and should not be the same process. **Not recommended for the problem
as stated** — it buys a longer session at the cost of becoming responsible for
other people's Drive credentials.

**4. FedCM / One Tap.** Does not apply. FedCM is scoped to `google.accounts.id`
(authentication), not `google.accounts.oauth2` (authorization). The FedCM
authorization extensions that do exist (Continuation API, Chrome 132+) still
require user interaction and still open a popup, Google publishes no
FedCM path to a Drive access token, and — decisively here — **WebKit has not
implemented FedCM at all**. Nothing for an iPhone.
*Risk: none, because there is nothing to adopt.*

**5. Keep the token alive more aggressively.** Rejected. Renewing earlier or on
more gestures does not reduce popups (one per hour is set by the token
lifetime); it only moves them, and moving them *into* gameplay is the worst
possible placement. The direction taken is the opposite: tolerate the gap, keep
the queue, and spend the popup at a moment the user chose.

## Reference

- [Use the token model](https://developers.google.com/identity/oauth2/web/guides/use-token-model) ·
  [GIS JS reference](https://developers.google.com/identity/oauth2/web/reference/js-reference) ·
  [Migrate to GIS](https://developers.google.com/identity/oauth2/web/guides/migration-to-gis)
- [Using OAuth 2.0 to access Google APIs](https://developers.google.com/identity/protocols/oauth2) (7-day Testing-status expiry, revocation triggers) ·
  [Client-side implicit flow](https://developers.google.com/identity/protocols/oauth2/javascript-implicit-flow) (deprecation wording)
- [Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) (`drive.appdata` = non-sensitive)
- [WebKit: Tracking Prevention](https://webkit.org/tracking-prevention/) ·
  [Updates to Storage Policy](https://webkit.org/blog/14403/updates-to-storage-policy/) ·
  [WWDC23: What's new in web apps](https://developer.apple.com/videos/play/wwdc2023/10120/)
- [Apple Developer Forums 759487](https://developer.apple.com/forums/thread/759487) (null `window.opener`, iOS 17.5+) ·
  [PocketBase #2429](https://github.com/pocketbase/pocketbase/discussions/2429) (OAuth popups in installed iOS PWAs)
- [Authorization code flow without client secret](https://www.googlecloudcommunity.com/gc/Developer-Tools/Authorization-Code-Flow-without-client-secret/m-p/814109) ·
  [Migrate to FedCM](https://developers.google.com/identity/gsi/web/guides/fedcm-migration)
