import SwiftUI

/// One compact disclosure row, shared by all inspector scopes.
struct InspectorSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: () -> Content
    @State private var expanded: Bool

    init(_ title: String, detail: String? = nil, expanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.detail = detail; self.content = content
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).frame(width: 12)
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(PhotonTheme.muted).lineLimit(1) }
                }
                .padding(.horizontal, 4).frame(height: 24)
                .background(PhotonTheme.raised).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 2, content: content)
                    .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
