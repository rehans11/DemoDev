# Research Spec — Case Resolution Time & Account Case Metrics

- **Feature slug:** `case-resolution-time`
- **Author:** salesforce-architect
- **Date:** 2026-07-23
- **Status:** ✅ Decisions D1–D7 answered by the user 2026-07-23 — see §4.4
- **Related:** [Technical Spec](./technical-spec.md) · [Implementation Log](../../implementation-log/case-resolution-time.md)

> **Reviewer note:** The `AskUserQuestion` tool was not available in the session that wrote
> this document, so the clarifying questions were captured as **blocking decisions D1–D7**
> in §4.3 with a recommended answer each. **They have since been put to the user and
> answered — see §4.4.** Two answers departed from the recommendation (**D1c: days, not
> hours**; **D4: Queueable, not synchronous**), so field names and the rollup mechanism in
> §3.2 and §6.2 below are superseded.
>
> ⚠️ **Where this document and the Technical Spec disagree, the
> [Technical Spec](./technical-spec.md) wins.** It is written against the actual answers.

---

## 1. Problem statement

Support leadership cannot currently answer "how long does it take us to resolve a Case?"
or "how is this Account trending on support?" There is no field on `Case` that stores a
resolution duration, and no aggregated view on `Account`.

Verbatim request:

> "Track how long it takes us to resolve Cases. When a Case is closed I want to see the
> resolution time on the Case itself, and I want to see on the Account how many Cases have
> been closed and what the average resolution time is. Support agents should be able to
> see this."

Restated precisely:

1. When a Case reaches a closed state, store a **resolution duration** on that Case record.
2. On the related **Account**, store (a) a **count of closed Cases** and (b) the
   **average resolution duration** across those Cases.
3. **Support agents** must be able to *read* these values (read, not write — they are
   derived values, so write access would corrupt them).

Business value: enables SLA reporting, per-Account support-load visibility for agents on
the Account page, and a baseline for measuring support process improvement.

---

## 2. Acceptance criteria

- [ ] AC1 — Closing a Case populates a resolution-duration field on that Case.
- [ ] AC2 — The value is derived, never hand-entered; it is read-only to end users.
- [ ] AC3 — The related Account shows a count of its closed Cases.
- [ ] AC4 — The related Account shows the average resolution duration of its closed Cases.
- [ ] AC5 — Account values stay correct when a Case is closed, reopened, re-closed,
      deleted, undeleted, or re-parented to a different Account.
- [ ] AC6 — Correct under bulk load: 200+ Cases in a single transaction, spanning multiple
      Accounts, with no governor-limit failure and no per-record SOQL/DML.
