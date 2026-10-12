import Foundation

@main
enum RunChecks {
    @MainActor static func main() async {
        var failures = 0
        for check in UIRecoveryCase.allCases {
            do {
                try await check.run()
                print("PASS \(check.rawValue)")
            } catch {
                failures += 1
                print("FAIL \(check.rawValue): \(error)")
            }
        }
        print("\(UIRecoveryCase.allCases.count - failures)/\(UIRecoveryCase.allCases.count) frontend checks passed.")
        if failures > 0 { exit(1) }
    }
}
