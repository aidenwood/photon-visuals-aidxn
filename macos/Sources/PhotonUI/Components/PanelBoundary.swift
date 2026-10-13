import SwiftUI

/// Local loading/recovery boundary. A retained value never swaps out its content tree.
struct PanelBoundary<Value: Sendable, Content: View, Skeleton: View>: View {
    let model: PanelModel<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content
    @ViewBuilder let skeleton: () -> Skeleton

    var body: some View {
        Group {
            if let value = model.value {
                content(value)
                    .overlay(alignment: .topTrailing) {
                        if model.phase.isLoading {
                            Text("Refreshing")
                                .font(.system(size: 10))
                                .padding(PhotonTheme.contentInset)
                                .background(PhotonTheme.raised, in: Rectangle())
                                .accessibilityLabel("\(model.name) refreshing")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let issue = model.phase.issue {
                            PanelFailureView(issue: issue, compact: true, retry: retry)
                        }
                    }
            } else if let issue = model.phase.issue {
                PanelFailureView(issue: issue, retry: retry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                skeleton().accessibilityLabel("\(model.name) loading")
            }
        }
    }
}
