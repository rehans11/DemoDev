# RULE: Apex Triggers — MANDATORY

Applies to any `*.trigger` under `force-app/**/triggers/`. Adhere strictly.

## One trigger per object
- Exactly **one** trigger per SObject. If a trigger already exists for the object, add
  to the handler — never create a second trigger. Verify first (Glob the triggers dir).

## Logic-less trigger + handler pattern
- The trigger body contains **no business logic** — it only delegates to a handler class.
- Handle all relevant contexts explicitly:
  `before insert, before update, before delete, after insert, after update, after delete, after undelete`.

Example shape:
```apex
trigger AccountTrigger on Account (before insert, before update, after insert, after update) {
    new AccountTriggerHandler().run();   // TriggerHandler framework dispatches by context
}
```

## Handler rules
- Use a consistent trigger-handler framework/base class across the project (match the
  existing one — check for an existing `TriggerHandler` before introducing a new pattern).
- **Bulkified**: operate on `Trigger.new`/`Trigger.old` collections; no SOQL/DML in loops.
- **Recursion control**: guard against re-entrancy with a static flag/set of processed IDs.
- Keep the handler thin — delegate real work to service classes (see `apex.md`).

## Ordering & side effects
- Do not assume execution order relative to Flows/other automation — verify existing
  automation on the object (Architect documents this in the spec). Avoid conflicting
  field updates across trigger + record-triggered flow.
- Respect the order of execution; avoid recursive DML that re-fires the trigger.

## Security
- Enforce CRUD/FLS in the service layer (see `security.md`); triggers run in system
  context by default.

## Testing
- Test each context path and **bulk (200+ records)** per `testing.md`.
