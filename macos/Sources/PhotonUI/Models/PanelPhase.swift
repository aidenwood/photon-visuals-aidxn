import Foundation

public struct PanelIssue: Error, Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public enum PanelPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(PanelIssue)

    public var isLoading: Bool { self == .loading }

    public var issue: PanelIssue? {
        guard case let .failed(issue) = self else { return nil }
        return issue
    }
}
