# Building

Most people should use [dingbat.gg](https://dingbat.gg) or a
[release binary](../../../releases). These instructions are for working on dingbat.

## Web / WebAssembly

```sh
nimble wasm          # Emscripten build -> web/em.js + web/em.wasm
python3 web/serve.py # serves web/ on http://localhost:8765
```

`serve.py` sends `Cross-Origin-Opener-Policy: same-origin-allow-popups` (required for
the Google Drive sign-in popup) and `Cache-Control: no-store`. The service worker caches
aggressively and stamps a `CACHE_VERSION`; if a change does not appear, hard-reload or
unregister the worker before assuming the build failed.

Online play needs a signaling server for room codes: Node and zero-dependency Nim
implementations live in `web/signaling/`.

## Native

Requires [SDL2](https://www.libsdl.org/) and [Dear ImGui](https://github.com/ocornut/imgui)
via [imguin](https://github.com/dinau/imguin).

```sh
nimble build -d:release   # -> ./dingbat
```

Linux: install `libsdl2-dev libgl1-mesa-dev` (Debian) or `SDL2-devel mesa-libGL-devel`
(Fedora). `nim.cfg` adds `-I/usr/include/SDL2` for the imgui backend; change that line if
your distro differs. SDL2 is loaded dynamically on Linux, statically on macOS and Windows.

`nimble install --depsOnly` fails inside the checkout on nimble 0.22 ("Couldnt find a
solution for the packages"); install from another directory instead, as CI does:
`cd /tmp && nimble install -y sdl2 imguin yaml stb_image zippy`.

## Windows (cross-compiled)

```sh
docker build --platform linux/amd64 -t dingbat-win-cross docker/windows-cross
docker run --rm --platform linux/amd64 \
  -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
  dingbat-win-cross ./docker/windows-cross/build.sh
```

Produces a self-contained `dist/windows/dingbat.exe` (SDL2 and the mingw C++ runtime
linked statically). A different SDL2 build can be substituted at runtime with
`SDL_DYNAMIC_API=C:\path\to\SDL2.dll`.

## CI

`.github/workflows/`: `test.yml` (all test suites, see `tests/README.md`),
`deploy-pages.yml` (wasm build to GitHub Pages on push to main), `build-artifacts.yml`
(the three desktop builds, `workflow_call` only), `build.yml` (calls it on every push and
PR), `release.yml` (on `v*` tags: same builds, checksummed and published). Linux builds on
`ubuntu-22.04` for the glibc 2.34 floor. The macOS job builds SDL2 from source because
Homebrew's `sdl2` now resolves to `sdl2-compat`, which ships no `libSDL2.a`.
