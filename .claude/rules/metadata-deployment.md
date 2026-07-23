# RULE: Metadata Retrieve / Validate / Deploy — MANDATORY (Developer)

SFDX source format, `sf` CLI, source root `force-app`. Never deploy to production.

## 0. Confirm target org
- `sf org display` → confirm alias, instance URL, and that it is a **sandbox/scratch**.
- If no default org or it's production/unknown → STOP and ask the user.

## 1. Retrieve before you change (avoid clobbering)
- Pull current state of what you'll touch:
  `sf project retrieve start --metadata ApexClass:MyClass,CustomObject:My__c`
- Diff against local; never blind-overwrite org changes you didn't author.

## 2. Validate (check-only dry run) — REQUIRED before real deploy
- `sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests --tests <TestClasses> --wait 33`
- This performs a full deploy simulation with tests but commits nothing. Fix and repeat
  until it passes clean.

## 3. Deploy
- `sf project deploy start --source-dir force-app --test-level RunSpecifiedTests --tests <TestClasses> --wait 33`
- For a validated deploy you may quick-deploy the validated id if available.

## 4. Run/confirm tests & coverage
- `sf apex run test --tests <TestClasses> --code-coverage --result-format human --wait 10`
- Confirm ≥75% org coverage and that each new/changed class is covered.

## 5. Destructive changes
- Deletions (fields, classes) require an explicit `destructiveChanges.xml` plan and user
  confirmation — never delete metadata silently.

## Logging
- Record every command, the deploy/validate id, pass/fail, and coverage in
  `docs/implementation-log/<feature>.md`.

## Notes
- `--test-level`: use `RunSpecifiedTests` with the exact classes for targeted changes;
  `RunLocalTests` when broad impact or the spec requires it.
- Keep `--wait` generous; report async ids if a command times out rather than assuming failure.
