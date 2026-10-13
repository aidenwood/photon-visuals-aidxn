import SwiftUI

struct WorkspaceHeader: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 16)).foregroundStyle(PhotonTheme.accent)
                Text("PHOTON").font(.system(size: 11, weight: .semibold)).tracking(1.6)
            }
            .frame(width: 132, alignment: .leading)

            HStack(spacing: 1) {
                ForEach(WorkspacePersona.allCases) { persona in
                    Button { model.switchPersona(persona) } label: {
                        Label(persona.rawValue, systemImage: persona.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).frame(height: PhotonTheme.controlHeight)
                            .background(
                                model.persona == persona ? PhotonTheme.accent.opacity(0.16) : .clear,
                                in: Rectangle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.performanceLocked)
                    .foregroundStyle(model.persona == persona ? PhotonTheme.foreground : PhotonTheme.muted)
                    .accessibilityAddTraits(model.persona == persona ? .isSelected : [])
                }
            }
            Spacer()
            if let issue = model.integrationIssue {
                StatusPill(title: issue.title, color: PhotonTheme.warning).help(issue.message)
            }
            StatusPill(title: "UI preview", color: PhotonTheme.warning)
            Menu {
                ForEach(WorkspaceTemplate.available(for: model.persona)) { template in
                    Button { model.switchTemplate(template) } label: {
                        if template == model.template { Label(template.rawValue, systemImage: "checkmark") }
                        else { Text(template.rawValue) }
                    }
                }
            } label: {
                Label(model.template.rawValue, systemImage: "rectangle.split.3x1")
                    .font(.system(size: 11)).foregroundStyle(PhotonTheme.muted)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.performanceLocked)
            #if DEBUG
            DiagnosticsMenu(model: model)
            #endif
            Button { model.isCommandPalettePresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Commands")
                    Text("⌘ K").foregroundStyle(PhotonTheme.faint)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
                .background(PhotonTheme.raised, in: Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(PhotonTheme.muted)
        }
        .padding(.horizontal, PhotonTheme.contentInset)
        .frame(height: 30)
        .background(PhotonTheme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(PhotonTheme.border).frame(height: 1) }
    }
}
