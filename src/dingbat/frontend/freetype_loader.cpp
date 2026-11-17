// Dear ImGui's FreeType font loader (vendor/imgui_freetype.cpp) for C callers
#include "imgui.h"
#include "vendor/imgui_freetype.h"

extern "C" const ImFontLoader* dingbat_freetype_loader(void) {
  return ImGuiFreeType::GetFontLoader();
}
