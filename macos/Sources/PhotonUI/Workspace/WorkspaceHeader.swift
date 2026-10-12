import SwiftUI

struct WorkspaceHeader: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 22)).foregroundStyle(PhotonTheme.accent)
                Text("PHOTON").font(.system(size: 13, weight: .semibold)).tracking(2.6)
            }
            .frame(width: 174, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(WorkspacePersona.allCases) { persona in
                    Button { model.switchPersona(persona) } label: {
                        Label(persona.rawValue, systemImage: persona.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(
                                model.persona == persona ? PhotonTheme.accent.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
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
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                    Text("Commands")
                    Text("⌘ K").foregroundStyle(PhotonTheme.faint)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(PhotonTheme.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).foregroundStyle(PhotonTheme.muted)
        }
        .padding(.horizontal, 20)
        .frame(height: 42)
        .background(PhotonTheme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(PhotonTheme.border).frame(height: 1) }
    }
}
