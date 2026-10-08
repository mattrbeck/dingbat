// The Swift export core's side of ios/e2e/export-core.mjs: reads the case
// files the test wrote and writes what ExportCore makes of them.
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let spec = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("spec.json"))) as! [String: Any]
func bytes(_ name: String) -> Data { try! Data(contentsOf: dir.appendingPathComponent(name)) }
func put(_ name: String, _ d: Data) { try! d.write(to: dir.appendingPathComponent("swift-" + name)) }

// Camera photos, from the album and from its backup copy.
for c in ["camera-main", "camera-backup"] {
    var out = Data()
    for p in ExportCore.cameraPhotos(rom: bytes("camera.rom"), sav: bytes(c + ".sav")) {
        out.append(contentsOf: Array("\(p.number):".utf8))
        out.append(ExportCore.greyPng2(p.pixels, w: ExportCore.camW, h: ExportCore.camH))
    }
    put(c + ".bin", out)
}
// The zip, at a fixed time.
let ms = spec["ms"] as! Double
let names = spec["zipNames"] as! [String]
let files = names.enumerated().map { (name: $0.element, data: bytes("zip\($0.offset).bin")) }
put("zip.zip", try! ExportCore.zip(files, now: Date(timeIntervalSince1970: ms / 1000)))
// Names, stamps, info.json.
let safe = (spec["names"] as! [String]).map(ExportCore.safeName)
let info = ExportCore.infoJSON(game: spec["game"] as! String, system: spec["system"] as! String, exportedMs: ms,
                               files: (spec["files"] as! [[String: String]]).map { ($0["path"]!, $0["kind"]!) })
let text = try! JSONSerialization.data(withJSONObject: ["safe": safe, "stamp": ExportCore.stamp(ms), "day": ExportCore.day(ms)],
                                       options: [.sortedKeys])
put("text.json", text)
put("info.json", info)
// Adding a zip back as a game: what ZipReader takes from each.
var picked: [String: Any] = [:]
for z in ["addback-export", "addback-other"] {
    let r = ZipReader.extractRom(from: bytes(z + ".zip"))
    picked[z] = ["rom": r?.name ?? "", "romLen": r?.rom.count ?? -1, "artLen": r?.art?.count ?? 0]
}
put("addback.json", try! JSONSerialization.data(withJSONObject: picked, options: [.sortedKeys]))
