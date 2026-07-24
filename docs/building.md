# Building

Most people should just use [gba.mattrb.com](https://gba.mattrb.com) or a
[release binary](../../../releases). These instructions are for working on dingbat
itself.

## Web / WebAssembly

The browser build is the default target, and what CI deploys to GitHub Pages.

```sh
nimble wasm
python3 web/serve.py
```

`nimble wasm` builds via Emscripten and sets the flags the web build requires.
`web/serve.py` serves `web/` on `http://localhost:8765` with the headers the app needs —
notably `Cross-Origin-Opener-Policy: same-origin-allow-popups`, which is required for
the Google Drive sign-in popup to work, and `Cache-Control: no-store` so you aren't
fighting the service worker while developing.

Online play needs a small signaling server to exchange room codes. Node and
zero-dependency Nim implementations both live in `web/signaling/`.

> **Testing gotcha.** The service worker caches aggressively and stamps a
> `CACHE_VERSION`. If a change doesn't appear, hard-reload or unregister the worker
> rather than assuming the build failed.

## Native

[SDL2](https://www.libsdl.org/) and [Dear ImGui](https://github.com/ocornut/imgui) (via
[imguin](https://github.com/dinau/imguin)) are required. SDL2 is available on every major
package manager.

```sh
nimble build -d:release
```

This places the binary at `./dingbat`.

## Windows (cross-compiled)

Windows binaries are cross-compiled with mingw-w64 inside a Docker container — no Windows
machine needed:

```sh
docker build --platform linux/amd64 -t dingbat-win-cross docker/windows-cross
docker run --rm --platform linux/amd64 \
  -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
  dingbat-win-cross ./docker/windows-cross/build.sh
```

This produces a self-contained `dist/windows/dingbat.exe`. SDL2 (zlib-licensed) and the
mingw C++ runtime are linked statically, so the single exe is the entire distribution.
If an end user ever needs a different SDL2 build — for a controller fix, say — SDL's
dynamic API override still works: set `SDL_DYNAMIC_API=C:\path\to\SDL2.dll`.

## CI

Four workflows in `.github/workflows/`:

| Workflow | Does |
|---|---|
| `test.yml` | mGBA suite, GB acceptance ROMs, link/rollback acceptance, networked TCP link, web storage + service-worker tests, headless-Chromium render and WebRTC pairing tests |
| `deploy-pages.yml` | Builds the wasm target and deploys `web/` to GitHub Pages on push to main |
| `build-windows.yml` | The Docker mingw cross-build, uploaded as an artifact |
| `release.yml` | On `v*` tags: Windows `.exe` + macOS `.app`/`.dmg`, checksummed and published |

Release binaries are unsigned.
