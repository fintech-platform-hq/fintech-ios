# Lenver iOS Engineering Guide

## Project purpose

Lenver is a native iOS client for personal finance. The app must treat the backend as the source of truth for financial writes and must make retry behavior explicit so that a transient network failure cannot create duplicate transactions.

## Detected platform and toolchain

- Xcode project: `Fintech.xcodeproj`
- Application target: `Fintech`
- Unit-test target: `FintechTests`
- UI-test target: `FintechUITests`
- Supported platform: iOS and iPadOS, deployment target 26.5
- Swift language mode: Swift 5 (`SWIFT_VERSION = 5.0`)
- Detected toolchain: Xcode 26.6 with Apple Swift 6.3.3
- Concurrency settings: approachable concurrency is enabled and the application target uses `MainActor` as its default actor isolation

Treat the project settings as authoritative if these values change.

## Skill Selection

- Before non-trivial tasks, inspect `docs/skills/README.md` and the relevant available skill instructions.
- Choose only skills relevant to the requested work, preferring fewer skills over more.
- Before planning or implementing, report the selected skills and why each one applies.
- Do not use UI or design skills for backend or networking work unless the task also includes a relevant UI or design concern.
- Do not use security, performance, or concurrency skills unless the task touches those concerns.

## Architectural boundaries

- Keep HTTP transport in `APIClient` and feature requests in their respective services.
- Use Foundation's `URLSession`, `Codable`, and Swift `async`/`await`. Do not add third-party dependencies or build a generic networking framework.
- SwiftUI views render state and initiate injected actions. They must never construct requests or perform live networking directly in a view body.
- Keep transport concerns, transaction endpoint behavior, and UI state in separate types.
- The backend is the source of truth for confirmed financial operations. Do not infer database readiness from `GET /health`; it is currently a process-level liveness response only.
- Model authentication against the enforced backend contract.

## Dependency injection

- Inject the transaction service into future feature or presentation code through a narrow transaction-specific boundary.
- Inject a configured `URLSession` into the concrete API client so tests can use a controlled `URLProtocol` without live traffic.
- Pass dependencies from the composition root. Avoid service locators, hidden singletons, and networking objects created inside views.
- Add protocols only at a real substitution boundary; do not mirror every concrete type with a protocol speculatively.

## Naming and modeling

- Use UpperCamelCase for types and lowerCamelCase for properties, methods, and local values.
- Give source files the name of their primary type.
- Use domain names such as `TransactionRequest`, `TransactionResponse`, and `TransactionService`; avoid vague names such as `Manager`, `Helper`, or `Utility`.
- Keep wire-format differences explicit with `CodingKeys`. Do not leak backend snake_case names into Swift property names.
- Represent monetary amounts as integer minor units. Never use floating-point values for transaction amounts.
- Model transaction type as a closed Swift enum matching the approved wire values.

## Concurrency requirements

- Use structured concurrency and cancellation-aware `async throws` APIs.
- UI-observable state belongs on `MainActor`; network and decoding boundaries must not depend on SwiftUI or assume main-actor execution.
- Values that cross concurrency domains must conform to `Sendable`. Request, response, error payload, and service dependency types should be value-semantic and `Sendable` where applicable.
- Do not add `@unchecked Sendable` merely to silence diagnostics. Document and test any case that genuinely requires it.
- Avoid detached tasks unless their lifetime and cancellation behavior are explicitly justified.

## Idempotency

- Generate one idempotency key per logical transaction operation.
- The idempotency key and the complete request payload, including `clientMutationId`, must remain stable across every retry of that same logical operation.
- A changed payload is a new logical operation and must use a new idempotency key.
- Do not regenerate a key inside a retry loop or after an ambiguous transport failure.

## Testing and verification

- Unit tests must use controlled URL loading and must never depend on the production API.
- Production API integration or smoke tests must be opt-in, separately invoked, and guarded by an explicit environment flag. They must never run from the default test plan, `scripts/verify.sh`, or routine CI.
- Before handing off a change, build and run the applicable tests using a disposable simulator. The existing `scripts/verify.sh` automatically selects and erases a simulator. Use Xcode or `xcodebuild` with an explicit disposable destination to preserve existing data. Then run:

```sh
git diff --check
git status --short
```

- Report build, test, and live-integration evidence separately. Never claim a live production check unless it was explicitly enabled and executed.

## Repository hygiene and scope

- Never commit generated Xcode user data, including `xcuserdata/`, `*.xcuserstate`, or user-specific workspace state.
- Preserve generated project files only when Xcode requires a deliberate shared project change.
- Keep changes proportional to the approved specification. Avoid speculative abstractions, unused extension points, unrelated UI, or premature offline-sync infrastructure.
