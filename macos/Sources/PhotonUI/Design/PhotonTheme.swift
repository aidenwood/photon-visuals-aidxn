import SwiftUI

// Local Velocity 9 editor palette; native system text matches its desktop typography.
enum PhotonTheme {
    static let background = Color(rgb: 0x0C0C10)
    static let panel = Color(rgb: 0x141419)
    static let raised = Color(rgb: 0x1C1C24)
    static let border = Color(rgb: 0x26262F)
    static let accent = Color(rgb: 0x8B5CF6)
    static let foreground = Color(rgb: 0xE7E7EE)
    static let muted = Color(rgb: 0x9A9AAB)
    static let faint = Color(rgb: 0x6B6B7B)
    static let warning = Color(rgb: 0xFBBF24)
    static let radius: CGFloat = 6
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
    }
}
