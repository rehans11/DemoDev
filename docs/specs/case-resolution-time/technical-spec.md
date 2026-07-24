# Technical Spec — Case Resolution Time & Account Case Metrics

- **Feature slug:** `case-resolution-time`
- **Author:** salesforce-architect
- **Date:** 2026-07-23
- **Status:** Ready for review
- **Related:** [Research Spec](./research-spec.md) · [Implementation Log](../../implementation-log/case-resolution-time.md)

> The Developer implements this **literally**. It must leave **zero design decisions**
> to the Developer. Every API name below is verified in the Research Spec §3.

### Schema evidence — repo paths (per `.claude/rules/data-model.md`)

The repo is the source of truth for schema. Every field this feature reads is cited below
by its `*.field-meta.xml` path, verified 2026-07-23:

| Field used by this feature | Repo evidence |
|---|---|
| `Case.AccountId` (Lookup → Account, `nillable`) | `force-app/main/default/objects/Case/fields/AccountId.field-meta.xml` |
| `Case.ClosedDate` | `force-app/main/default/objects/Case/fields/ClosedDate.field-meta.xml` |
| `Case.Status` (`New` / `Working` / `Escalated` / `Closed`) | `force-app/main/default/objects/Case/fields/Status.field-meta.xml` |
| `Case.IsClosed` | Standard system field — no `*.field-meta.xml` is retrieved for it; confirmed queryable via `SELECT IsClosed FROM Case` |
| `Case.CreatedDate` | Standard audit field — not retrieved as metadata; confirmed queryable |
| Case OWD `ReadWriteTransfer` | `force-app/main/default/objects/Case/Case.object-meta.xml` |
| Account OWD `ReadWrite` | `force-app/main/default/objects/Account/Account.object-meta.xml` |

**No name collision** for the four new fields: the only existing custom fields are
`Case/fields/{EngineeringReqNumber__c, Product__c, PotentialLiability__c, SLAViolation__c}`
and `Account/fields/{Active__c, CustomerPriority__c, NumberofLocations__c,
SLAExpirationDate__c, SLASerialNumber__c, SLA__c, UpsellOpportunity__c}`.

> ⚠️ **Known repo-vs-org discrepancy — the Developer must not "fix" this.**
> `force-app/main/default/objects/Case/fields/` contains `BusinessHoursId.field-meta.xml`,
> `EntitlementId.field-meta.xml`, `SlaStartDate`, `SlaExitDate`, `MilestoneStatus`,
> `IsStopped`, `StopStartDate`, and `IsClosedOnCreate` — but these fields **do not exist in
> the `demo` org**. Verified live 2026-07-23:
> `sf data query --query "SELECT Id, BusinessHoursId FROM Case LIMIT 1"` →
> `ERROR ... No such column 'BusinessHoursId' on entity 'Case'`.
> Entitlement Management is off in the org; those files are retrieved shells.
> **For these specific fields the org is authoritative and the repo is stale.** This design
> therefore references none of them, and that is precisely why D1b is calendar time (§0).
> Do not delete those files and do not build against them.

---

## 0. Decisions this spec is built on (user-signed-off 2026-07-23)

The Research Spec §4.3 raised seven blocking decisions. All are now answered. **This spec
is written against these answers, not against the Research Spec's original
recommendations** — where they differ, this document wins.

| ID | Decision | Answer | Effect on this spec |
|----|----------|--------|---------------------|
| D1a | Start point | `Case.CreatedDate` | Per E33 — `CaseHistory` has zero Status rows, so no alternative is derivable. |
| D1b | Clock | **Calendar** (24×7 wall-clock) | No `BusinessHours.diff()` dependency. Confirmed valid: `SELECT BusinessHoursId FROM Case` errors with *"No such column"* — the field does not exist. |
| D1c | Unit | **DAYS**, `Number(10,2)` | ⚠️ **Changed from the Research Spec**, which proposed hours. All field API names now read `..._Days__c`. |
| D2 | Reopen / re-close | **Recalculate** to latest `ClosedDate`; **clear** the value while the Case is open | §3.4 `CaseResolutionService` |
| D3a | Rollup scope | **All closed Cases, ever** — no filter | §3.6 `CaseSelector` — `WHERE IsClosed = true` only |
| D3b | Negative duration (dirty data) | Store **`null`**; the Case still counts toward `Closed_Case_Count__c` but is excluded from the average | §3.4 guard + §3.5 (`AVG()` ignores nulls) |
| D3c | `Case_Metrics_Last_Calculated__c` | **Included** — carried from the Research Spec recommendation, not separately asked. It is additive and read-only; say so if you want it dropped. Its value rises with D4 = async, because it is the only way to tell "rollup hasn't run yet" from "zero closed Cases". | §2 field table |
| D3d | Cases with no Account | Still stamp `Resolution_Time_Days__c`; contribute to no rollup | §3.4 / §3.3 |
| D3e | Accounts with zero closed Cases | Count = `0`, average = `null` | §3.5 seeding step |
| D4 | Timing | ⚠️ **Async via Queueable** | **Changed from the Research Spec**, which recommended synchronous. Drives §3.7, and the new risks in §0.1. |
| D5a | Permissions | Create `CaseResolutionMetrics_Read`, read-only FLS, **assign it to no one** | §2.2 |
| D5b | Layouts | `Case (Support) Layout` + `Case Layout`; `Account (Support) Layout` + `Account Layout` | §2.3 |
| D5c | Read-only | Yes — FLS `readable=true editable=false` **and** layout `behavior=Readonly` | §2.2 / §2.3 |
| D6 | Backfill | **Build it, do not run it** | §3.8, §3.9, §7.5 |
| D7 | Naming | Underscore-separated | All API names below |

### 0.1 Consequences of D4 = Queueable that the Developer must implement for

Choosing async instead of synchronous changes four things. Each has a concrete instruction
later in this spec — they are collected here so none is missed.

| # | Consequence | Where it is handled |
|---|-------------|---------------------|
| A1 | **Account values lag the Case save.** A user who closes a Case and immediately opens the Account may see stale metrics for a few seconds. This is accepted. `Case_Metrics_Last_Calculated__c` makes the lag visible. | §2.1, §8 AC4 |
| A2 | **A rollup failure no longer blocks the Case save.** Under the synchronous design a bad rollup would roll the whole transaction back loudly. Asynchronously it fails silently apart from the Apex job-error email. Mitigation: bounded retry on lock errors, then let the job fail so it surfaces in **Setup → Apex Jobs**. Never swallow. | §3.7 |
| A3 | **Enqueue limits are now a real constraint.** `System.enqueueJob` is capped at 50 per transaction, and at **1** inside a Batch `execute()`. A data load touching Cases in several DML statements can exhaust it. Mitigation: per-transaction dedupe of Account Ids + a synchronous fallback when no queueable slot remains. | §3.3 step 5 |
| A4 | **Row-lock contention between concurrent jobs** on the same Account is more likely than in the synchronous design, because jobs from different user transactions can overlap. Mitigation: deterministic Id-sorted update order + bounded retry. | §3.5, §3.7 |

---

## 1. Build order (checklist the Developer will mirror)

1. `git checkout main && git pull --ff-only origin main` → `git checkout -b feature/case-resolution-time`.
   Working tree must be clean apart from `docs/**`. (`.claude/rules/git-workflow.md`)
2. `sf org display` → confirm alias **`demo`**. ⚠️ This org is **Developer Edition with
   `IsSandbox = false`** (Research Spec E2/C7). It is **not** production and is a valid
   deploy target — do **not** halt because `IsSandbox` is false.
3. Create the four custom fields (§2.1).
4. Create the permission set `CaseResolutionMetrics_Read` (§2.2).
5. Edit the four page layouts (§2.3).
6. **Read §3.0 in full before writing any class** — the call graph, the two-transaction trace,
   and the four invariants. The before/after context split is the core of the design and is
   easy to get subtly wrong.
7. Create Apex in this order (each compiles against the previous):
   `TriggerHandler` → `CaseSelector` → `CaseResolutionService` → `AccountCaseRollupService`
   → `AccountCaseRollupQueueable` → `CaseTriggerHandler` → `CaseTrigger`
   → `AccountCaseMetricsRecalcBatch` → `CaseResolutionBackfillBatch`.
8. Create `TestDataFactory` and the nine test classes (§6).
9. Validate check-only (§7.2). Fix and repeat until clean.
10. Deploy (§7.3), run tests, capture coverage (§7.4).
11. **Do not execute the backfill batch** (§7.5).
12. Append every command, id, and result to `docs/implementation-log/case-resolution-time.md`.
13. Push branch, `gh pr create --base main`. **Do not merge.**

---

## 2. Data model changes

### 2.1 Custom fields

All four are `apiVersion` — file has no `<apiVersion>` element (CustomField metadata does
not carry one); the **project's** `sourceApiVersion` stays `61.0`. All are `required=false`,
`unique=false`, `externalId=false`, `trackFeedHistory=false`, no default value.

| API Name | Type | Details | Permission set |
|----------|------|---------|----------------|
| `Case.Resolution_Time_Days__c` | Number | `precision=10`, `scale=2` (8 integer + 2 decimal digits) | `CaseResolutionMetrics_Read` (read-only) |
| `Account.Closed_Case_Count__c` | Number | `precision=9`, `scale=0` | `CaseResolutionMetrics_Read` (read-only) |
| `Account.Average_Resolution_Time_Days__c` | Number | `precision=10`, `scale=2` | `CaseResolutionMetrics_Read` (read-only) |
| `Account.Case_Metrics_Last_Calculated__c` | DateTime | — | `CaseResolutionMetrics_Read` (read-only) |

