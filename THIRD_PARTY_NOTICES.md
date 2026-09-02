# Third-party notices

dingbat is MIT (see LICENSE). The shipped binaries also contain, or derive
from, the following. Each entry names the licence and the notice its
licence asks to be kept.

## Compiled into the desktop, web and iOS builds

| Component | Licence | Copyright |
|---|---|---|
| Nim compiler runtime and standard library | MIT | Andreas Rumpf and the Nim contributors |
| zippy (zlib/deflate in Nim) | MIT | Ryan Oldenburg |
| Emscripten runtime, emmalloc (web only) | MIT / NCSA | Emscripten authors |
| musl libc (web only) | MIT | Rich Felker, et al. |
| libc++, libc++abi, compiler-rt (web only) | Apache-2.0 with LLVM exception | LLVM Project |

## Compiled into the desktop build only

| Component | Licence | Copyright |
|---|---|---|
| nim-lang/sdl2 bindings | MIT | the nim-lang/sdl2 contributors |
| SDL2 (static on macOS and Windows) | zlib | Sam Lantinga |
| imguin, cimgui, Dear ImGui and its SDL2/OpenGL3 backends | MIT | the imguin authors; Stephan Dilly; Omar Cornut |
| glad OpenGL loader | public domain / CC0 | David Herberth |
| NimYAML | MIT | Felix Krause |
| stb_image, stb_image_write | public domain / MIT | Sean Barrett |

## Code derived from other projects

- **Booth multiplier carry model** (`src/dingbat/gba/arm/arm.nim`): a port of
  zaydlang/multiplication-algorithm, zlib licence, Copyright (c) 2024
  zaydlang. The full zlib notice is kept in the source file as the licence
  requires.
- **GBA colour-correction model** (`src/dingbat.nim`, `src/dingbat_wasm.nim`,
  `src/dingbat_ios.nim`, `web/glpresent.js`): the gamma and mixing constants
  of the ares emulator's GBA colour model. ISC licence, Copyright (c)
  2004-2025 ares team, Near et al. Permission to use, copy, modify, and/or
  distribute this software for any purpose with or without fee is hereby
  granted, provided that the above copyright notice and this permission
  notice appear in all copies. THE SOFTWARE IS PROVIDED "AS IS" AND THE
  AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE.
- **GBC colour-correction model**: Pokefan531's "GBC-Color" constants,
  published in the public domain.

## Bundled content

- `web/goodboy-demo-en.gba`: the Goodboy Galaxy demo, included with its
  authors' permission for the web and iOS demo mode. All rights remain with
  its authors; it is not covered by dingbat's licence.

## MIT licence text

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions: The above copyright
notice and this permission notice shall be included in all copies or
substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
THE USE OR OTHER DEALINGS IN THE SOFTWARE.
