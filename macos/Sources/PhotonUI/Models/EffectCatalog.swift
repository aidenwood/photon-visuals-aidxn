import Foundation

/// Planning metadata only. Execution/capability descriptors come from the engine.
struct EffectCatalogItem: Identifiable {
    let name: String
    let category: String
    var id: String { name }
}

enum EffectCatalog {
    static let planned: [EffectCatalogItem] = [
        ("Colour", ["Add Subtract", "Colorize", "Invert RGB", "Vignette"]),
        ("Transform", ["Flip", "Mirror", "Keystone", "Tile", "Slide", "Kaleidoscope", "Suckr", "Wave Warp", "Ripples", "Tunnel"]),
        ("Filter", ["RadialBlur", "LoRez", "Shift RGB", "Blow", "Twitch"]),
        ("Geometry", ["Linear Cloner", "Radial Cloner", "Cube Tiles", "Fragment", "VideoWall", "Stripper", "Iterate"]),
        ("Time & noise", ["Freeze", "Particle System", "Goo", "Static", "Shift Glitch", "Distortion"]),
    ].flatMap { category, names in names.map { EffectCatalogItem(name: $0, category: category) } }
}