Files:
- `force-app/main/default/objects/Case/fields/Resolution_Time_Days__c.field-meta.xml`
- `force-app/main/default/objects/Account/fields/Closed_Case_Count__c.field-meta.xml`
- `force-app/main/default/objects/Account/fields/Average_Resolution_Time_Days__c.field-meta.xml`
- `force-app/main/default/objects/Account/fields/Case_Metrics_Last_Calculated__c.field-meta.xml`

**Exact labels, descriptions and help text** (`.claude/rules/data-model.md` requires both a
Description and Help Text on every custom field — note the org's existing stock fields omit
these; do not copy that):

| Field | Label | Description | Inline help text |
|-------|-------|-------------|------------------|
| `Resolution_Time_Days__c` | `Resolution Time (Days)` | `Calendar days between Case CreatedDate and ClosedDate. Populated automatically by CaseTriggerHandler when the Case is closed and cleared when it is reopened. Blank if the Case is open or if ClosedDate precedes CreatedDate. Do not edit manually.` | `Calendar days elapsed from Case creation to closure. Calculated automatically; blank while the Case is open.` |
| `Closed_Case_Count__c` | `Closed Case Count` | `Total number of closed Cases ever related to this Account. Recalculated asynchronously by AccountCaseRollupQueueable. Do not edit manually.` | `How many of this Account's Cases have been closed, all time.` |
| `Average_Resolution_Time_Days__c` | `Average Resolution Time (Days)` | `Average of Resolution_Time_Days__c across this Account's closed Cases. Cases with no resolution time (open, or ClosedDate before CreatedDate) are excluded from the average but still counted in Closed_Case_Count__c. Do not edit manually.` | `Average calendar days to close a Case for this Account. Blank if no closed Case has a valid resolution time.` |
| `Case_Metrics_Last_Calculated__c` | `Case Metrics Last Calculated` | `Timestamp of the last successful recalculation of Closed_Case_Count__c and Average_Resolution_Time_Days__c. Blank means the rollup has never run for this Account.` | `When the case metrics on this Account were last recalculated.` |

Exact XML shape (mirror `Account/fields/NumberofLocations__c.field-meta.xml`, adding the
`description` and `inlineHelpText` elements it lacks):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Resolution_Time_Days__c</fullName>
    <description>…as above…</description>
    <externalId>false</externalId>
    <inlineHelpText>…as above…</inlineHelpText>
    <label>Resolution Time (Days)</label>
    <precision>10</precision>
    <required>false</required>
    <scale>2</scale>
    <trackFeedHistory>false</trackFeedHistory>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

For `Case_Metrics_Last_Calculated__c` use `<type>DateTime</type>` with no
`precision`/`scale`/`unique`.

**Do not** add `<trackHistory>` to any of these fields.

### 2.2 Permission set

File: `force-app/main/default/permissionsets/CaseResolutionMetrics_Read.permissionset-meta.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Read-only visibility of the derived Case resolution time and Account case metrics. Grants field-level read only; no object, Apex, or user permissions. Values are maintained by Apex in system mode and must never be user-editable.</description>
    <hasActivationRequired>false</hasActivationRequired>
    <label>Case Resolution Metrics - Read</label>
    <fieldPermissions>
        <editable>false</editable>
        <field>Account.Average_Resolution_Time_Days__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>false</editable>
        <field>Account.Case_Metrics_Last_Calculated__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>false</editable>
        <field>Account.Closed_Case_Count__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>false</editable>
        <field>Case.Resolution_Time_Days__c</field>
        <readable>true</readable>
    </fieldPermissions>
</PermissionSet>
```

Rules for the Developer:
- **Do not** add a `<license>` element — it would restrict who the set can be assigned to.
- **Do not** add `objectPermissions`, `classAccesses`, or `userPermissions`. Support agents
  already have Case and Account access; this set grants field read only (least privilege,
  `.claude/rules/security.md`).
- **Do not create a `PermissionSetAssignment`** for any user or profile (D5a). The user
  assigns it. Assignment inside Apex tests is fine and required (§6.7).
- **Do not** edit any `*.profile-meta.xml`.

### 2.3 Page layouts (modify existing — do not create new)

Add a read-only layout item to the existing **`System Information`** section (verified
present on all four files) of:

| File | Field to add |
|------|--------------|
| `layouts/Case-Case %28Support%29 Layout.layout-meta.xml` | `Resolution_Time_Days__c` |
| `layouts/Case-Case Layout.layout-meta.xml` | `Resolution_Time_Days__c` |
| `layouts/Account-Account %28Support%29 Layout.layout-meta.xml` | `Closed_Case_Count__c`, `Average_Resolution_Time_Days__c`, `Case_Metrics_Last_Calculated__c` |
| `layouts/Account-Account Layout.layout-meta.xml` | `Closed_Case_Count__c`, `Average_Resolution_Time_Days__c`, `Case_Metrics_Last_Calculated__c` |

Each item, appended to the **last** `<layoutColumns>` of that section:

```xml
<layoutItems>
    <behavior>Readonly</behavior>
    <field>Resolution_Time_Days__c</field>
</layoutItems>
```

`behavior` **must** be `Readonly` (D5c). Do **not** touch the Sales or Marketing layouts,
and do **not** touch `CaseClose-Close Case Layout` (the value does not exist yet at the
moment the Close Case screen is shown).

---

## 3. Apex

Every `*.cls-meta.xml` uses `<apiVersion>61.0</apiVersion>` (Research Spec C5/E3).
Source root: `force-app/main/default/classes/` and `/triggers/`.

---

### 3.0 Call graph & runtime flow — read this before writing any class

#### 3.0.1 Static dependency graph (who calls whom)

Arrows point **downward only**. There are no upward or sideways calls, and no cycles —
`CaseTriggerHandler` never calls a batch, and no service ever calls a handler.

```
  ── ENTRY POINTS ────────────────────────────────────────────────────────────────
  CaseTrigger                     CaseResolutionBackfillBatch      AccountCaseMetricsRecalcBatch
  (before ins/upd +               (manual, D6 — never auto-run)    (manual / chained)
   after ins/upd/del/undel)                │                                │
        │                                  │                                │
        ▼                                  │                                │
  ── DISPATCH ──────────────────────────── │ ────────────────────────────── │ ─────
  TriggerHandler.run()                     │                                │
   · bypass check                          │                                │
   · MAX_RUNS guard (safety net only)      │                                │
   · switch on Trigger.operationType       │                                │
        │                                  │                                │
        ├──────────────┬───────────────────┼────────────────────────────────┼─────
        ▼              ▼                   │                                │
  CaseTriggerHandler   CaseTriggerHandler  │                                │
   .beforeInsert        .afterInsert       │                                │
   .beforeUpdate        .afterUpdate       │                                │
        │               .afterDelete       │                                │
        │               .afterUndelete     │                                │
        │                    │             │                                │
        │                    │             │                                │
  ── SERVICE (business logic) ─────────────┼────────────────────────────────┼─────
        │                    │             │                                │
        │   ┌────────────────┼─────────────┘                                │
        ▼   ▼                │                                              │
  CaseResolutionService      │                                              │
   .applyResolutionTimes(List<Case>, Map<Id,Case>, Set<String> closedStatuses)
   .buildResolutionUpdates(List<Case>, Set<String>)   ← backfill path only   │
        └─► .calculateResolutionDays(Datetime, Datetime)   ← PURE            │
                                                                            │
   ⚠ PURE — no SOQL, no DML, no System.now() of its own. The closed-status   │
     set and the "now" instant are both INJECTED by the caller.             │
        │                    │                                              │
        │  before ctx:       │  after ctx: collect Account Ids, then         │
        │  mutates Trigger.new│  enqueue. NO DML on Case anywhere.           │
        │  in memory.        │                                              │
        │  ZERO DML.         ▼                                              │
        │                                                                   │
  ── ASYNC HOP ────────────────────────────────────────────────────────────────
                       AccountCaseRollupQueueable.execute()                 │
                        · try → recalculate                                 │
                        · catch lock error → chain self (attempt+1, max 3)  │
                             │                                              │
                             │ ◄── sync fallback, no queueable slot (A3) ───┤
                             ▼                                              ▼
  ── SERVICE (aggregation) ──────────────────────────────────────────────────────
  AccountCaseRollupService.recalculate(Set<Id>)        [without sharing]
   · seed every Account → 0 / null / now
   · chunk Ids by 500
        │
        ▼
  ── SELECTOR (all SOQL lives here) ─────────────────────────────────────────────
  CaseSelector.getClosedStatusLabels()               ← SELECT ... FROM CaseStatus
  CaseSelector.aggregateClosedCaseMetrics(List<Id>)  ← the only aggregate query
  CaseSelector.closedCaseBackfillLocator()           ← backfill batch only
        │
        ▼
  update List<Account>     ← 1 DML, Id-sorted, all-or-none
        │
        ▼
  (nothing) — no Account trigger, no record-triggered Flow, no validation rule
             exists in this org, so the chain terminates here. Verified E15/E17.
```

**Class → what it may call** (the Developer should be able to tick every line):

| Class | Calls | Must NOT call |
|---|---|---|
| `CaseTrigger` | `CaseTriggerHandler.run()` — nothing else | any service, any SOQL/DML |
| `TriggerHandler` | its own `virtual` methods | anything feature-specific |
| `CaseTriggerHandler` | `CaseResolutionService`, `CaseSelector.getClosedStatusLabels()`, `System.enqueueJob`, `AccountCaseRollupService` (fallback only) | any batch; **any DML on Case** |
| `CaseResolutionService` | nothing | any SOQL, any DML, any selector, `System.now()` |
| `AccountCaseRollupService` | `CaseSelector` | any handler, any queueable |
| `CaseSelector` | nothing | any DML |
| `AccountCaseRollupQueueable` | `AccountCaseRollupService`, itself (retry) | `CaseSelector` directly |
| `CaseResolutionBackfillBatch` | `CaseSelector`, `CaseResolutionService`, `TriggerHandler.bypass`, `AccountCaseMetricsRecalcBatch` | `AccountCaseRollupService` directly |
| `AccountCaseMetricsRecalcBatch` | `AccountCaseRollupService` | `CaseSelector` directly |

