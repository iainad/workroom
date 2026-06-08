import AppKit
import SwiftUI

/// A setup log docked under a workroom's terminal: the shared content plus a draggable
/// top edge to resize it. It stays up after the run completes (the user closes it) so
/// the output remains available for review.
struct ScriptLogPanel: View {
  @ObservedObject var session: ScriptLogSession
  var onClose: () -> Void

  @State private var height: CGFloat = 200
  @State private var dragStartHeight: CGFloat?

  private static let minHeight: CGFloat = 100
  private static let maxHeight: CGFloat = 600

  var body: some View {
    VStack(spacing: 0) {
      resizeHandle
      ScriptLogContent(session: session, onClose: onClose)
    }
    .frame(height: height)
  }

  /// A thin grabber along the top edge to resize the panel.
  private var resizeHandle: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))  // invisible but hit-testable
      .frame(height: 5)
      .contentShape(Rectangle())
      .gesture(
        DragGesture()
          .onChanged { value in
            let start = dragStartHeight ?? height
            if dragStartHeight == nil { dragStartHeight = start }
            height = min(Self.maxHeight, max(Self.minHeight, start - value.translation.height))
          }
          .onEnded { _ in dragStartHeight = nil }
      )
      .onHover { inside in
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
  }
}
