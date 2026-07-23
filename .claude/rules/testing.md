# RULE: Apex Testing — MANDATORY

Applies to `*Test.cls` and any `@isTest` code. Adhere strictly.

## Coverage & intent
- Org minimum is **75%**, but coverage is a byproduct, not the goal. Test **behavior**.
- Every class/trigger you add or change must have meaningful tests. Aim high on the
  logic you wrote; cover positive, negative, and boundary paths.

## Structure
- Use `@isTest` on class and methods. Use `@TestSetup` for shared test data.
- Follow **Arrange–Act–Assert**. Wrap the exercised code in `Test.startTest()` /
  `Test.stopTest()` to get fresh limits and force async to run.
- Meaningful assertions with the `Assert` class (`Assert.areEqual`, `Assert.isTrue`,
  message args). **No assertion = not a real test.** Never write tests that only run
  code to inflate coverage.

## Data
- **Never** use `@isTest(SeeAllData=true)`. Create all data in-test.
- Use a `TestDataFactory` for reusable record creation.
- Test **bulk**: insert **200+** records to prove bulkification and catch limit issues.

## Scenarios to cover (per spec)
- Positive: expected inputs → expected outcome (assert data/state).
- Negative: invalid input, validation errors (`try/catch` + assert error/`DmlException`).
- Bulk: 200+ records in one operation.
- Security/permissions: use `System.runAs` with a minimal-access user; assert CRUD/FLS
  behavior (see `security.md`).
- Async: assert results after `Test.stopTest()`.

## Mocking & isolation
- Mock callouts with `HttpCalloutMock` / `Test.setMock`; never make real callouts.
- Use dependency injection / `@TestVisible` seams instead of `SeeAllData`.

## Running (Developer)
- Validate first: `sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests --tests <Classes>`.
- Then: `sf apex run test --tests <Classes> --code-coverage --result-format human --wait 10`.
- Record test run id, pass/fail, and per-class coverage in the Implementation Log.
