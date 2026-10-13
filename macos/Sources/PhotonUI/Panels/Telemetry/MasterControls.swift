import SwiftUI

struct MasterControls: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.performanceLocked.toggle() } label: {
                Label(model.performanceLocked ? "Locked" : "Lock", systemImage: model.performanceLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.performanceLocked ? PhotonTheme.warning : PhotonTheme.muted)
            Rectangle().fill(PhotonTheme.border).frame(width: 1, height: 16)
            Text("Master").font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
            LiveFader(value: model.master.value?.opacity ?? 1, label: "Master opacity", change: model.setMasterOpacity)
                .frame(width: 145)
            .disabled(model.master.value == nil)
            Button { model.toggleBlackout() } label: {
                Text("BLACKOUT").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
                    .background(
                        model.isBlackedOut ? Color.red.opacity(0.35) : PhotonTheme.raised,
                        in: Rectangle()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isBlackedOut ? .red : PhotonTheme.muted)
            .accessibilityLabel(model.isBlackedOut ? "Release blackout" : "Blackout")
            .help("Toggle master blackout")
            if model.master.phase.issue != nil {
                Button("Retry") { model.reloadMaster() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(PhotonTheme.warning)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
