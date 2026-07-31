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
  - type (debit/credit)
  - optional description

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