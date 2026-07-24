# Implementation Log — Case Resolution Time & Account Case Metrics

- **Feature slug:** `case-resolution-time`
- **Related:** [Research Spec](../specs/case-resolution-time/research-spec.md) · [Technical Spec](../specs/case-resolution-time/technical-spec.md)

> Append-only, chronological audit trail. Both agents write here. Never rewrite history —
> add new entries. Include enough evidence that a human can reconstruct exactly what
> happened and why.

---

## 2026-07-23 — architect — Research phase

**Context / goal:** Design a way to track Case resolution time and surface aggregate case
metrics on Account, per the user's request.

**Actions & commands run:** Read-only org introspection — `sf org display`,
`sf sobject describe --sobject Case`, `--sobject Account`, `sf data query` against
`Organization`, `BusinessHours`, `Case`, `CaseHistory`, `PermissionSet`, `User`, plus Tooling
API queries for `ApexClass`, `ApexTrigger`, `ValidationRule`, and reads of local metadata
under `force-app/main/default/`.

**Findings / decisions:** Captured as evidence items E1–E36 in
[Research Spec §3](../specs/case-resolution-time/research-spec.md). Five options (A–E)
evaluated; **Option E** chosen — stored `Number` field on Case written by Apex, plus an Apex
aggregate rollup onto Account.

**Evidence:** Research Spec §3.1 evidence table.

**Open questions / blockers:** Seven blocking decisions D1–D7 recorded in Research Spec §4.3.
`AskUserQuestion` was unavailable in that session, so they were written up rather than asked.

**Status:** blocked (awaiting user)

---

## 2026-07-23 — architect — Re-verification of critical evidence

**Context / goal:** Before writing the Technical Spec, re-confirm the evidence the design
actually depends on, rather than trusting the earlier session's table wholesale.

**Actions & commands run:**
```
$ cat sfdx-project.json
  → sourceApiVersion = 61.0

$ ls force-app/main/default/classes/ force-app/main/default/triggers/
  → both empty  (confirms E14: no Apex, no TriggerHandler framework, no Case trigger)

$ ls force-app/main/default/permissionsets/
  → Experience_Profile_Manager.permissionset-meta.xml
    sfdcInternalInt__sfdc_scrt2.permissionset-meta.xml   (confirms E24: no support-agent set)

$ sf org display
  → alias=demo, apiVersion=67.0, connectedStatus=Connected,
    instanceUrl=https://orgfarm-b6c5946ad2-dev-ed.develop.my.salesforce.com

$ sf data query --query "SELECT Id, BusinessHoursId FROM Case LIMIT 1"
  → ERROR at Row:1:Column:12
    No such column 'BusinessHoursId' on entity 'Case'.

$ sf data query --query "SELECT Status, COUNT(Id) c FROM Case GROUP BY Status"
  → Closed: 23, New: 3

$ sf data query --query "SELECT Id, CaseNumber, CreatedDate, ClosedDate, IsClosed
                         FROM Case WHERE IsClosed = true LIMIT 5"
  → all rows: CreatedDate = 2026-07-20T13:24:36Z, ClosedDate = 2025-05-31T18:59:51Z

$ sf data query --query "SELECT Id,Name,IsActive,IsDefault,MondayStartTime,MondayEndTime,
                         SaturdayStartTime,SaturdayEndTime FROM BusinessHours"
  → 1 row: Default, IsActive=true, IsDefault=true, all times 00:00:00.000Z

$ grep -o "<label>[^<]*</label>" on the four target layout files
  → "System Information" section present in all four
```

**Findings / decisions:**
1. **`Case.BusinessHoursId` does not exist in the org.** This is stronger evidence than the
   earlier describe-absence: a direct SOQL reference errors. It confirms Entitlement
   Management is off and settles D1b.
2. **Repo-vs-org discrepancy confirmed and characterised.** The repo *does* contain
   `Case/fields/BusinessHoursId.field-meta.xml` (and `EntitlementId`, `SlaStartDate`,
   `SlaExitDate`, `MilestoneStatus`, `IsStopped`, `StopStartDate`, `IsClosedOnCreate`).
   `.claude/rules/data-model.md` makes the repo the source of truth, but here the repo is
   demonstrably stale — the live org rejects the column. Recorded explicitly in Technical
   Spec §0 as a "do not fix this" note so the Developer neither builds against those fields
   nor deletes the files.
3. **Dirty data re-confirmed.** All closed Cases still have `ClosedDate` ≈ 13.5 months before
   `CreatedDate`. A negative-duration guard is mandatory, not defensive coding.
4. **Business Hours is effectively 24×7** (every start time equals its end time), so a
   business-hours calculation would return numerically identical results to calendar time
   today — reinforcing D1b.
5. `System Information` exists on all four target layouts, so no new layout section is needed.

**Evidence:** command output above.

**Status:** done

---

## 2026-07-23 — architect — Blocking decisions resolved with the user

**Context / goal:** Close out D1–D7 via `AskUserQuestion` before writing the Technical Spec,
per CLAUDE.md Prime Directive 1 ("assume nothing").

**Actions & commands run:** Two rounds of `AskUserQuestion`, four questions each.

**Findings / decisions:**

