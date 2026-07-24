/**
 * Tests for CaseResolutionBackfillBatch.
 *
 * The batch itself is NEVER executed against org data (D6); these tests exercise it only
 * against records created inside the test.
 *
 * See technical-spec.md section 6.8.
 */
@isTest
private class CaseResolutionBackfillBatchTest {
    private static final String CASE_HANDLER = 'CaseTriggerHandler';

    @isTest
    static void backfillRestoresMissingResolutionTimes() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 3, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-2));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-6));
        update new List<Case>{
            new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS),
            new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS)
        };

        // Simulate pre-feature data: closed Cases carrying no resolution time.
        TriggerHandler.bypass(CASE_HANDLER);
        update new List<Case>{
            new Case(Id = cases[0].Id, Resolution_Time_Days__c = null),
            new Case(Id = cases[1].Id, Resolution_Time_Days__c = null)
        };
        TriggerHandler.clearBypass(CASE_HANDLER);
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Case WHERE Resolution_Time_Days__c != NULL],
            'Precondition: no Case carries a resolution time before the backfill.'
        );
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        Database.executeBatch(new CaseResolutionBackfillBatch(), 200);
        Test.stopTest();

        Map<Id, Case> byId = new Map<Id, Case>(
            [SELECT Id, Resolution_Time_Days__c FROM Case WHERE Id IN :cases]
        );
        Assert.isTrue(
            Math.abs(byId.get(cases[0].Id).Resolution_Time_Days__c - 2.00) < 0.01,
            'The two-day Case must be restored to ~2.00; got '
                + byId.get(cases[0].Id).Resolution_Time_Days__c
        );
        Assert.isTrue(
            Math.abs(byId.get(cases[1].Id).Resolution_Time_Days__c - 6.00) < 0.01,
            'The six-day Case must be restored to ~6.00; got '
                + byId.get(cases[1].Id).Resolution_Time_Days__c
        );
        Assert.isNull(
            byId.get(cases[2].Id).Resolution_Time_Days__c,
            'The still-open Case must remain blank.'
        );
        Assert.isTrue(
            CaseTriggerHandler.enqueuedAccountIds.isEmpty(),
            'The bypass must have kept the Case trigger from enqueuing anything - without it '
                + 'scope 2 onward would breach the one-Queueable-per-batch-execute cap.'
        );
    }

    @isTest
    static void backfillClearsAStaleValueOnAReopenedCase() {
        // This is why the locator selects ALL Cases, not just closed ones.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];

        TriggerHandler.bypass(CASE_HANDLER);
        update new Case(Id = c.Id, Resolution_Time_Days__c = 12.34);
        TriggerHandler.clearBypass(CASE_HANDLER);
        Assert.areEqual(
            12.34,
            [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id].Resolution_Time_Days__c,
            'Precondition: an open Case is holding a stale value.'
        );

        Test.startTest();
        Database.executeBatch(new CaseResolutionBackfillBatch(), 200);
        Test.stopTest();

        Assert.isNull(
            [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id].Resolution_Time_Days__c,
            'The backfill must clear a stale value from an open Case.'
        );
    }

    @isTest
    static void backfillLeavesCorrectValuesAlone() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        Test.setCreatedDate(c.Id, Datetime.now().addDays(-5));
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Case beforeBackfill = [
            SELECT Resolution_Time_Days__c, LastModifiedDate
            FROM Case
            WHERE Id = :c.Id
        ];

        Test.startTest();
        Database.executeBatch(new CaseResolutionBackfillBatch(), 200);
        Test.stopTest();

        Case afterBackfill = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id];
        Assert.areEqual(
            beforeBackfill.Resolution_Time_Days__c,
            afterBackfill.Resolution_Time_Days__c,
            'A Case already holding the correct value must be left exactly as it was.'
        );
    }
}
