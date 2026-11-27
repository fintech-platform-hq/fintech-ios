import Foundation

nonisolated enum DemoConfiguration {
    /// A demo-only account identifier used by the development composition root.
    /// Its presence does not imply that the current user owns this account.
    static let disposableTransactionAccountID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!
}