| ID | Answer | Matched the research-spec recommendation? |
|----|--------|-------------------------------------------|
| D1b/D1c | Calendar time, unit = **DAYS**, `Number(10,2)` | ⚠️ **No** — the spec proposed hours. All field API names changed to `..._Days__c`. |
| D2 | Recalculate to the latest `ClosedDate`; clear while reopened | Yes |
| D3a | All closed Cases ever, unfiltered | Yes |
| D3b | Negative duration → store `null`; counted but not averaged | Yes |
| D4 | **Async via Queueable** | ⚠️ **No** — the spec recommended synchronous. |
| D5a | Create `CaseResolutionMetrics_Read`; assign to no one | Yes |
| D6 | Build the backfill batch, do not run it | Yes |
| D7 | Underscore-separated API names | Yes |

D3c (`Case_Metrics_Last_Calculated__c`) was **not** put to the user; it is carried forward
from the research-spec recommendation and flagged as such in Technical Spec §0 so it can be
dropped on request. Its value is higher now that D4 is async — it is the only way to
distinguish "rollup has not run yet" from "zero closed Cases".

**Two answers departed from the recommendations, and both changed the design:**
- **D1c (days, not hours)** — renames all four fields and every assertion.
- **D4 (Queueable, not synchronous)** — the larger change. It introduced four new
  consequences that the synchronous design did not have, each now carrying an explicit
  instruction in the Technical Spec: async lag on Account values (A1); rollup failure no
  longer rolls back the Case save (A2); `System.enqueueJob` limits become a real constraint,
  including the 1-per-Batch-`execute()` cap (A3); and higher cross-transaction row-lock
  contention (A4). Mitigations: per-transaction Account-Id dedupe with a synchronous
  fallback when no queueable slot remains, deterministic Id-sorted update order, and a
  bounded retry that only retries lock errors.

**Open questions / blockers:** None blocking. Two items for the user to note at review:
D3c was assumed-in rather than asked; and the user should decide whether to correct the
seeded `ClosedDate` data, since until they do every Account will show a non-zero closed-Case
count with a **blank** average.

**Status:** done

---

## 2026-07-23 — architect — Technical Spec written

**Context / goal:** Produce a Technical Spec the Developer can implement literally.

**Actions & commands run:** Wrote
`docs/specs/case-resolution-time/technical-spec.md` from
`docs/TEMPLATES/technical-spec-template.md`.

**Findings / decisions:** Design as specified:
- **4 fields** — `Case.Resolution_Time_Days__c` (Number 10,2);
  `Account.Closed_Case_Count__c` (Number 9,0);
  `Account.Average_Resolution_Time_Days__c` (Number 10,2);
  `Account.Case_Metrics_Last_Calculated__c` (DateTime).
- **9 Apex classes/triggers** — `TriggerHandler` (new project-standard base),
  `CaseTrigger` (after-only, logic-free), `CaseTriggerHandler`, `CaseResolutionService`,
  `AccountCaseRollupService` (`without sharing`, justified), `CaseSelector`,
  `AccountCaseRollupQueueable`, `AccountCaseMetricsRecalcBatch`,
  `CaseResolutionBackfillBatch`.
- **8 test classes + `TestDataFactory`.**
- **1 permission set** `CaseResolutionMetrics_Read`, read-only FLS, unassigned.
- **4 layouts modified**, `System Information` section, `behavior=Readonly`.
- Cost: 1 DML on Case + 1 Queueable per trigger transaction; the rollup is
  1 DML + ⌈n/500⌉ SOQL.

Design points worth a reviewer's attention:
- The resolution arithmetic is isolated in a **pure static method**
  (`calculateResolutionDays(Datetime, Datetime)`) specifically because `Case.CreatedDate` and
  `Case.ClosedDate` are `createable=false, updateable=false` and cannot be set by a test.
  Negative and boundary cases are unit-tested directly against that method; DML-based tests
  use `Test.setCreatedDate` and tolerance assertions.
- `AVG()` is read via `Decimal.valueOf(String.valueOf(...))` rather than a hard `(Decimal)`
  cast, because the aggregate may surface as `Double`.
- The trigger is **after-only** on purpose — `ClosedDate` population timing inside a `before`
  context could not be verified read-only, so the design avoids depending on it.
- `without sharing` on the rollup service is a deliberate, documented exception to
  `.claude/rules/security.md`: a user-mode aggregate would make the stored average depend on
  who clicked Save (AC7). The security boundary is moved to the read side instead.

**Evidence:** [Technical Spec](../specs/case-resolution-time/technical-spec.md).

**Open questions / blockers:** Awaiting human review/approval before `/develop`.

**Status:** done — **awaiting user approval**

**Guardrail confirmation:**
```
$ git status --short
?? docs/TEST-SCENARIO.md
?? docs/implementation-log/case-resolution-time.md
?? docs/specs/case-resolution-time/

$ git status --short -- force-app/
(no output)
```
**Zero files created or modified under `force-app/**` by the Architect.**

---

## 2026-07-23 — architect — Added call graph & runtime flow (§3.0)

**Context / goal:** User asked, before implementation, for an explicit map of how the classes
call one another and how the automation flows.

**Actions & commands run:** Added **§3.0 "Call graph & runtime flow"** to the Technical Spec,
ahead of the per-class specifications.

**Findings / decisions:** Documenting the flow surfaced three invariants that were implicit
in the per-class specs and are now stated explicitly, because breaking any of them produces
a silent wrong answer rather than a compile error:

1. **The stamp DML must precede the rollup dispatch.** The Queueable aggregates
   `Resolution_Time_Days__c` *from the database*. If the enqueue were moved above the
   `update` in `handle()`, T2 would average pre-update values. Order is now fixed and stated:
   stamp → collect Account Ids → dispatch.
2. **`isStampingResolution` must be reset in a `finally`.** If an exception escaped with the
   flag still `true`, every subsequent Case trigger in that transaction would silently no-op.
3. **`CaseResolutionService` must stay pure** — no SOQL, no DML, no `System.now()`. This is
   the only reason the negative-duration and rounding cases are unit-testable at all, since
   `CreatedDate`/`ClosedDate` cannot be set on a record.

Also confirmed while tracing: the synchronous fallback (A3) is still correct even though it
runs before T1 commits, because SOQL within a transaction sees that transaction's own
uncommitted DML. And the chain **terminates** at the Account `update` — no Account trigger,
record-triggered Flow, or validation rule exists in this org (E15/E17), so there is no
cascade back into Case.

Contents: static dependency graph, a per-class "may call / must not call" table, a two-
transaction runtime trace including the re-entrant pass, the per-context behaviour matrix,
governor cost, and the manual repair path.

**Evidence:** [Technical Spec §3.0](../specs/case-resolution-time/technical-spec.md).

**Status:** done — still awaiting user approval before `/develop`

---

## 2026-07-23 — architect — Design correction: stamp moved to a `before` trigger

**Context / goal:** On reviewing the call graph the user challenged the design directly:
*"why is the DML refiring the trigger — shouldn't there be a trigger guard that doesn't allow
that?"* The challenge was correct and the design has changed.

**Actions & commands run:**
```
$ sf data query --query "SELECT MasterLabel, IsClosed, IsDefault, SortOrder
                         FROM CaseStatus ORDER BY SortOrder"
  New        false  true   1
  Working    false  false  2
  Escalated  false  false  3
  Closed     true   false  4
```

**Findings / decisions:**

Two separate points were tangled in the question, and the second one exposed a genuine
weakness:

1. **A guard cannot prevent a trigger from firing.** `isStampingResolution` did exist and did
   work, but Salesforce fires triggers on every DML unconditionally — no Apex flag suppresses
   the *firing*, only the *work* done by the re-entrant invocation. So the guard was not
   missing; it was simply the ceiling of what a guard can do.
2. **The self-DML should not have existed at all.** Stamping a field on the record being saved
   is textbook `before`-trigger work: mutate `Trigger.new` in memory, zero DML, nothing to
   re-enter, no guard required. The previous design took an unnecessary detour.

**Why the original detour was taken, and why it was wrong.** R4 in the Research Spec noted
that `Case.ClosedDate`/`IsClosed` are platform-derived and not reliably populated inside a
`before` context — a real gotcha. But that only bites if the design *depends on those fields*
in the before context, and it need not. `CaseStatus` is a queryable standard object exposing
`IsClosed` per Status value (verified above), so closed-ness can be derived from `Status` —
which is the user's own input and always present in `Trigger.new` — and the close instant is
`System.now()`. R4 was allowed to dictate the architecture when it should only have dictated
which fields to read.

**Is `System.now()` faithful?** Yes at this precision. It differs from the platform's
`ClosedDate` by the milliseconds of the save; the field is `Number(10,2)` in **days**, where
`0.01` = 14.4 minutes. It is also arguably closer to the truth: `ClosedDate` is
`createable=false, updateable=false`, so `Status` is the sole cause of a Case closing.

**Revised design:**
- `CaseTrigger` gains `before insert, before update` alongside the existing after contexts.
- Stamping → `before`, via `CaseResolutionService.applyResolutionTimes(newCases, oldMap,
  closedStatuses, nowInstant)`, mutating `Trigger.new` in place.
- Rollup dispatch → unchanged, still in the `after` contexts (where `IsClosed`/`ClosedDate`
  are committed and safe to read).
- `isStampingResolution` **deleted**. `TriggerHandler.MAX_RUNS` remains as a generic safety net.
- `CaseSelector.getClosedStatusLabels()` added — statically cached, 1 SOQL per transaction.
- `CaseResolutionService` keeps both a live variant (`applyResolutionTimes`, injected `now`)
  and a stored variant (`buildResolutionUpdates`, reads `ClosedDate`) for the backfill batch,
  sharing one pure `calculateResolutionDays`.

**New invariant discovered while reworking this — the most important correctness rule in the
feature.** With `System.now()` as the close instant, the stamp must fire **only on a
transition into a closed Status**, never on every save of an already-closed Case. Otherwise
each subsequent edit to a closed Case would push the close instant forward and silently
inflate the number. Encoded as invariant 1 (§3.0.6), given a dedicated row in the
`applyResolutionTimes` transition matrix (§6.1), an end-to-end test (§6.2), and **AC15**.
This mirrors the platform, which does not rewrite `ClosedDate` on unrelated edits either.

**Net effect on governor cost:** T1 goes from *1 DML + 0 SOQL* to *0 DML + 1 cached SOQL*.
A good trade twice over — DML is the scarcer limit (150 vs 100), and a DML on Case re-enters
the trigger whereas a SOQL does not.

