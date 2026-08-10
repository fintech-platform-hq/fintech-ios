<!--
Sync Impact Report
- Version change: template (unversioned) -> 1.0.0
- Modified principles: template placeholders -> I. Spec-Driven Feature Work; II. SwiftUI-First Native
  iOS; III. API Contract Alignment; IV. Money Correctness; V. Networking Boundaries;
  VI. Testing and Validation; VII. Small PRs and Maintainability; VIII. Security Mindset
- Added sections: Engineering Constraints; Delivery Workflow
- Removed sections: none
- Follow-up TODOs: none
-->
# Fintech iOS Constitution

## Core Principles

### I. Spec-Driven Feature Work
Non-trivial features MUST begin with a specification that states intended behavior before
implementation. A plan MUST define the technical approach before code is written, and tasks
MUST be small enough to review and verify independently. Implementation, review, and follow-up
work MUST remain aligned with the approved specification, plan, and tasks.

### II. SwiftUI-First Native iOS
The app MUST prefer native SwiftUI patterns and system components when they meet the product
need; custom UI requires a clear user-facing reason. User interfaces MUST support accessibility
and Dynamic Type. Every user-facing flow MUST receive manual validation on an iPhone before
merge, because automated coverage cannot establish the complete device experience.

### III. API Contract Alignment
iOS request and response models MUST match the documented backend contract. Networking work
MUST use OpenAPI or another approved documented contract as its source, and contract mismatches
MUST be resolved before UI polish. The client MUST NOT silently invent backend behavior.

### IV. Money Correctness
Business monetary values MUST use integer minor units; `Double` and other floating-point types
MUST NOT represent money. Currency formatting is presentation-only and MUST NOT alter the
underlying value. Calculations, requests, and tests MUST retain deterministic integer values.

### V. Networking Boundaries
Views MUST NOT perform networking directly. Network transport MUST remain behind API clients and
transaction-specific services, while ViewModels coordinate UI state and user actions. Idempotency
keys and request payloads MUST remain explicit and stable for a logical retry, and their behavior
MUST be tested.

### VI. Testing and Validation
Meaningful behavior MUST have deterministic automated tests. Automated tests MUST NOT call
production services; any live check is opt-in and separate from routine validation.
`scripts/verify.sh` is the repository validation harness, and every PR MUST document the
validation performed and any intentionally unrun checks.

### VII. Small PRs and Maintainability
Changes MUST be small, focused, readable, and reviewable. Teams MUST avoid speculative
abstractions and broad rewrites unless an approved specification justifies them. Each PR MUST
preserve a clear path from requirement to implementation and verification.

### VIII. Security Mindset
Authentication data, tokens, Keychain contents, and personal finance data MUST be treated as
sensitive. The app MUST NOT introduce insecure storage or logging of sensitive data.
Security-related changes require explicit review and appropriate tests before merge.

## Engineering Constraints

Fintech is a lightweight, portfolio-grade native iOS app. It uses SwiftUI, Swift Testing,
Foundation networking, and injected API-client/service boundaries. New dependencies, generic
frameworks, service locators, and hidden singletons MUST NOT be introduced without a documented
need in the feature specification. The backend remains the source of truth for confirmed
financial writes.

## Delivery Workflow

Before review, contributors MUST run `scripts/verify.sh` and `git diff --check` when the change
affects implementation. Documentation-only changes require proportionate validation. Pull
requests MUST identify the linked specification, state scope, summarize validation, and call out
known risks. Manual iPhone validation is required for user-facing flows and MUST be recorded in
the PR.

## Governance

This constitution governs project engineering decisions and takes precedence over informal
practice. Amendments MUST be made in this file, include a Sync Impact Report, and state the
resulting semantic version change. MAJOR versions remove or redefine a governing principle,
MINOR versions add a principle or materially expand guidance, and PATCH versions clarify wording
without changing governance. Reviewers MUST check applicable PRs for constitutional compliance;
exceptions require a documented, time-bounded rationale in the approved specification or PR.

**Version**: 1.0.0 | **Ratified**: 2026-08-10 | **Last Amended**: 2026-08-10