#### 3.0.2 Runtime trace — the main path, "agent closes a Case"

This spans **two transactions**. Getting the boundary right is the whole design.

> **Design correction, 2026-07-23.** An earlier draft of this spec stamped the Case from an
> `after update` trigger via a self-`update`, guarded by a static `isStampingResolution`
> flag. That worked, but it was the wrong shape: **no Apex guard can stop a trigger from
> firing** — Salesforce fires triggers on every DML unconditionally, and a flag can only make
> the re-entrant invocation return early. The right fix is to not issue the DML at all.
> Stamping a field on the record being saved is `before`-trigger work: mutate `Trigger.new`
> in memory, zero DML, nothing to re-fire, no recursion guard needed.
> See §3.0.7 for why the original `ClosedDate` objection (R4) does not apply.

```
╔═ TRANSACTION 1 — the user's save ════════════════════════════════════════════╗
║                                                                              ║
║  1  Agent sets Status = 'Closed', saves.                                      ║
║                                                                              ║
║  2  CaseTrigger fires ── BEFORE UPDATE                                        ║
║  3  TriggerHandler.run()   runCounts['casetriggerhandler'] = 1                ║
║  4  CaseTriggerHandler.beforeUpdate()                                         ║
║       closedStatuses = CaseSelector.getClosedStatusLabels()   ◄── SOQL #1     ║
║                                        (statically cached; once per txn)      ║
║  5  CaseResolutionService.applyResolutionTimes(                               ║
║         Trigger.new, Trigger.oldMap, closedStatuses, System.now())            ║
║       for the Case:  wasClosed=false → nowClosed=true  ⇒ TRANSITION           ║
║       c.Resolution_Time_Days__c = calculateResolutionDays(                    ║
║                                     c.CreatedDate, nowInstant)  = 3.00        ║
║       ── written straight onto Trigger.new. NO DML. NOTHING RE-FIRES. ──      ║
║                                                                              ║
║  6  Platform saves the record — Status, ClosedDate (platform-set) and         ║
║     Resolution_Time_Days__c all persist in ONE write.                         ║
║                                                                              ║
║  7  CaseTrigger fires ── AFTER UPDATE  (once, normally — not re-entrant)      ║
║  8  CaseTriggerHandler.afterUpdate()                                          ║
║       ── in AFTER context IsClosed / ClosedDate are the committed values,     ║
║          so they are safe to read here (unlike in BEFORE). ──                 ║
║                                                                              ║
║  9  Collect affected Account Ids:                                             ║
║       relevant = (new.IsClosed || old.IsClosed)                               ║
║                  && (IsClosed changed || ClosedDate changed || AccountId chg) ║
║       → add BOTH new.AccountId and old.AccountId (non-null)                   ║
║                                                                              ║
║ 10  toProcess = affected − enqueuedAccountIds     (per-transaction dedupe)    ║
║ 11  enqueuedAccountIds.addAll(toProcess)                                      ║
║ 12  Queueable slot free?  ── YES ──► System.enqueueJob(AccountCaseRollup…)    ║
║                           ── NO  ──► AccountCaseRollupService.recalculate()   ║
║                                       inline; still correct, SOQL sees this   ║
║                                       transaction's own uncommitted DML.      ║
║                                                                              ║
║ 13  ✅ COMMIT.  Case.Resolution_Time_Days__c durable.                          ║
║     Total added cost: 1 SOQL, ZERO DML, 1 queued job.                         ║
╚══════════════════════════════════════════════════════════════════════════════╝
                                    │
                         (seconds later, platform-scheduled)
                                    ▼
╔═ TRANSACTION 2 — the Queueable ══════════════════════════════════════════════╗
║                                                                              ║
║ 17  AccountCaseRollupQueueable.execute()   [system context, no running user  ║
║                                             sharing to inherit]              ║
║ 18  AccountCaseRollupService.recalculate(accountIds)                          ║
║ 19  · calcTime = System.now()                                                 ║
║ 20  · sortedIds = accountIds sorted            (deterministic lock order, A4) ║
║ 21  · SEED each Account → count 0, avg null, lastCalc = calcTime              ║
║       ── seeding is what makes an Account that lost its last closed Case      ║
║          correctly fall back to 0/null instead of keeping a stale figure ──   ║
║ 22  · for each chunk of 500 Ids:                                              ║
║         CaseSelector.aggregateClosedCaseMetrics(chunk)   ◄── SOQL #1..n       ║
║           SELECT AccountId, COUNT(Id), AVG(Resolution_Time_Days__c)           ║
║           FROM Case WHERE AccountId IN :chunk AND IsClosed = true             ║
║           GROUP BY AccountId                                                  ║
║         ── reads the value committed in step 16. Ordering is guaranteed       ║
║            because T1 committed before this job was dequeued. ──              ║
║         ── AVG() ignores nulls ⇒ D3b falls out for free: a dirty Case is      ║
║            counted by COUNT(Id) but contributes nothing to the average. ──    ║
║ 23  · overlay results onto the seeded map                                     ║
║ 24  update accounts;                          ◄── DML #1, all-or-none         ║
║                                                                              ║
║     on UNABLE_TO_LOCK_ROW and attempt < 3 → chain self with attempt+1         ║
║     on anything else                      → rethrow → Setup ▸ Apex Jobs (A2)  ║
║                                                                              ║
║ 25  ✅ COMMIT. Account metrics visible.                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

#### 3.0.3 What each trigger context actually does

Stamping and rollup-dispatch are now cleanly split across the before/after boundary.

| Context | Job | Detail |
|---|---|---|
| `before insert` | **Stamp** | Derive closed-ness from `Status`. `CreatedDate` is null (record doesn't exist yet) ⇒ a Case created already-closed gets **`0.00`**, which is definitionally right: created and closed in the same instant. |
| `before update` | **Stamp** | `CreatedDate` is populated for an existing record. Stamp only on a **transition** into a closed Status (see §3.0.6 invariant 1). |
| `after insert` | Dispatch | `new.AccountId` where `IsClosed == true`. An inserted *open* Case changes no closed-case metric. |
| `after update` | Dispatch | `new.AccountId` **and** `old.AccountId` when the relevance predicate passes. Adding **both** is what makes re-parenting correct — the old Account must lose the Case. |
| `after delete` | Dispatch | `old.AccountId` where `old.IsClosed == true`. The Account must lose the Case from its count. |
| `after undelete` | Dispatch | `new.AccountId` where `IsClosed == true`. The Account must regain it. Field values survive delete, so no re-stamp is needed. |

- Insert and undelete collapse to the same dispatch branch (`oldMap == null`) — intentional,
  they need identical treatment.
- **No context performs DML on Case.** The stamp is an in-memory write in `before`; the
  after contexts only read and enqueue.
- **The update predicate deliberately does nothing** when an *open* Case is edited or
  re-parented — neither Account's closed-case metrics can change, so no job is enqueued.
  This is what keeps ordinary Case editing from flooding the queue.

#### 3.0.4 Governor cost

| | SOQL | DML | Queueable |
|---|---|---|---|
| **T1** — any Case DML, 1 or 200 records | **1** (`CaseStatus`, statically cached — once per transaction however many times the trigger fires) | **0** | **1** |
| **T1** — Case DML of *m* records | **1** | **0** | **≤ ⌈m/200⌉** |
| **T2** — rollup, *n* Accounts | **⌈n/500⌉** (1 for the trigger path, where *n* ≤ 400) | **1** | 0 (unless retrying) |

⚠️ **Queueable count scales with DML *chunks*, not with records or Accounts.** The platform
processes a DML statement in batches of 200, firing the trigger once per chunk. The
per-transaction `enqueuedAccountIds` dedupe collapses *overlapping* Account sets across
chunks, but it cannot merge chunks whose Account sets are **disjoint** — those legitimately
need separate jobs. So a 250-record update spanning 5 Accounts (50 each, grouped) fires twice
over Accounts 1–4 then Account 5, and enqueues **2** jobs. That is correct behaviour, not a
dedupe failure. Assert against `⌈m/200⌉`, never against a literal `1`.

Both are **constant with batch size**, which is what AC6 asserts. Nothing in either path
scales per-record.

Versus the earlier after-trigger draft this trades **1 DML for 1 cached SOQL** — a good
trade twice over: DML is the scarcer resource (150 vs 100), and more importantly a DML on
Case re-enters the trigger while a SOQL does not.

#### 3.0.5 The repair path (manual only — D6)

Separate entry point, never reached from the trigger:

```
CaseResolutionBackfillBatch          scope 200
  ├─ start()   → CaseSelector.closedCaseBackfillLocator()   [ALL Cases, not just closed —
  │                                                          so a Case reopened while the
  │                                                          trigger was inactive gets its
  │                                                          stale value CLEARED]
  ├─ execute() → TriggerHandler.bypass('CaseTriggerHandler')
  │              CaseResolutionService.buildResolutionUpdates(scope)
  │              update  ← fires CaseTrigger, which returns instantly (bypassed)
  │              finally { clearBypass }
  │
  │   ⚠ The bypass is load-bearing, not hygiene: a Batch execute() may enqueue only
  │     ONE Queueable (A3). Without it, scope 2 onward would throw.
  │
  └─ finish()  → Database.executeBatch(new AccountCaseMetricsRecalcBatch(), 200)
                    │
                    └─ execute() → AccountCaseRollupService.recalculate(scopeAccountIds)