**Also updated:** Research Spec R4 marked superseded with the reasoning; R3 (re-entrancy) is
now dissolved rather than mitigated, since there is no DML on Case to recurse on. Added
`CaseSelectorTest` (9 test classes now). Added AC14/AC15/AC16 and four new items to the rules
compliance checklist, including "no recursion flag in `CaseTriggerHandler` — if you felt the
need for one, something is doing DML that shouldn't be."

**Open questions / blockers:** None.

**Status:** done — still awaiting user approval before `/develop`

---

## Deploy & test record

| Date | Command | Target org | Result | Deploy/Test Id | Coverage |
|------|---------|-----------|--------|----------------|----------|
| 2026-07-23 | `sf project deploy validate` (`--source-dir force-app`) | demo | ❌ Failed — 13 pre-existing baseline components, 0 tests run | `0Afg500000CSImHCAX` | — |
| 2026-07-23 | `sf project deploy validate` (targeted, un-encoded layouts) | demo | ❌ Failed — layout names need `%28`/`%29` | `0Afg500000CSJ41CAH` | — |
| 2026-07-23 | `sf project deploy validate` (targeted, encoded) | demo | ❌ Failed — 28/28 components OK; 68/71 tests (spec test-plan defects T1/T2/T3) | `0Afg500000CSJ8rCAH` | — |
| 2026-07-23 | `sf project deploy validate` (after T1/T2/T3 fixes) | demo | ✅ Succeeded — 72/72 tests | `0Afg500000CSJGvCAP` | — |
| 2026-07-23 | `sf project deploy quick --job-id 0Afg500000CSJGvCAP` | demo | ✅ Succeeded — 28 components | `0Afg500000CSJNNCA5` | — |
| 2026-07-23 | `sf apex run test --code-coverage` | demo | ✅ 72 ran / 72 passed / 0 failed | `707g500000asxlL` | **93% org-wide**; per-class 83–100% |

---

## 2026-07-23 — developer — Implementation, validation & deploy

**Context / goal:** Implement the approved Technical Spec literally on a feature branch,
validate check-only, deploy to `demo`, run the specified tests, and open a PR.

### Branch & target org

```
$ git checkout main && git pull --ff-only origin main
  → Already up to date.
$ git checkout -b feature/case-resolution-time
  → Switched to a new branch 'feature/case-resolution-time'

$ sf org display
  Alias            demo
  Api Version      67.0
  Connected Status Connected
  Id               00Dg500000G0Yq5EAF
  Instance Url     https://orgfarm-b6c5946ad2-dev-ed.develop.my.salesforce.com
```
Confirmed the intended Developer Edition org per Technical Spec §7.1 / research-spec E2/C7.
`IsSandbox = false` is expected for Developer Edition and is **not** a halt condition.

### Re-verification of the §10 escalation triggers (all still hold)

```
$ sf data query --query "SELECT MasterLabel, IsClosed, IsDefault, SortOrder FROM CaseStatus ORDER BY SortOrder"
  New false true 1 / Working false false 2 / Escalated false false 3 / Closed true false 4
$ sf data query --use-tooling-api --query "SELECT Name, TableEnumOrId FROM ApexTrigger WHERE NamespacePrefix = null"   → 0 records
$ sf data query --use-tooling-api --query "SELECT ValidationName, ... FROM ValidationRule"                             → 0 records
$ sf data query --use-tooling-api --query "SELECT Name FROM ApexClass WHERE NamespacePrefix = null"                    → 0 records
```
`CaseStatus` is queryable and returns exactly one closed status, so the `before`-context
design (§3.0.7) is valid. No pre-existing Case trigger, validation rule, or Apex.

### Retrieve-before-change (§7.1)

```
$ sf project retrieve start --metadata "Layout:Case-Case Layout" --metadata "Layout:Case-Case (Support) Layout" \
                            --metadata "Layout:Account-Account Layout" --metadata "Layout:Account-Account (Support) Layout"
  → Succeeded, 4 layouts
$ git status --short -- force-app/
  → (no output)
```
**No drift** — the retrieved layouts were byte-identical to git, so nothing org-side was
clobbered.

### Files created / changed

**Custom fields (4, new)**
- `objects/Case/fields/Resolution_Time_Days__c.field-meta.xml` — Number(10,2)
- `objects/Account/fields/Closed_Case_Count__c.field-meta.xml` — Number(9,0)
- `objects/Account/fields/Average_Resolution_Time_Days__c.field-meta.xml` — Number(10,2)
- `objects/Account/fields/Case_Metrics_Last_Calculated__c.field-meta.xml` — DateTime

**Permission set (1, new)** — `permissionsets/CaseResolutionMetrics_Read.permissionset-meta.xml`
(field read-only on all four; no object/Apex/user permissions; assigned to no one).

**Layouts (4, modified)** — one `<layoutItems>` with `<behavior>Readonly</behavior>` appended
to the last `<layoutColumns>` of the existing `System Information` section on
`Case-Case Layout`, `Case-Case (Support) Layout`, `Account-Account Layout`,
`Account-Account (Support) Layout`. Sales/Marketing and `CaseClose-Close Case Layout`
untouched, per D5b.

**Apex (8 production classes + 1 trigger, new)** — `TriggerHandler`, `CaseSelector`,
`CaseResolutionService`, `AccountCaseRollupService`, `AccountCaseRollupQueueable`,
`CaseTriggerHandler`, `AccountCaseMetricsRecalcBatch`, `CaseResolutionBackfillBatch`,
`CaseTrigger`. All `*-meta.xml` at `<apiVersion>61.0</apiVersion>`.

