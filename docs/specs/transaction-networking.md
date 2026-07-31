# Transaction Networking Specification

Status: proposed for human approval before production implementation

Last source inspection: 2026-07-31

## Feature objective

Add the first small, testable iOS networking boundary for creating a transaction with safe retry semantics. The feature will encode the implemented backend request exactly, send a stable idempotency key, decode the implemented response, and map transport and HTTP failures into a focused `APIError`.

This document records conflicts between the backend implementation, the backend README, and `fintech-docs`. Production Swift implementation must not begin until the contract decisions in **Human approval required** are resolved.

## Sources inspected

- `../fintech-api/src/main.ts`
- `../fintech-api/src/modules/transactions/dto/create-transaction.dto.ts`
- `../fintech-api/src/modules/transactions/transactions.controller.ts`
- `../fintech-api/src/modules/transactions/transactions.service.ts`
- `../fintech-api/src/common/logging/request-logging.middleware.ts`
- `../fintech-api/db.sql`
- `../fintech-api/README.md`
- `../fintech-docs/api/openapi/transactions.yaml`
- `../fintech-docs/api/transactions.md`
- Related idempotency, money, backend-source-of-truth, and schema ADRs in `../fintech-docs`

No production request was made during discovery. The verified behavior below is source-verified against the accessible repositories, not live-deployment-verified.

## Verified backend contract

### Endpoint and headers

- Method and path: `POST /transactions`
- Production base URL supplied for the project: `https://fintech-api-87yw.onrender.com`
- Required request headers:
  - `Content-Type: application/json`
  - `Idempotency-Key: <UUID>`
- Authentication: not implemented or enforced by the current backend.
- Successful response status: `201 Created` for both a new transaction and a same-key/same-payload replay.
- Relevant error statuses implemented: `400 Bad Request`, `409 Conflict`, and `500 Internal Server Error`.
- The middleware returns an `X-Request-Id` response header, but it always generates a new UUID and does not preserve a client-supplied request ID.
- `GET /health` returns `{"status":"ok"}` and is liveness only; it does not establish database readiness.

The service checks only that `Idempotency-Key` is nonempty, but the PostgreSQL column is `uuid`. Therefore a valid UUID is the effective successful-request contract.

### Request JSON

The current backend DTO accepts only the following camelCase keys because global validation uses `whitelist: true` and `forbidNonWhitelisted: true`:

| JSON field | Required | Implemented validation | Proposed Swift property |
|---|---:|---|---|
| `accountId` | yes | UUID string | `accountId: UUID` |
| `categoryId` | no | UUID string when present; `null` is accepted | `categoryId: UUID?` |
| `type` | yes | `"debit"` or `"credit"` | `type: TransactionType` |
| `amountMinor` | yes | integer in the DTO; database requires greater than zero | `amountMinor: Int` |
| `currency` | yes | exactly three uppercase ASCII letters | `currency: String` |
| `description` | no | string when present; `null` is accepted; no implemented length limit | `description: String?` |
| `occurredAt` | yes | DTO checks only that it is a string; PostgreSQL must parse it as `timestamptz` | `occurredAt: Date` with an approved RFC 3339 encoding strategy |
| `clientMutationId` | yes | UUID string; included in the idempotency request hash but not persisted in the transaction row | `clientMutationId: UUID` |

Example matching the current implementation:

```json
{
  "accountId": "00000000-0000-0000-0000-000000000001",
  "categoryId": null,
  "type": "credit",
  "amountMinor": 15000,
  "currency": "BRL",
  "description": null,
  "occurredAt": "2026-07-30T18:00:00.000Z",
  "clientMutationId": "00000000-0000-0000-0000-000000000002"
}
```

Omitting an optional field and sending it as `null` produce the same server-side idempotency hash because the service normalizes missing `categoryId` and `description` values to `null`.

### Response JSON

The controller returns the PostgreSQL row directly. The implemented wire keys are snake_case and both nullable fields are returned:

```json
{
  "id": "6aef7ec3-58fb-4ac7-8ff2-920e90ce0b4c",
  "account_id": "00000000-0000-0000-0000-000000000001",
  "category_id": null,
  "type": "credit",
  "amount_minor": 15000,
  "currency": "BRL",
  "description": null,
  "occurred_at": "2026-07-30T18:00:00.000Z",
  "created_at": "2026-07-30T18:00:01.421Z"
}
```

| JSON field | Wire type | Proposed Swift property |
|---|---|---|
| `id` | UUID string | `id: UUID` |
| `account_id` | UUID string | `accountId: UUID` |
| `category_id` | UUID string or `null` | `categoryId: UUID?` |
| `type` | `"debit"` or `"credit"` | `type: TransactionType` |
| `amount_minor` | integer | `amountMinor: Int` |
| `currency` | string | `currency: String` |
| `description` | string or `null` | `description: String?` |
| `occurred_at` | ISO-formatted timestamp string after JSON serialization | `occurredAt: Date` |
| `created_at` | ISO-formatted timestamp string after JSON serialization | `createdAt: Date` |

The proposed model uses explicit `CodingKeys`; global snake-case conversion is unnecessary for the camelCase request and could hide contract mistakes.

### Current error format

No custom exception filter changes the response. The current NestJS error envelope is:

```json
{
  "statusCode": 400,
  "message": "Idempotency key required",
  "error": "Bad Request"
}
```

DTO validation uses the same envelope with `message` as an array of strings:

```json
{
  "statusCode": 400,
  "message": [
    "clientMutationId must be a UUID"
  ],
  "error": "Bad Request"
}
```

Different-payload idempotency reuse returns:

```json
{
  "statusCode": 409,
  "message": "Idempotency key was already used with a different request",
  "error": "Conflict"
}
```

Some database-derived `400` and `409` exceptions use Nest's generic message instead. Unexpected persistence failures fall through as `500 Internal Server Error`.

## Contract inconsistencies

| Area | Backend implementation | OpenAPI / docs / README conflict |
|---|---|---|
| Production server | Supplied deployment is `fintech-api-87yw.onrender.com` | OpenAPI uses `https://api.fintech-platform.com` |
| Authentication | No authentication or authorization guard | OpenAPI requires bearer JWT; transaction docs require `Authorization` and describe `403` |
| Request example | `clientMutationId` is required by the DTO | Backend README examples omit it and therefore do not satisfy current validation |
| Idempotency key | Database requires UUID | Backend README uses `transaction-example-001`, which is not a UUID |
| Response casing | Direct database row uses snake_case | OpenAPI and transaction docs specify camelCase |
| Response fields | Includes `category_id` and `description`, including `null` | OpenAPI omits `categoryId` entirely and does not require `description`; examples omit category |
| Error body | Nest envelope uses `statusCode`, `message`, and `error`; validation messages may be an array | OpenAPI/docs specify `{ "code", "message" }` |
| Amount validation | DTO accepts any integer; database enforces `amount_minor > 0` | OpenAPI declares `minimum: 1` and docs describe request validation |
| Description validation | Any string length is accepted | OpenAPI declares `maxLength: 255` |
| Timestamp validation | DTO accepts any string; PostgreSQL performs timestamp parsing | OpenAPI declares `date-time`; docs require valid UTC ISO 8601 |
| Client mutation semantics | Required and included only in request hashing; not stored or checked independently | Docs claim uniqueness per user |
| Request correlation | Server always replaces an incoming value with a generated `X-Request-Id` | Backend README says clients may provide their own identifier |
| Health semantics | Process-level liveness only | Any interpretation as database readiness would be incorrect; backend README explicitly notes this limitation |

The domain definition also mentions decimal money in one invariant and data-model section, while the accepted money ADR, current schema, DTO, and OpenAPI use integer minor units. The iOS feature must use integer minor units.

## Request model

`TransactionRequest` is a value type conforming to `Encodable`, `Equatable`, and `Sendable`. It owns the exact eight fields listed above. `TransactionType` is a `String`, `Codable`, `Sendable` enum with only `debit` and `credit`.

The initializer should reject locally knowable invariants that are already part of the intended contract:

- `amountMinor > 0`
- currency matches `^[A-Z]{3}$`

Date encoding must be centralized and covered by an exact JSON test. The approved strategy must preserve a stable payload across retries; the request must be encoded once or encoded deterministically from unchanged values.

## Response model

`TransactionResponse` is a value type conforming to `Decodable`, `Equatable`, `Identifiable`, and `Sendable`. It maps the nine implemented snake_case fields through explicit `CodingKeys`.

Use one shared, explicitly configured date-decoding strategy for `occurred_at` and `created_at`, including fractional-second and non-fractional RFC 3339 fixtures if both formats are approved. Do not make required backend fields optional merely to hide decoding failures.

## Error mapping

`APIError` should remain focused and `Sendable`:

| Condition | Proposed mapping |
|---|---|
| `URLSession` / `URLError` failure | `.transport(URLError)` or an equivalent Sendable transport description |
| Non-HTTP response | `.invalidResponse` |
| Response decoding failure after a successful status | `.decoding` |
| HTTP 400 | `.badRequest(messages: [String])` |
| HTTP 409 | `.idempotencyConflict(message: String?)` |
| HTTP 500 through 599 | `.server(statusCode: Int, message: String?)` |
| Other non-2xx status | `.http(statusCode: Int, message: String?)` |

The internal error payload decoder must accept Nest's string-or-array `message` shape and preserve useful messages without exposing raw response bodies or sensitive infrastructure details. A later backend migration to documented error codes requires an approved contract update and fixtures; it must not be guessed in this implementation.

## Idempotency behavior

- The caller creates one UUID idempotency key for one logical transaction operation before the first attempt.
- The same key and byte-equivalent logical payload, including the same `clientMutationId`, are reused after timeouts, connection loss, or any retry where the first outcome is unknown.
- The key must not be regenerated within `APIClient`, `TransactionService`, or a retry loop.
- Same key plus same normalized payload returns the original response with status `201` and must decode as success.
- Same key plus different payload returns `409` and maps to `APIError.idempotencyConflict`.
- A genuinely changed transaction is a new operation with a new idempotency key and a new `clientMutationId`.
- Automatic retries are not required in the first implementation. The initial boundary must make a caller-directed retry safe.

## Concurrency and Sendable requirements

- Public networking operations are `async throws` and cancellation-aware.
- Request, response, transaction type, server error payload, and injectable service boundaries conform to `Sendable` where applicable.
- UI-facing state remains `MainActor` isolated. Networking types do not import SwiftUI and do not mutate view state.
- Prefer value types. If shared mutable transport state becomes necessary, isolate it with an actor rather than locks or `@unchecked Sendable`.
- Do not use `Task.detached`. Cancellation from the calling task should propagate to `URLSession`.
- The project currently compiles in Swift 5 language mode with approachable concurrency and main-actor default isolation enabled; tests must compile under those detected settings without suppressing concurrency warnings.

## Proposed file layout

```text
Fintech/
├── Networking/
│   ├── APIClient.swift
│   └── APIError.swift
└── Transactions/
    ├── TransactionRequest.swift
    ├── TransactionResponse.swift
    ├── TransactionService.swift
    └── TransactionType.swift

FintechTests/
├── Networking/
│   └── APIClientTests.swift
├── Support/
│   └── URLProtocolStub.swift
└── Transactions/
    └── TransactionServiceTests.swift
```

Filesystem-synchronized Xcode groups should discover these files without manual project-file entries. Exact grouping may be collapsed if implementation shows that fewer files are clearer; do not add layers beyond the named responsibilities.

## Dependency boundaries

- `APIClient` owns base-URL resolution, `URLRequest` construction, `URLSession.data(for:)`, status handling, and JSON coding.
- `TransactionService` owns the `/transactions` operation and requires the caller to provide the stable request and idempotency key.
- The concrete `APIClient` receives a configured `URLSession` through initialization.
- Tests use an injected ephemeral session backed by a controlled `URLProtocol`; no generic transport framework is required.
- Future presentation code receives a narrow transaction-service dependency from the app composition root. SwiftUI does not construct `URLSession`, `APIClient`, or endpoint requests.
- Models depend only on Foundation. Networking does not depend on SwiftUI. No third-party package is introduced.

