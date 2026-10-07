// PLACEHOLDER — replaced by the touch controls / controllers work.
import SwiftUI

/// Sensors, haptics, controllers, camera: installed once at launch.
final class Peripherals {
    static let shared = Peripherals()
    func install() {}
    var cameraOn = false
    func recenterTilt() {}
    func cameraButton() {}
}

/// Arranges the stage, the top bar and the touch controls for the device
/// and orientation. `stage` fills the rect it is given.
struct PlayLayout<Stage: View, Bar: View>: View {
    let stage: Stage
    let bar: Bar
    var body: some View {
        VStack(spacing: 0) {
            bar
            stage
        }
    }
}

/// Global-coordinate rects of every drawn touch control, so a tap on the
/// picture can keep clear of them.
final class PadGeometry {
    static let shared = PadGeometry()
    var rects: [CGRect] = []
}