- [ ] AC7 — Account aggregates are identical regardless of *which* user saved the Case
      (i.e. they are not skewed by the saving user's record visibility).
- [ ] AC8 — Support agents can read all three/four new fields; they cannot edit them.
- [ ] AC9 — Cases with no Account do not error and do not corrupt any rollup.
- [ ] AC10 — Apex coverage ≥ 75% org-wide with meaningful assertions on every new class.

---

## 3. Metadata evidence (read-only)

All evidence gathered 2026-07-23 against target org alias `demo`. Full command log in the
[Implementation Log](../../implementation-log/case-resolution-time.md).

### 3.1 Evidence table

| # | Item | How verified (command) | Finding |
|---|------|------------------------|---------|
| E1 | Target org identity | `sf org display --json` | `alias=demo`, `id=00Dg500000G0Yq5EAF`, `instanceUrl=https://orgfarm-b6c5946ad2-dev-ed.develop.my.salesforce.com`, `apiVersion=67.0`, `connectedStatus=Connected` |
| E2 | Org is **not production** | `sf data query --query "SELECT Id, OrganizationType, IsSandbox FROM Organization"` | `OrganizationType = "Developer Edition"`, `IsSandbox = false`. It is a **Developer Edition org**, i.e. non-production, safe for the Developer to deploy to. It is *not* a sandbox — `IsSandbox=false` — so any "must be a sandbox" check must accept Developer Edition explicitly. |
| E3 | Project API version | `cat sfdx-project.json` | `sourceApiVersion = 61.0`. Org runs 67.0. Per CLAUDE.md §1 all new `*-meta.xml` use **61.0**. |
| E4 | CLI version | `sf --version` | `@salesforce/cli/2.144.6` |
| E5 | Case field inventory | `sf sobject describe --sobject Case` | Exactly **40** fields. Relevant: `CreatedDate` (datetime, `createable=false updateable=false`), `ClosedDate` (datetime, `createable=false updateable=false`), `IsClosed` (boolean, `createable=false updateable=false`), `AccountId` (reference), `Status` (picklist). |
| E6 | **No** existing resolution/duration field on Case | same describe + `grep -ril "resolution" force-app/` | Only custom Case fields are `EngineeringReqNumber__c`, `SLAViolation__c`, `Product__c`, `PotentialLiability__c`. Nothing tracks duration. No name collision for a new field. |
| E7 | Case `Status` picklist values | `sf sobject describe --sobject Case` → `Status.picklistValues` | `New` (default), `Working`, `Escalated`, `Closed` — all active. Only 4 values. Describe does **not** expose which are "closed" statuses, therefore the design keys off `IsClosed`, not the `Status` string. |
| E8 | Case→Account is a **Lookup**, not Master-Detail | `sf sobject describe --sobject Case` → `AccountId` | `{"type":"reference","referenceTo":["Account"],"relationshipName":"Account","cascadeDelete":false,"restrictedDelete":false,"writeRequiresMasterRead":false,"nillable":true}` — `cascadeDelete=false` and `writeRequiresMasterRead=false` prove this is a lookup. |
| E9 | Account→Case child relationship | `sf sobject describe --sobject Account` → `childRelationships` | `{"childSObject":"Case","field":"AccountId","relationshipName":"Cases","cascadeDelete":false,"restrictedDelete":true}`. `restrictedDelete=true` ⇒ an Account with related Cases **cannot be deleted**, so Account-delete cascade is not a scenario we must handle. |
| E10 | **Roll-Up Summary is impossible here** | E8 + E9 + [Salesforce Help: Roll-Up Summary Field](https://help.salesforce.com/s/articleView?id=platform.fields_about_roll_up_summary_fields.htm&language=en_US&type=5) | Roll-up summary fields require the parent to be on the **master side of a master-detail relationship**. `Case.AccountId` is a lookup and cannot be converted to master-detail (Case is a standard object). ⇒ **`Account.Closed_Case_Count__c` / average cannot be declarative roll-up summaries.** Apex, Flow, or a rollup package is mandatory. |
| E11 | Entitlements / Milestones **not enabled** | `sf sobject describe --sobject Case` (full field-name list) | `BusinessHoursId`, `EntitlementId`, `SlaStartDate`, `SlaExitDate`, `MilestoneStatus`, `IsStopped`, `StopStartDate` are **absent** from the describe. Entitlement Management is off. ⇒ a Case cannot carry its own Business Hours. |
| E12 | **Evidence discrepancy** — local metadata vs. org describe | `ls force-app/main/default/objects/Case/fields/` vs. E11 | Local retrieved source *does* contain `BusinessHoursId.field-meta.xml`, `EntitlementId.field-meta.xml`, `SlaStartDate`, `SlaExitDate`, `MilestoneStatus`, `IsStopped`, `StopStartDate`, `IsClosedOnCreate`, but the live describe does not return them. **The describe is authoritative.** The build must reference only describe-verified fields: `CreatedDate`, `ClosedDate`, `IsClosed`, `AccountId`, `Status`. |
| E13 | Business Hours configuration | `sf data query --query "SELECT Id,Name,IsActive,IsDefault,TimeZoneSidKey,MondayStartTime,MondayEndTime,SaturdayStartTime,SaturdayEndTime,SundayStartTime,SundayEndTime FROM BusinessHours"` | One record: `Default`, `IsActive=true`, `IsDefault=true`, `America/Los_Angeles`, and **every** start/end time is `00:00:00.000Z` including Saturday and Sunday. Salesforce treats start==end as a 24-hour day ⇒ the org's only Business Hours record is effectively **24×7**, so business-hours elapsed time is currently *identical* to calendar elapsed time. |
| E14 | **Zero** Apex in the org | `sf data query --use-tooling-api --query "SELECT Name FROM ApexClass WHERE NamespacePrefix = null"` → `[]`; `... FROM ApexTrigger` → `[]`; `ls force-app/main/default/classes` → empty; `ls force-app/main/default/triggers` → empty | No Apex classes, no triggers. **No existing `TriggerHandler` base framework exists** — this feature must establish one. No one-trigger-per-object conflict on Case. |
| E15 | **Zero** validation rules | `sf data query --use-tooling-api --query "SELECT ValidationName, EntityDefinition.QualifiedApiName, Active FROM ValidationRule"` → `[]` | No validation rules anywhere in the org ⇒ the Account rollup `update` cannot be blocked by a VR today. |
| E16 | Workflow rules on Case | `cat force-app/main/default/workflows/Case.workflow-meta.xml`; `grep -c "<rules>"` → `0` | The file contains only one **field update definition** (`ChangePriorityToHigh`) and **zero `<rules>` elements** ⇒ no active workflow rule fires on Case. No field-update ordering conflict. |
| E17 | Flows | `ls force-app/main/default/flows/` | Only `sfdc_default_ReportExport_Protection_Flow`. **No record-triggered flow on Case or Account** ⇒ no trigger-vs-flow ordering conflict, and no risk of a Flow and the new trigger fighting over the same field. |
| E18 | Case assignment rules | `cat force-app/main/default/assignmentRules/Case.assignmentRules-meta.xml` | `Standard` rule **active**, 5 entries, all assigning to `epic.205394471256@orgfarm.salesforce.com` based on `Account.SLA__c` / `Account.Type` / `Account.BillingCountry`. Only sets `OwnerId`; does not touch dates or Status. No conflict. |
| E19 | Case escalation rules | `cat force-app/main/default/escalationRules/Case.escalationRules-meta.xml` | `Standard` rule **active**, 8 entries, `businessHoursSource=Case`, `escalationStartTime=CaseCreation`, thresholds 120–1440 minutes. Note the tension with E11: the rule declares a Case-sourced business-hours model while Case has no `BusinessHoursId` field — a further reason not to build resolution time on top of Case business hours. |
| E20 | Duplicate rules | `ls force-app/main/default/duplicateRules/` | Account, Contact, Lead only. **No Case duplicate rule.** No interference. |
| E21 | Record types | describe `recordTypeInfos` for Case and Account | Both objects have **only `Master`**. No record-type-based scoping is possible or needed. |
| E22 | OWD / sharing model | `force-app/main/default/objects/Case/Case.object-meta.xml`, `.../Account/Account.object-meta.xml` | Case: `sharingModel = ReadWriteTransfer`, `externalSharingModel = Private`. Account: `sharingModel = ReadWrite`, `externalSharingModel = Private`. |
| E23 | Sharing rules | `cat force-app/main/default/sharingRules/Case.sharingRules-meta.xml`, `Account.sharingRules-meta.xml` | Both files are **empty** (`<SharingRules/>`). No criteria/owner-based sharing rules exist. |
| E24 | Permission sets in source | `ls force-app/main/default/permissionsets/` | Only `Experience_Profile_Manager.permissionset-meta.xml` and `sfdcInternalInt__sfdc_scrt2...`. Reading `Experience_Profile_Manager` shows it grants only `userPermissions` (community/report perms: `AccessCMC`, `ManageNetworks`, `RunReports`, …) — **no object or field permissions at all.** |
| E25 | Permission sets in the org | `sf data query --query "SELECT Name, Label, Type FROM PermissionSet WHERE IsOwnedByProfile = false"` | ~130 results, essentially all Salesforce-shipped `Standard`/`Session`/`Group` sets (`ServiceUserPsl`, `CRMUserPsl`, Data Cloud, Commerce, Agentforce, …). **There is no bespoke "support agent" permission set.** ⇒ one must be created. |
| E26 | Active users / profiles | `sf data query --query "SELECT Profile.Name, COUNT(Id) FROM User WHERE IsActive = true GROUP BY Profile.Name"` | `System Administrator: 2`, `Analytics Cloud Security User: 1`, `Analytics Cloud Integration User: 1`, `Chatter Free User: 1`, `null: 3`. **There are zero active users who are "support agents"**, so the target audience cannot be inferred from data — it must be stated by the user. |
| E27 | Support profile & its layouts | `grep layoutAssignments "force-app/main/default/profiles/Custom%3A Support Profile.profile-meta.xml"` | A `Custom: Support Profile` exists and is assigned `Case-Case %28Support%29 Layout` and `Account-Account %28Support%29 Layout`. This is the closest thing to a "support agent" persona in the org (but has 0 active users — E26). |
| E28 | Page layouts available | `ls force-app/main/default/layouts/` | Case: `Case Layout`, `Case (Support) Layout`, `Case (Sales) Layout`, `Case (Marketing) Layout`, plus `CaseClose-Close Case Layout`. Account: `Account Layout`, `Account (Support) Layout`, `Account (Sales) Layout`, `Account (Marketing) Layout`. Existing sections on both Support layouts include `System Information` and `Additional Information`. |
| E29 | Lightning record pages | `ls force-app/main/default/flexipages/` | Only `*_UtilityBar` flexipages. **No custom Lightning record page for Case or Account** ⇒ field visibility is driven by **page layouts**, so layouts must be edited. |
| E30 | Data volume | `sf data query --query "SELECT COUNT(Id) FROM Case"` → `26`; `... FROM Account` → `13` | 26 Cases, 13 Accounts. Tiny — production-scale behaviour must be proven by tests, not by this data. |
| E31 | Closed-Case distribution | `sf data query --query "SELECT Status, COUNT(Id) FROM Case GROUP BY Status"` | `Closed: 23`, `New: 3`. `SELECT COUNT(Id) FROM Case WHERE IsClosed = true AND AccountId = null` → **`0`** (every Case currently has an Account). |
| E32 | **Existing data is dirty — negative durations** | `sf data query --query "SELECT Id, CaseNumber, CreatedDate, ClosedDate FROM Case WHERE IsClosed = true"` | **All 23** closed Cases have `CreatedDate = 2026-07-20T13:24:36Z` and `ClosedDate = 2025-05-31T18:59:51Z` — i.e. **ClosedDate precedes CreatedDate by ~13.5 months**. A naive `ClosedDate - CreatedDate` yields ≈ **−9,834 hours** for every existing closed Case. A negative-duration guard is **mandatory**, not defensive coding. |
| E33 | No Status history to fall back on | `sf data query --query "SELECT COUNT(Id) FROM CaseHistory WHERE Field = 'Status'"` → `0` | `Case.Status` has `trackHistory=true` in metadata, but there are **zero** history rows. Any definition of resolution time based on "first Status change" or "first time it hit Closed" is **unverifiable for existing data** and would only work going forward. |
| E34 | Aggregate functions on formula fields | [SOQL & SOSL Reference — Support for Field Types in Aggregate Functions](https://developer.salesforce.com/docs/atlas.en-us.soql_sosl.meta/soql_sosl/sforce_api_calls_soql_select_agg_functions_field_types.htm) | `AVG()`/`SUM()` support `double`, `int`, `currency`, `percent`. For calculated (formula) fields, "support for aggregate functions depends on the type of the calculated field." Support for a *numeric* formula is therefore **conditional and not verifiable in this org** (E35). A stored `Number` field is unconditionally supported. |
| E35 | No formula field exists to test against | describes of Case, Account, Opportunity filtered on `calculated == true` | **Zero** formula fields on all three objects ⇒ the aggregate-on-formula behaviour could not be empirically proven read-only. Per "assume nothing", the design does not depend on it. |
| E36 | Git working tree | `git status --short` | Only `?? docs/TEST-SCENARIO.md` untracked. **Zero changes under `force-app/**` — the Architect wrote nothing there.** |

### 3.2 Impacted metadata inventory

**To be created (all by the Developer):** *— superseded by Technical Spec §2/§3 after the
D1c (days) and D4 (Queueable) answers; kept here for the audit trail.*

- **Objects/fields**
  - ~~`Case.Resolution_Time_Hours__c`~~ → **`Case.Resolution_Time_Days__c`** — Number(10,2)
  - `Account.Closed_Case_Count__c` — Number(9,0)
  - ~~`Account.Average_Resolution_Time_Hours__c`~~ → **`Account.Average_Resolution_Time_Days__c`** — Number(10,2)
  - `Account.Case_Metrics_Last_Calculated__c` — DateTime *(recommended, see D3c — carried into the build)*
- **Apex** — `TriggerHandler` (base), `CaseTrigger`, `CaseTriggerHandler`,
  `CaseResolutionService`, `AccountCaseRollupService`, `CaseSelector`,
  `CaseResolutionBackfillBatch` *(D6: build, don't run)*, plus — new, required by the D4
  Queueable answer — **`AccountCaseRollupQueueable`** and **`AccountCaseMetricsRecalcBatch`**
- **Apex tests** — `TestDataFactory`, `TriggerHandlerTest`, `CaseResolutionServiceTest`,
  `AccountCaseRollupServiceTest`, `CaseTriggerHandlerTest`
- **Security** — new permission set `CaseResolutionMetrics_Read`
- **Layouts (modified)** — `Case-Case (Support) Layout`, `Account-Account (Support) Layout`,
  and (recommended) `Case-Case Layout`, `Account-Account Layout` — see D5b

**Untouched (verified as non-conflicting):** Case assignment rules (E18), Case escalation
rules (E19), Case workflow (E16), all flows (E17), duplicate rules (E20), sharing rules
(E23), OWD (E22), record types (E21), profiles.

**LWC/Aura:** none. The requirement ("see this on the record") is satisfied by page-layout
fields; no custom UI is justified.

---

## 4. Constraints, risks, and assumptions-to-confirm

### 4.1 Hard constraints (evidence-backed)

| ID | Constraint | Evidence |
|----|-----------|----------|
| C1 | **No declarative roll-up summary on Account for Cases.** Requires master-detail; Case→Account is a lookup and cannot be converted. | E8, E9, E10 |
| C2 | `Case.CreatedDate`, `ClosedDate`, `IsClosed` are all `createable=false, updateable=false` — they are platform-maintained and cannot be set by Apex or by a data load through the normal API. | E5 |
| C3 | Business hours cannot be sourced *per Case* — `Case.BusinessHoursId` does not exist because Entitlement Management is off. Only the single org-default `BusinessHours` record is usable, and it is configured **24×7**, making business hours numerically identical to calendar time today. | E11, E13 |
| C4 | No `TriggerHandler` framework exists; this feature must introduce one and it becomes the project standard. | E14 |
| C5 | New `*-meta.xml` must declare `apiVersion` / `<apiVersion>61.0</apiVersion>` even though the org is on 67.0. | E3 |
| C6 | Field visibility is layout-driven; there is no Lightning record page to edit. | E29 |
| C7 | The org is Developer Edition with `IsSandbox = false`. Any pre-deploy safety check must whitelist `OrganizationType = 'Developer Edition'` rather than testing `IsSandbox`. | E2 |

### 4.2 Risks

| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R1 | **All 23 existing closed Cases have `ClosedDate < CreatedDate`** (negative duration). | Garbage metric on day one; a negative average on every Account. | Guard: never store a negative duration — store `null`. `AVG()` ignores nulls, so those Cases contribute to the *count* but not the *average*. Confirm via **D3b**. |
| R2 | Account rollup computed with the saving user's record visibility would differ per user. | Stored aggregate becomes non-deterministic; violates AC7. | The rollup service runs in **system mode** (`without sharing`, no `WITH USER_MODE` on the aggregate query) — explicitly justified in the Technical Spec §3. |
| R3 | Writing the Case field requires DML on Case from within the Case trigger ⇒ re-entrancy. | Infinite recursion / limit blowout. | Static self-update guard + `TriggerHandler` bypass API; the re-entrant pass returns immediately. |
| R4 | `ClosedDate` population timing in a **before** trigger is not documented reliably and could not be verified read-only in this org. | A before-trigger design could silently store wrong values. | ~~Design avoids the question entirely — all logic runs in `after` contexts.~~ **SUPERSEDED 2026-07-23** — see below. |

> **R4 revised.** The original mitigation (after-only trigger) forced a self-`update` on Case
> from within the Case trigger, which re-fires the trigger and needs a static recursion guard
> (R3). That is a worse trade than the risk it avoided. **A guard cannot stop a trigger from
> firing** — Salesforce fires triggers on every DML unconditionally; a flag only makes the
> re-entrant pass return early. The correct fix is to issue no DML at all.
>
> The risk is now mitigated properly: the stamp moved to `before insert`/`before update`
> (in-memory write to `Trigger.new`, zero DML, nothing to re-enter), and the design **stops
> depending on `ClosedDate`/`IsClosed` in the before context** rather than gambling on their
> timing. Closed-ness is derived from `Status` against `CaseStatus` (verified queryable
> 2026-07-23: `New/Working/Escalated` open, `Closed` closed), and the close instant is
> `System.now()`. At `Number(10,2)` **days**, `0.01` = 14.4 minutes, so the millisecond gap
> versus the platform's `ClosedDate` cannot alter the stored value.
>
> **R3 (re-entrancy) is dissolved rather than mitigated** — there is no longer any DML on Case
> to recurse on. See Technical Spec §3.0.6 and §3.0.7.
| R5 | Account merge re-parents child Cases; Case triggers are not guaranteed to fire on merge-driven reparenting. | Stale rollups on the surviving Account after a merge. | Out of scope for v1; the backfill batch (D6) is the remediation tool. Documented in §6 "Out of scope". |
| R6 | Aggregate `GROUP BY` queries are capped (2,000 aggregate rows / query). | Failure on very wide transactions. | Max affected Accounts per trigger batch = 200 new + 200 old = 400 ≪ 2,000. Batch backfill chunks by Account. |
| R7 | `update` of Accounts from a Case trigger could be blocked by a future Account validation rule or a locked Account row. | Case save fails for an unrelated reason. | Today there are **zero** validation rules (E15). Design uses all-or-none DML so failures surface loudly rather than silently skewing data. Re-evaluate if VRs are added. |
| R8 | Row-lock contention: many Cases closing across few Accounts in parallel transactions. | `UNABLE_TO_LOCK_ROW`. | Accounts updated once per transaction, sorted by Id to reduce deadlock probability; documented in Technical Spec §3. |
| R9 | Aggregate support for *formula* fields is conditional and unverifiable here. | A formula-based design might not aggregate. | Design uses a **stored Number** field, which is unconditionally aggregable (E34). |
| R10 | Zero active support-agent users exist (E26), so permission-set assignment cannot be validated end-to-end in this org. | AC8 unprovable by manual click-through. | Proven instead by an Apex `System.runAs` test against a freshly created minimal-access user. |

### 4.3 Blocking decisions — **USER SIGN-OFF REQUIRED BEFORE BUILD**

These are the genuine ambiguities in the request. Each has a recommended answer with
reasoning; the Technical Spec is written against the recommendations. **Nothing here was
silently assumed** — if a recommendation is wrong, the Technical Spec changes.

---

**D1 — What exactly is "resolution time", and in what unit?**

- **D1a — Start point.** `Case.CreatedDate`, or the first Status change (i.e. when an agent
  actually picked it up)?
  *Recommendation: `CreatedDate`.* Evidence E33 — `CaseHistory` has **zero** Status rows, so
  a "first Status change" definition is unverifiable for existing data and would produce a
  metric that only works for Cases created after go-live.
- **D1b — Clock.** Calendar (24×7 wall-clock) elapsed time, or Business Hours?
  *Recommendation: calendar.* Evidence E11 + E13 — Case has no `BusinessHoursId` (Entitlements
  off) and the sole org `BusinessHours` record is configured 24×7, so a Business-Hours
  calculation would return **exactly the same number** today while adding a
  `BusinessHours.diff()` dependency and a hidden coupling to a config the support team can
  change without warning. The stored-field design keeps this switchable later.
- **D1c — Unit.** Hours (e.g. `36.25`), days, or both?
  *Recommendation: hours only*, `Number(10,2)`. One canonical unit avoids two fields that can
  disagree; days are trivially derived in a report formula. If the user wants days on the
  layout, say so now — it changes the field list.

---

**D2 — What happens when a Case is reopened and re-closed?**

- (a) **Recalculate** from `CreatedDate` to the *latest* `ClosedDate` (total time-to-final-resolution), or
- (b) **Freeze** the value from the *first* close, or
- (c) Measure only the most recent open→close cycle?

*Recommendation: (a) recalculate to the latest `ClosedDate`.* It is the only option that is
purely a function of fields the platform maintains (E5), needs no history object (E33), and
is self-healing. Sub-question: **while a Case is reopened (`IsClosed` goes true→false),
should `Resolution_Time_Hours__c` be cleared?** *Recommendation: yes, clear it* — an open
Case has no resolution time, and leaving a stale value would inflate the Account average.

---

**D3 — Which Cases count toward the Account rollup?**

- **D3a — Scope.** All closed Cases ever, or filtered (by `Type`, `Origin`, `Reason`, date
  window, e.g. "last 12 months")?
  *Recommendation: all closed Cases ever, unfiltered.* No filter is stated in the request,
  Case has only the `Master` record type (E21), and any filter is a business rule I cannot
  derive from metadata. **This is the single most likely thing to be wrong — please confirm.**
- **D3b — The dirty-data case.** Given **all 23** existing closed Cases have
  `ClosedDate < CreatedDate` (E32), should such a Case (i) count in
  `Closed_Case_Count__c` but be excluded from the average, (ii) be excluded from both, or
  (iii) be stored as a negative number?
  *Recommendation: (i).* Store `null` in `Resolution_Time_Hours__c`; `AVG()` ignores nulls, so
  the Case counts as closed but does not poison the average. **Consequence the user must
  accept: with today's data, every Account will show a non-zero closed-Case count and a
  *blank* average until the data is fixed.**
- **D3c — Transparency field.** Should the Account also carry
  `Case_Metrics_Last_Calculated__c` (DateTime)?
  *Recommendation: yes.* Cheap, and it lets agents and admins tell "zero closed Cases" apart
  from "never calculated" — important given D3b will produce blank averages.
- **D3d — Cases with no Account.** Currently zero (E31), but possible (`AccountId` is
  `nillable=true`, E8).
  *Recommendation: still calculate `Resolution_Time_Hours__c` on the Case; simply contribute
  to no rollup.* Confirm that orphan Cases are not expected to roll up anywhere else.
- **D3e — Accounts with zero closed Cases.** Should `Closed_Case_Count__c` be `0` or blank?
  *Recommendation: `0` for the count, `null` for the average.*

---

**D4 — Real-time or scheduled?**

Recompute synchronously in the Case trigger (values correct the instant the Case is saved),
or asynchronously / nightly (lighter save-time cost, values lag)?

*Recommendation: synchronous in an `after` trigger.* At this volume (E30: 26 Cases, 13
Accounts) async adds complexity for no benefit, and "when a Case is closed I want to see
the resolution time" reads as immediate. The design bulkifies to a fixed **2 SOQL + 2 DML**
per transaction regardless of batch size, so it scales. If the user expects >10k Cases
closing per hour or heavy parallel saves, say so — that changes the answer to Queueable.

---

**D5 — Security & UI placement**

- **D5a — Which permission set?** Evidence E24/E25: the org has **no** support-agent
  permission set, and the only bespoke one (`Experience_Profile_Manager`) grants zero object
  or field permissions. There are **zero active support users** (E26). A `Custom: Support
  Profile` exists (E27) but per `.claude/rules/security.md` we grant via permission sets,
  never profiles.
  *Recommendation: create a new permission set `CaseResolutionMetrics_Read` granting
  **Read-only** FLS on all new fields and nothing else.* **The user must tell us who gets it
  assigned** — the Developer will not assign it to anyone without that instruction.
- **D5b — Which layouts?** Case has 4 layouts and Account has 4 (E28); there is no Lightning
  record page (E29).
  *Recommendation: add the fields to `Case (Support) Layout` + `Case Layout`, and
  `Account (Support) Layout` + `Account Layout`, in the `System Information` section, marked
  `Readonly`.* Confirm whether Sales/Marketing layouts should also show them.
- **D5c — Read-only?** *Recommendation: yes, read-only everywhere* (FLS = readable but not
  editable, plus `behavior=Readonly` on the layout) so admins can't hand-edit derived values
  either. Note Apex in system mode still writes them.

---

**D6 — Backfill the 23 existing closed Cases?**

A trigger only fires on future saves. The 23 existing closed Cases (E31) will have a blank
`Resolution_Time_Hours__c` and their Accounts blank rollups until something touches them —
and per E32 those 23 would all compute to `null` anyway under D3b.

- (a) Build **and run** a backfill batch, (b) build it but do not run it, or (c) don't build it?

*Recommendation: (b) — build `CaseResolutionBackfillBatch`, do not execute it.* It is needed
operationally (post-merge repair per R5, and after any future definition change), but
executing it performs **DML on real org data**, which is outside a metadata deployment and
requires the user's explicit go-ahead. Note the backfill would set 23 Cases to `null` and 13
Accounts to `Closed_Case_Count__c = 23-ish / average = blank` — cosmetically it changes
little until the source data is corrected.

---

**D7 — Field API-name style**

`.claude/rules/naming-conventions.md` prescribes descriptive PascalCase and also says "match
the existing convention in this org". Existing custom fields are `SLAExpirationDate__c`,
`NumberofLocations__c`, `CustomerPriority__c`, `EngineeringReqNumber__c` — **PascalCase with
no underscores**.

*Recommendation: use underscore-separated names* (`Resolution_Time_Hours__c`,
`Closed_Case_Count__c`, `Average_Resolution_Time_Hours__c`). Reasoning: every existing custom
field in this org ships with the stock Developer-Edition sample data set (they appear on
Account/Case alongside `SLA__c`, `UpsellOpportunity__c`, etc.) — that is Salesforce's demo
data, **not a curated house convention**, and one of them (`NumberofLocations__c`) is
inconsistent even with itself. Underscore-separated is the modern Salesforce standard and
more readable. **Flagging explicitly because this is a judgement call, not evidence.**

---

## 5. Options considered

### Option A — Formula field on Case + Apex rollup on Account

`Case.Resolution_Time_Hours__c` as a Number formula:
`IF(OR(NOT(IsClosed), ISBLANK(ClosedDate), ClosedDate < CreatedDate), NULL, ROUND((ClosedDate - CreatedDate) * 24, 2))`,
with Apex only for the Account aggregates.

- **Pros:** zero code for the Case field; always correct with no recursion, no DML, no
  trigger-timing questions; reopen/re-close handled automatically; no backfill needed —
  all 23 existing Cases get a value instantly; nothing to keep in sync.
- **Cons:** (1) Aggregate-function support on formula fields is **conditional on the formula's
  data type** (E34) and could not be empirically verified in this org because it contains
  **zero** formula fields (E35) — the whole Account rollup would rest on an unverified
  assumption, which CLAUDE.md forbids. (2) A formula **cannot** express Business Hours, so
  switching D1b later means dropping and recreating the field (a destructive change).
  (3) Formula fields are not indexed the same way, hurting large list-view/report filters.
  (4) Cannot be backfilled/frozen if the definition ever needs to change historically.
- **Effort:** lowest. **Risk:** medium (rests on E34/E35 uncertainty).

### Option B — Record-triggered Flow on Case + Flow-based rollup

- **Pros:** declarative; `.claude/rules/data-model.md` prefers declarative where it fits; no
  Apex test burden.
- **Cons:** Flow cannot perform a `GROUP BY` aggregate — recomputing an Account average
  requires a Get Records of *all* the Account's closed Cases into a collection and a manual
  loop, which hits the **element-iteration and heap limits** on Accounts with many Cases and
  degrades badly in bulk. No clean recursion control. Harder to unit-test to the 200-record
  bar `.claude/rules/testing.md` demands. No Flow exists on these objects today (E17), so
  this establishes a pattern that will need replacing later.
- **Effort:** medium. **Risk:** high at scale.

### Option C — Declarative Roll-Up Summary fields on Account

- **Verdict: IMPOSSIBLE.** Rejected on evidence, not preference. Roll-up summaries require
  the parent to be the master in a master-detail relationship; `Case.AccountId` is a lookup
  (`cascadeDelete=false`, `writeRequiresMasterRead=false` — E8) and a standard object's
  standard lookup cannot be converted (E10).

### Option D — Third-party rollup package (DLRS / Rollup Helper)

- **Pros:** battle-tested, declarative config, handles reparent/delete/undelete.
- **Cons:** introduces an unmanaged/managed package dependency into a project that currently
  has **zero** Apex (E14) and no package baseline; DLRS still deploys generated Apex
  triggers, so the "no code" benefit is illusory for governance; version/upgrade risk;
  outside the spec-driven workflow this repo enforces (its metadata would not live under
  `force-app/**` review).
- **Effort:** low-ish. **Risk:** governance/dependency.

### Option E — Stored Number field on Case, written by Apex, + Apex aggregate rollup ⟵ **CHOSEN**

- **Pros:** the stored field is a plain `Number` (`double`), which **unconditionally**
  supports `AVG()`/`COUNT()`/`GROUP BY` (E34) — so the Account rollup is a single aggregate
  SOQL regardless of how many Cases an Account has; supports a Business-Hours definition
  later without a destructive schema change (C3/D1b); backfillable and filterable/indexable;
  negative-duration guard (R1/E32) lives in one testable place; one trigger + handler +
  service + selector matches `.claude/rules/apex.md` and `triggers.md` exactly.
- **Cons:** most code; requires a recursion guard and one extra DML on Case per transaction;
  requires a backfill for historical Cases (D6); establishes a `TriggerHandler` framework
  that must be maintained.
- **Effort:** highest. **Risk:** low — every risk has a named mitigation in §4.2.

---

## 6. Recommended solution design

### 6.1 Chosen approach

**Option E.** Two reasons dominate, both evidence-driven:

1. **The Account rollup cannot be declarative (C1/E10), so Apex is required no matter what.**
   Given Apex is unavoidable for half the feature, splitting the Case half into a formula
   would spread one feature across two paradigms for no net saving.
2. **A stored `Number` is the only aggregation approach this org's evidence can guarantee.**
   E34 says aggregate support on a formula field is conditional on its type, and E35 shows
   there is no formula field anywhere in this org to prove it against. Per CLAUDE.md Prime
   Directive 1, the design must not rest on an unverified platform behaviour.

Secondary reinforcement: the negative-duration reality (E32) and the Business-Hours
optionality (C3/D1b) both want the calculation to live in one testable Apex method rather
than in a formula string.

### 6.2 Control & data flow

```
  Case DML (insert / update / delete / undelete)
        │
        ▼
  CaseTrigger  ── after insert, after update, after delete, after undelete
        │        (logic-free; delegates only)
        ▼
  CaseTriggerHandler extends TriggerHandler
        │  ├─ guard: if this is our own re-entrant write → return immediately
        │  │
        │  ├─ 1. CaseResolutionService.applyResolutionTimes(newCases, oldMap)
        │  │        · needs value  : IsClosed == true  AND ClosedDate != null
        │  │                         AND ClosedDate >= CreatedDate
        │  │                         → hours = (ClosedDate − CreatedDate)/3600000, 2dp
        │  │        · needs null   : IsClosed == false  (reopened)          [D2]
        │  │                         OR ClosedDate < CreatedDate            [D3b/E32]
        │  │        · ONE update on the changed Cases, wrapped in the guard
        │  │
        │  └─ 2. AccountCaseRollupService.recalculate(affectedAccountIds)
        │           affectedAccountIds = new AccountId ∪ old AccountId
        │                                (covers reparenting, delete, undelete)
        │           · seed every Account with count=0, avg=null, lastCalc=now  [D3e]
        │           · ONE aggregate SOQL via CaseSelector, SYSTEM MODE:        [R2]
        │                SELECT AccountId, COUNT(Id), AVG(Resolution_Time_Hours__c)
        │                FROM Case WHERE AccountId IN :ids AND IsClosed = true
        │                GROUP BY AccountId
        │             (AVG ignores nulls ⇒ dirty Cases counted but not averaged) [D3b]
        │           · overlay results, ONE update on Account
        ▼
  Account.Closed_Case_Count__c · Average_Resolution_Time_Hours__c · Case_Metrics_Last_Calculated__c
```

**Cost per transaction: 2 SOQL + 2 DML, constant with batch size.**

### 6.3 Security posture

- **Reads/writes inside the rollup run in SYSTEM mode, deliberately.** `.claude/rules/security.md`
  prefers `WITH USER_MODE`, but applying it to the aggregate query would compute each
  Account's average from only the Cases the *saving user* can see (Case OWD is
  `ReadWriteTransfer` with `externalSharingModel = Private` — E22), making the stored value
  depend on who clicked Save. That directly violates **AC7**. The Technical Spec therefore
  instructs the Developer **not** to add `WITH USER_MODE` to the rollup query, with this
  justification recorded in the class header.
- **The security boundary is the read boundary instead:** all four fields are granted
  **read-only** FLS via `CaseResolutionMetrics_Read` and marked `Readonly` on layouts, so no
  user can write a derived value. There is no `@AuraEnabled` entry point and no LWC, so
  there is no client-facing surface to protect.
- A `System.runAs` negative test with a minimal-access user proves the fields are not
  writable and that access is denied without the permission set.

### 6.4 Explicitly out of scope

- Any LWC / Aura component, custom report type, dashboard, or list view.
- Business-Hours-based durations (blocked by C3; revisit if D1b is answered "business hours").
- First-response time, time-in-status, SLA-breach flags, per-agent metrics.
- Rollups on any object other than Account (e.g. Contact, Asset, parent Account roll-through).
- Re-computation triggered by **Account merge** (R5) — remediated manually via the backfill batch.
- **Executing** the backfill against org data (D6) — build only, run on explicit approval.
- Correcting the existing dirty `ClosedDate` data (E32) — a data-quality task, not this build.
- Assigning `CaseResolutionMetrics_Read` to any user or profile (needs D5a).

---

## 4.4 Decision resolution (added 2026-07-23, after user sign-off)

All seven blocking decisions were put to the user via `AskUserQuestion` and answered.

| ID | Answer | vs. recommendation |
|----|--------|--------------------|
| D1a | `Case.CreatedDate` as the start point | ✅ as recommended |
| D1b | Calendar time (not business hours) | ✅ as recommended |
| **D1c** | **Unit = DAYS**, `Number(10,2)` | ⚠️ **differs** — spec proposed hours |
| D2 | Recalculate to latest `ClosedDate`; clear while reopened | ✅ as recommended |
| D3a | All closed Cases ever, unfiltered | ✅ as recommended |
| D3b | Negative duration → `null`; counted, not averaged | ✅ as recommended |
| D3c | `Case_Metrics_Last_Calculated__c` included | ⚠️ **not separately asked** — carried from the recommendation; flagged in Technical Spec §0 as droppable on request |
| D3d | Orphan Cases stamped, roll up nowhere | ✅ as recommended |
| D3e | Count `0`, average `null` | ✅ as recommended |
| **D4** | **Async via Queueable** | ⚠️ **differs** — spec recommended synchronous |
| D5a | Create `CaseResolutionMetrics_Read`, assign to nobody | ✅ as recommended |
| D5b | Support + default layouts for Case and Account | ✅ as recommended |
| D5c | Read-only FLS **and** `behavior=Readonly` | ✅ as recommended |
| D6 | Build the backfill batch, do not run it | ✅ as recommended |
| D7 | Underscore-separated API names | ✅ as recommended |

### Impact of the two departures

**D1c (days instead of hours)** — mechanical. Divisor becomes `86400000` ms/day; all field
API names, labels, descriptions, and assertions read `Days`.

**D4 (Queueable instead of synchronous)** — structural. It invalidates part of §6.2's control
flow and adds two classes. Four consequences the synchronous design did not have, each now
carrying an explicit instruction in Technical Spec §0.1 and §3:

| # | Consequence | Mitigation in the Technical Spec |
|---|---|---|
| A1 | Account values lag the Case save by seconds | Accepted; `Case_Metrics_Last_Calculated__c` makes the lag visible |
| A2 | A rollup failure no longer rolls back the Case save — it fails to the Apex Jobs log instead of loudly (this weakens R7's original mitigation) | Bounded retry on lock errors only; never swallow; non-lock exceptions rethrown |
| A3 | `System.enqueueJob` limits become real: 50/transaction, and **1** inside a Batch `execute()` | Per-transaction Account-Id dedupe + synchronous fallback when no slot remains; backfill batch bypasses the Case trigger entirely |
| A4 | Higher cross-transaction row-lock contention on shared Accounts (amplifies R8) | Deterministic Id-sorted update order + bounded retry |

### Standing data-quality consequence the user has accepted

Per D3b, with the org's current data **every Account will show a non-zero
`Closed_Case_Count__c` and a blank `Average_Resolution_Time_Days__c`** until the seeded
`ClosedDate < CreatedDate` records (E32) are corrected. That correction is not part of this
build.
