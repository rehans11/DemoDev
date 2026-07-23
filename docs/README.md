# Spec-Driven Salesforce Development — How to use this repo

This project separates **design** from **build** with two Claude agents governed by
`CLAUDE.md` and the rules in `.claude/rules/`.

## Workflow

1. **Design** — invoke the `architect` skill (type `/architect <feature description>`,
   or just ask to "design/spec out <feature>"). It scans org metadata, asks you clarifying questions,
   and writes:
   - `docs/specs/<feature-slug>/research-spec.md` — findings + solution design
   - `docs/specs/<feature-slug>/technical-spec.md` — exact implementation instructions
   - `docs/implementation-log/<feature-slug>.md` — audit trail
   The architect never writes code or deploys.

2. **Review** — you read the specs. Approve or send changes back to the architect.

3. **Build** — invoke the `develop` skill (type `/develop <feature-slug>`, or ask to
   "build/implement <feature-slug>"). It cuts a `feature/<feature-slug>` branch from
   `main`, implements the Technical Spec exactly, then validates (check-only) → deploys to
   the sandbox → runs Apex tests, appends everything to the implementation log, and
   **opens a PR against `main`** for you to review and merge. It never merges its own PR.

## Folders
- `docs/specs/<feature-slug>/` — the two specs per feature.
- `docs/implementation-log/<feature-slug>.md` — append-only audit log per feature.
- `docs/TEMPLATES/` — copy these to start a new spec/log.
- `.claude/rules/` — mandatory best-practice rules, auto-injected when editing
  matching files under `force-app/` (via the PreToolUse hook in `.claude/settings.json`).

## Guardrails (see CLAUDE.md)
- Nothing is assumed — decisions require metadata evidence or explicit requirements.
- Architect designs only; Developer builds strictly to spec.
- Sandbox/scratch only — never production.
- Everything is logged for human review.
