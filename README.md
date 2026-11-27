# Lenver iOS

The native SwiftUI client for Lenver, a personal finance project focused on recording transactions and understanding account history.

The published source includes email/password authentication, Sign in with Apple, explicit account linking, and idempotent transaction creation. The I1–I5 account journey is a Debug opt-in. It covers a BRL opening balance, account history, dated balance checks, retroactive expense recovery, and audited corrections.

## Development

Open `Lenver.xcodeproj` in Xcode and select the `Lenver` scheme. Review the [engineering guide](AGENTS.md) before running checks. Use a fresh, disposable simulator for UI tests and keep live API smoke tests disabled for routine verification.

| Build configuration | Bundle ID | API host |
| --- | --- | --- |
| `Debug` | `com.ferrari.lenver` | Explicit simulator environment selector |
| `Release` | `com.ferrari.lenver` | `fintech-api-87yw.onrender.com` |
| `StagingRelease` | `com.ferrari.lenver.staging` | Explicit HTTPS `LENVER_STAGING_API_BASE_URL` build setting |

Both app IDs use automatic signing and the Sign in with Apple capability. They
use their own default Keychain groups. The first launch of each new app ID
requires a fresh login. To test Apple staging on a device, select
`StagingRelease` in the scheme action. The Debug `-staging` override remains
available for simulator tests and disables Apple authorization when the app
Bundle ID differs from the selected environment. The shared scheme defaults
to the loopback API on port 8080 for Debug runs in Simulator. Set the port in
your local scheme when needed. Enable `LENVER_IDENTITY_UI_TEST_CREDENTIALS=1`
only for an explicit synthetic loopback test.

iOS selects English (US copy and formatting) or Brazilian Portuguese through
system language settings. English is the development language and fallback.
Amounts always represent BRL, in integer minor units on the wire.

## Related repositories

- [Lenver Backend](https://github.com/lenver-hq/lenver-backend)
- [Lenver Docs](https://github.com/lenver-hq/lenver-docs)