Two stages, chained — every Case stamp is committed before any Account is aggregated.
```

#### 3.0.6 Four invariants the Developer must not break

1. **Stamp only on a *transition* into a closed Status — never on every save of an already-closed
   Case.** If the stamp recomputed whenever `Status` is closed, every later edit to a closed
   Case would push the close instant forward and silently inflate the resolution time. The
   rule is:
   - `!nowClosed` → set `null` (open, or reopened — D2)
   - `nowClosed && !wasClosed` → compute and set (first close, or re-close after reopen — D2)
   - `nowClosed && wasClosed` → **leave the existing value untouched**

   This mirrors the platform's own behaviour: `ClosedDate` is not rewritten when you edit an
   already-closed Case either.
2. **No DML on Case anywhere in the trigger path.** The stamp is an in-memory write to
   `Trigger.new` in a `before` context. Re-introducing a self-`update` brings back the
   re-entrancy problem that this design exists to avoid.
3. **`CaseResolutionService` stays pure** — no SOQL, no DML, and **no `System.now()` of its
   own**. Both the closed-status set and the "now" instant are injected by the caller. That
   is the only reason the negative-duration, rounding, and transition cases can be unit-tested
   directly (§6.1), since `CreatedDate`/`ClosedDate` are not settable on a record.
4. **Never read `IsClosed` or `ClosedDate` in a `before` context.** They are platform-derived
   and not reliably populated until after the before-trigger runs. Derive closed-ness from
   `Status` + `CaseSelector.getClosedStatusLabels()` instead. Reading them in an `after`
   context is fine and is what §3.0.3 does.

#### 3.0.7 Why `before` is safe here — the R4 objection, resolved

The Research Spec (R4) argued for an after-only trigger because `Case.ClosedDate`'s
population timing inside a `before` context is not reliably documented and could not be
verified read-only in this org. **That objection is still true, and this design simply stops
depending on it.**

| | Value needed in `before` | Source |
|---|---|---|
| ❌ Old approach | "is this Case closed?" → `IsClosed` | platform-derived, unreliable in `before` |
| ❌ Old approach | "when did it close?" → `ClosedDate` | platform-derived, unreliable in `before` |
| ✅ This design | "is this Case closed?" → `Status` ∈ closed set | `Status` is the user's own input, always present in `Trigger.new`; the closed set comes from `CaseStatus`, verified queryable 2026-07-23 |
| ✅ This design | "when did it close?" → `System.now()` | the save instant |

`CaseStatus` verification (2026-07-23):
```
$ sf data query --query "SELECT MasterLabel, IsClosed, IsDefault, SortOrder FROM CaseStatus ORDER BY SortOrder"
  New        false  true   1
  Working    false  false  2
  Escalated  false  false  3
  Closed     true   false  4
```
So today exactly one Status is closed. Querying `CaseStatus` rather than hardcoding
`'Closed'` means the feature keeps working if an admin later adds e.g.
`Closed - No Response` — the same robustness the `IsClosed`-based approach had for free.

**Is `System.now()` a faithful substitute for `ClosedDate`?** Yes, at this precision. They
differ by the milliseconds the platform takes to complete the save. The field is
`Number(10,2)` in **days**, where `0.01` day = **14.4 minutes**. A millisecond divergence
cannot change the stored value. It is also self-consistent: `Case.ClosedDate` is
`createable=false, updateable=false`, so `Status` is the sole cause of a Case closing —
deriving from `Status` is arguably closer to the truth than reading the field the platform
derives from it.

**Where `ClosedDate` *is* still used:** the backfill batch (§3.9), which runs over historical
records where `System.now()` is meaningless and the stored `ClosedDate` is the only evidence
available. Both paths share the same pure `calculateResolutionDays(created, closed)` method
and differ only in how they obtain `closed`.

---

### 3.1 `TriggerHandler` — new base framework (`inherited sharing virtual`)

No trigger framework exists in this org (E14); this establishes the project standard.

```apex
public inherited sharing virtual class TriggerHandler {
    @TestVisible private static Set<String> bypassedHandlers = new Set<String>();
    @TestVisible private static Map<String, Integer> runCounts = new Map<String, Integer>();
    private static final Integer MAX_RUNS = 10;

    public class TriggerHandlerException extends Exception {}

    public static void bypass(String handlerName)      { bypassedHandlers.add(handlerName.toLowerCase()); }
    public static void clearBypass(String handlerName)  { bypassedHandlers.remove(handlerName.toLowerCase()); }
    public static void clearAllBypasses()               { bypassedHandlers.clear(); }
    public static Boolean isBypassed(String handlerName){ return bypassedHandlers.contains(handlerName.toLowerCase()); }

    public void run() { … }

    protected virtual void beforeInsert()  {}
    protected virtual void beforeUpdate()  {}
    protected virtual void beforeDelete()  {}
    protected virtual void afterInsert()   {}
    protected virtual void afterUpdate()   {}
    protected virtual void afterDelete()   {}
    protected virtual void afterUndelete() {}
}
```

`run()` behaviour, exactly:
1. `String handlerName = String.valueOf(this).split(':')[0];`
2. If `!Trigger.isExecuting` → `throw new TriggerHandlerException('TriggerHandler.run() may only be called from trigger context.')`
3. If `isBypassed(handlerName)` → `return;`
4. Read the current run count (default `0`). If `>= MAX_RUNS` →
   `throw new TriggerHandlerException('Maximum trigger runs (10) exceeded for ' + handlerName)`.
   Otherwise store `count + 1`.
5. `switch on Trigger.operationType` dispatching `BEFORE_INSERT`/`BEFORE_UPDATE`/`BEFORE_DELETE`/
   `AFTER_INSERT`/`AFTER_UPDATE`/`AFTER_DELETE`/`AFTER_UNDELETE` to the matching virtual
   method, with `when else { }`.

Sharing rationale: `inherited sharing` because it is a reusable base that must not impose a
sharing mode on subclasses (`.claude/rules/apex.md`).

### 3.2 `CaseTrigger` — the only trigger on Case (logic-free)

File: `force-app/main/default/triggers/CaseTrigger.trigger` (+ `-meta.xml`, apiVersion 61.0).
Verified: **zero** existing Case triggers (E14), so there is no one-trigger-per-object conflict.

```apex
trigger CaseTrigger on Case (before insert, before update,
                             after insert, after update, after delete, after undelete) {
    new CaseTriggerHandler().run();
}
```

Context split (see §3.0.3 and §3.0.7):
- **`before insert` / `before update`** — stamp `Resolution_Time_Days__c` directly onto
  `Trigger.new`. No DML, so nothing re-fires. Closed-ness is derived from `Status`, never
  from `IsClosed`/`ClosedDate` (invariant 4).
- **`after insert` / `after update` / `after delete` / `after undelete`** — collect affected
  Account Ids and dispatch the rollup. `IsClosed`/`ClosedDate` are the committed values here
  and are safe to read.

Do **not** add `before delete`. Do **not** perform DML on Case in any context.

### 3.3 `CaseTriggerHandler` (`inherited sharing`, extends `TriggerHandler`)

```apex
public inherited sharing class CaseTriggerHandler extends TriggerHandler {
    @TestVisible private static Set<Id> enqueuedAccountIds = new Set<Id>();
    @TestVisible private static Boolean lastRunUsedSyncFallback = false;
}
```

> There is **no** `isStampingResolution` flag and **no** recursion guard in this class. Both
> became unnecessary when the stamp moved to a `before` context — there is no DML on Case, so
> there is nothing to re-enter. `TriggerHandler`'s `MAX_RUNS` counter remains only as a
> generic safety net.

#### Stamping — `beforeInsert()` / `beforeUpdate()`

Both delegate to:
```apex
private void stamp(List<Case> newCases, Map<Id, Case> oldMap) {
    CaseResolutionService.applyResolutionTimes(
        newCases,
        oldMap,                                   // null on insert
        CaseSelector.getClosedStatusLabels(),
        System.now()
    );
}
```
- `beforeInsert()` → `stamp(Trigger.new, null)`
- `beforeUpdate()` → `stamp(Trigger.new, Trigger.oldMap)`

The service mutates `Trigger.new` in place. **No DML, no return value to write back.**
`System.now()` is captured once here and injected, so every Case in the batch shares one
consistent instant and the service stays pure (invariant 3).

#### Rollup dispatch — `afterInsert()` / `afterUpdate()` / `afterDelete()` / `afterUndelete()`

Each delegates to one private method:

```apex
private void dispatchRollup(List<Case> newCases, Map<Id, Case> oldMap)
```
called as:
- `afterInsert()`   → `dispatchRollup(Trigger.new, null)`
- `afterUpdate()`   → `dispatchRollup(Trigger.new, Trigger.oldMap)`
- `afterDelete()`   → `dispatchRollup(null, Trigger.oldMap)`
- `afterUndelete()` → `dispatchRollup(Trigger.new, null)`

`dispatchRollup()` steps, in order:

1. **Collect affected Account Ids** into `Set<Id> affected`:
   - **insert**  (`oldMap == null && newCases != null`): add `c.AccountId` for each Case where
     `c.IsClosed == true` and `c.AccountId != null`.
   - **update**: for each Case, let `o = oldMap.get(c.Id)`. Include only if
     ```apex
     (c.IsClosed == true || o.IsClosed == true) &&
     (c.IsClosed != o.IsClosed || c.ClosedDate != o.ClosedDate || c.AccountId != o.AccountId)
     ```
     then add both `c.AccountId` and `o.AccountId` when non-null. (Adding **both** is what
     makes re-parenting correct — the old Account must lose the Case.)
   - **delete** (`newCases == null`): add `o.AccountId` for each old Case where
     `o.IsClosed == true` and `o.AccountId != null`.
   - **undelete**: same rule as insert.
   Note the update predicate deliberately does nothing when an *open* Case is edited or
   re-parented — neither Account's closed-case metrics can change.
2. **Dispatch** (skip entirely if `affected.isEmpty()`):
   ```apex
   Set<Id> toProcess = new Set<Id>(affected);
   toProcess.removeAll(enqueuedAccountIds);          // per-transaction dedupe (A3)
   if (toProcess.isEmpty()) { return; }
   enqueuedAccountIds.addAll(toProcess);
   if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
       System.enqueueJob(new AccountCaseRollupQueueable(toProcess));
   } else {
       lastRunUsedSyncFallback = true;               // no queueable slot left (A3)
       AccountCaseRollupService.recalculate(toProcess);
   }
   ```
   The synchronous fallback exists because `System.enqueueJob` is limited to **1** inside a
   Batch `execute()` and 50 per transaction. Correctness must not depend on a slot being
   available. Do not remove it, and do not swallow an exception from it.

Sharing rationale: `inherited sharing` — the handler itself does no unqualified querying; the
sharing decision belongs to the services it calls.

### 3.4 `CaseResolutionService` (`inherited sharing`)

Responsibility: the resolution-time arithmetic and the D2/D3b rules. **All the interesting
logic lives in pure static methods with every dependency injected, so it is directly
unit-testable without DML** — this matters because `Case.CreatedDate` and `Case.ClosedDate`
are `createable=false, updateable=false` (Research Spec C2/E5) and cannot be set on a record
by a test.

```apex
public inherited sharing class CaseResolutionService {
    @TestVisible private static final Long MILLIS_PER_DAY = 86400000L;

    public static Decimal calculateResolutionDays(Datetime createdDate, Datetime closedDate)
    public static void applyResolutionTimes(List<Case> newCases, Map<Id, Case> oldMap,
                                            Set<String> closedStatuses, Datetime nowInstant)
    public static List<Case> buildResolutionUpdates(List<Case> cases)
}
```

**`calculateResolutionDays(Datetime createdDate, Datetime closedDate)` → `Decimal`**
- `createdDate == null || closedDate == null` → return `null`.
- `Long ms = closedDate.getTime() - createdDate.getTime();`
- `ms < 0` → return `null`. **This is the D3b / R1 guard and is mandatory, not defensive
  padding**: all 23 closed Cases in this org today have `ClosedDate` ≈ 13.5 months *before*
  `CreatedDate` (E32, re-verified 2026-07-23). Without it every Account shows a ≈ −410 day
  average.
- Otherwise `return (Decimal.valueOf(ms) / MILLIS_PER_DAY).setScale(2, System.RoundingMode.HALF_UP);`
- Never throws.

**`applyResolutionTimes(List<Case> newCases, Map<Id,Case> oldMap, Set<String> closedStatuses, Datetime nowInstant)` → `void`**

The `before insert` / `before update` path. **Mutates `newCases` in place. Performs no SOQL
and no DML, and calls no `System.now()` of its own** — `nowInstant` is injected so a test can
pin it and so every Case in a batch shares one instant.

Return immediately if `newCases` is null or empty. Otherwise, for each Case `c`:

```apex
Boolean nowClosed = c.Status != null && closedStatuses.contains(c.Status);
Boolean wasClosed = (oldMap != null)
                    && oldMap.containsKey(c.Id)
                    && oldMap.get(c.Id).Status != null
                    && closedStatuses.contains(oldMap.get(c.Id).Status);

