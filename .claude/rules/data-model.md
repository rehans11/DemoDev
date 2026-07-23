# RULE: Data Model & Schema — MANDATORY

Applies to metadata under `force-app/**/objects/**` (objects, fields, relationships,
validation rules, record types). Adhere strictly.

## Verify before you change
- **Never invent** object or field API names, picklist values, or relationships.
  Confirm current schema with `sf sobject describe --sobject <API_Name>` and read the
  retrieved metadata first. The Architect must cite this evidence in the spec.
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
