public enum InspectorScope: String, CaseIterable, Sendable {
    case composition = "Composition", layer = "Layer", group = "Group", clip = "Clip", column = "Column"
}

enum BrowserScope: String, CaseIterable {
    case files = "Files", effects = "Effects", sources = "Sources", compositions = "Compositions"
}
