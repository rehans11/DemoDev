# RULE: Naming Conventions — MANDATORY

Consistent, descriptive names across all metadata. No cryptic abbreviations.

## Apex
- Classes: `PascalCase`. Suffix by role: `AccountTriggerHandler`, `AccountTriggerHelper`,
  `AccountService`, `AccountSelector`, `AccountController` (LWC-facing), `AccountTest`.
- Trigger framework trio for an object must match exactly: `AccountTrigger` →
  `AccountTriggerHandler` → `AccountTriggerHelper` (see `triggers.md`).
- Methods: `camelCase`, verb-first (`calculateDiscount`). Constants: `UPPER_SNAKE_CASE`.
- Variables: `camelCase`, meaningful (no `x`, `tmp`, `l` for lists — use `accounts`).
- One trigger per object: `<Object>Trigger` (e.g., `AccountTrigger`).

## LWC / Aura
- LWC folder & JS: `camelCase` (e.g., `accountList`). Aura: `PascalCase`.
- Public props (`@api`): `camelCase`. Events: lowercase, no spaces (`recordselected`).

## Metadata (data model)
- Custom object: `PascalCase__c` (e.g., `Invoice_Line__c` acceptable if it matches org
  convention — match existing style; verify first).
- Custom field: descriptive `PascalCase__c`; booleans read as a question/state
  (`IsActive__c`). External IDs suffixed clearly (`ExternalId__c`).
- Permission Set: `<Feature>_<Access>` (e.g., `Invoicing_ReadWrite`).
- Validation Rule / Flow / etc.: descriptive PascalCase stating intent.

## General
- Match the **existing convention in this org** when it differs — verify by reading
  neighboring metadata before naming. Consistency with what's there beats theory.
- No spaces or reserved words in API names; labels are human-readable, API names are stable.
