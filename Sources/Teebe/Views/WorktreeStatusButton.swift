import SwiftUI

/// Native popover with a short hover delay; clicking also opens it for keyboard users.
struct WorktreeStatusButton: View {
    let presentation: MergeIndicatorPresentation
    var isSelected = false
    var isChecking = false
    var informationOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchorHovered = false
    @State private var popoverHovered = false
    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    private var tint: Color {
        if isSelected { return .white }
        switch presentation.tone {
        case .merged: return Palette.green
        case .attention: return .orange
        case .error: return .red
        case .secondary: return Palette.secondaryText
        }
    }

    var body: some View {
        Button { hoverTask?.cancel(); isPresented.toggle() } label: {
            Group {
                if informationOnly { Image(systemName: "info.circle").font(.system(size: 12)) } else {
                    GitStatusGlyph(symbol: presentation.symbol)
                }
            }
                .frame(width: 15, height: 16)
                .foregroundStyle(tint)
                .frame(width: 25, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.white.opacity(anchorHovered || isPresented ? 0.18 : 0)
                              : Color.primary.opacity(anchorHovered || isPresented ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.description)
        .accessibilityHint("Show merge details")
        .onHover { anchorHovered = $0; updateHover() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: anchorHovered || isPresented)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(presentation.tone == .error ? Color.red : Color.primary)
                ForEach(presentation.details, id: \.self) { detail in
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if isChecking {
                    Text("Refreshing…").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .onHover { popoverHovered = $0; updateHover() }
        }
        .onDisappear { hoverTask?.cancel(); isPresented = false }
    }

    private func updateHover() {
        hoverTask?.cancel()
        let shouldOpen = anchorHovered || popoverHovered
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(shouldOpen ? 180 : 220)) } catch { return }
            guard !Task.isCancelled else { return }
            isPresented = shouldOpen
        }
    }
}

/// Conventional Git graph: round commits joined by a branch or merge line.
struct GitStatusGlyph: View {
    let symbol: MergeIndicatorPresentation.Symbol

    var body: some View {
        switch symbol {
        case .branch:
            Canvas { context, size in
                context.scaleBy(x: size.width / 16, y: size.height / 16)
                var lines = Path()
                lines.move(to: CGPoint(x: 4, y: 11))
                lines.addLine(to: CGPoint(x: 4, y: 2))
                lines.move(to: CGPoint(x: 1, y: 5))
                lines.addLines([CGPoint(x: 4, y: 2), CGPoint(x: 7, y: 5)])
                lines.move(to: CGPoint(x: 12, y: 5))
                lines.addLine(to: CGPoint(x: 12, y: 14))
                lines.move(to: CGPoint(x: 9, y: 11))
                lines.addLines([CGPoint(x: 12, y: 14), CGPoint(x: 15, y: 11)])
                context.stroke(lines, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                var nodes = Path()
                nodes.addEllipse(in: CGRect(x: 2, y: 11, width: 4, height: 4))
                nodes.addEllipse(in: CGRect(x: 10, y: 1, width: 4, height: 4))
                context.stroke(nodes, with: .foreground, lineWidth: 1.3)
            }
        case .broken:
            ZStack {
                Image(systemName: "folder").font(.system(size: 14))
                Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).offset(y: 2)
            }
        case .merge: Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .medium))
        case .edit: Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium))
        case .ignored: Image(systemName: "eye.slash").font(.system(size: 13))
        case .unknown: Image(systemName: "questionmark.circle").font(.system(size: 12))
        case .warning: Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
        case .checking: Image(systemName: "clock").font(.system(size: 12))
        }
    }
}
