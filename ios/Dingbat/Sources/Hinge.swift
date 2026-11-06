import SwiftUI
import UIKit

/// The hinge of a foldable iPhone (iOS 27.1 UIHinge): half-folded is the
/// hinge partly open, the laptop posture -- PlayGeometry then keeps the
/// picture above the crease and the controls below it. The API gives the
/// hinge's status and angle, not where it runs, so the layout takes the
/// middle of the inner screen held upright (the cover screen is half of it).
final class HingeState: ObservableObject {
    static let shared = HingeState()
    @Published private(set) var halfFolded = false

    /// Debug builds: `-half-folded` as if partly open, `-no-hinge` as if
    /// flat, whatever the hinge says (screenshots of either posture).
    private let forced: Bool? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-half-folded") { return true }
        if args.contains("-no-hinge") { return false }
        #endif
        return nil
    }()

    private init() { halfFolded = forced ?? false }

    func set(partlyOpen: Bool) {
        let v = forced ?? partlyOpen
        if v != halfFolded { withAnimation(.easeOut(duration: 0.25)) { halfFolded = v } }
    }
}

/// An empty view carrying the UIHingeInteraction (it reports for the
/// hierarchy it is in). The interaction is in the iOS 27.1 SDK only: built
/// with an older Xcode (Swift before 6.4) the app has no hinge.
struct HingeObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            v.addInteraction(UIHingeInteraction { _, update in
                HingeState.shared.set(partlyOpen: update.hinge?.status == .partiallyOpen)
            })
        }
        #endif
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}
