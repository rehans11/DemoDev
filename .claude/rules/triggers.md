# RULE: Apex Triggers — MANDATORY

Applies to any `*.trigger` under `force-app/**/triggers/`. Adhere strictly.

## The framework: Trigger → Handler → Helper

Three layers, no exceptions:

| Layer | Class | Responsibility |
|-------|-------|----------------|
| Trigger | `<Object>Trigger` | Context dispatch ONLY. No logic. |
| Handler | `<Object>TriggerHandler` | Recursion guard + orchestration. Delegates to Helper. |
| Helper | `<Object>TriggerHelper` | The actual business logic, bulkified. |

- **Exactly one trigger per SObject.** If a trigger already exists for the object, add to
  the existing handler — never create a second trigger. Verify first (Glob the triggers dir).
- The Helper may call Service/Selector classes for shared logic (see `apex.md`).

## 1. Trigger — dispatch only

Declare **all seven contexts**, construct the handler with `(Trigger.new, Trigger.oldMap)`,
and route. Nothing else belongs here.

```apex
trigger AccountTrigger on Account (
    before insert, after insert,
    before update, after update,
    before delete, after delete,
    after undelete
)
{
    // Optional: bypass switch via custom setting / static flag
    // if (TriggerSettings__c.getInstance().TriggersDisabled__c) {
    //     return;
    // }

    AccountTriggerHandler handler = new AccountTriggerHandler(Trigger.new, Trigger.oldMap);

    if (Trigger.isBefore)
    {
        if (Trigger.isInsert)
        {
            handler.beforeInsert();
        }
        else if (Trigger.isUpdate)
        {
            handler.beforeUpdate();
        }
        else if (Trigger.isDelete)
        {
            handler.beforeDelete();
        }
    }
    else if (Trigger.isAfter)
    {
        if (Trigger.isInsert)
        {
            handler.afterInsert();
        }
        else if (Trigger.isUpdate)
        {
            handler.afterUpdate();
        }
        else if (Trigger.isDelete)
        {
            handler.afterDelete();
        }
        else if (Trigger.isUndelete)
        {
            handler.afterUndelete();
        }
    }
}
```

## 2. Handler — recursion guard + orchestration

- Constructor takes `(List<SObject> newRecords, Map<Id, SObject> oldMap)`.
  **Null-safety is required:** on delete `Trigger.new` is null; on insert/undelete
  `Trigger.oldMap` is null. Never dereference without checking.
- One public method per context: `beforeInsert()`, `beforeUpdate()`, `beforeDelete()`,
  `afterInsert()`, `afterUpdate()`, `afterDelete()`, `afterUndelete()`.
- **Recursion guard: a static `Set<Id> processedIds`.** Filter records already handled,
  then mark them. Static state persists for the transaction, which is exactly the scope
  you want.
- Handler holds **no business logic** — it guards, filters, and delegates to the Helper.

```apex
public with sharing class AccountTriggerHandler {

    private List<Account> newRecords;
    private Map<Id, Account> oldMap;

    @TestVisible
    private static Set<Id> processedIds = new Set<Id>();

    public AccountTriggerHandler(List<Account> newRecords, Map<Id, Account> oldMap) {
        this.newRecords = newRecords;
        this.oldMap = oldMap;
    }

    public void afterUpdate() {
        List<Account> toProcess = filterUnprocessed(this.newRecords);
        if (toProcess.isEmpty()) {
            return;                       // already handled this transaction
        }
        markProcessed(toProcess);
        AccountTriggerHelper.handleAfterUpdate(toProcess, this.oldMap);
    }

    /**
     * Returns only records not yet processed in this transaction.
     * NOTE: before-insert records have no Id yet — the guard is a no-op there,
     * which is correct (a before-insert cannot recurse on itself).
     */
    private List<Account> filterUnprocessed(List<Account> records) {
        List<Account> unprocessed = new List<Account>();
        if (records == null) {
            return unprocessed;
        }
        for (Account record : records) {
            if (record.Id != null && !processedIds.contains(record.Id)) {
                unprocessed.add(record);
            }
        }
        return unprocessed;
    }

    private void markProcessed(List<Account> records) {
        for (Account record : records) {
            processedIds.add(record.Id);
        }
    }
}
```

### Recursion-guard requirements
- `processedIds` is **`static`** and marked `@TestVisible` so tests can reset it.
- Mark records processed **before** delegating, so re-entrant DML sees them.
- The guard is a no-op in `before insert` (no Ids yet) — that's expected; a before-insert
  cannot re-fire itself.
- Never use a single `static Boolean hasRun` — it wrongly blocks legitimate second
  batches in the same transaction. Use the Id set.

## 3. Helper — the business logic

- `<Object>TriggerHelper`, typically `public with sharing` with `static` methods.
- **Bulkified**: operate on collections. No SOQL/DML inside loops.
- Use maps/sets to avoid nested loops and repeated queries.
- Delegate genuinely shared/reusable logic to Service classes (see `apex.md`).
- Enforce CRUD/FLS here or in the service layer (see `security.md`) — triggers run in
  system context by default.

## Ordering & side effects
- Do not assume execution order relative to Flows/other automation — verify existing
  automation on the object (the Architect documents this in the spec). Avoid conflicting
  field updates across trigger + record-triggered flow.
- Respect the order of execution; avoid recursive DML that re-fires the trigger.

## Testing
- Test **every** context path the trigger declares, and **bulk (200+ records)** per `testing.md`.
- Explicitly test the recursion guard: perform an update that would re-fire the trigger
  and assert the logic ran **once**. Reset `AccountTriggerHandler.processedIds` between
  scenarios via the `@TestVisible` hook.