**Apex tests (1 factory + 9 test classes, new)** — `TestDataFactory`, `TriggerHandlerTest`,
`CaseSelectorTest`, `CaseResolutionServiceTest`, `CaseTriggerHandlerTest`,
`AccountCaseRollupServiceTest`, `AccountCaseRollupQueueableTest`,
`CaseResolutionMetricsSecurityTest`, `CaseResolutionBackfillBatchTest`,
`AccountCaseMetricsRecalcBatchTest`.

### §3.10 rules-compliance self-check (all verified by grep before validating)

- No SOQL/DML in any loop; all SOQL confined to `CaseSelector` (+ the two batch locators).
- **Zero DML on Case in the trigger path** — grep for `insert|update|delete` in
  `CaseTriggerHandler`, `CaseResolutionService`, `CaseSelector` returns nothing.
  Asserted at runtime by `triggerPerformsNoDmlOnCase` and the bulk test.
- **No recursion/re-entrancy flag** in `CaseTriggerHandler`. `TriggerHandler.MAX_RUNS`
  remains as the generic safety net, which also satisfies `.claude/rules/triggers.md`'s
  recursion-control requirement — so that rule and invariant 2 do **not** conflict.
- `IsClosed`/`ClosedDate` are never read in a `before` context; only in `after` contexts and
  in `buildResolutionUpdates` (backfill, committed records).
- The literal `'Closed'` appears nowhere outside test code.
- No `@AuraEnabled`, no hardcoded Ids/URLs/credentials, `@TestVisible` used throughout.

### Deviations from the Technical Spec — all deliberate, none affecting the design

| # | Spec text | What was done | Why |
|---|---|---|---|
| **V1** | §7.2/§7.3 deploy `--source-dir force-app` | Deployed the **28 feature components explicitly by `--metadata`** | A whole-directory deploy fails on **13 pre-existing components** in the `base org metadata` commit (802baa6) that have nothing to do with this feature: `Settings:Analytics/Campaign/Communities/EinsteinAI/EmailAdministration/EmployeeUser/EncryptionKey/IdentityProvider/Pardot/PlatformEncryption/SceGlobalModelOptOut/Territory2` and `CleanDataService:DataCloudGeoLocation`. Verified untouched by me via `git status --short -- force-app/main/default/settings/` (empty). Same components, narrower scope — no design change. Validate id `0Afg500000CSImHCAX` records the failure. |
| **V2** | §3.7 `public class AccountCaseRollupQueueable` (no sharing keyword) | Declared `public inherited sharing class` | §3.10 mandates "sharing keyword present and deliberate on **every** class". Behaviour-neutral: the class does no SOQL/DML of its own and `AccountCaseRollupService` is `without sharing`, which governs the actual data access. |
| **V3** | §3.0.1 call graph shows `buildResolutionUpdates(List<Case>, Set<String>)` | Implemented the **1-argument** form | §3.4's code block, §3.4's described behaviour (reads `c.IsClosed`, needs no status set) and §3.9's call site `buildResolutionUpdates((List<Case>) scope)` all specify one argument. The call-graph diagram is the lone outlier. |
| **V4** | §3.8/§3.9 batches, sharing unspecified | Both declared `with sharing` | `.claude/rules/apex.md` default, and §3.10 says "**the one** `without sharing`" — singular — so only `AccountCaseRollupService` may carry it. |

### Deviations from the Technical Spec's TEST PLAN — three genuine spec defects, flagged for review

These three are **spec errors, not implementation choices**. Each is documented in a comment
at the assertion site. No assertion was weakened to make a test pass.

| # | Spec text | Problem | Resolution |
|---|---|---|---|
| **T1** | §6.6: `Assert.areEqual(1, Limits.getQueueableJobs())` for **250** Cases across 5 Accounts | Arithmetically impossible. The platform processes a DML statement in chunks of **200**, so the trigger fires **twice** (200 + 50) over **disjoint** Account sets (1–4, then 5). The dedupe cannot merge passes that never overlap. The spec's own governor table §3.0.4 scopes the "1 Queueable" figure to "1 or 200 records". Observed: 2. | Assert **2** (= one job per 200-record DML chunk) plus `jobs < accounts.size()`, with the reasoning in-line. The dedupe invariant the spec wanted is proven separately and exactly by `repeatedDispatchesForTheSameAccountAreDeduped` (2 DML on the same Account → **1** job). **Design is correct; only the spec's expected number was wrong.** |
| **T2** | §6.7: after assigning `CaseResolutionMetrics_Read`, a **minimum-access** user can read all four fields | Self-contradictory with §2.2. `Field.isAccessible()` is false whenever **object** access is missing, whatever the FLS. Verified: `Minimum Access - Salesforce` has **no** `ObjectPermissions` row for Case or Account, and §2.2 deliberately grants no `objectPermissions` (D5a). So no permission set of this shape could ever make that assertion true. | Positive FLS test now runs as a **Standard User** (verified Case+Account Read/Edit, but **no** FLS on the four new fields since no profile was edited) — isolating the permission set as the sole cause of field readability, which is what AC8 actually asserts. The minimum-access **negative** test is kept unchanged, and a third test asserts a Standard User *without* the set still cannot see the fields. |
| **T3** | §6.3: determinism test runs as a user "who can see none of the Cases" | Impossible in this org. Case OWD is **`ReadWriteTransfer`** (research-spec E22) — public read/write — so every user with Case access sees every Case. Observed: the user saw all 2. | Removed that invented precondition; kept the determinism assertion AC7 actually requires (identical stored count/average regardless of running user). Noted in-line that `without sharing` remains the correct defence if Case OWD is ever tightened to Private, at which point this test would start genuinely exercising the sharing difference. |

