# RULE: Apex Classes — MANDATORY

Applies to any `*.cls` under `force-app/**/classes/`. Adhere strictly.

## Architecture
- Separate concerns. For trigger-driven work the mandatory chain is
  **Trigger → Handler → Helper** (see `triggers.md`): the trigger only dispatches
  contexts, the handler owns the `processedIds` recursion guard and delegates, the
  helper holds the bulkified business logic.
- The Helper may call **Service** (shared business logic) and **Selector** (SOQL)
  classes when logic is reused beyond one trigger. Don't invent a service layer for
  logic used in exactly one place — keep it in the helper.
- Classes are `with sharing` by default. Use `without sharing` only when the spec
  explicitly justifies it; `inherited sharing` for reusable service/library classes.
- No business logic in constructors; keep methods single-responsibility and testable.
- Prefer `public`/`private` with the narrowest scope. Expose `@AuraEnabled` only what
  LWC/Aura needs.

## Bulkification & Governor Limits (non-negotiable)
- **Never** place SOQL, SOSL, or DML inside a `for` loop. Query once, work on collections.
- Assume every entry point can receive **200+ records**. Handle collections, not singletons.
- Use maps/sets to avoid nested loops and repeated queries.
- No unbounded queries — always filter and, where relevant, `LIMIT`.
- Aggregate DML: build lists and do one `insert`/`update` per object.

## Security (see security.md)
- Enforce CRUD/FLS. Prefer `WITH USER_MODE` on SOQL/DML, or `Security.stripInaccessible`,
  or `Schema.describe` checks. Do not rely on `with sharing` alone for FLS.
- Never trust client input; validate in Apex.

## SOQL/DML
- Selective queries; index-friendly filters. Avoid `SELECT *`-style over-fetching —
  query only needed fields.
- Use `Database.` methods with `allOrNone`/error handling when partial success matters.
- Null-check query results; never assume a record exists.

## Error handling & logging
- Catch specific exceptions; don't swallow. Use `AuraHandledException` for LWC-facing errors.
- Add `throw`/custom exceptions with actionable messages. No silent failures.
- Use `@TestVisible` instead of loosening access modifiers for tests.

## Async
- Choose the right tool: `@future` (simple, no return), Queueable (chaining/state),
  Batch (large volume), Scheduled. Respect async limits and chaining rules.
- `@future` params must be primitives/collections of primitives.

## Style
- Follow `naming-conventions.md`. No hardcoded IDs, URLs, or credentials — use Custom
  Metadata / Custom Settings / Named Credentials.
- ApiVersion in `*.cls-meta.xml` = 61.0.
- Every class needs test coverage per `testing.md`.
