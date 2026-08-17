# Fintech Project Context Handover

Updated: 2026-08-17

This file is a safe starting point for a new Codex/ChatGPT account. It captures
the project context available at handover time; source code and project files are
the authority whenever this document disagrees with them. Do not add credentials,
real account IDs, or production payloads to this document.

## Repositories and source of truth

The local project family comprises:

- iOS client: `/Users/ferrari/Xcode/fintech-ios` (this repository)
- NestJS/PostgreSQL API: `/Users/ferrari/Xcode/fintech-api`
- shared API/product documentation: `/Users/ferrari/Xcode/fintech-docs`

For the implemented transaction contract, read the current backend controller,
DTO, service, schema/migrations, and `openapi.yaml` before changing either client
or documentation. Do not treat older prose docs as more authoritative than code.
The current iOS app deliberately has no authentication because the backend does
not yet enforce an approved authentication contract.

## What is implemented

The iOS app contains a Create Transaction MVP:

```text
FintechApp composition root
  -> CreateTransactionViewModel (@MainActor, @Observable)
    -> TransactionCreating
      -> TransactionService
        -> APIClient (injected URLSession)
```

- `Fintech/FintechApp.swift` constructs `APIClient`, `TransactionService`, and
  the injected view model. Views do not construct requests or perform networking.
- `Fintech/Transactions/` models the request/response, service boundary, and
  closed `TransactionType` enum.
- `Fintech/Transactions/CreateTransaction/` implements the native SwiftUI Form,
  money input, description editor, state machine, and read-only success summary.
- `FintechTests/` uses a controlled `URLProtocol` for all routine networking
  tests. `FintechUITests/` covers the app flow and accessibility identifiers.

## Transaction contract

The public transaction types are exactly `expense` and `income`. Legacy `debit`
and `credit` are not valid new public payload values.

`POST /transactions` expects a JSON body with camelCase fields:

```text
accountId, categoryId?, type, amountMinor, currency, description?,
occurredAt, clientMutationId
```

Use `Content-Type: application/json` and a UUID `Idempotency-Key` header. Money
is an integer number of minor units; never use `Double` or `Float`. The response
is decoded as camelCase and includes `id`, account/category data, type, amount,
currency, description, `occurredAt`, and `createdAt`.

The current client base URL is defined in `APIClient.productionBaseURL`. Treat it
as endpoint configuration, not proof that a live deployment or database is
healthy. `GET /health` is process liveness only.

## Critical financial-write invariant: idempotency

One logical operation owns one complete request and one idempotency key.

- Generate the UUID idempotency key and `clientMutationId` once.
- Reuse both with the unchanged request after an ambiguous failure.
- A changed form is a new logical operation: create a new key and mutation ID.
- Do not add automatic retries or regenerate keys inside `APIClient` or
  `TransactionService`.
- Same key and payload should replay successfully (`201`); same key with a
  changed payload maps to `409`.

`CreateTransactionViewModel` retains its `PendingOperation` for a safe manual
retry and clears it after a meaningful form edit. It also ignores concurrent
submissions while busy.

## UI and accessibility decisions

- Expense is displayed with `-`; income is displayed with `+`. The serialized
  `amountMinor` remains positive in both cases.
- The bottom action uses `safeAreaInset`, shows loading inside the button, and
  becomes `Create Another` after success.
- Description is optional, trimmed on submit, limited to 255 characters, and
  displayed in a bounded UIKit-backed editor so repeated newlines cannot grow the
  enclosing Form row.
- The success screen renders a captured submitted snapshot, not a disabled form.
- Important identifiers include `createTransaction.amount`,
  `createTransaction.type`, `createTransaction.descriptionSurface`,
  `createTransaction.status`, and `createTransaction.submit`.
- For the signed-amount UI test, wait on the actual value of a freshly queried
  `createTransaction.amount` with an XCTest predicate (for example,
  `+R$ 15,02`), not on the segmented control selection and not with a fixed sleep.

## Toolchain and boundaries

- Xcode project/scheme: `Fintech.xcodeproj` / `Fintech`
- Test targets: `FintechTests`, `FintechUITests`
- iOS/iPadOS deployment target: 26.5
- Swift language mode: 5.0; approachable concurrency is enabled and app default
  actor isolation is `MainActor`.
- Keep request/response/error and dependency-boundary values `Sendable`.
- Use structured concurrency; avoid detached tasks and `@unchecked Sendable`.
- Add no third-party dependencies, service locator, generic networking framework,
  offline queue, or authentication layer without an approved contract.

## Verification and live-test safety

Before handing off source changes, run:

```sh
./scripts/verify.sh
git diff --check
git status --short
```

Report simulator build/test evidence separately from live API evidence.
`scripts/verify.sh` resets the selected simulator and runs the scheme's build and
tests. A simulator service/destination/debugger failure is an environment failure
unless a feature assertion fails.

The only production smoke test is intentionally opt-in and mutates production:
`ProductionTransactionSmokeTests` requires both `RUN_LIVE_API_TESTS=1` and
`LIVE_API_ACCOUNT_ID` containing a disposable account UUID. Never run it by
default, from routine CI, or without explicit approval for that execution.

## Current repository state at handover

- Branch: `main`
- Working tree: clean when this handover was created
- Recent product commit history includes `feat(transactions): finalize create
  transaction flow`, followed by UI/sign presentation refinements and Spec Kit
  documentation setup.

The app composition root still uses a documented demo-only account UUID. It is
not evidence of ownership or a production-ready account; a real demonstration
needs a provisioned backend account.

## Known cross-repository context and risks

- The API has a historical idempotency compatibility shim for hashes created
  before the `debit`/`credit` to `expense`/`income` rename. It must not cause new
  legacy payloads to be accepted.
- The API is currently unauthenticated. Users/accounts/categories/devices,
  Redis, offline sync, and a full financial-domain model are planned rather than
  implemented.
- The API's first-write concurrency behavior uses transaction-level protection;
  future work should retain explicit concurrency coverage rather than assuming
  ordinary `FOR UPDATE` locks an absent idempotency row.
- Documentation has historically drifted from the backend. Validate proposed
  doc changes against the live source repositories and distinguish implemented
  behavior from target architecture.

## How the new account should begin work

1. Open this repository and read `AGENTS.md` first.
2. Read `docs/skills/README.md`, then select only the skills relevant to the
   actual request.
3. Inspect `git status --short` before editing; preserve unrelated user changes.
4. For changes touching the transaction API, inspect the companion API and docs
   repositories before deciding on a contract change.
5. Keep live production checks opt-in and explicitly approved.

## Prompt to paste into the new Codex account

```text
I am continuing the Fintech project. The iOS repository is at
/Users/ferrari/Xcode/fintech-ios. Start by reading AGENTS.md and
docs/PROJECT_CONTEXT_HANDOVER.md, then inspect git status without changing
anything. Treat the iOS app, companion API repository at
/Users/ferrari/Xcode/fintech-api, and docs repository at
/Users/ferrari/Xcode/fintech-docs as a related system. Preserve the transaction
contract: camelCase payloads, expense/income, positive integer amountMinor, a
UUID Idempotency-Key, and stable request/key reuse for retries. Do not run live
production tests or change backend/docs unless I explicitly ask. Report the
skills selected for any non-trivial work and verify source changes with
./scripts/verify.sh, git diff --check, and git status --short.
```