if (!nowClosed) {
    c.Resolution_Time_Days__c = null;                 // open, or reopened (D2)
} else if (!wasClosed) {                              // TRANSITION into closed
    c.Resolution_Time_Days__c = (c.CreatedDate == null)
        ? 0.00                                        // closed-on-create: before insert,
                                                      // CreatedDate not yet assigned
        : calculateResolutionDays(c.CreatedDate, nowInstant);
}
// else: already closed and staying closed → leave the existing value untouched
```

⚠️ The final `else` branch is **invariant 1** and is the single most important line in this
class. Without it, every save of an already-closed Case would re-stamp against a fresh
`nowInstant` and silently inflate the number. It also mirrors the platform: `ClosedDate` is
not rewritten when you edit an already-closed Case.

`closedStatuses` comes from `CaseSelector.getClosedStatusLabels()` — **never** hardcode
`'Closed'`, and **never** read `c.IsClosed` or `c.ClosedDate` here (invariant 4).

Cases with a null `AccountId` are handled identically (D3d) — Account has nothing to do with
the Case-level stamp.

**`buildResolutionUpdates(List<Case> cases)` → `List<Case>`**

The **backfill path only** (§3.9). Historical records already carry a committed `ClosedDate`,
and `System.now()` is meaningless for them, so this variant computes from the stored fields.

- Returns an empty list for a null/empty input.
- For each Case: `desired = (c.IsClosed == true) ? calculateResolutionDays(c.CreatedDate, c.ClosedDate) : null;`
  Reading `IsClosed`/`ClosedDate` is safe here — the batch queries committed records, not a
  `before`-trigger view.
- Compare `desired` with `c.Resolution_Time_Days__c`, treating null-vs-null as equal and
  null-vs-value as different. If different, add
  `new Case(Id = c.Id, Resolution_Time_Days__c = desired)` to the result.
- Returns only records that actually changed — an unchanged Case must not be re-DML'd.
- **No SOQL and no DML.** The caller owns the DML.

Both entry points share `calculateResolutionDays`; they differ only in how they obtain the
close instant (`nowInstant` live, stored `ClosedDate` historically). Those agree to within
the milliseconds of a save — far below `0.01` day (14.4 minutes).

### 3.5 `AccountCaseRollupService` (**`without sharing`** — explicitly justified)

```apex
public without sharing class AccountCaseRollupService {
    private static final Integer ACCOUNTS_PER_QUERY = 500;
    public static void recalculate(Set<Id> accountIds)
}
```

> **Sharing justification — must be reproduced verbatim in the class header comment.**
> `.claude/rules/security.md` prefers `WITH USER_MODE`. It is deliberately **not** used here.
> Case OWD is `ReadWriteTransfer` with `externalSharingModel = Private` (E22), so a
> user-mode aggregate would compute each Account's average from only the Cases the *saving
> user* can see — making a stored value depend on who clicked Save. That violates AC7. The
> rollup therefore runs in system mode. The security boundary for this feature is the
> **read** boundary instead: all four fields are read-only FLS (§2.2) and `Readonly` on the
> layouts (§2.3), so no user can write a derived value.

`recalculate(Set<Id> accountIds)` behaviour, exactly:
1. Return immediately if `accountIds` is null or empty.
2. `Datetime calcTime = System.now();`
3. Build `List<Id> sortedIds = new List<Id>(accountIds); sortedIds.sort();`
   Sorting gives a deterministic Account update order across concurrent jobs, which reduces
   deadlock probability (A4 / R8).
4. **Seed** a `Map<Id, Account>` in `sortedIds` order with
   `new Account(Id = aId, Closed_Case_Count__c = 0, Average_Resolution_Time_Days__c = null,
   Case_Metrics_Last_Calculated__c = calcTime)`.
   Seeding is what makes an Account that just lost its last closed Case correctly fall back
   to `0` / `null` (D3e, AC5).
5. **Aggregate, chunked** — iterate `sortedIds` in slices of `ACCOUNTS_PER_QUERY` (500) and
   call `CaseSelector.aggregateClosedCaseMetrics(chunk)`. Chunking keeps each query under the
   2,000 `AggregateResult` row cap (R6) no matter how many Accounts a backfill passes in.
   For each `AggregateResult ar`:
   ```apex
   Id accId       = (Id) ar.get('accId');
   Integer cnt    = (Integer) ar.get('caseCount');
   Object rawAvg  = ar.get('avgDays');
   Decimal avgDays = (rawAvg == null) ? null : Decimal.valueOf(String.valueOf(rawAvg));
   ```
   ⚠️ Convert the average via `Decimal.valueOf(String.valueOf(...))`, **not** a direct
   `(Decimal)` cast — `AVG()` may surface as `Double` and a hard cast would throw at runtime.
   Then set `Closed_Case_Count__c = cnt` and
   `Average_Resolution_Time_Days__c = (avgDays == null) ? null : avgDays.setScale(2, System.RoundingMode.HALF_UP)`
   on the seeded Account.
   Accounts absent from the aggregate results keep their seeded `0` / `null`.
6. `update accountsToUpdate;` — one DML, all-or-none, built in `sortedIds` order.
   Do not use `Database.update(list, false)`; a partial success would silently leave skewed
   metrics. Let it throw so `AccountCaseRollupQueueable` can retry or fail loudly (A2).
7. No `try/catch` inside this method.

Cost: **1 DML + ⌈n/500⌉ SOQL** per invocation. From the trigger path *n* ≤ 400
(200 new + 200 old Account Ids), so 1 SOQL + 1 DML.

### 3.6 `CaseSelector` (`inherited sharing`)

```apex
public inherited sharing class CaseSelector {
    @TestVisible private static Set<String> cachedClosedStatuses;

    public static Set<String> getClosedStatusLabels() {
        if (cachedClosedStatuses == null) {
            cachedClosedStatuses = new Set<String>();
            for (CaseStatus cs : [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = true]) {
                cachedClosedStatuses.add(cs.MasterLabel);
            }
        }
        return cachedClosedStatuses;
    }

    public static List<AggregateResult> aggregateClosedCaseMetrics(List<Id> accountIds) {
        return [
            SELECT AccountId accId, COUNT(Id) caseCount, AVG(Resolution_Time_Days__c) avgDays
            FROM Case
            WHERE AccountId IN :accountIds AND IsClosed = true
            GROUP BY AccountId
        ];
    }

    public static Database.QueryLocator closedCaseBackfillLocator() {
        return Database.getQueryLocator([
            SELECT Id, AccountId, IsClosed, CreatedDate, ClosedDate, Resolution_Time_Days__c
            FROM Case
        ]);
    }
}
```

- `getClosedStatusLabels()` is **statically cached**, so the `CaseStatus` query costs **1
  SOQL per transaction** no matter how many times `CaseTrigger` fires. `CaseStatus` is a
  standard, queryable object — verified 2026-07-23, returning `New/Working/Escalated` as open
  and `Closed` as closed (§3.0.7). Querying it rather than hardcoding `'Closed'` keeps the
  feature correct if an admin adds another closed status later.
  `@TestVisible` on the cache so a test can inject a synthetic set.
- The aggregate has **no `WITH USER_MODE`** — deliberate, per §3.5. `inherited sharing`
  means it resolves to *without sharing* when called from `AccountCaseRollupService`.
- `WHERE ... IsClosed = true` and nothing else — D3a, all closed Cases ever, unfiltered.
- `AVG()` ignores nulls, which is precisely what implements D3b: a dirty Case is counted by
  `COUNT(Id)` but contributes nothing to the average.
- The backfill locator selects **all** Cases (not just closed ones) so the batch can also
  *clear* a stale value on a Case that was reopened while the trigger was inactive.

### 3.7 `AccountCaseRollupQueueable implements Queueable`

```apex
public class AccountCaseRollupQueueable implements Queueable {
    @TestVisible private static final Integer MAX_ATTEMPTS = 3;
    @TestVisible private static Boolean retryScheduled = false;

