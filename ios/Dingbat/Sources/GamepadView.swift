// On-screen touch gamepad matching the web UI's layout (web/index.html
// #controls). Input ids match the web build's data-inputs: 0 UP, 1 DOWN,
// 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START, 8 L, 9 R.
//
// SwiftUI draws the buttons and reports their frames in the "pad" coordinate
// space via a preference; an invisible multi-touch UIKit overlay hit-tests
// every active touch against those frames and forwards input-set changes to
// the core. Its hitTest only claims points inside a button.

import SwiftUI
import UIKit

struct PadRect: Equatable {
    let inputs: [Int]
    let rect: CGRect
}

struct PadRectsKey: PreferenceKey {
    static var defaultValue: [PadRect] = []
    static func reduce(value: inout [PadRect], nextValue: () -> [PadRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Registers this view as a touch target for the given input ids.
    func padTarget(_ inputs: [Int]) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PadRectsKey.self,
                    value: [PadRect(inputs: inputs, rect: geo.frame(in: .named("pad")))])
            }
        )
    }
}

// MARK: - Multi-touch routing overlay

final class TouchRoutingUIView: UIView {
    var rects: [PadRect] = []
    var onInput: ((Int, Bool) -> Void)?
    var onPressedChange: ((Set<Int>) -> Void)?

    private var activeTouches = Set<UITouch>()
    private var pressed = Set<Int>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only claim touches that start on a pad button; everything else
        // falls through to the UI beneath/behind this overlay.
        inputs(at: point) != nil ? self : nil
    }

    private func inputs(at point: CGPoint) -> [Int]? {
        for r in rects where r.rect.contains(point) { return r.inputs }
        for r in rects where r.rect.insetBy(dx: -8, dy: -8).contains(point) { return r.inputs }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        recompute()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }

    private func recompute() {
        var now = Set<Int>()
        for touch in activeTouches {
            let p = touch.location(in: self)
            if let ids = inputs(at: p) { now.formUnion(ids) }
        }
        guard now != pressed else { return }
        for id in now.subtracting(pressed) { onInput?(id, true) }
        for id in pressed.subtracting(now) { onInput?(id, false) }
        pressed = now
        onPressedChange?(now)
    }
}

/// Fill the same container that carries `.coordinateSpace(name: "pad")` so
/// overlay-local coordinates equal pad-space coordinates.
struct TouchRoutingOverlay: UIViewRepresentable {
    var rects: [PadRect]
    var onInput: (Int, Bool) -> Void
    var onPressedChange: (Set<Int>) -> Void

    func makeUIView(context: Context) -> TouchRoutingUIView {
        let view = TouchRoutingUIView()
        view.onInput = onInput
        view.onPressedChange = onPressedChange
        return view
    }

    func updateUIView(_ view: TouchRoutingUIView, context: Context) {
        view.rects = rects
        view.onInput = onInput
        view.onPressedChange = onPressedChange
    }
}

// MARK: - Button visuals (web .pad-btn styling)

private struct PadKeyStyle: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: pressed
                        ? [Theme.padPressedTop, Theme.padPressedBot]
                        : [Theme.padTop, Theme.padBottom],
                    startPoint: .top, endPoint: .bottom))
            .foregroundColor(pressed ? Theme.accent : Theme.textDim)
    }
}

struct DPadView: View {
    let size: CGFloat
    let pressed: Set<Int>

    private func armPressed(_ id: Int) -> Bool { pressed.contains(id) }

    var body: some View {
        let cell = size / 3
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: cell, height: cell)
                    .padTarget([0, 2])
                arm(0, corners: [.topLeft, .topRight], cell: cell)
                Color.clear.frame(width: cell, height: cell)
                    .padTarget([0, 3])
            }
            HStack(spacing: 0) {
                arm(2, corners: [.topLeft, .bottomLeft], cell: cell)
                center(cell: cell)
                arm(3, corners: [.topRight, .bottomRight], cell: cell)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: cell, height: cell)
                    .padTarget([1, 2])
                arm(1, corners: [.bottomLeft, .bottomRight], cell: cell)
                Color.clear.frame(width: cell, height: cell)
                    .padTarget([1, 3])
            }
        }
        .frame(width: size, height: size)
    }

    private func arm(_ id: Int, corners: UIRectCorner, cell: CGFloat) -> some View {
        Color.clear
            .frame(width: cell, height: cell)
            .modifier(PadKeyStyle(pressed: armPressed(id)))
            .overlay(
                RoundedCorner(radius: 9, corners: corners)
                    .stroke(armPressed(id) ? Theme.padPressedBorder : Theme.border2, lineWidth: 1))
            .clipShape(RoundedCorner(radius: 9, corners: corners))
            .shadow(color: armPressed(id) ? Theme.accentGlow : .clear, radius: 8)
            .padTarget([id])
    }

    private func center(cell: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Theme.padTop, Theme.padBottom],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color.black.opacity(0.25))
                .padding(cell * 0.22)
        }
        .frame(width: cell, height: cell)
    }
}

struct FaceButtonsView: View {
    let buttonSize: CGFloat
    let pressed: Set<Int>

    var body: some View {
        let width = buttonSize * 2.2
        let height = buttonSize * 2.9
        ZStack(alignment: .topTrailing) {
            faceButton("A", id: 4)
                .offset(y: height * 0.14)
            faceButton("B", id: 5)
                .offset(x: -(width - buttonSize), y: height - buttonSize - height * 0.14)
        }
        .frame(width: width, height: height, alignment: .topTrailing)
    }

    private func faceButton(_ label: String, id: Int) -> some View {
        let isDown = pressed.contains(id)
        return Text(label)
            .font(.system(size: buttonSize * 0.32, weight: .semibold))
            .frame(width: buttonSize, height: buttonSize)
            .modifier(PadKeyStyle(pressed: isDown))
            .overlay(Circle().stroke(isDown ? Theme.padPressedBorder : Theme.border2, lineWidth: 1))
            .clipShape(Circle())
            .shadow(color: isDown ? Theme.accentGlow : .clear, radius: 8)
            .padTarget([id])
    }
}

struct ShoulderButton: View {
    let label: String
    let id: Int
    let pressed: Set<Int>

    var body: some View {
        let isDown = pressed.contains(id)
        let shape = RoundedCorner(radius: 10, corners: [.topLeft, .topRight])
        return Text(label)
            .font(.system(size: 14, weight: .semibold))
            .tracking(1.8)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .modifier(PadKeyStyle(pressed: isDown))
            .overlay(shape.stroke(isDown ? Theme.padPressedBorder : Theme.border2, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: isDown ? Theme.accentGlow : .clear, radius: 8)
            .padTarget([id])
    }
}

struct PillButton: View {
    let label: String
    let id: Int
    let pressed: Set<Int>

    var body: some View {
        let isDown = pressed.contains(id)
        return Text(label.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .frame(width: 120, height: 32)
            .modifier(PadKeyStyle(pressed: isDown))
            .overlay(Capsule().stroke(isDown ? Theme.padPressedBorder : Theme.border2, lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: isDown ? Theme.accentGlow : .clear, radius: 8)
            .padTarget([id])
    }
}
