# Create Transaction UI Skill

## Goal
Build a SwiftUI screen to create a transaction using TransactionService.

## Constraints

- Do not call networking from View directly
- Use ViewModel (Observable)
- Handle loading, success, error states
- Do not introduce global state
- Keep UI minimal

## Architecture

View
→ ViewModel
→ TransactionService
→ APIClient

## Requirements

- Form with:
  - amount
  - type (expense/income)
  - optional description
- Visual amount sign is presentation only:
  - Expense renders `-R$`
  - Income renders `+R$`
  - `amountMinor` stays positive in both cases
- Retry of the same logical submission reuses the same idempotency state
- Editing the form after a change or failure starts a new logical operation when applicable

- Generate:
  - Idempotency-Key (UUID)
  - clientMutationId (UUID)

- Call:
  TransactionService.createTransaction(...)

## UI States

- idle
- loading
- success
- error

## Non-goals

- no navigation
- no persistence
- no caching
