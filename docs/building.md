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

Requires [SDL 3](https://www.libsdl.org/) (through the official
[nim-lang/sdl3](https://github.com/nim-lang/sdl3) binding) and
[Dear ImGui](https://github.com/ocornut/imgui) via [imguin](https://github.com/dinau/imguin).

```sh
nimble build -d:release   # -> ./dingbat
```

macOS: `brew install sdl3`. Linux: `libsdl3-dev libgl1-mesa-dev` (Ubuntu 25.04+, Debian
13+), `SDL3-devel mesa-libGL-devel` (Fedora 42+), `sdl3` (Arch); older distros build it
with `.github/scripts/build-sdl3.sh /usr/local` (as root). SDL 3 is linked at build time
everywhere: dynamically for a dev build, statically for the release builds (`-d:macdist`
on macOS; CI's Linux and Windows builds have only `libSDL3.a` to link).

`nimble install --depsOnly` fails inside the checkout on nimble 0.22 ("Couldnt find a
solution for the packages"); install from another directory instead, as CI does:
`cd /tmp && nimble install -y "https://github.com/nim-lang/sdl3@#bb137829ff619b0a27a473628cb28fc1c86f3fe5" imguin yaml stb_image zippy`
(the registry's `sdl3` is an older, unofficial binding, so the official one is named by URL;
`sdl2` too for the web build).

## Windows (cross-compiled)

```sh
docker build --platform linux/amd64 -t dingbat-win-cross \
  -f docker/windows-cross/Dockerfile .github/scripts
docker run --rm --platform linux/amd64 \
  -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
  dingbat-win-cross ./docker/windows-cross/build.sh
```

Produces a self-contained `dist/windows/dingbat.exe` (SDL 3 and the mingw C++ runtime
linked statically). A different SDL 3 build can be substituted at runtime with
`SDL_DYNAMIC_API=C:\path\to\SDL3.dll`.

## CI

`.github/workflows/`: `test.yml` (all test suites, see `tests/README.md`),
`deploy-pages.yml` (wasm build to GitHub Pages on push to main), `build-artifacts.yml`
(the three desktop builds, `workflow_call` only), `build.yml` (calls it on every push and
PR), `release.yml` (on `v*` tags: same builds, checksummed and published). Linux builds on
`ubuntu-22.04` for the glibc 2.34 floor. All three jobs build a static SDL 3 from source
(`.github/scripts/build-sdl3.sh`, cached): Homebrew's `sdl3` and SDL's mingw devel package
ship no `libSDL3.a`, and Ubuntu 22.04 has no SDL 3 package.
