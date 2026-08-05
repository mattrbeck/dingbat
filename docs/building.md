# Building

Most people should just use [dingbat.gg](https://dingbat.gg) or a
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

On Linux install the development packages first (`apt install libsdl2-dev
libgl1-mesa-dev`, or `dnf install SDL2-devel mesa-libGL-devel`). `nim.cfg` adds
`-I/usr/include/SDL2` for the imgui SDL2 backend, which is where both Debian and Fedora
put those headers; if your distro differs, that is the line to change. SDL2 is loaded
dynamically here, so the runtime package must be installed to *run* the binary — macOS
and Windows link it statically instead.

> **Dependency gotcha.** `nimble install --depsOnly` currently fails inside the checkout
> with "Couldnt find a solution for the packages" on nimble 0.22. Install them one at a
> time from another directory instead — `cd /tmp && nimble install -y sdl2 imguin yaml
> stb_image zippy` — which is what CI does.

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

Five workflows in `.github/workflows/`:

| Workflow | Does |
|---|---|
| `test.yml` | mGBA suite, GB acceptance ROMs, link/rollback acceptance, networked TCP link, web storage + service-worker tests, headless-Chromium render and WebRTC pairing tests |
| `deploy-pages.yml` | Builds the wasm target and deploys `web/` to GitHub Pages on push to main |
| `build-artifacts.yml` | The three desktop builds. Not triggered directly — `workflow_call` only |
| `build.yml` | Calls `build-artifacts.yml` on every push and PR, so any commit's binaries are downloadable from its run |
| `release.yml` | On `v*` tags: calls the same `build-artifacts.yml`, then checksums and publishes the three files |

The builds live in `build-artifacts.yml` so the per-push and release paths cannot
drift — a release ships the same recipe that has been running on every commit.

Linux builds on `ubuntu-22.04` on purpose: a glibc-linked binary runs only on its
build glibc or newer, and 22.04's `GLIBC_2.34` floor covers Ubuntu 22.04+, Debian 12+
and Fedora 35+.

The macOS job builds SDL2 **from source** rather than from Homebrew. The `sdl2`
formula no longer exists — the name resolves to `sdl2-compat`, a shim over SDL3 that
ships no `libSDL2.a`, so `-d:macdist` cannot link against it. The pinned source build
is cached between runs.

Release binaries are unsigned.
