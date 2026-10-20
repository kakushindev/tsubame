import SwiftUI

/// The workspace's bottom pane: a resizable, collapsible strip under the resource
/// table that holds the YAML editor and the log viewer.
///
/// Deliberately plain. The pane is a container for work, so its chrome is one
/// separator, one row of tabs, and a drag area — everything else is the tool
/// inside it. It uses the system bar material and separator so it reads as part of
/// the window rather than a panel drawn on top of it.
struct WorkspaceBottomPane<Content: View>: View {
    @Bindable var model: WorkspacePaneModel
    /// The height of the whole area the pane and the content share, so the pane can
    /// never be dragged past the point where the table disappears.
    let availableHeight: Double
    /// Raised when the user works in the pane, so ⌘W closes a pane tool rather
    /// than the resource tab behind it.
    var focused: () -> Void = {}
    @ViewBuilder let content: (WorkspacePaneModel.Tool) -> Content

    @State private var dragStartHeight: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var headerHeight = WorkspacePaneModel.headerHeight

    /// Leaves at least a few rows of the table visible whatever the window size.
    private var maximumHeight: Double {
        max(WorkspacePaneModel.minimumHeight, availableHeight - 180)
    }

    private var resolvedHeight: Double {
        model.isCollapsed
            ? headerHeight
            : min(max(model.height, WorkspacePaneModel.minimumHeight), maximumHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if !model.isCollapsed, let tool = model.selected {
                Divider()
                content(tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Any interaction inside a tool counts as working in the pane.
                    .onTapGesture(perform: focused)
            }
        }
        .frame(height: resolvedHeight)
        .background(.bar)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isCollapsed)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(model.tools) { tool in
                PaneTab(
                    tool: tool,
                    isSelected: tool.id == model.selection && !model.isCollapsed,
                    select: { model.select(tool.id); focused() },
                    close: { model.close(tool.id) }
                )
            }
            Spacer(minLength: 8)
            Button {
                model.isCollapsed.toggle()
            } label: {
                Image(systemName: model.isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.isCollapsed ? "Expand the pane" : "Collapse the pane")
            .accessibilityLabel(model.isCollapsed ? "Expand pane" : "Collapse pane")
        }
        .padding(.horizontal, 10)
        .frame(height: headerHeight)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        // The whole header is the drag target, which is both a larger area than a
        // hairline divider and the behaviour a split view already has.
        .gesture(resizeGesture)
        #if os(macOS)
        .onHover { inside in
            if inside, !model.isCollapsed { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        #endif
        .onTapGesture(count: 2) { model.isCollapsed.toggle() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane tools")
        // Resizing by pointer is unavailable to VoiceOver and to the keyboard, so
        // the same two steps exist as actions.
        .accessibilityAction(named: "Make pane taller") {
            model.height = min(model.height + 80, maximumHeight)
        }
        .accessibilityAction(named: "Make pane shorter") {
            model.height = max(model.height - 80, WorkspacePaneModel.minimumHeight)
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard !model.isCollapsed else { return }
                let start = dragStartHeight ?? model.height
                if dragStartHeight == nil { dragStartHeight = start }
                // Dragging up grows the pane, so the delta is inverted.
                model.height = min(max(start - value.translation.height,
                                       WorkspacePaneModel.minimumHeight), maximumHeight)
            }
            .onEnded { _ in dragStartHeight = nil }
    }
}

/// One tool's tab. Selected state carries weight and a fill rather than colour
/// alone, so it survives Increase Contrast and colour-blind vision.
private struct PaneTab: View {
    let tool: WorkspacePaneModel.Tool
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tool.kind.symbol)
                .font(.caption2)
            Text(tool.kind.title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
            Text(tool.subject)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            // Always present for touch and VoiceOver; hover only changes emphasis,
            // so the control never depends on a pointer.
            .opacity(isHovering || isSelected ? 1 : 0.55)
            .accessibilityLabel("Close \(tool.kind.title) for \(tool.subject)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
