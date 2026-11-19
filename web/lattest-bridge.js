// lattest.html's way into the app page it frames: index.js's let/const
// globals are not window properties, and the page's Content-Security-Policy
// refuses an inline script, but runs one of this origin's files (which
// shares the page's global scope). Safari won't read a File constructed in
// another realm: write the bytes into the wasm FS and load directly, as
// handleRomFile does after its read.
window.__loadRomBytes = async (bytes) => {
  writeToFS("rom.gba", bytes);
  await addRecentRom("m7_demo.gba", bytes);
  await loadRom("rom.gba", "m7_demo.gba");
};
