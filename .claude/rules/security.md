# RULE: Security — MANDATORY

Applies whenever you touch Apex, LWC/Aura, objects/fields, permission sets, or profiles.
Security is not optional and is never deferred "for later."

## CRUD / FLS enforcement (Apex)
- Enforce object and field-level security on **every** read and write of data the
  running user could access. Choose one and be consistent:
  - `SELECT ... WITH USER_MODE` and DML in user mode (`as user`) — preferred, modern.
  - `Security.stripInaccessible(AccessType.X, records)` before returning/DML.
  - Explicit `Schema.sObjectType.<Obj>.isCreateable()/isAccessible()/isUpdateable()`.
- `with sharing` controls **record** visibility, NOT field/object permissions — you
  still need FLS/CRUD checks. Use `without sharing` only with explicit justification.
- `@AuraEnabled` methods must enforce security even though they can run in system-ish
  contexts — the client is never a trust boundary.

## Sharing & visibility
- Design record access deliberately: OWD, role hierarchy, sharing rules, manual/Apex
  sharing. The spec must state the intended visibility; verify current OWD before change.
- Apex sharing (`__Share` rows / `Sharing` reason) only when declarative can't do it.

## Permissions model
- Grant access via **Permission Sets / Permission Set Groups**, not by editing profiles.
- Every new object/field/Apex class/LWC that users need must be added to the correct
  permission set(s); list them in the spec. Least privilege — grant only what's required.

## SOQL/SOSL injection
- Never concatenate untrusted input into dynamic SOQL. Use bind variables; if dynamic,
  use `String.escapeSingleQuotes()` and allow-list field/object names.

## Secrets & config
- No hardcoded credentials, tokens, session IDs, or endpoints. Use **Named Credentials**,
  Custom Metadata, or Protected Custom Settings. Never log secrets.
- Callouts: use Named Credentials; validate TLS; handle timeouts/errors.

## LWC/Aura
- Escape user content (framework does by default — don't defeat it with `innerHTML`).
- Enforce security server-side; disabling a button is UX, not security.

## Testing
- Include a **negative/permission test**: run as a user *without* access via
  `System.runAs` and assert access is denied / data is stripped.
