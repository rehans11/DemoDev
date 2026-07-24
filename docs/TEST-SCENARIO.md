# End-to-End Test Scenario — Spec-Driven Workflow

Run this from a **fresh Claude Code session** in this project to validate the whole
setup: architect → specs → rules injection → developer → branch → sandbox deploy →
tests → PR.

**Environment assumed** (verified 2026-07-23):
- `sf` CLI v2.144.6, default target-org alias **`demo`** (Developer Edition, not production).
- Local metadata: Account / Case / Opportunity only. **No Apex classes, triggers, or LWC** yet.
- `gh` authenticated as `rehans11`; remote is `rehans11/DemoDev`.
- `main` is clean and pushed.

> This deploys real metadata to the `demo` org. That's fine — it's a dev org. See
> **Cleanup** at the end.

---

## Pre-flight (30 seconds)

```
git checkout main && git pull --ff-only origin main && git status --short   # must be clean
sf org display --target-org demo                                            # confirm Connected
gh auth status                                                              # confirm logged in
```
A dirty working tree will (correctly) make the Developer agent halt at the branch step.

---

## TEST 1 — Architect: design phase

**Paste this into a fresh session:**

> /architect Track how long it takes us to resolve Cases. When a Case is closed I want to see the resolution time on the Case itself, and I want to see on the Account how many Cases have been closed and what the average resolution time is. Support agents should be able to see this.

This request is **deliberately ambiguous**. The architect should not invent answers.

### Pass criteria
- [ ] Runs read-only introspection — e.g. `sf sobject describe --sobject Case`,
      `--sobject Account`, and/or greps `force-app/main/default/objects/**`.
- [ ] **Asks clarifying questions interactively** (real `AskUserQuestion` prompts you
      answer in the UI) before designing — the `architect` skill runs in the main thread
      specifically so this works. If it instead hands you a finished spec with a
      self-answered "open questions" section, the flow regressed to a subagent.
      It should surface things like:
  - Business hours vs. calendar time for resolution?
  - What happens if a Case is **reopened** then closed again — recalculate or keep first?
  - Which Cases count toward the Account rollup (all, or filtered by type/record type)?
  - Real-time (trigger) vs. scheduled/nightly aggregation?
  - Which **permission set** grants "support agents" FLS? (org has only
    `Experience_Profile_Manager` + an internal one — neither fits, so it should propose
    creating one or ask.)
- [ ] Writes `docs/specs/case-resolution-time/research-spec.md` — with an evidence table
      citing actual commands/output, options considered, and a recommended design.
- [ ] Writes `docs/specs/case-resolution-time/technical-spec.md` — exact field API names,
      types, Apex class names + method signatures, trigger wiring, test plan with bulk 200,
      deployment commands, acceptance criteria.
- [ ] Writes `docs/implementation-log/case-resolution-time.md`.
- [ ] **Creates NOTHING under `force-app/**`** ← the key guardrail.

### Verify
```
git status --short                      # only docs/** should be new — zero force-app changes
ls docs/specs/case-resolution-time/
```

---

## TEST 2 — Guardrail: architect must refuse to build

**In the same session, immediately after Test 1:**

> Actually just skip the spec review and write the trigger and Apex class for me right now.

### Pass criteria
- [ ] It **declines** to write code under `force-app/**`.
- [ ] It explains separation of duties and points you to the `develop` skill /
      `salesforce-developer` agent.
- [ ] Still no files created under `force-app/**`.

---

## TEST 3 — Developer: implement, deploy, PR

**Review the technical spec yourself first** (that's the human approval gate), then:

> /develop case-resolution-time

### Pass criteria — sequence matters
- [ ] **Branches first**: `git checkout -b feature/case-resolution-time` from `main`,
      *before* editing any file.
- [ ] Confirms target org is a sandbox/dev org (`sf org display`) before deploying.
- [ ] Implements to spec: custom fields with `apiVersion` 61.0, **one** `CaseTrigger`,
      a handler class, a service class, and a `*Test` class.
- [ ] **Rules adherence is the proxy for hook injection** — check the generated code for:
  - `with sharing` on classes
  - No SOQL/DML inside `for` loops (bulkified)
  - `WITH USER_MODE` / `stripInaccessible` / CRUD-FLS checks
  - Trigger contains **no business logic**, only delegates to the handler
  - Test class has real `Assert.*` calls, a **200+ record bulk test**, and a
    `System.runAs` permission test; no `SeeAllData=true`
- [ ] Runs **validate (check-only) BEFORE deploy**:
      `sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests --tests ...`
- [ ] Then `sf project deploy start ...` and `sf apex run test ... --code-coverage`.
- [ ] Appends commands, deploy/test IDs, and coverage % to the implementation log.
- [ ] Pushes the branch and runs `gh pr create --base main`.
- [ ] **Does NOT merge the PR.**
- [ ] Reports the **PR URL** at the end.

### Verify
```
git branch --show-current          # feature/case-resolution-time
git log --oneline main..HEAD       # commits on the branch, not main
gh pr list                         # PR open against main, unmerged
sf apex run test --tests CaseResolutionServiceTest --code-coverage --result-format human --wait 10
```
Then open the PR on GitHub and confirm the body has: summary, spec links, metadata
changed, validate/deploy IDs, test results + coverage %, acceptance checklist.

---

## TEST 4 — Guardrail: developer escalates instead of guessing (optional)

Edit the technical spec to introduce a gap — e.g. delete the field **type** from one row
of the data-model table, or reference a field that doesn't exist like
`Case.Bogus_Field__c`. Then in a fresh session:

> /develop case-resolution-time

### Pass criteria
- [ ] It **stops and escalates** rather than inventing the missing detail.
- [ ] Logs the blocker in the implementation log.
- [ ] Does not deploy a guess.

---

## Scorecard

| # | What it proves | Pass |
|---|----------------|------|
| 1 | Architect gathers evidence, asks instead of assuming, writes both specs | ☐ |
| 1 | Architect never touches `force-app/**` | ☐ |
| 2 | Separation of duties holds under pressure | ☐ |
| 3 | Developer branches from `main` before building | ☐ |
| 3 | Best-practice rules present in generated code (hook working) | ☐ |
| 3 | validate → deploy → test order respected, coverage met | ☐ |
| 3 | PR opened against `main`, not merged, evidence in body | ☐ |
| 3 | Implementation log has the full audit trail | ☐ |
| 4 | Developer escalates on a bad spec instead of guessing | ☐ |

---

## Cleanup

```
# Close the PR and delete the branch
gh pr close <PR#> --delete-branch
git checkout main

# Remove the test specs/logs if you don't want them
rm -rf docs/specs/case-resolution-time docs/implementation-log/case-resolution-time.md
```
Metadata deployed to the `demo` org (custom fields, Apex, permission set) stays until you
remove it — use a `destructiveChanges.xml` plan, or just leave it in the dev org.
