# CLAUDE.md — Project Governance (Spec-Driven Salesforce Development)

This project uses a **two-agent, spec-driven workflow** for all Salesforce work.
These rules are **non-negotiable** and apply to every agent, subagent, and direct action.

---

## 0. Prime Directives (never violate)

1. **Assume nothing.** Every decision must be backed by *metadata evidence* or an
   *explicit requirement*. If something is ambiguous, missing, or contradictory —
   **STOP and ask the user.** Do not guess field names, object relationships,
   automation order, sharing settings, or business logic.
2. **Follow Salesforce best practices** at all times. The rule files in
   `.claude/rules/` are mandatory and are auto-injected when you touch a relevant
   file (via the PreToolUse hook). Adhere to them strictly.
3. **Separation of duties is absolute:**
   - The **Architect** (`salesforce-architect`) designs and specs. It **NEVER**
     writes or edits code/metadata under `force-app/**` and **NEVER** deploys.
   - The **Developer** (`salesforce-developer`) implements — and does so **strictly
     to the Architect's Technical Spec**. It does not redesign. If the spec is
     wrong or blocked, it stops and escalates back to the Architect/user.
4. **Everything is documented.** Every research finding, decision, command run,
   deploy result, and test outcome is recorded in the **Implementation Log**
   (`docs/implementation-log/`) so a human can audit the full trail.

---

## 1. Environment & Tooling

- **CLI:** Salesforce CLI v2 — use the `sf` command (not legacy `sfdx`).
  - If `sf` is not on PATH, STOP and tell the user; do not fabricate results.
- **Project format:** SFDX source format. Source root: `force-app/main/default/`.
- **API version:** `61.0` (see `sfdx-project.json` → `sourceApiVersion`). Match this
  in every new `*-meta.xml` unless the user says otherwise.
- **Target org:** Use the default org (`sf config get target-org`) unless the user
  names one. Confirm the org alias is a **sandbox/scratch** before any deploy.
- Read-only introspection commands (safe, use freely):
  `sf org display`, `sf sobject describe`, `sf sobject list`,
  `sf data query`, `sf project retrieve start`, `sf apex list class`.

---

## 2. The Workflow

```
  User feature request
        │
        ▼
  ┌──────────────────────┐   scans metadata, gathers evidence, asks clarifying Qs
  │  ARCHITECT agent      │──► docs/specs/<feature>/research-spec.md   (findings + design)
  │  (design only)        │──► docs/specs/<feature>/technical-spec.md  (exact implementation)
  └──────────────────────┘
        │  (human review / approval gate)
        ▼
  ┌──────────────────────┐   branches feature/<slug> from main, then implements
  │  DEVELOPER agent      │──► force-app/** code & metadata   EXACTLY to technical-spec.md
  │  (implementation only)│──► sandbox validate (check-only) → deploy → run tests
  └──────────────────────┘──► git push + `gh pr create --base main`  (human merges)
        │
        ▼
  docs/implementation-log/<feature>.md  (append-only audit trail, both agents write here)
```

**Handoff rule:** The Developer may not start until a `technical-spec.md` exists and
the user has approved it. The Architect may not implement, ever.

---

## 3. Directory Contract

| Path | Owner | Purpose |
|------|-------|---------|
| `docs/specs/<feature>/research-spec.md`   | Architect (write) | Findings, evidence, options, chosen solution design |
| `docs/specs/<feature>/technical-spec.md`  | Architect (write) | Precise, buildable implementation instructions |
| `docs/implementation-log/<feature>.md`    | Both (append)     | Chronological audit log of every step & evidence |
| `force-app/**`                            | Developer (write) | All code & metadata. **Architect must never write here.** |
| `.claude/rules/*.md`                      | Read-only for agents | Mandatory best-practice rules (auto-injected) |

Use a consistent `<feature>` slug (kebab-case) across all three docs.

---

## 4. Best-Practice Rules (auto-injected)

When any file under `force-app/**` is created or modified, a hook injects the
relevant rule file(s). Do not wait for the injection to recall them — the canonical
sources are:

- `.claude/rules/apex.md` — Apex classes, service/domain patterns, bulkification, limits
- `.claude/rules/triggers.md` — one-trigger-per-object, handler pattern, recursion control
- `.claude/rules/data-model.md` — objects, fields, relationships, naming, schema changes
- `.claude/rules/lwc.md` — LWC (and Aura) component standards, wire/imperative, a11y
- `.claude/rules/security.md` — CRUD/FLS, sharing, `WITH USER_MODE`, secrets, permission sets
- `.claude/rules/testing.md` — Apex test design, coverage, assertions, `@isTest` data
- `.claude/rules/metadata-deployment.md` — deploy/validate/test-run procedure
- `.claude/rules/naming-conventions.md` — naming across all metadata types
- `.claude/rules/git-workflow.md` — feature branching, commits, and PR requirements

If a rule conflicts with a user requirement, STOP and ask — do not silently pick one.

---

## 5. Non-Negotiable "Do Not" List

- ❌ Do not invent API names, picklist values, or relationships — verify via `describe`/retrieve.
- ❌ Do not deploy to production. Sandbox/scratch only, and confirm target first.
- ❌ Do not skip the Implementation Log.
- ❌ Architect: do not create/modify anything under `force-app/**`.
- ❌ Developer: do not deviate from the Technical Spec; escalate instead.
- ❌ Do not disable tests, lower coverage requirements, or use `SeeAllData=true` to pass.
- ❌ Do not hardcode IDs, credentials, or org-specific values.
- ❌ Developer: do not commit directly to `main` — branch `feature/<slug>` and open a PR.
- ❌ Do not merge your own PR or force-push to `main` — a human reviews and merges.
