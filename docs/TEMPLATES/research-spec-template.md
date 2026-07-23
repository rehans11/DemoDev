# Research Spec — <Feature Name>

- **Feature slug:** `<feature-slug>`
- **Author:** salesforce-architect
- **Date:** <YYYY-MM-DD>
- **Status:** Draft | Awaiting user answers | Ready for review | Approved
- **Related:** [Technical Spec](./technical-spec.md) · [Implementation Log](../../implementation-log/<feature-slug>.md)

## 1. Problem statement
What the user asked for, restated precisely. Business goal and value.

## 2. Acceptance criteria
- [ ] Criterion 1 (observable, testable)
- [ ] Criterion 2

## 3. Metadata evidence (read-only)
Everything here must be verified — cite the command and its output. No assumptions.

| Item | How verified (command) | Finding |
|------|------------------------|---------|
| Object `X__c` exists w/ fields … | `sf sobject describe --sobject X__c` | … |
| Existing automation on Object | retrieve + read | trigger/flow/VR present: … |

### Impacted metadata inventory
- Objects/fields: …
- Apex (classes/triggers/handlers): …
- LWC/Aura: …
- Automation (flows, VR, duplicate rules): …
- Security (OWD, sharing, permission sets): …

## 4. Constraints, risks, and assumptions-to-confirm
- Constraints (limits, volume, existing patterns): …
- Risks (ordering conflicts, data migration, perf): …
- **Open questions asked of the user** (and answers): …

## 5. Options considered
For each option: description, pros, cons, effort, risk.
1. **Option A** — …
2. **Option B** — …

## 6. Recommended solution design
The chosen approach and **why**, tied directly to the evidence and requirements.
Include a high-level diagram/flow of data and control. State what is explicitly
**out of scope**.
