import SwiftUI

/// How a clipped line slides on hover: after a dwell it moves left at a reading
/// pace until its end shows, holds, jumps back to the start, holds, and repeats.
/// nil when the line fits and so never moves. Pure.
struct HoverSlide: Equatable {
    static let dwell: Duration = .milliseconds(500)
    static let pointsPerSecond: CGFloat = 30
    static let holdAtEnd: Duration = .milliseconds(1_200)
    static let holdAtStart: Duration = .milliseconds(800)

    /// How far the line moves left.
    let distance: CGFloat
    /// How long one slide to the end takes.
    let duration: Double

    init?(textWidth: CGFloat, available: CGFloat) {
        let distance = textWidth - available
        guard available > 0, distance > 1 else { return nil }
        self.distance = distance
        duration = Double(distance / Self.pointsPerSecond)
    }
}

/// A one-line label that, while its row is hovered and it is truncated, slides
/// so the whole text can be read, then returns to its truncated start the moment
/// the pointer leaves. The text is laid out once; only its offset animates, and
/// nothing runs for rows that aren't hovered or with Reduce Motion.
struct HoverSlidingLine: View {
    let text: String
    @Environment(\.rowHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var available: CGFloat = 0
    @State private var intrinsic: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var moving = false

    private var slide: HoverSlide? { HoverSlide(textWidth: intrinsic, available: available) }
    private var active: Bool { hovered && !reduceMotion && slide != nil }

    var body: some View {
        Text(text).lineLimit(1).truncationMode(.tail)
            .opacity(moving ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in available = width }
                }
            }
            .overlay(alignment: .leading) {
                Text(text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in intrinsic = width }
                        }
                    }
                    .offset(x: offset)
                    .opacity(moving ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            // Soft edges only while it moves: the still line keeps its ellipsis.
            .mask {
                if moving {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                           .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
            .task(id: Identity(text: text, active: active, slide: slide)) {
                reset()
                guard active, let slide else { return }
                do {
                    try await Task.sleep(for: HoverSlide.dwell)
                    moving = true
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: slide.duration)) { offset = -slide.distance }
                        try await Task.sleep(for: .seconds(slide.duration) + HoverSlide.holdAtEnd)
                        reset(keepMoving: true)
                        try await Task.sleep(for: HoverSlide.holdAtStart)
                    }
                } catch {
                    // Cancelled: the pointer left or the text changed; `reset` ran or will.
                }
            }
            .onChange(of: active) { _, isActive in if !isActive { reset() } }
    }

    /// Back to the start at once, without animating.
    private func reset(keepMoving: Bool = false) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            if !keepMoving { moving = false }
        }
    }

    private struct Identity: Equatable {
        let text: String
        let active: Bool
        let slide: HoverSlide?
    }
}
