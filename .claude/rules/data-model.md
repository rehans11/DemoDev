# RULE: Data Model & Schema — MANDATORY

Applies to metadata under `force-app/**/objects/**` (objects, fields, relationships,
validation rules, record types). Adhere strictly.

## Verify before you change
- **Never invent** object or field API names, picklist values, or relationships.
- **The repo is the source of truth.** Confirm current schema by reading
  `force-app/main/default/objects/<Object>/fields/*.field-meta.xml`. Cite those paths as
  evidence in the spec. Only fall back to `sf sobject describe --sobject <API_Name>` when
  the repo genuinely lacks the field (e.g. a standard field never retrieved) — a describe
  is ~106KB of JSON versus ~13KB of readable XML.
- If the repo may be stale vs. the org, run
  `sf project retrieve start --metadata <Type>` first — never silently assume either way.
- Check for existing fields/objects that already serve the need before creating new ones.

## Naming & structure
- Custom objects/fields end in `__c`; follow `naming-conventions.md`.
- Field API names: descriptive, PascalCase words, no ambiguous abbreviations.
- Add a clear **Description** and **Help Text** to every custom field.
- Choose the narrowest correct type/length. Money/number: set precision/scale
  deliberately. Text: don't oversize. Use picklists (ideally Global Value Sets) over
  free text where values are constrained.

## Relationships
- Master-Detail vs Lookup is a deliberate design decision (roll-up, sharing, cascade
  delete, reparenting) — the spec must state which and why.
- Beware the limits: fewer than 40 relationships per object; avoid unnecessary MD chains.
- Set required/lookup-delete behavior explicitly.

## Data integrity
- Prefer declarative enforcement (required fields, validation rules, unique/external ID)
  before Apex. Validation rule error messages must be user-actionable.
- Use **External Id** + **Unique** for integration keys.
- Don't store computed values you can derive with formula/roll-up unless justified.

## Governance
- ApiVersion in `*-meta.xml` = 61.0.
- New fields need FLS on the appropriate **permission set(s)** — never on profiles by
  default (see `security.md`). The spec must list which permission sets get access.
- Changing field type / deleting fields is destructive — call it out; deletions go
  through a `destructiveChanges` plan, never silently.
- Keep page layouts / Lightning pages updated so new required fields are reachable.
