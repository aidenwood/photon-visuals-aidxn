import Testing

@Suite("Independent UI recovery and adapter validation")
struct RecoveryTests {
    @Test(arguments: UIRecoveryCase.allCases)
    @MainActor func recovery(_ check: UIRecoveryCase) async throws {
        try await check.run()
    }
}
