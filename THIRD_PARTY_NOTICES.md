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
| nim-lang/sdl3 bindings | MIT | the nim-lang/sdl3 contributors |
| SDL 3 (static in the release builds) | zlib | Sam Lantinga |
| imguin, cimgui, Dear ImGui and its SDL 3/OpenGL3 backends | MIT | the imguin authors; Stephan Dilly; Omar Cornut |
| Dear ImGui's Metal backend (macOS; `src/dingbat/frontend/vendor/`, unmodified from v1.92.4-docking, which imguin does not ship) | MIT | Omar Cornut |
| Dear ImGui's FreeType font loader, imgui_freetype (Windows and Linux; `src/dingbat/frontend/vendor/`, unmodified from v1.92.4-docking, which imguin does not ship) | MIT | Omar Cornut, Aleksei Skriabin, Mike Sartain |
| FreeType 2.15.0 (static in the Windows and Linux builds, not in the macOS build; built by `.github/scripts/build-freetype.sh`) | FreeType License (FTL), the first of its dual licences (credit below) | David Turner, Robert Wilhelm, Werner Lemberg and the FreeType Project |
| glad OpenGL loader | public domain / CC0 | David Herberth |
| NimYAML | MIT | Felix Krause |
| stb_image, stb_image_write | public domain / MIT | Sean Barrett |
| Inter 4.1, Regular and SemiBold (`src/dingbat/frontend/vendor/fonts/`, unmodified from the v4.1 release), the UI font on Linux and Windows' fallback (not in the macOS build) | SIL Open Font License 1.1 (text below) | The Inter Project Authors |
| JetBrains Mono 2.304, Regular (`src/dingbat/frontend/vendor/fonts/`, unmodified from the v2.304 release), the monospaced UI font on Linux and Windows' fallback (not in the macOS build) | SIL Open Font License 1.1 (text below) | The JetBrains Mono Project Authors |

The UI's other fonts are the system's, read from it at run time and not
distributed with dingbat: San Francisco and SF Mono on macOS, Segoe UI and
Consolas on Windows.

The Windows and Linux builds are based in part on the work of the FreeType
Team (https://freetype.org). Portions of this software are copyright ©
2026 The FreeType Project (https://freetype.org). All rights reserved.

## Compiled into the iOS build only

The online link's WebRTC data channel, built unmodified from the pinned
tags by `ios/build-webrtc.sh` (libdatachannel v0.24.6, mbedTLS v3.6.7).
The MPL-2.0 components' source is the upstream source at those tags.

| Component | Licence | Copyright |
|---|---|---|
| libdatachannel | MPL-2.0 | Paul-Louis Ageneau |
| libjuice (ICE) | MPL-2.0 | Paul-Louis Ageneau |
| usrsctp (SCTP) | BSD-3-Clause | Randall Stewart and Michael Tuexen |
| plog (logging, header-only) | MIT | Sergey Podobry |
| Mbed TLS, with its p256-m and Everest (Curve25519) third-party code | Apache-2.0 | the Mbed TLS contributors |

## Code derived from other projects

- **Booth multiplier carry model** (`src/dingbat/gba/arm/arm.nim`): a port of
  zaydlang/multiplication-algorithm, zlib licence, Copyright (c) 2024
  zaydlang. The full zlib notice is kept in the source file as the licence
  requires.
- **GBA colour-correction model** (`src/dingbat.nim`, `src/dingbat_wasm.nim`,
  `src/dingbat_ios.nim`, `web/glpresent.js`,
  `ios/Dingbat/Sources/PresentShader.swift`): the gamma and mixing constants
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

## SIL Open Font License 1.1 (Inter, JetBrains Mono)

```
Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)
Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION AND CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
