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
                                .padding(6)
                                .background(PhotonTheme.raised, in: Capsule())
                                .padding(8)
                                .accessibilityLabel("\(model.name) refreshing")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let issue = model.phase.issue {
                            PanelFailureView(issue: issue, compact: true, retry: retry)
                                .padding(8)
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
