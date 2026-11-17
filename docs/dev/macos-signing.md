# macOS signing and notarization

The macOS `.dmg` is signed with a Developer ID, runs under the hardened runtime and
is notarized by Apple, so it opens with a double-click and no Gatekeeper override.
CI does this only when the secrets below exist; without them it builds the same
unsigned `.dmg` as before and says so in a notice on the run.

## What happens

`.github/scripts/make-macos-app.sh` builds `dingbat.app`. When `MACOS_SIGN_IDENTITY`
is set it calls `.github/scripts/macos-sign.sh`, which:

1. signs any nested code, then the bundle: `--options runtime --timestamp`, with
   `.github/scripts/dingbat.entitlements` (nested code: none today, SDL is static);
2. checks `codesign --verify --deep --strict` and that the runtime flag is set;
3. zips the app, `xcrun notarytool submit --wait`, then `xcrun stapler staple` it,
   so a copy dragged out of the `.dmg` opens offline too;
4. builds the `.dmg` from the stapled app, signs it, submits and staples it;
5. `spctl --assess` on both, which must say `source=Notarized Developer ID`.

Two notary submissions per build, a few minutes each. Notarization is skipped (sign
only) when no notary credentials are set; an ad hoc identity (`-`) is never
submitted. Pull requests never sign. The workflow then runs the smoke test
(`smoke-desktop.sh`) again on the signed app's binary: the hardened runtime is the
one thing that could break a build the unsigned smoke test passed.

The bundle version is unchanged: the tag for `v*` builds, `0.0.0` otherwise. The
macOS job sets `MACOSX_DEPLOYMENT_TARGET=11.0`, matching `LSMinimumSystemVersion`;
without it the binary required the runner's own macOS (15).

## Entitlements: none

The hardened runtime with no exceptions:

| Entitlement | Needed? | Why |
|---|---|---|
| `cs.allow-jit`, `cs.allow-unsigned-executable-memory` | no | interpreters only, no generated code |
| `cs.disable-library-validation` | no | SDL is linked statically; everything loaded at run time is Apple's (the OpenGL renderer bundle, keyboard layouts) |
| `cs.allow-dyld-environment-variables` | no | nothing uses `DYLD_*` |
| `device.audio-input`, `device.camera` | no | sound is playback only; SDL is built without its camera subsystem; the DS microphone is fed only on web and iOS |
| `network.client`, `network.server`, `files.user-selected.*` | no effect | App Sandbox entitlements; the app is not sandboxed, so link play's sockets and ROM, save and settings files work without them |

A side effect: SDL's `SDL_DYNAMIC_API` override cannot load a replacement SDL that is
not signed by the same team.

## Privacy prompts and Info.plist

No usage-description keys are needed. The static `libSDL3.a` uses no CoreBluetooth
(not linked), no AVFoundation capture (camera off) and no microphone; gamepads come
through GameController and IOKit HID, which need no permission. A controller that
presents itself as a keyboard could make macOS ask for Input Monitoring, which has
no Info.plist key. Hosting a link (Link Cable, or Advanced > Host) listens on every
interface, so with the macOS firewall on, the first host asks to accept incoming
connections; a signed app is asked once.

## What to set up (once)

Only the team's Account Holder can make a Developer ID certificate.

1. **Developer ID Application certificate.** In Keychain Access: Certificate Assistant
   > Request a Certificate From a Certificate Authority, saved to disk. At
   developer.apple.com > Certificates > +, choose **Developer ID Application**,
   profile type **G2 Sub-CA**, upload the request, download the `.cer` and open it.
   Then in Keychain Access, My Certificates, export the identity (certificate and
   private key) as a `.p12` with a strong password. Keep the `.p12` and the
   password somewhere safe: the key cannot be downloaded again.
2. **App Store Connect API key** for notarytool. App Store Connect > Users and Access
   > Integrations > App Store Connect API > Team Keys > +, access **Developer**
   (enough for notarization). Download the `AuthKey_<KEYID>.p8` (offered once) and
   note the Key ID and the Issuer ID shown above the list.
3. **GitHub secrets** (Settings > Secrets and variables > Actions), from a shell:

   ```sh
   base64 -i developer-id.p12 | gh secret set MACOS_CERT_P12
   gh secret set MACOS_CERT_PASSWORD           # prompts for the .p12 password
   base64 -i AuthKey_<KEYID>.p8 | gh secret set MACOS_NOTARY_KEY_P8
   gh secret set MACOS_NOTARY_KEY_ID --body <KEYID>
   gh secret set MACOS_NOTARY_ISSUER --body <issuer UUID>
   ```

   `MACOS_CERT_P12` alone signs without notarizing (a warning on the run).
4. **Try it off main first:** run Build by hand on a branch (Actions > Build > Run
   workflow). It signs and notarizes but publishes nothing; the run's
   `dingbat-macos` artifact should open with a double-click on another Mac, and
   `spctl -a -vv -t open --context context:primary-signature dingbat-macos.dmg`
   should say `Notarized Developer ID`.

## Signing on your own Mac

```sh
xcrun notarytool store-credentials dingbat \
  --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer UUID>
tools/macos-release.sh --dry-run dingbat-macos.dmg   # prints every step
tools/macos-release.sh dingbat-macos.dmg             # signs, notarizes, staples
```

The argument is CI's unsigned `.dmg` (its binary is bundled again) or a `-d:macdist`
binary; with none it builds one, which needs the static `/opt/homebrew/lib/libSDL3.a`
(`docs/building.md`). Output goes to `dist/macos/`. It signs with the one Developer
ID Application identity in your keychains, or `MACOS_SIGN_IDENTITY=<SHA-1>` when
there is more than one (`security find-identity -v -p codesigning`).
`--no-notarize` signs only; `MACOS_SIGN_IDENTITY=- tools/macos-release.sh
--no-notarize ...` signs ad hoc with the hardened runtime, for checking a build
runs under it without any certificate.
