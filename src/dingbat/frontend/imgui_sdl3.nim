## Dear ImGui's SDL 3 platform backend, compiled from imguin's copy of the
## imgui sources but declared against the sdl3 package's types. imguin's own
## impl_sdl3 imports a second SDL 3 binding (sdl3_nim), whose Window and
## Event are different Nim types from ours; these calls are all the
## frontend needs.

import sdl3
# imgui's include dirs, for the C++ backend. Windows and Linux draw with
# OpenGL, whose imguin module puts them there along with ImGui's GL backend.
when defined(macosx): import imgui_paths
else: import imguin/impl_opengl

# Found on the search path, which holds the imguin package root
{.compile: "imguin/private/cimgui/imgui/backends/imgui_impl_sdl3.cpp".}

{.push cdecl, importc.}
proc ImGui_ImplSDL3_InitForOpenGL*(window: Window; sdl_gl_context: GLContext): bool
proc ImGui_ImplSDL3_InitForMetal*(window: Window): bool
proc ImGui_ImplSDL3_Shutdown*()
proc ImGui_ImplSDL3_NewFrame*()
proc ImGui_ImplSDL3_ProcessEvent*(event: ptr Event): bool
{.pop.}