### Known coverage gap (documented, not worked around)

`AccountCaseRollupQueueable` lines 47–49 (`retryScheduled = true`, the `!Test.isRunningTest()`
guard, and the chained `System.enqueueJob`) are uncovered: reaching them requires a genuine
`UNABLE_TO_LOCK_ROW`, which cannot be produced deterministically in an Apex test, and the
spec itself forbids the chain from executing under `Test.isRunningTest()`. The retry
*decision* is fully covered by `isRetryableRecognisesOnlyLockErrors` (lock/lowercase/ROW_LOCK
→ true; validation error and null → false), and both non-retryable exits are covered.
Class coverage is still **86%**.

### Validate (check-only)

```
$ sf project deploy validate --metadata <28 components> --test-level RunSpecifiedTests \
    --tests TriggerHandlerTest --tests CaseSelectorTest --tests CaseResolutionServiceTest \
    --tests CaseTriggerHandlerTest --tests AccountCaseRollupServiceTest \
    --tests AccountCaseRollupQueueableTest --tests CaseResolutionMetricsSecurityTest \
    --tests CaseResolutionBackfillBatchTest --tests AccountCaseMetricsRecalcBatchTest --wait 33
```

| Attempt | Validate Id | Result |
|---|---|---|
| 1 (`--source-dir force-app`, per spec) | `0Afg500000CSImHCAX` | **Failed** — 13 pre-existing baseline components (see V1). Zero test runs. |
| 2 (targeted, layout names un-encoded) | `0Afg500000CSJ41CAH` | **Failed** — parenthesised layout names need `%28`/`%29`. |
| 3 (targeted, encoded) | `0Afg500000CSJ8rCAH` | **Failed** — 28/28 components fine; **68/71 tests passed**, 3 failures = defects T1/T2/T3 above. |
| 4 (after T1/T2/T3 fixes) | **`0Afg500000CSJGvCAP`** | ✅ **Succeeded — 72/72 tests passing, 0 failures.** |

### Deploy

```
$ sf project deploy quick --job-id 0Afg500000CSJGvCAP --wait 33
  → Successfully deployed (0Afg500000CSJNNCA5).
```
**Deploy Id: `0Afg500000CSJNNCA5`** — 28 components to org alias `demo`.

### Tests & coverage (§6.9)

```
$ sf apex run test --tests TriggerHandlerTest,CaseSelectorTest,CaseResolutionServiceTest,\
CaseTriggerHandlerTest,AccountCaseRollupServiceTest,AccountCaseRollupQueueableTest,\
CaseResolutionMetricsSecurityTest,CaseResolutionBackfillBatchTest,AccountCaseMetricsRecalcBatchTest \
    --code-coverage --result-format human --wait 10
```

**Test Run Id `707g500000asxlL` — 72 ran, 72 passed, 0 failed, 100% pass rate.
Org-Wide Coverage: 93%.**

| Class | Coverage | Uncovered |
|---|---|---|
| `CaseTrigger` | **100%** | — |
| `CaseSelector` | **100%** | — |
| `AccountCaseRollupService` | **100%** | — |
| `AccountCaseMetricsRecalcBatch` | **100%** | — |
| `CaseResolutionBackfillBatch` | **100%** | — |
| `CaseResolutionService` | **98%** | 64 (null-`closedStatuses` defensive fallback) |
| `CaseTriggerHandler` | **95%** | 85, 132–133 (no-queueable-slot sync fallback, A3) |
| `AccountCaseRollupQueueable` | **86%** | 47–49 (lock-retry chain — see gap above) |
| `TriggerHandler` | **83%** | unused `beforeDelete`/other virtual no-op bodies |

Every class exceeds the 75% bar; org-wide 93% ≫ 75%.

### Acceptance criteria verification

