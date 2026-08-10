# Skill Selection Guide

Skills are focused instruction sets for recurring iOS engineering concerns. Before a non-trivial task, inspect the available `docs/skills/<skill-name>/SKILL.md` files and select only the skills that directly apply to the requested work. A missing skill must not be assumed to be available.

Report the selected skills and a one-line reason for each before planning or implementing. Use at most three skills by default. Do not load every skill automatically; add another skill only when the task has a distinct concern that requires it.

| Task type | Recommended skills |
| --- | --- |
| SwiftUI screen, navigation, layout, or component work | `swiftui-ui-patterns`, `swiftui-view-refactor` |
| Apple-style interaction, motion, typography, or visual polish | `apple-design`, `swiftui-ui-patterns` |
| VoiceOver, Dynamic Type, assistive technologies, or accessibility audit | `ios-accessibility` |
| Unit tests, UI tests, flaky tests, or XCTest migration | `swift-testing` |
| `async`/`await`, actors, `Sendable`, data races, or Swift 6 migration | `swift-concurrency` |
| Slow SwiftUI updates, janky scrolling, excessive recomputation, or memory pressure | `swiftui-performance-audit` |
| Keychain, biometrics, CryptoKit, tokens, certificates, or OWASP review | `swift-security` |
| Backend API client, request/response modeling, or idempotency | No UI/design skill by default; select concurrency or security only if the task explicitly touches those concerns. |

When a task spans multiple rows, prefer the smallest set that covers the actual work. For example, a SwiftUI form with VoiceOver work may use `swiftui-ui-patterns` and `ios-accessibility`; it should not automatically load performance, security, testing, or concurrency guidance.
