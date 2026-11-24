import AppKit
import SwiftUI

/// Defaults keys for the flush sidebar's width and visibility.
enum WorkspaceFlushSidebarDefaults {
  static let widthKey = "Org2Workspace.flushSidebar.width.v1"
  static let hiddenKey = "Org2Workspace.flushSidebar.hidden.v1"
}

/// A sidebar column that runs flush to the window edges and meets the main
/// area at one draggable hairline, with no inset panel or rounded corners.
struct WorkspaceFlushSidebarSplit<Sidebar: View, Detail: View>: View {
  let containerWidth: CGFloat
  let isSidebarHidden: Bool
  @Binding var storedWidth: Double
  @ViewBuilder var sidebar: () -> Sidebar
  @ViewBuilder var detail: () -> Detail

  @State private var dragWidth: CGFloat?
  @State private var dragStartWidth: CGFloat?
  @State private var isHoveringDivider = false

  private static var dividerHitWidth: CGFloat { 9 }

  var body: some View {
    let width = dragWidth ?? WorkspaceSidebarLayout.flushWidth(
      stored: storedWidth > 0 ? CGFloat(storedWidth) : nil,
      containerWidth: containerWidth
    )
    HStack(spacing: 0) {
      if !isSidebarHidden {
        sidebar()
          .frame(width: width)
          .frame(maxHeight: .infinity)
          .transition(.move(edge: .leading))

        Rectangle()
          .fill(WorkspaceDesign.hairline)
          .frame(width: 1)
          .frame(maxHeight: .infinity)
          .overlay { dividerHandle(currentWidth: width) }
          .zIndex(1)
      }

      detail()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func dividerHandle(currentWidth: CGFloat) -> some View {
    Color.clear
      .frame(width: Self.dividerHitWidth)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onHover { hovering in
        guard hovering != isHoveringDivider else { return }
        isHoveringDivider = hovering
        if hovering {
          NSCursor.resizeLeftRight.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHoveringDivider {
          isHoveringDivider = false
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            let start = dragStartWidth ?? currentWidth
            dragStartWidth = start
            dragWidth = WorkspaceSidebarLayout.flushWidth(
              stored: start + value.translation.width,
              containerWidth: containerWidth
            )
          }
          .onEnded { _ in
            if let dragWidth {
              storedWidth = Double(dragWidth)
            }
            dragWidth = nil
            dragStartWidth = nil
          }
      )
      .accessibilityLabel("Resize Sidebar")
  }
}
