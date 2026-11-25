# Lenver iOS

The native SwiftUI client for Lenver, a personal finance project focused on recording transactions and understanding account history.

The published source includes email/password authentication, Sign in with Apple, explicit account linking, and idempotent transaction creation. The I1–I5 account journey is a Debug opt-in. It covers a BRL opening balance, account history, dated balance checks, retroactive expense recovery, and audited corrections.

## Development

Open `Fintech.xcodeproj` in Xcode and select the `Fintech` scheme. Review the [engineering guide](AGENTS.md) before running checks. Use a fresh, disposable simulator for UI tests and keep live API smoke tests disabled for routine verification.

## Related repositories

- [Lenver Backend](https://github.com/lenver-hq/lenver-backend)
- [Lenver Docs](https://github.com/lenver-hq/lenver-docs)