| AC | Verdict | Evidence |
|---|---|---|
| AC1 | ✅ | `closingAnAgedCaseStampsResolutionTime` — Case aged 3 days stamps ≈3.00 (tolerance <0.01). |
| AC2 | ✅ | `FieldPermissions` in org: all four `PermissionsRead=true, PermissionsEdit=false`; all four layout items `<behavior>Readonly</behavior>`. |
| AC3 | ✅ | `closingACaseRollsUpToTheAccount`, `multipleAccountsAreAggregatedIndependently`; selector filters on `IsClosed = true` only (D3a). |
| AC4 | ✅ | Average asserted post-`Test.stopTest()`; `Case_Metrics_Last_Calculated__c` non-null in every rollup test. |
| AC5 | ✅ | Dedicated tests for close, reopen, re-close, delete, undelete, re-parent (both Accounts updated). |
| AC6 | ⚠️ ✅ | 250 Cases / 5 Accounts, one DML: **1 DML**, **≤2 SOQL**, no governor failure, all 250 stamped, each Account = 50. Queueables = **2, not the 1 the spec predicted** — see defect T1; the design is correct, the spec's number was not. |
| AC7 | ✅ | `aggregatesAreIdenticalRegardlessOfTheRunningUser` — identical stored values as admin and as another user. Caveat T3: Case OWD is public, so this cannot currently differ by user anyway. |
| AC8 | ✅ | Three tests: no perm set + min access → inaccessible; no perm set + object access → still inaccessible; with perm set → readable **and `isUpdateable()` false on all four**. See defect T2 for the subject-profile change. |
| AC9 | ✅ | `caseWithNoAccountIsStampedAndCausesNoRollup` — orphan Case stamped ≈4.00, **0** jobs enqueued. |
| AC10 | ✅ | `calculateResolutionDaysReturnsNullWhenClosedPrecedesCreated` (−410 days → null); `nullResolutionCasesAreCountedButNotAveraged` (counted, excluded from average). |
| AC11 | ✅ | 93% org-wide; every new class covered with behavioural assertions. |
| AC12 | ✅ | `SELECT Name, TableEnumOrId FROM ApexTrigger` → exactly one row, `CaseTrigger` on `Case`. Body is a single `new CaseTriggerHandler().run();`. |
| AC13 | ✅ | `git status` shows changes only under `force-app/**` and `docs/**`; `git status -- force-app/main/default/profiles/` empty; `SELECT COUNT(Id) FROM PermissionSetAssignment WHERE PermissionSet.Name = 'CaseResolutionMetrics_Read'` → **0**. |
| AC14 | ✅ | `triggerPerformsNoDmlOnCase` and the bulk test both assert `Limits.getDmlStatements() == 1`. `runCountsRecordExactlyOneBeforeAndOneAfterPass` asserts exactly 2 handler runs — never a third. |
| AC15 | ✅ | `editingAnAlreadyClosedCaseLeavesTheValueUnchanged` — two further saves of a closed Case leave the number identical; plus the `Closed→Closed` row of the unit transition matrix (seeded 99.99, still 99.99). |
| AC16 | ✅ | grep: no `'Closed'` literal outside tests; `getClosedStatusLabelsIsStaticallyCached` asserts the 2nd call adds **0** SOQL; bulk test asserts ≤2 queries for 250 records. |

### Post-deploy guardrails honoured (§7.5)

```
$ sf data query --query "SELECT ApexClass.Name, Status, JobType FROM AsyncApexJob
                         WHERE ApexClass.Name IN ('CaseResolutionBackfillBatch','AccountCaseMetricsRecalcBatch')"
  → 0 records
$ sf data query --query "SELECT COUNT(Id) FROM PermissionSetAssignment
                         WHERE PermissionSet.Name = 'CaseResolutionMetrics_Read'"
  → 0
$ sf data query --query "SELECT Status, COUNT(Id) c FROM Case GROUP BY Status"
  → Closed 23, New 3   (unchanged from research-spec E31)
```
- ❌ Neither batch executed — both deployed **idle** (D6).
- ❌ Permission set assigned to **nobody** (D5a).
- ❌ No profile edited; seeded `ClosedDate < CreatedDate` data left exactly as found.

### ⚠️ Operational finding for the user — the fields are invisible to everyone right now

Deploying a custom field via the Metadata API grants FLS to **no profile**, including System
Administrator, and this feature edits no profile by design. Consequence, verified live:

```
$ sf data query --query "SELECT COUNT(Id) FROM Case WHERE Resolution_Time_Days__c != NULL"
  → ERROR: No such column 'Resolution_Time_Days__c' on entity 'Case'
$ sf data query --use-tooling-api --query "SELECT QualifiedApiName, DataType FROM FieldDefinition WHERE ..."
  → Average_Resolution_Time_Days__c Number(8,2) / Case_Metrics_Last_Calculated__c Date/Time
    Closed_Case_Count__c Number(9,0) / Resolution_Time_Days__c Number(8,2)
```
The fields **exist and are correct** (Tooling API above; `Number(8,2)` is how the platform
renders `precision=10, scale=2` — 8 integer + 2 decimal digits, exactly as §2.1 specifies).
The SOQL error is FLS, not absence. Apex writes them fine because it runs in system mode.
**To see them in the UI, assign `CaseResolutionMetrics_Read`** — which per D5a the Developer
deliberately did not do. This is expected behaviour, but it will look like a broken deploy to
anyone who checks a record page first, so it is called out here and in the PR.

**Status:** done — validate `0Afg500000CSJGvCAP`, deploy `0Afg500000CSJNNCA5`,
test run `707g500000asxlL`, 72/72 passing, 93% org-wide coverage.

### Branch & PR

- **Branch:** `feature/case-resolution-time` (cut from up-to-date `main`, commit `3645a90`)
- **PR:** https://github.com/rehans11/DemoDev/pull/1 — opened against `main`, **left for human review, not merged**

**Status:** done — awaiting human review and merge.

---

## 2026-07-23 — architect — Post-implementation verification & spec corrections

**Context / goal:** Independently verify the Developer's report rather than relaying it, and
fix the spec defects it surfaced so the documents and the code agree.

