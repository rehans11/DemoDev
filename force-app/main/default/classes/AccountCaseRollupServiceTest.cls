/**
 * Tests for AccountCaseRollupService.
 *
 * See technical-spec.md section 6.3.
 */
@isTest
private class AccountCaseRollupServiceTest {
    private static final Decimal TOLERANCE = 0.01;
    private static final String CASE_HANDLER = 'CaseTriggerHandler';

    @isTest
    static void averagesTheValidResolutionTimesOfClosedCases() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-2));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-4));
        closeAll(cases);

        Test.startTest();
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Test.stopTest();

        Account reloaded = readMetrics(acct.Id);
        Assert.areEqual(2, reloaded.Closed_Case_Count__c, 'Both closed Cases must be counted.');
        Assert.isTrue(
            Math.abs(reloaded.Average_Resolution_Time_Days__c - 3.00) < TOLERANCE,
            'The average of 2 and 4 days must be ~3.00; got '
                + reloaded.Average_Resolution_Time_Days__c
        );
        Assert.isNotNull(
            reloaded.Case_Metrics_Last_Calculated__c,
            'Every processed Account must be stamped with a calculation timestamp (D3c).'
        );
    }

    @isTest
    static void nullResolutionCasesAreCountedButNotAveraged() {
        // D3b: AVG() ignores nulls, so a dirty Case counts toward the total but contributes
        // nothing to the average.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-5));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-5));
        closeAll(cases);
        blankResolutionTime(new List<Id>{ cases[1].Id });

        Test.startTest();
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Test.stopTest();

        Account reloaded = readMetrics(acct.Id);
        Assert.areEqual(
            2,
            reloaded.Closed_Case_Count__c,
            'A Case with no valid resolution time still counts as closed (D3b).'
        );
        Assert.isTrue(
            Math.abs(reloaded.Average_Resolution_Time_Days__c - 5.00) < TOLERANCE,
            'The average must reflect the VALID Case only; got '
                + reloaded.Average_Resolution_Time_Days__c
        );
    }

    @isTest
    static void allNullResolutionTimesProduceACountWithABlankAverage() {
        // This is the exact state of this org's seeded data today (research-spec E32).
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 3, true);
        closeAll(cases);
        blankResolutionTime(new List<Id>{ cases[0].Id, cases[1].Id, cases[2].Id });

        Test.startTest();
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Test.stopTest();

        Account reloaded = readMetrics(acct.Id);
        Assert.areEqual(3, reloaded.Closed_Case_Count__c, 'All three must still be counted.');
        Assert.isNull(
            reloaded.Average_Resolution_Time_Days__c,
            'With no valid resolution time anywhere the average must be blank, not zero.'
        );
    }

    @isTest
    static void accountWithNoClosedCasesGetsZeroAndNull() {
        // D3e.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        TestDataFactory.createCases(acct.Id, 2, true);

        Test.startTest();
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Test.stopTest();

        Account reloaded = readMetrics(acct.Id);
        Assert.areEqual(0, reloaded.Closed_Case_Count__c, 'Zero closed Cases means count 0.');
        Assert.isNull(
            reloaded.Average_Resolution_Time_Days__c,
            'Zero closed Cases means a blank average, not zero.'
        );
        Assert.isNotNull(
            reloaded.Case_Metrics_Last_Calculated__c,
            'The timestamp is what distinguishes "zero closed Cases" from "never calculated".'
        );
    }

    @isTest
    static void seedingResetsAnAccountThatLostItsLastClosedCase() {
        // AC5: without the seeding step the Account would keep a stale figure forever.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 1, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-3));
        closeAll(cases);
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Assert.areEqual(
            1,
            readMetrics(acct.Id).Closed_Case_Count__c,
            'Precondition: the Account has one closed Case.'
        );

        TriggerHandler.bypass(CASE_HANDLER);
        delete cases;
        TriggerHandler.clearBypass(CASE_HANDLER);

        Test.startTest();
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Test.stopTest();

        Account reloaded = readMetrics(acct.Id);
        Assert.areEqual(
            0,
            reloaded.Closed_Case_Count__c,
            'The seeding step must reset the count to 0, not leave the stale 1.'
        );
        Assert.isNull(
            reloaded.Average_Resolution_Time_Days__c,
            'The seeding step must reset the average to null.'
        );
    }

    @isTest
    static void multipleAccountsAreAggregatedIndependently() {
        List<Account> accounts = TestDataFactory.createAccounts(3, true);
        List<Case> cases = new List<Case>();
        cases.addAll(TestDataFactory.createCases(accounts[0].Id, 3, false));
        cases.addAll(TestDataFactory.createCases(accounts[1].Id, 1, false));
        insert cases;
        closeAll(cases);

        Test.startTest();
        AccountCaseRollupService.recalculate(
            new Set<Id>{ accounts[0].Id, accounts[1].Id, accounts[2].Id }
        );
        Test.stopTest();

        Map<Id, Account> byId = new Map<Id, Account>(
            [
                SELECT Id, Closed_Case_Count__c, Average_Resolution_Time_Days__c
                FROM Account
                WHERE Id IN :accounts
            ]
        );
        Assert.areEqual(3, byId.get(accounts[0].Id).Closed_Case_Count__c, 'Account 0 has 3.');
        Assert.areEqual(1, byId.get(accounts[1].Id).Closed_Case_Count__c, 'Account 1 has 1.');
        Assert.areEqual(
            0,
            byId.get(accounts[2].Id).Closed_Case_Count__c,
            'Account 2 has none and must be seeded to 0, not skipped.'
        );
    }

    @isTest
    static void nullAndEmptyInputPerformNoDml() {
        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        AccountCaseRollupService.recalculate(null);
        AccountCaseRollupService.recalculate(new Set<Id>());
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(
            dmlBefore,
            dmlAfter,
            'Null / empty input must return immediately without touching the database.'
        );
    }

    @isTest
    static void aggregatesAreIdenticalRegardlessOfTheRunningUser() {
        // AC7 / R2: the stored aggregate must not depend on who saved the Case.
        //
        // NOTE FOR REVIEWERS - the technical spec 6.3 wording ("a minimum-access user who
        // can see none of the Cases") cannot be reproduced in THIS org: Case OWD is
        // ReadWriteTransfer (research-spec E22), i.e. public read/write, so every user with
        // Case access sees every Case. Record visibility therefore cannot differ per user
        // today, and an assertion that the user sees zero Cases fails (verified: it sees
        // all of them). The determinism assertion below is the one AC7 actually requires
        // and it is kept intact. The `without sharing` keyword remains the correct defence
        // for the day someone tightens Case OWD to Private - at which point this test would
        // start genuinely exercising the sharing difference.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-2));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-4));
        closeAll(cases);

        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Account asAdmin = readMetrics(acct.Id);

        User minUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            minUser = TestDataFactory.createMinimumAccessUser();
        }

        Test.startTest();
        System.runAs(minUser) {
            AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        }
        Test.stopTest();

        Account asMinUser = readMetrics(acct.Id);
        Assert.areEqual(
            asAdmin.Closed_Case_Count__c,
            asMinUser.Closed_Case_Count__c,
            'The stored count must not depend on who saved the Case.'
        );
        Assert.areEqual(
            asAdmin.Average_Resolution_Time_Days__c,
            asMinUser.Average_Resolution_Time_Days__c,
            'The stored average must not depend on who saved the Case (AC7).'
        );
        Assert.areEqual(2, asMinUser.Closed_Case_Count__c, 'Both Cases must still be counted.');
    }

    // ------------------------------------------------------------------------------ helpers

    private static void closeAll(List<Case> cases) {
        List<Case> closures = new List<Case>();
        for (Case c : cases) {
            closures.add(new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS));
        }
        update closures;
    }

    /**
     * Simulates pre-feature / dirty data: a closed Case holding no resolution time.
     * The trigger is bypassed so it cannot re-stamp the value on the way through.
     */
    private static void blankResolutionTime(List<Id> caseIds) {
        List<Case> blanks = new List<Case>();
        for (Id caseId : caseIds) {
            blanks.add(new Case(Id = caseId, Resolution_Time_Days__c = null));
        }
        TriggerHandler.bypass(CASE_HANDLER);
        try {
            update blanks;
        } finally {
            TriggerHandler.clearBypass(CASE_HANDLER);
        }
    }

    private static Account readMetrics(Id accountId) {
        return [
            SELECT Closed_Case_Count__c, Average_Resolution_Time_Days__c,
                Case_Metrics_Last_Calculated__c
            FROM Account
            WHERE Id = :accountId
        ];
    }
}