    private final Set<Id> accountIds;
    private final Integer attempt;

    public AccountCaseRollupQueueable(Set<Id> accountIds) { this(accountIds, 1); }
    public AccountCaseRollupQueueable(Set<Id> accountIds, Integer attempt) { … }

    public void execute(QueueableContext context) { … }
}
```

`execute()` behaviour, exactly:
```apex
try {
    AccountCaseRollupService.recalculate(accountIds);
} catch (Exception e) {
    if (attempt < MAX_ATTEMPTS && isRetryable(e)) {
        retryScheduled = true;
        if (!Test.isRunningTest()) {          // Apex forbids chaining Queueables in tests
            System.enqueueJob(new AccountCaseRollupQueueable(accountIds, attempt + 1));
        }
    } else {
        throw e;                              // surface in Setup → Apex Jobs (A2)
    }
}
```

`private static Boolean isRetryable(Exception e)` returns `true` when
`e.getMessage()` contains `'UNABLE_TO_LOCK_ROW'` or `'ROW_LOCK'` (case-insensitive),
`false` otherwise. Only lock contention is retried (A4) — a validation-rule or FLS failure
must not be retried, it must fail loudly.

Never swallow an exception. The `retryScheduled` flag exists solely so tests can assert the
retry decision without relying on chaining (which Apex disallows in test context).

No `Database.AllowsCallouts` — there are no callouts.

### 3.8 `AccountCaseMetricsRecalcBatch implements Database.Batchable<SObject>`

Repair tool. Recomputes metrics for **every** Account.

- `start(Database.BatchableContext bc)` → `Database.getQueryLocator([SELECT Id FROM Account])`
- `execute(bc, List<SObject> scope)` → build a `Set<Id>` of the scope's Account Ids and call
  `AccountCaseRollupService.recalculate(ids)`.
- `finish(bc)` → no-op.
- Recommended scope size when invoked: **200**.
- It is `Database.Batchable`, **not** `Database.Stateful` — no cross-scope accumulation, so
  no heap growth however many Accounts exist.
- It does not enqueue anything, so the 1-queueable-per-batch-execute cap is irrelevant.

### 3.9 `CaseResolutionBackfillBatch implements Database.Batchable<SObject>`

Repair tool for the Case-level stamp. **Built but never executed by the Developer** (D6).

- `start(bc)` → `CaseSelector.closedCaseBackfillLocator()`
- `execute(bc, List<SObject> scope)`:
  ```apex
  TriggerHandler.bypass('CaseTriggerHandler');
  try {
      List<Case> updates = CaseResolutionService.buildResolutionUpdates((List<Case>) scope);
      if (!updates.isEmpty()) { update updates; }
  } finally {
      TriggerHandler.clearBypass('CaseTriggerHandler');
  }
  ```
  ⚠️ **The bypass is load-bearing, not hygiene, and remains necessary even though the trigger
  no longer does DML on Case.** Two independent reasons:
  1. Each scope's `update` fires the **after** contexts, which would enqueue a Queueable — and
     a Batch `execute()` may enqueue only **one** (A3). Scope 2 onward would throw.
  2. It also fires **`before update`**, where `applyResolutionTimes` would see an
     already-closed Case staying closed and — correctly, per invariant 1 — leave the value
     alone. That happens to be harmless, but relying on it would couple the batch to the
     trigger's transition logic. The bypass makes the batch's write authoritative.

  Note this is why `buildResolutionUpdates` (stored-`ClosedDate` variant) exists separately
  from `applyResolutionTimes` (live-`now` variant) — see §3.4.
- `finish(bc)` → `Database.executeBatch(new AccountCaseMetricsRecalcBatch(), 200);`
  Chaining is what makes the two-stage repair correct: all Case stamps are committed before
  any Account is aggregated.
- Not `Database.Stateful`.

Class header comment must state: *"Operational repair tool. Not executed as part of any
deployment. Run only with explicit user approval — it performs DML on production-of-record
data. Per D6 in the technical spec."*

### 3.10 Rules compliance checklist (Developer self-verifies before validate)

- [ ] No SOQL or DML inside any `for` loop, anywhere.
- [ ] Every entry point handles 200+ records via collections.
- [ ] Exactly one trigger on Case; it contains no business logic.
- [ ] **No DML on Case anywhere in the trigger path** — the stamp is an in-memory write to
      `Trigger.new` in a `before` context (invariant 2).
- [ ] **No recursion/re-entrancy flag in `CaseTriggerHandler`** — if you felt the need for one,
      something is doing DML that shouldn't be.
- [ ] **`IsClosed` / `ClosedDate` are never read in a `before` context** (invariant 4).
- [ ] The literal `'Closed'` appears nowhere outside test code.
- [ ] Sharing keyword present and deliberate on every class; the one `without sharing` carries
      its verbatim justification comment.
- [ ] No hardcoded Ids, usernames, org URLs, or credentials.
- [ ] No `@AuraEnabled` methods (there is no UI layer in this feature).
- [ ] `@TestVisible` used instead of widening access modifiers.
- [ ] Every `*.cls-meta.xml` / `*.trigger-meta.xml` declares `<apiVersion>61.0</apiVersion>`.

---

## 4. LWC / Aura

**None.** The requirement — see these values on the Case and the Account record — is met by
page-layout fields (§2.3). There is no Lightning record page for Case or Account in this org
(E29), so layouts are the correct and only lever. Do not create any component, tab, custom
report type, or list view.

---

## 5. Automation (flows / validation rules)

**No new flows, validation rules, workflow rules, or process builders.**

Verified non-conflicting, leave untouched:

| Existing automation | Evidence | Why there is no conflict |
|---|---|---|
| Case assignment rules (`Standard`, active, 5 entries) | E18 | Sets `OwnerId` only. |
| Case escalation rules (`Standard`, active, 8 entries) | E19 | Sets escalation/owner state; does not touch `CreatedDate`, `ClosedDate`, or the new fields. |
| `Case.workflow-meta.xml` | E16 | Contains a field-update *definition* (`ChangePriorityToHigh`) and **zero** `<rules>` — nothing fires. |
| Flows | E17 | Only `sfdc_default_ReportExport_Protection_Flow`. No record-triggered flow on Case or Account. |
| Validation rules | E15 | **Zero** org-wide, so the Account `update` cannot be blocked today. |
| Duplicate rules | E20 | Account/Contact/Lead only; none on Case. |

If the Developer discovers any of the above has changed since 2026-07-23, **stop and
escalate** — do not adapt the design.

---

## 6. Test plan

Reference: `.claude/rules/testing.md`. No `SeeAllData=true` anywhere. Every test asserts;
no coverage-padding tests.

### 6.0 `TestDataFactory` (`@isTest public class`)

Marked `@isTest` so it does not count toward org code. Provides:
- `static List<Account> createAccounts(Integer count, Boolean doInsert)`
- `static List<Case> createCases(Id accountId, Integer count, Boolean doInsert)` — `Status = 'New'`
  (a verified active picklist value, E7).
- `static User createMinimumAccessUser()` — Profile `Minimum Access - Salesforce`, unique
  username built from `UserInfo.getOrganizationId()` + a counter. **Must be called inside
  `System.runAs(new User(Id = UserInfo.getUserId()))`** to avoid `MIXED_DML_OPERATION`.
- `static void assignPermissionSet(Id userId, String permSetName)` — queries
  `PermissionSet WHERE Name = :permSetName` and inserts a `PermissionSetAssignment`.

**Setting dates in tests.** `CreatedDate` and `ClosedDate` are `createable=false,
updateable=false` (C2). Therefore:
- Use `Test.setCreatedDate(caseId, Datetime.now().addDays(-3))` to age a Case.
- Never try to assign `ClosedDate`. Obtain it by updating `Status = 'Closed'`; the platform
  sets `ClosedDate ≈ System.now()`.
- For any assertion on a specific number, allow a small tolerance —
  `Assert.isTrue(Math.abs(actual - 3.00) < 0.01, msg)` — because the close happens
  milliseconds after `now()`.
- **Negative and boundary durations are tested against the pure
  `CaseResolutionService.calculateResolutionDays(Datetime, Datetime)` method directly**, with
  literal `Datetime` arguments. Do not attempt to manufacture a negative duration through DML.

### 6.1 `CaseResolutionServiceTest`

| Scenario | Assertion |
|---|---|
Every one of these is a **pure in-memory call** — no DML, no SOQL, no org data. Build `Case`
objects in memory and inject `closedStatuses` and `nowInstant`.

`calculateResolutionDays`:

| Scenario | Assertion |
|---|---|
| Positive — created 3 days before close | `calculateResolutionDays(now-3d, now)` → `Assert.areEqual(3.00, result)` |
| Fractional / rounding | `calculateResolutionDays(t, t.addMinutes(36))` → `0.03` (HALF_UP at 2dp) |
| Zero duration | equal Datetimes → `Assert.areEqual(0.00, result)` |
| **Negative duration (D3b / E32)** | `calculateResolutionDays(now, now.addDays(-410))` → `Assert.isNull(result)` |
| Null created / null closed | → `Assert.isNull(result)` |

`applyResolutionTimes` — the transition matrix. **This is the highest-value table in the
test plan; it is where invariant 1 lives.** Use `closedStatuses = new Set<String>{'Closed'}`
and a fixed `nowInstant`:

| old `Status` | new `Status` | Expected `Resolution_Time_Days__c` | Covers |
|---|---|---|---|
| *(insert)* `New` | — | `null` | open on create |
| *(insert)* `Closed` | — | `0.00` (`CreatedDate` null in before insert) | closed-on-create |
| `New` | `Closed` | computed from `CreatedDate` → `nowInstant` | first close (D2) |
| `Working` | `Closed` | computed | close from any open status |
| **`Closed`** | **`Closed`** | **UNCHANGED — pre-existing value preserved** | ⚠️ **invariant 1** — seed the Case with `99.99` and assert it is still `99.99` |
| `Closed` | `Working` | `null` | reopen clears (D2) |
| `Closed` → `Working` → `Closed` | | recomputed against the **new** `nowInstant`, not the first | re-close (D2) |
| any | `Closed`, `CreatedDate` after `nowInstant` | `null` | negative guard reached through the real entry point |

Also assert:

| Scenario | Assertion |
|---|---|
| Multi-status robustness | pass `closedStatuses = {'Closed','Closed - No Response'}`; both stamp correctly — proves nothing hardcodes `'Closed'` |
| Null / empty input | returns without exception |
| Purity | `Limits.getDmlStatements()` **and** `Limits.getQueries()` unchanged across the call |
| No hidden clock | two calls with the same injected `nowInstant` produce identical values |

`buildResolutionUpdates` (backfill variant, reads stored `ClosedDate`):

| Scenario | Assertion |
|---|---|
| Closed Case with valid dates | returns one `Case` carrying the computed value |
| Closed Case with `ClosedDate < CreatedDate` | returns one `Case` carrying `null` (D3b) |
| Open Case holding a stale value | returns one `Case` carrying `null` |
| Case already holding the correct value | `Assert.areEqual(0, result.size())` — no needless DML |
| Empty/null input | empty list, no exception |
| Purity | `Limits.getDmlStatements()` unchanged |

### 6.2 `CaseTriggerHandlerTest`

| Scenario | Assertion |
|---|---|
| Close a Case aged 3 days (`Test.setCreatedDate`) | `Resolution_Time_Days__c ≈ 3.00` on requery (tolerance `< 0.01`) |
| Reopen a closed Case (`Status` → `Working`) | `Resolution_Time_Days__c` is **null** (D2) |
| Re-close after reopen | recomputed against the **latest** close, not the first (D2) |
| **Edit an already-closed Case** (change `Subject` only) | ⚠️ `Resolution_Time_Days__c` is **unchanged** — the end-to-end proof of invariant 1 |
| Insert a Case with `Status = 'Closed'` | `Resolution_Time_Days__c == 0.00` |
| Editing an open Case | no Queueable enqueued — `Limits.getQueueableJobs()` did not increase |
| Case with `AccountId = null` closed | Case is stamped; no exception; no rollup attempted (D3d, AC9) |
| Re-parent a **closed** Case to another Account | both old and new Account Ids collected — assert both Accounts' counts after `Test.stopTest()` (AC5) |
| Delete a closed Case | source Account's count drops by 1 |
| Undelete it | count returns |
| **No DML on Case** | close a Case inside `Test.startTest()`/`stopTest()` and assert `Limits.getDmlStatements() == 1` (the test's own update only) — proves the trigger adds no self-DML |
| **No re-entrancy** | after a close, `Assert.areEqual(2, TriggerHandler.runCounts.get('casetriggerhandler'))` — exactly one `before` + one `after` pass, never a third |

### 6.3 `AccountCaseRollupServiceTest`

| Scenario | Assertion |
|---|---|
| Two closed Cases, 2 and 4 days | count `= 2`, average `≈ 3.00` |
| One valid + one null-resolution Case | count `= 2`, average equals the **valid** one only (D3b) |
| **All** closed Cases have null resolution | count `> 0`, average `Assert.isNull(...)` — the exact state of this org today |
| Account with zero closed Cases | count `= 0`, average `null` (D3e) |
| Account whose last closed Case was deleted | count falls back to `0`, average `null` (seeding step, AC5) |
| Every processed Account | `Case_Metrics_Last_Calculated__c` is not null (D3c) |
| Null / empty input | returns without exception and performs no DML |
| Determinism (AC7) | run `recalculate` under `System.runAs` as a non-admin user and assert the stored count/average are **identical** to the admin-computed values |

> **Spec defect, corrected 2026-07-23.** An earlier draft required a user "who can see none
> of the Cases". That precondition is **unsatisfiable in this org**: Case OWD is
> `ReadWriteTransfer` (Research Spec E22) — public read/write — so any user with Case object
> access sees every Case, and any user without it sees none *because of CRUD*, not sharing.
>
> **Consequence the reviewer should register:** `without sharing` on
> `AccountCaseRollupService` is currently **belt-and-braces, not load-bearing**. It becomes
> load-bearing the moment Case OWD is tightened to Private or Public Read Only — at which
> point a user-mode aggregate would silently make each Account's average depend on who
> clicked Save. Keep the keyword and its justification comment; the risk it guards is real
> but latent. Re-run this test as a genuine visibility test if OWD ever changes.

### 6.4 `AccountCaseRollupQueueableTest`

| Scenario | Assertion |
|---|---|
| Enqueue → `Test.stopTest()` | Account metrics populated |
| Retry decision on a lock error | invoke `isRetryable` behaviour via a simulated message; assert `retryScheduled == true` and that no chain is attempted under `Test.isRunningTest()` |
| Non-retryable exception | rethrown — assert with `try/catch` + `Assert.fail()` if no exception |
| `MAX_ATTEMPTS` exhausted | exception propagates rather than looping |

### 6.5 `TriggerHandlerTest`

| Scenario | Assertion |
|---|---|
| `bypass` / `isBypassed` / `clearBypass` / `clearAllBypasses` | round-trip, case-insensitive |
| Bypassed handler does not run | close a Case with `bypass('CaseTriggerHandler')` set → `Resolution_Time_Days__c` stays null |
| `run()` outside trigger context | `TriggerHandlerException` thrown — assert the message |
| Max-run guard | drive `runCounts` to `MAX_RUNS` and assert `TriggerHandlerException` |

Add a `CaseSelectorTest` covering `getClosedStatusLabels()`: it returns `{'Closed'}` in this
org, and a second call in the same transaction does **not** issue another query (assert
`Limits.getQueries()` is unchanged across the second call — proves the static cache).

### 6.6 Bulk — `CaseTriggerHandlerBulkTest` (or a `@isTest` method inside `CaseTriggerHandlerTest`)

**Required by `.claude/rules/testing.md`.**
- Arrange: 5 Accounts × 50 Cases = **250 Cases**, inserted open.
  Do **not** call `Test.setCreatedDate` on all 250 — leave `CreatedDate ≈ now`, so closing
  them yields a valid `≈ 0.00` day resolution. Numeric precision is proven in §6.1.
- Act: `Test.startTest();` update all 250 to `Status = 'Closed'` in **one** DML;
  `Test.stopTest();` (forces the Queueable to run).
- Assert:
  - all 250 Cases have a non-null `Resolution_Time_Days__c`;
  - each of the 5 Accounts has `Closed_Case_Count__c = 50`;
  - each Account's `Average_Resolution_Time_Days__c` is non-null and `< 0.01`;
  - `Assert.areEqual(1, Limits.getDmlStatements())` inside the window — the test's own update
    and **nothing else**. The trigger contributes zero DML however many records are in scope;
  - `Limits.getQueries()` inside the window is `<= 2` — the cached `CaseStatus` lookup does
    not repeat per record or per trigger pass;
  - **`Limits.getQueueableJobs()` equals `⌈250/200⌉ = 2`** — one job per DML chunk, *not* one
    per Case (250) and *not* one per Account (5). Assert against the chunk formula, not a
    literal. See the warning in §3.0.4: with 50 grouped Cases per Account, chunk 1 covers
    Accounts 1–4 and chunk 2 covers Account 5, so the two passes see **disjoint** Account
    sets and the dedupe correctly cannot merge them.

  > **Spec defect, corrected 2026-07-23.** An earlier draft asserted `1` here, which is
  > arithmetically impossible for 250 records and contradicted this spec's own §3.0.4
  > (which scoped the "1 Queueable" figure to "1 or 200 records"). Found during
  > implementation.

### 6.7 `CaseResolutionMetricsSecurityTest` (permission / negative test)

**Required by `.claude/rules/security.md`.** Create all users inside
`System.runAs(new User(Id = UserInfo.getUserId()))` to avoid `MIXED_DML_OPERATION`.

Three cases, and the choice of profile matters in each:

1. **Negative — minimum-access user, no permission set.** Profile
   `Minimum Access - Salesforce`. Assert `isAccessible() == false` for all four fields.
2. **Baseline — Standard User, no permission set.** Assert
   `Schema.SObjectType.Case.isAccessible() == true` (so object access is *not* the variable)
   but all four fields `isAccessible() == false`.
3. **Positive — Standard User **with** `CaseResolutionMetrics_Read`.** Assert:
   - `isAccessible() == true` for all four fields;
   - `isUpdateable() == false` for all four — **this is the assertion that proves derived
     values cannot be hand-edited** (AC8, D5c).

> **Spec defect, corrected 2026-07-23.** An earlier draft used the *minimum-access* user for
> the positive case too. That can never pass and contradicted §2.2 of this same document:
> §2.2 deliberately grants **no** `objectPermissions` (D5a, least privilege), and
> `Field.isAccessible()` is false whenever object access is missing regardless of FLS. No
> permission set of the specified shape could have satisfied it.
>
> Using a Standard User for cases 2 and 3 isolates the permission set as the **sole**
> variable, which is what AC8 actually claims. The minimum-access negative case is retained
> as case 1, so nothing is lost.

### 6.8 Batch tests

- `CaseResolutionBackfillBatchTest` — insert Cases, close some, **null out** their
  `Resolution_Time_Days__c` with the trigger bypassed to simulate pre-feature data, then run
  the batch inside `Test.startTest()/stopTest()`. Assert the values are restored and that
  `CaseTriggerHandler.enqueuedAccountIds` stayed empty (proving the bypass worked).
- `AccountCaseMetricsRecalcBatchTest` — corrupt an Account's metrics directly, run the batch,
  assert they are corrected.

### 6.9 Exact test command

```
sf apex run test \
  --tests TriggerHandlerTest,CaseSelectorTest,CaseResolutionServiceTest,CaseTriggerHandlerTest,AccountCaseRollupServiceTest,AccountCaseRollupQueueableTest,CaseResolutionMetricsSecurityTest,CaseResolutionBackfillBatchTest,AccountCaseMetricsRecalcBatchTest \
  --code-coverage --result-format human --wait 10
