import Foundation

/// Editor preferences only; never stored as engine state or restored to outputs.
@MainActor
struct WorkspacePreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func template(for persona: WorkspacePersona) -> WorkspaceTemplate {
        let available = WorkspaceTemplate.available(for: persona)
        if let name = defaults.string(forKey: key(persona)),
           let value = WorkspaceTemplate(rawValue: name), available.contains(value) { return value }
        return persona == .perform ? .perform : .mapping
    }

    func save(_ value: WorkspaceTemplate, for persona: WorkspacePersona) {
        defaults.set(value.rawValue, forKey: key(persona))
    }

    private func key(_ persona: WorkspacePersona) -> String { "photon.workspace.layout.\(persona.rawValue)" }
}
