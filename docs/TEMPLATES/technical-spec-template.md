# Technical Spec — <Feature Name>

- **Feature slug:** `<feature-slug>`
- **Author:** salesforce-architect
- **Date:** <YYYY-MM-DD>
- **Status:** Draft | Ready for review | Approved for build
- **Related:** [Research Spec](./research-spec.md) · [Implementation Log](../../implementation-log/<feature-slug>.md)

> The Developer implements this **literally**. It must leave **zero design decisions**
> to the Developer. Every API name below must already be verified in the Research Spec.

## 1. Build order (checklist the Developer will mirror)
1. …
2. …

## 2. Data model changes
For each object/field: API name, label, type, length/precision, required?, default,
picklist values, relationship type + parent, help text, which permission set(s) get FLS.
Reference: `.claude/rules/data-model.md`, `.claude/rules/security.md`.

| API Name | Type | Details | Permission set(s) |
|----------|------|---------|-------------------|
| `X__c.Field__c` | … | … | … |

## 3. Apex
For each class/trigger: full name, responsibility, sharing keyword, method signatures,
security enforcement approach (`WITH USER_MODE` / stripInaccessible), error handling,
async type if any. Trigger wiring per one-trigger-per-object handler pattern.
Reference: `.claude/rules/apex.md`, `.claude/rules/triggers.md`, `.claude/rules/security.md`.

- **`ClassName`** (`with sharing`): …
  - `ReturnType methodName(Type param)` — behavior, inputs, outputs, errors.

## 4. LWC / Aura
For each component: name, purpose, `@api` props, events emitted/handled, wired vs
imperative Apex methods, targets (`*.js-meta.xml`), states (loading/empty/error), a11y.
Reference: `.claude/rules/lwc.md`, `.claude/rules/security.md`.

## 5. Automation (flows / validation rules)
Exact criteria, actions, and order relative to existing triggers/flows. Note conflicts.

## 6. Test plan
Reference: `.claude/rules/testing.md`.
- Test classes: `…Test`
- Scenarios: positive / negative / bulk (200+) / permission (runAs) — list each with
  the assertion expected.
- Required coverage and **exact test command**:
  `sf apex run test --tests <Classes> --code-coverage --result-format human --wait 10`

## 7. Deployment plan
Reference: `.claude/rules/metadata-deployment.md`.
1. Retrieve affected metadata.
2. Validate (check-only): `sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests --tests <Classes>`
3. Deploy: `sf project deploy start --source-dir force-app --test-level RunSpecifiedTests --tests <Classes>`
4. Confirm tests + coverage.
- Destructive changes (if any): explicit list + confirmation required.

## 8. Acceptance criteria (Developer verifies each)
- [ ] …

## 9. Out of scope
- …
