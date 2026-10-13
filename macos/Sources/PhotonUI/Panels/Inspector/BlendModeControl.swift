import SwiftUI

/// The layer blend menu.
///
/// Its contents are the renderer's published modes verbatim — see
/// ``BlendModeOption``. It cannot offer a mode the compositor does not have,
/// and it cannot miss one the compositor gained.
struct BlendModeControl: View {
    let options: [BlendModeOption]
    let value: Int32
    let select: (Int32) -> Void
    /// Shown instead of the menu when there is no layer to apply a blend to.
    /// A menu that accepts a pick and has nowhere to put it is the control
    /// this app exists not to ship.
    var unavailable: String? = nil

    var body: some View {
        ParameterRow(label: "Blend") {
            if let unavailable {
                Text(unavailable)
                    .font(.system(size: 11)).foregroundStyle(PhotonTheme.muted)
                    .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
                    .frame(width: 120, alignment: .leading)
                    .accessibilityLabel("Blend mode unavailable")
                    .accessibilityValue(unavailable)
            } else {
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            ForEach(options) { option in
                Button { select(option.id) } label: {
                    if option.id == value { Label(option.name, systemImage: "checkmark") }
                    else { Text(option.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.name(for: value)).font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
            .background(PhotonTheme.raised, in: Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 120)
        // One published mode means the renderer offered nothing to switch to.
        .disabled(options.count < 2)
        .accessibilityLabel("Blend mode").accessibilityValue(options.name(for: value))
    }
}

/// The grid strip's blend picker: same catalogue, same action, no label column.
struct CompactBlendMenu: View {
    let options: [BlendModeOption]
    let value: Int32
    let title: String
    let select: (Int32) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button { select(option.id) } label: {
                    if option.id == value { Label(option.name, systemImage: "checkmark") }
                    else { Text(option.name) }
                }
            }
        } label: {
            Text(options.name(for: value))
                .font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(options.count < 2)
        .help("\(title) blend mode")
        .accessibilityLabel("\(title) blend mode")
        .accessibilityValue(options.name(for: value))
    }
}
