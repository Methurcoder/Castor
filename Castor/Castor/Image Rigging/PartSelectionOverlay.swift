import SwiftUI

struct PartSelectionOverlay: View {
    @Binding var document: RigDocument
    @Binding var selectedPartID: RigPart.ID?
    @State private var dragStartRects: [RigPart.ID: CGRect] = [:]
    @State private var hoveredPartID: RigPart.ID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(sortedPartIndices, id: \.self) { index in
                    let partBinding = Binding<RigPart>(
                        get: { document.parts[index] },
                        set: { document.parts[index] = $0 }
                    )
                    let part = partBinding.wrappedValue
                    let rect = displayRect(for: part.normalizedRect, in: proxy.size)
                    partOverlay(part: partBinding, rect: rect, canvasSize: proxy.size)
                }
            }
        }
    }

    private var sortedPartIndices: [Int] {
        document.parts.indices.sorted { left, right in
            let leftPart = document.parts[left]
            let rightPart = document.parts[right]
            if leftPart.id == hoveredPartID {
                return false
            }
            if rightPart.id == hoveredPartID {
                return true
            }
            if leftPart.id == selectedPartID {
                return false
            }
            if rightPart.id == selectedPartID {
                return true
            }
            return leftPart.zIndex < rightPart.zIndex
        }
    }

    private func partOverlay(part: Binding<RigPart>, rect: CGRect, canvasSize: CGSize) -> some View {
        let isSelected = selectedPartID == part.wrappedValue.id
        let isHovered = hoveredPartID == part.wrappedValue.id
        let color = color(for: part.wrappedValue.kind)
        let fillOpacity = isSelected ? 0.14 : isHovered ? 0.20 : 0.06
        let strokeOpacity = isHovered && !isSelected ? 0.62 : 1

        return ZStack(alignment: .bottomTrailing) {
            shape(for: part.wrappedValue.shape)
                .stroke(color.opacity(strokeOpacity), style: StrokeStyle(lineWidth: isSelected ? 3 : isHovered ? 2.2 : 1.5, dash: isSelected ? [] : [5, 4]))
                .background(shape(for: part.wrappedValue.shape).fill(color.opacity(fillOpacity)))
                .overlay {
                    if isHovered && !isSelected {
                        shape(for: part.wrappedValue.shape)
                            .fill(.black.opacity(0.10))
                    }
                }

            Text(part.wrappedValue.kind.label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(isHovered ? 0.95 : 0.82)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(4)

            if isSelected {
                Rectangle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .overlay(Rectangle().stroke(color, lineWidth: 2))
                    .offset(x: 5, y: 5)
                    .gesture(resizeGesture(part: part, canvasSize: canvasSize))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredPartID = part.wrappedValue.id
                selectedPartID = part.wrappedValue.id
            } else if hoveredPartID == part.wrappedValue.id {
                hoveredPartID = nil
            }
        }
        .onTapGesture {
            selectedPartID = part.wrappedValue.id
        }
        .gesture(moveGesture(part: part, canvasSize: canvasSize))
    }

    private func shape(for partShape: RigPartShape) -> AnyShape {
        switch partShape {
        case .rectangle:
            AnyShape(Rectangle())
        case .ellipse:
            AnyShape(Ellipse())
        }
    }

    private func moveGesture(part: Binding<RigPart>, canvasSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                selectedPartID = part.wrappedValue.id
                let startRect = dragStartRects[part.wrappedValue.id] ?? part.wrappedValue.normalizedRect
                dragStartRects[part.wrappedValue.id] = startRect
                var rect = startRect
                rect.origin.x += value.translation.width / max(canvasSize.width, 1)
                rect.origin.y += value.translation.height / max(canvasSize.height, 1)
                part.wrappedValue.normalizedRect = clamped(rect)
            }
            .onEnded { _ in
                dragStartRects[part.wrappedValue.id] = nil
            }
    }

    private func resizeGesture(part: Binding<RigPart>, canvasSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let startRect = dragStartRects[part.wrappedValue.id] ?? part.wrappedValue.normalizedRect
                dragStartRects[part.wrappedValue.id] = startRect
                var rect = startRect
                rect.size.width += value.translation.width / max(canvasSize.width, 1)
                rect.size.height += value.translation.height / max(canvasSize.height, 1)
                part.wrappedValue.normalizedRect = clamped(rect)
            }
            .onEnded { _ in
                dragStartRects[part.wrappedValue.id] = nil
            }
    }

    private func displayRect(for normalizedRect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * size.width,
            y: normalizedRect.minY * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        )
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.03), 1)
        let height = min(max(rect.height, 0.03), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func color(for kind: RigPartKind) -> Color {
        switch kind {
        case .head:
            .red
        case .leftEye, .rightEye:
            .cyan
        case .mouth:
            .pink
        case .body:
            .green
        case .hair:
            .orange
        }
    }
}

struct AnyShape: Shape {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}