```

Required: **≥ 75%** org-wide, and every new class individually covered with meaningful
assertions. Record the test run id and per-class coverage in the Implementation Log.

---

## 7. Deployment plan

Reference: `.claude/rules/metadata-deployment.md`.

### 7.1 Confirm target and retrieve first

```
sf org display
```
Expect alias `demo`, `https://orgfarm-b6c5946ad2-dev-ed.develop.my.salesforce.com`, Connected.
⚠️ `IsSandbox = false` because it is a **Developer Edition** org (E2/C7) — this is a valid,
non-production target. Do not halt on that flag alone.

Retrieve the metadata being modified so org-side changes are not clobbered:
```
sf project retrieve start --metadata "Layout:Case-Case Layout","Layout:Case-Case (Support) Layout","Layout:Account-Account Layout","Layout:Account-Account (Support) Layout"
```
Diff the result before editing. If anything differs from what is in git, **stop and report**.

### 7.2 Validate (check-only) — REQUIRED before any real deploy

```
sf project deploy validate --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests TriggerHandlerTest --tests CaseSelectorTest --tests CaseResolutionServiceTest --tests CaseTriggerHandlerTest \
  --tests AccountCaseRollupServiceTest --tests AccountCaseRollupQueueableTest \
  --tests CaseResolutionMetricsSecurityTest --tests CaseResolutionBackfillBatchTest \
  --tests AccountCaseMetricsRecalcBatchTest \
  --wait 33
```
Repeat until clean. Record the validate id.

