import Foundation

nonisolated enum DemoConfiguration {
    /// A placeholder used only by the development/demo composition root.
    /// It does not imply account ownership and must be replaced with an
    /// explicitly provisioned disposable account before a production demo.
    static let disposableTransactionAccountID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
}