## Testing strategy

Focused unit tests must cover:

1. Exact camelCase request encoding, including UUIDs, integer minor units, optional `null`/omitted behavior, and the approved timestamp representation.
2. Exact snake_case success decoding with nullable `category_id` and `description`.
3. Successful handling of `201` for both initial and replay fixtures.
4. Presence and stability of `Idempotency-Key` across two caller-directed attempts of the same logical operation.
5. `Content-Type: application/json` and the exact `/transactions` URL.
6. Nest error decoding for string and array messages.
7. Mapping for `400`, `409`, `5xx`, unexpected status, transport failure, invalid response, and malformed success JSON.
8. Task cancellation propagation.
9. Validation of positive minor units and uppercase three-letter currency if enforced in the request initializer.

All default tests use stubs and make no external requests. Existing app and UI tests remain part of `scripts/verify.sh`.

## Opt-in production smoke-test strategy

Production smoke tests are separate from unit tests and from `scripts/verify.sh`.

- Require an explicit flag such as `RUN_PRODUCTION_TRANSACTION_SMOKE_TESTS=1`.
- Require all disposable test identifiers and payload values to be supplied explicitly; do not embed a real account or reusable production idempotency key.
- Use a fresh operation UUID for the first call, then replay exactly the same payload and key to verify the same transaction ID is returned.
- If conflict behavior is tested, use a separate disposable key and controlled payload.
- Record status, returned transaction ID, and `X-Request-Id`, but never log sensitive payload data.
- Skip rather than fail when the opt-in flag or required fixture values are absent.
- Never infer persistence or database readiness from `GET /health`.
- Running a mutating production smoke test requires human approval each time.

## Acceptance criteria

- The approved request is encoded with exactly the implemented field names and validation rules.
- A UUID `Idempotency-Key` is sent on every transaction request and remains stable with the unchanged request across retries.
- A `201` snake_case transaction row decodes into the strongly typed response model.
- Nest's current `400` and `409` payloads map to focused, testable `APIError` cases.
- Transport, invalid-response, decoding, unexpected-status, and server failures are represented without leaking infrastructure details.
- All networking APIs use async/await, respect cancellation, and satisfy the project's Sendable/isolation rules.
- SwiftUI contains no networking in view bodies and receives dependencies from a composition boundary.
- Unit tests use controlled URL loading and never contact production.
- `./scripts/verify.sh`, `git diff --check`, and the existing app build and tests pass.
- No authentication, third-party package, generic networking framework, or UI is added.

## Explicit non-goals

- SwiftUI screens or presentation changes
- Authentication, authorization, JWT storage, or account ownership enforcement
- Backend or OpenAPI modifications
- A generic endpoint/router/networking framework
- Automatic retry policy, exponential backoff, or reachability monitoring
- Offline persistence, transaction queues, reconciliation, or background sync
- Certificate pinning
- Database-readiness checks based on `GET /health`
- Live production traffic from the default verification harness
- Third-party dependencies

## Human approval required

Before production Swift implementation, approve or resolve:

1. Whether iOS targets the backend's current snake_case response or waits for the backend to adopt the documented camelCase response.
2. Whether the backend will adopt the documented `{code, message}` error schema or iOS should implement the current Nest envelope first.
3. The canonical timestamp validation and RFC 3339 encoding/decoding policy, including fractional seconds.
4. Whether backend validation will be aligned with the OpenAPI minimum amount, description length, and date-time constraints before client rollout.
5. Confirmation that `clientMutationId` remains required and clarification of its intended persistence/uniqueness semantics.
6. Confirmation that UUID is the canonical `Idempotency-Key` format and correction of the backend README example.
7. Confirmation that authentication remains out of scope for this milestone and that the production Render URL replaces the OpenAPI placeholder for this client.
8. Whether client-provided request correlation should be supported; current middleware always generates a new `X-Request-Id`.
9. Explicit authorization and disposable fixture data before any mutating production smoke test is run.
