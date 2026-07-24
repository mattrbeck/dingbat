// Simulate a play session: three different ROMs loaded one after another, the
// way the app's loadRom does it (each written to FS under its own name).
window.benchSession = async () => {
  const heap = () => +(Module.memory.buffer.byteLength/1048576).toFixed(1);
  const out = { start: heap(), steps: [] };
  for (const name of ["PokemonFireRed.gba", "PokemonEmerald.gba", "MetroidFusion.gba"]) {
    const buf = new Uint8Array(await (await fetch(name)).arrayBuffer());
    Module.FS.writeFile(name, buf);
    Module.ccall("initFromEmscripten", null, ["string"], [name]);
    Module._benchFrames(10);
    let inFS = 0;
    for (const n of ["PokemonFireRed.gba","PokemonEmerald.gba","MetroidFusion.gba"]) {
      try { inFS += Module.FS.stat(n).size; } catch {}
    }
    out.steps.push({ loaded: name, heapMB: heap(), deadRomsInFS_MB: +(inFS/1048576).toFixed(1) });
  }
  return out;
};
