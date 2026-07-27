import SwiftUI

/// MANAGE always reserves the same left-hand width for its selectable list. Feature
/// views still own their empty states and detail lifecycle; this owns only the shared
/// split geometry.
struct ManageListDetail<ListContent: View, DetailContent: View>: View {
    @Environment(\.theme) private var theme
    let listContent: ListContent
    let detailContent: DetailContent

    init(@ViewBuilder list: () -> ListContent,
         @ViewBuilder detail: () -> DetailContent) {
        listContent = list()
        detailContent = detail()
    }

    var body: some View {
        HStack(spacing: 0) {
            listContent.frame(width: 224)
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            detailContent
        }
    }
}

/// The scrolling contract shared by every MANAGE list: selection changes reveal the
/// selected stable identity without making the component know any feature's model.
struct ManageListScrollView<ScrollID: Hashable, Content: View>: View {
    @Environment(\.motion) private var motion
    let selection: Int
    let scrollTarget: ScrollID?
    let content: Content

    init(selection: Int, scrollTarget: ScrollID?,
         @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.scrollTarget = scrollTarget
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .onChange(of: selection) { _ in
                    guard let scrollTarget else { return }
                    withAnimation(motion.selectionScroll) {
                        proxy.scrollTo(scrollTarget, anchor: .center)
                    }
                }
        }
    }
}

/// Selection paint, hit target, and native button behaviour for MANAGE's six visual
/// row shapes. Icons, names, badges, and trailers remain model-specific content.
struct ManageListRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let selected: Bool
    let onSelect: () -> Void
    let content: Content

    init(selected: Bool, onSelect: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.onSelect = onSelect
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(selected ? theme.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .contentShape(Rectangle())
            .live(action: onSelect)
    }
}

/// The shared action treatment used by Prompt, Suggested, and Snippet details.
struct ManageActionButton: View {
    enum Style {
        case standard
        case prominent
    }

    @Environment(\.theme) private var theme
    let title: String
    let symbol: String
    let style: Style
    let action: () -> Void

    init(_ title: String, _ symbol: String, style: Style,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.action = action
    }

    private var prominent: Bool {
        switch style {
        case .standard: return false
        case .prominent: return true
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(prominent ? theme.onAccent : theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(prominent ? theme.accent : theme.surface,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(prominent ? .clear : theme.rule.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The uppercase metadata treatment shared exactly by Prompt and Snippet details.
///
/// Shell metadata (`metaRow`, Views.swift:1711) keeps a distinct title-case, 9.5pt
/// treatment, and that is retained pending a visual decision rather than a decision
/// already taken: repo history shows it as two-of-three drift — two of the three detail
/// panes uppercase at 9pt and the third does not — so it was left alone here because
/// changing it moves visible pixels, not because it is the intended design. Fold it in
/// (or rule it out) when someone actually looks at the three panes side by side.
struct ManageMetaRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
    }
}
