import UIKit

/// Where the notch or Dynamic Island ends on an iPhone held upright, so a
/// DS game's top screen can start right under it (PlayGeometry.ndsPortrait;
/// web nds/ndsutil.js `CUTOUTS` keeps the same numbers by screen size).
/// Measured on each model's simulator: the screen mask for the notches
/// (iOS's own exclusion area is up to 1.7pt short of the drawn notch) and
/// the system's exclusion area for the islands (`-probe-cutout`).
enum PhoneCutout {
    /// "iPhone18,3"; the simulator reports the model it plays.
    static let modelIdentifier: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// The cut-out's bottom edge in points from the top, for a play area
    /// that is the whole screen held upright; nil for anything else (an
    /// iPad, Split View, a phone this table doesn't know).
    static func bottom(screen size: CGSize, safeTop: CGFloat) -> CGFloat? {
        let screen = UIScreen.main.bounds.size
        guard size.width < size.height, abs(size.width - screen.width) < 1,
              abs(size.height - screen.height) < 1 else { return nil }
        if let v = byModel[modelIdentifier] { return v }
        return bySize["\(Int(size.width))x\(Int(size.height))@\(Int(safeTop.rounded()))"]
    }

    static let byModel: [String: CGFloat] = [
        // Notches
        "iPhone10,3": 30, "iPhone10,6": 30,                     // X
        "iPhone11,2": 30, "iPhone11,4": 30, "iPhone11,6": 30,   // XS, XS Max
        "iPhone11,8": 33, "iPhone12,1": 33,                     // XR, 11
        "iPhone12,3": 30, "iPhone12,5": 30,                     // 11 Pro, 11 Pro Max
        "iPhone13,1": 34.33,                                    // 12 mini
        "iPhone13,2": 32, "iPhone13,3": 32, "iPhone13,4": 32,   // 12, 12 Pro, 12 Pro Max
        "iPhone14,4": 37.5,                                     // 13 mini
        "iPhone14,5": 33.67, "iPhone14,2": 33.67, "iPhone14,3": 33.67, // 13, 13 Pro, 13 Pro Max
        "iPhone14,7": 33.67, "iPhone14,8": 33.67,               // 14, 14 Plus
        "iPhone17,5": 33.67, "iPhone18,5": 33.67,               // 16e, 17e
        // Dynamic Islands
        "iPhone15,2": 48, "iPhone15,3": 48,                     // 14 Pro, 14 Pro Max
        "iPhone15,4": 48, "iPhone15,5": 48,                     // 15, 15 Plus
        "iPhone16,1": 48, "iPhone16,2": 48,                     // 15 Pro, 15 Pro Max
        "iPhone17,3": 48, "iPhone17,4": 48,                     // 16, 16 Plus
        "iPhone17,1": 50.67, "iPhone17,2": 50.67,               // 16 Pro, 16 Pro Max
        "iPhone18,3": 50.67, "iPhone18,1": 50.67, "iPhone18,2": 50.67, // 17, 17 Pro, 17 Pro Max
        "iPhone18,4": 56.67,                                    // Air
        "iPhone19,2": 50.67, "iPhone19,3": 50.67,               // 18 Pro, 18 Pro Max
    ]

    /// A model not listed: the web's table, by screen size and status bar.
    static let bySize: [String: CGFloat] = [
        "375x812@44": 30, "414x896@44": 30, "414x896@48": 33, "375x812@50": 37.5,
        "390x844@47": 33.67, "428x926@47": 33.67,
        "393x852@59": 48, "430x932@59": 48, "402x874@62": 50.67, "440x956@62": 50.67,
        "420x912@68": 56.67,
    ]
}
