## Dear ImGui's include directories for the C++ and Objective-C++ backends
## compiled here (imgui_impl_sdl3.cpp, imgui_impl_metal.mm), found in imguin
## on the search path. imguin's own impl_opengl puts them there too, but also
## compiles ImGui's OpenGL backend, which macOS does not draw with.

import std/[compilesettings, os]

const CIMGUI_DIR = block:
  var dir = ""
  # nimble's package directories are lazy paths; a --path may also name the
  # imguin directory itself
  for p in querySettingSeq(searchPaths) & querySettingSeq(lazyPaths):
    for root in [p / "imguin", p]:
      if dir.len == 0 and fileExists(root / "private/cimgui/imgui/imgui.h"):
        dir = root / "private/cimgui"
  doAssert dir.len > 0, "imguin's imgui sources are not on the search path"
  dir

{.passC: "-I" & CIMGUI_DIR.}
{.passC: "-I" & CIMGUI_DIR / "imgui".}
