// Screen text reader for tools/playtest: macOS Vision OCR over a GBA
// framebuffer dump (binary PPM), no third-party dependencies.
//
// Usage: screenread <frame.ppm>...     one JSON line per image
//        screenread --serve            read PPM paths on stdin, JSON line each
//
// Output: {"path":..., "lines":[{"text":..., "conf":0.98, "box":[x,y,w,h]}]}
// Boxes are in GBA pixels, top-left origin. Frames are upscaled with nearest
// neighbour before recognition (bitmap fonts at 1x are too small for Vision)
// and read twice, as-is and inverted, since light-on-dark menu text is read
// less reliably; duplicate lines from the two passes are merged.
import CoreGraphics
import Foundation
import Vision

let SCALE = 4

func loadPPM(_ path: String) -> (Int, Int, [UInt8])? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  let bytes = [UInt8](data)
  var fields: [String] = []
  var i = 0
  while fields.count < 4 && i < bytes.count {
    while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09) { i += 1 }
    if i < bytes.count && bytes[i] == 0x23 {  // comment
      while i < bytes.count && bytes[i] != 0x0A { i += 1 }
      continue
    }
    var tok = ""
    while i < bytes.count && !(bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09) {
      tok.append(Character(UnicodeScalar(bytes[i]))); i += 1
    }
    fields.append(tok)
  }
  i += 1
  guard fields.count == 4, fields[0] == "P6", let w = Int(fields[1]), let h = Int(fields[2]),
        i + w * h * 3 <= bytes.count else { return nil }
  return (w, h, Array(bytes[i ..< i + w * h * 3]))
}

func makeImage(_ w: Int, _ h: Int, _ rgb: [UInt8], invert: Bool) -> CGImage? {
  let sw = w * SCALE, sh = h * SCALE
  var rgba = [UInt8](repeating: 255, count: sw * sh * 4)
  for y in 0 ..< sh {
    for x in 0 ..< sw {
      let s = ((y / SCALE) * w + (x / SCALE)) * 3
      let d = (y * sw + x) * 4
      for c in 0 ..< 3 { rgba[d + c] = invert ? 255 - rgb[s + c] : rgb[s + c] }
    }
  }
  let provider = CGDataProvider(data: Data(rgba) as CFData)!
  return CGImage(width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: sw * 4,
                 space: CGColorSpaceCreateDeviceRGB(),
                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

struct Line { var text: String; var conf: Float; var box: [Int] }

func recognize(_ image: CGImage, _ w: Int, _ h: Int) -> [Line] {
  let req = VNRecognizeTextRequest()
  req.recognitionLevel = .accurate
  req.usesLanguageCorrection = false
  req.minimumTextHeight = 0.02
  let handler = VNImageRequestHandler(cgImage: image, options: [:])
  try? handler.perform([req])
  var out: [Line] = []
  for obs in req.results ?? [] {
    guard let cand = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox  // normalized, bottom-left origin
    let box = [Int((b.minX * CGFloat(w)).rounded()), Int(((1 - b.maxY) * CGFloat(h)).rounded()),
               Int((b.width * CGFloat(w)).rounded()), Int((b.height * CGFloat(h)).rounded())]
    out.append(Line(text: cand.string, conf: cand.confidence, box: box))
  }
  return out
}

func overlaps(_ a: [Int], _ b: [Int]) -> Bool {
  let ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
  let iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
  return ix * iy * 2 > min(a[2] * a[3], b[2] * b[3])
}

func read(_ path: String) -> [String: Any] {
  guard let (w, h, rgb) = loadPPM(path) else { return ["path": path, "error": "cannot read PPM"] }
  var lines: [Line] = []
  for invert in [false, true] {
    guard let img = makeImage(w, h, rgb, invert: invert) else { continue }
    for l in recognize(img, w, h) {
      if let k = lines.firstIndex(where: { overlaps($0.box, l.box) }) {
        if l.conf > lines[k].conf && l.text.count >= lines[k].text.count { lines[k] = l }
      } else {
        lines.append(l)
      }
    }
  }
  lines.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
  return ["path": path,
          "lines": lines.map { ["text": $0.text, "conf": Double($0.conf), "box": $0.box] as [String: Any] }]
}

func emit(_ obj: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--serve"] {
  while let line = readLine() {
    let p = line.trimmingCharacters(in: .whitespaces)
    if p.isEmpty { continue }
    emit(read(p))
  }
} else if args.isEmpty {
  FileHandle.standardError.write("Usage: screenread <frame.ppm>... | --serve\n".data(using: .utf8)!)
  exit(2)
} else {
  for p in args { emit(read(p)) }
}