### 7.3 Deploy

```
sf project deploy start --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests TriggerHandlerTest --tests CaseSelectorTest --tests CaseResolutionServiceTest --tests CaseTriggerHandlerTest \
  --tests AccountCaseRollupServiceTest --tests AccountCaseRollupQueueableTest \
  --tests CaseResolutionMetricsSecurityTest --tests CaseResolutionBackfillBatchTest \
  --tests AccountCaseMetricsRecalcBatchTest \
  --wait 33
```
Or quick-deploy the validated id. Record the deploy id.

### 7.4 Confirm tests and coverage

Run §6.9. Record run id, pass/fail, per-class coverage.

### 7.5 Post-deploy — what NOT to do

- ❌ **Do not execute `CaseResolutionBackfillBatch`** (D6). It performs DML on real org data
  and needs the user's explicit approval. Note in the PR that it is deployed and idle, and
  that running it today would set the 23 dirty Cases to `null` and populate Account counts.
- ❌ **Do not assign** `CaseResolutionMetrics_Read` to any user or profile (D5a).
- ❌ **Do not** modify the seeded Case data to fix the `ClosedDate < CreatedDate` problem.

### 7.5b Two things found during implementation (2026-07-23)

**1. The fields are invisible to *everyone*, including System Administrators, until the
permission set is assigned.** A Metadata API field deploy grants FLS to no profile, and this
feature edits no profile by design (D5a). The immediate effect:

```
$ sf data query --query "SELECT COUNT(Id) FROM Case WHERE Resolution_Time_Days__c != null"
  ERROR: No such column 'Resolution_Time_Days__c' on entity 'Case'
```

even as the deploying admin. The fields **do** exist — confirmed via Tooling API
`FieldDefinition` (`Resolution_Time_Days__c`, `Number(8, 2)`). This is expected behaviour of
the chosen security posture, not a broken deploy, but it looks exactly like one. **Assign
`CaseResolutionMetrics_Read` (or grant yourself FLS) before concluding anything is wrong.**

**2. `--source-dir force-app` cannot validate or deploy in this repo.** 13 components that
pre-date this feature fail — 12 `Settings` plus `CleanDataService:DataCloudGeoLocation`, all
introduced by the `base org metadata` commit and none touched by this branch. The working
alternative is to deploy the feature's components explicitly by `--metadata`. This is a
**pre-existing repo defect that will block CI on every future change** and is worth fixing
separately; it is out of scope for this feature.

### 7.6 Destructive changes

**None.** No `destructiveChanges.xml` is part of this feature.

---

## 8. Acceptance criteria (Developer verifies each)

- [ ] **AC1** — Closing a Case populates `Case.Resolution_Time_Days__c` with calendar days to 2dp.
- [ ] **AC2** — The value is derived only; read-only FLS and `Readonly` on every layout it appears on.
- [ ] **AC3** — `Account.Closed_Case_Count__c` reflects all closed Cases ever for that Account (D3a).
- [ ] **AC4** — `Account.Average_Resolution_Time_Days__c` reflects the average of valid resolution
      times, **after the Queueable completes** (async lag is accepted, A1);
      `Case_Metrics_Last_Calculated__c` is stamped.
- [ ] **AC5** — Values stay correct across close, reopen, re-close, delete, undelete, and
      re-parent to a different Account.
- [ ] **AC6** — 250 Cases across 5 Accounts in one transaction: no governor failure, no
      per-record SOQL/DML, exactly one Queueable enqueued.
- [ ] **AC7** — Account aggregates are identical regardless of which user saved the Case
      (proved by the `System.runAs` determinism test, §6.3).
- [ ] **AC8** — With `CaseResolutionMetrics_Read` a minimum-access user can **read** all four
      fields and **cannot update** any of them; without it, none are accessible.
- [ ] **AC9** — A Case with no Account is stamped and causes no error or rollup corruption.
- [ ] **AC10** — Negative-duration Cases store `null`, count toward `Closed_Case_Count__c`, and
      are excluded from the average (verify against the 23 seeded Cases if the backfill is
      ever run).
- [ ] **AC11** — Org-wide Apex coverage ≥ 75% with meaningful assertions on every new class.
- [ ] **AC12** — Exactly one trigger exists on Case and it contains no business logic.
- [ ] **AC14** — The trigger performs **zero DML on Case**. Closing a Case inside
      `Test.startTest()`/`stopTest()` shows `Limits.getDmlStatements() == 1` (the caller's own
      update). No recursion guard is needed anywhere in `CaseTriggerHandler`.
- [ ] **AC15** — Editing an already-closed Case leaves `Resolution_Time_Days__c` **unchanged**
      (invariant 1). Saving a closed Case repeatedly must never move the number.
- [ ] **AC16** — Nothing hardcodes the string `'Closed'`. Closed statuses come from
      `CaseSelector.getClosedStatusLabels()`, and the `CaseStatus` query runs at most once per
      transaction.
- [ ] **AC13** — Nothing outside `force-app/**` + `docs/**` changed; no profile was edited; no
      permission set assignment was created.

---

## 9. Out of scope

- Any LWC / Aura component, custom tab, report type, dashboard, or list view.
- Business-hours-based durations (D1b = calendar; also blocked by C3 — `Case.BusinessHoursId`
  does not exist and the org's only Business Hours record is 24×7).
- First-response time, time-in-status, SLA-breach flags, per-agent or per-queue metrics.
- Rollups onto any object other than Account (Contact, Asset, parent-Account roll-through).
- Recomputation triggered by **Account merge** (R5) — Case triggers are not guaranteed to fire
  on merge-driven reparenting. Remediate by running `AccountCaseMetricsRecalcBatch` manually.
- **Executing** either batch (D6).
- Correcting the seeded `ClosedDate < CreatedDate` data (E32) — a data-quality task.
- Assigning `CaseResolutionMetrics_Read` to anyone (D5a).
- Adding the fields to the Sales/Marketing layouts or the Close Case layout.

---

## 10. Escalate — do not guess

Stop and return to the Architect/user if any of these are true:

- Any evidence in Research Spec §3 no longer holds (e.g. a Case trigger, validation rule, or
  record-triggered Flow now exists, or `Case.BusinessHoursId` has appeared).
- `CaseStatus` is not queryable, or `getClosedStatusLabels()` returns an empty set — the whole
  `before`-context design depends on it (§3.0.7).
- You find yourself needing a recursion guard, or needing to `update` a Case from within
  `CaseTriggerHandler`. That means the before/after split has been broken; re-read §3.0.
- `Decimal.valueOf(String.valueOf(ar.get('avgDays')))` throws, or `AVG()` on the new field
  behaves unexpectedly.
- `Test.setCreatedDate` does not affect the value the trigger reads from `Trigger.new`.
- Validation cannot reach 75% coverage without weakening assertions.
- Any step here would require editing a profile, deploying to a non-`demo` org, or running a
  batch against org data.