**Actions & commands run:**
```
$ git log --oneline main..HEAD          → 2 commits on feature/case-resolution-time
$ git log --oneline -1 main             → main unmoved
$ gh pr list --state all                → PR #1 OPEN, base main, mergedAt: null
$ git diff --name-only main..HEAD -- force-app/   → 47 files, all expected

$ sf apex run test --tests <9 classes> --code-coverage --wait 20
  → Test Run Id 707g500000atJf0 · 72 ran / 72 passed / 0 failed · Org Wide Coverage 93%

$ sf data query --query "SELECT ApexClass.Name, JobType, Status FROM AsyncApexJob
                         WHERE ApexClass.Name IN ('CaseResolutionBackfillBatch',
                                                  'AccountCaseMetricsRecalcBatch')"
  → 0 records                            (neither batch was ever executed — D6 respected)

$ sf data query --query "SELECT COUNT(Id) FROM PermissionSetAssignment
                         WHERE PermissionSet.Name = 'CaseResolutionMetrics_Read'"
  → 0                                    (D5a respected)

$ sf data query --use-tooling-api --query "SELECT QualifiedApiName, DataType FROM
    FieldDefinition WHERE EntityDefinition.QualifiedApiName = 'Case'
    AND QualifiedApiName = 'Resolution_Time_Days__c'"
  → Resolution_Time_Days__c · Number(8, 2)   (precision 10 / scale 2 = 8 integer + 2 decimal)
```

Source inspection of `CaseTrigger`, `CaseResolutionService`, `CaseTriggerHandler`, plus greps
for DML on Case, recursion flags, hardcoded `'Closed'`, and `PermissionSetAssignment`.

**Findings — all four invariants verified in the shipped code:**

| Invariant | Verified |
|---|---|
| 1 — stamp only on transition; `Closed → Closed` untouched | ✅ the `else` branch is present in `applyResolutionTimes` with its rationale comment |
| 2 — zero DML on Case in the trigger path | ✅ grep finds DML keywords only inside comments; `triggerPerformsNoDmlOnCase` test passes |
| 3 — `CaseResolutionService` pure | ✅ no SOQL/DML/`System.now()`; both dependencies injected |
| 4 — no `IsClosed`/`ClosedDate` in a `before` context | ✅ read only in `dispatchRollup` (after) and `buildResolutionUpdates` (batch) |

Also verified: no recursion flag anywhere; `'Closed'` never hardcoded outside tests;
`TestDataFactory` correctly `@isTest`; sharing keyword present on every class.

**Three spec defects confirmed as genuine — all mine, all found by the Developer:**

1. **§6.6 asserted 1 Queueable for 250 Cases; the correct answer is 2.** DML processes in
   200-record chunks, so the trigger fires twice over *disjoint* Account sets (1–4, then 5)
   and the dedupe cannot merge passes that never overlap. My own §3.0.4 had scoped the
   "1 Queueable" figure to "1 or 200 records" — the test contradicted the spec's own table.
   **Fixed:** §3.0.4 now states the `⌈m/200⌉` rule explicitly; §6.6 asserts the formula.
2. **§6.7 contradicted §2.2.** It required a *minimum-access* user to read the fields once
   granted the permission set, but §2.2 deliberately grants no `objectPermissions`, and
   `Field.isAccessible()` is false whenever object access is missing regardless of FLS. No
   permission set of that shape could ever have satisfied it. **Fixed:** three explicit
   cases — minimum-access negative, Standard User baseline, Standard User + permission set
   positive — isolating the permission set as the sole variable. The Developer's
   implementation is *stronger* than the original spec, not weaker.
3. **§6.3's determinism precondition was unsatisfiable.** Case OWD is `ReadWriteTransfer`
   (E22), so no user can "see none of the Cases" for sharing reasons. **Fixed**, and the
   consequence recorded: `without sharing` on `AccountCaseRollupService` is currently
   **belt-and-braces, not load-bearing**. It becomes load-bearing only if Case OWD is
   tightened to Private/Public Read Only. Keyword and justification retained — the risk is
   real but latent.

**Two operational findings added to §7.5b:**
- The new fields are invisible to **everyone including System Administrators** until
  `CaseResolutionMetrics_Read` is assigned — a Metadata API field deploy grants FLS to no
  profile, and this feature edits none by design. `SELECT Resolution_Time_Days__c FROM Case`
  errors with *"No such column"* for the deploying admin. Expected, but indistinguishable
  from a broken deploy at a glance.
- `--source-dir force-app` cannot validate in this repo: 13 pre-existing components (12
  `Settings` + `CleanDataService:DataCloudGeoLocation`) from the `base org metadata` commit
  fail, none touched by this branch. **Pre-existing repo defect that will block CI on every
  future change**; out of scope here, worth fixing separately.

**Accepted deviations (behaviour-neutral, logged by the Developer):**
`AccountCaseRollupQueueable` given `inherited sharing` (§3.10 requires a keyword on every
class); `buildResolutionUpdates` built in its 1-arg form per §3.4/§3.9 (the §3.0.1 diagram
showed 2 args and was the outlier); both batches `with sharing` (§3.10 says "*the one*
`without sharing`").

**Known coverage gap, documented rather than worked around:**
`AccountCaseRollupQueueable` at 86% — lines 47–49 need a real `UNABLE_TO_LOCK_ROW`, which is
not deterministically producible in Apex, and the spec itself forbids the retry chain from
running under test. The retry *decision* is fully covered via the `retryScheduled` flag.

**Status:** done — implementation verified, PR #1 open and unmerged, awaiting human review

---
