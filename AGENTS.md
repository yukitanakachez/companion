## Rules every agent follows

1. **Stay in your paths.** Edit only the paths your workstream owns (table above). Reading anything is fine.
2. **Frozen contracts.** After WS0 merges, these are frozen: `Package.swift`, `project.yml`, `contracts/`, `Sources/CompanionCore/`, `Sources/CompanionTestSupport/`, `scripts/`, `AGENTS.md`. If your task truly needs a change, **stop and tell the human** with the exact proposed diff and why. Do not work around it by duplicating a contract type.
3. **Use the APIs below verbatim.** The "Cross-workstream APIs" section is the contract between workstreams. If you are the producer, implement those exact public names, parameters and types (you may add more public API). If you are the consumer, use only what's listed.
4. **One branch + worktree per workstream**, cut from `main`:
   ```bash
   scripts/new-workstream.sh ws1-llm     # creates ../companion-ws1-llm on branch ws/ws1-llm
   ```
   (Or create a Superset workspace per workstream on a branch of the same name.)
5. **TDD, small commits.** Follow your plan's steps. Commit after each task with a conventional message (`feat(llm): …`, `test(bridge): …`).
6. **Before merging:** `git fetch && git rebase main`, then `scripts/test-all.sh` must pass. Merge into `main` with `git merge --no-ff ws/<id>` (or a PR). Because paths don't overlap, rebases should be conflict-free; if one isn't, you touched a path you don't own.
7. **Swift 6 strict concurrency** is on. AppKit/SwiftUI types are `@MainActor`. Cross-module values are `Sendable`.
8. **Never commit secrets** (API keys, pairing tokens, real textbook PDFs).
9. **Public structs get public memberwise inits.** Every `public struct` you expose across modules declares an explicit `public init` with all stored properties in declared order — Swift won't synthesize a public one, and neighbours construct your types.

Workstream plans live in `docs/superpowers/plans/`; read `2026-11-01-companion-00-overview.md` first.
