/**
 * Tests for AccountCaseMetricsRecalcBatch.
 *
 * The batch itself is NEVER executed against org data (D6); these tests exercise it only
 * against records created inside the test.
 *
 * See technical-spec.md section 6.8.
 */
@isTest
private class AccountCaseMetricsRecalcBatchTest {
    @isTest
    static void recalcBatchCorrectsCorruptedAccountMetrics() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-1));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-5));
        update new List<Case>{
            new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS),
            new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS)
        };

        // Corrupt the metrics directly, as an Account merge or a missed trigger would.
        update new Account(
            Id = acct.Id,
            Closed_Case_Count__c = 999,
            Average_Resolution_Time_Days__c = 888.88,
            Case_Metrics_Last_Calculated__c = null
        );

        Test.startTest();
        Database.executeBatch(new AccountCaseMetricsRecalcBatch(), 200);
        Test.stopTest();

        Account reloaded = [
            SELECT Closed_Case_Count__c, Average_Resolution_Time_Days__c,
                Case_Metrics_Last_Calculated__c
            FROM Account
            WHERE Id = :acct.Id
        ];
        Assert.areEqual(
            2,
            reloaded.Closed_Case_Count__c,
            'The batch must replace the corrupted count with the true value.'
        );
        Assert.isTrue(
            Math.abs(reloaded.Average_Resolution_Time_Days__c - 3.00) < 0.01,
            'The average of 1 and 5 days must be ~3.00; got '
                + reloaded.Average_Resolution_Time_Days__c
        );
        Assert.isNotNull(
            reloaded.Case_Metrics_Last_Calculated__c,
            'The batch must stamp the calculation timestamp.'
        );
    }

    @isTest
    static void recalcBatchSeedsAccountsWithNoClosedCases() {
        List<Account> accounts = TestDataFactory.createAccounts(3, true);
        TestDataFactory.createCases(accounts[0].Id, 2, true);

        Test.startTest();
        Database.executeBatch(new AccountCaseMetricsRecalcBatch(), 200);
        Test.stopTest();

        List<Account> reloaded = [
            SELECT Closed_Case_Count__c, Average_Resolution_Time_Days__c,
                Case_Metrics_Last_Calculated__c
            FROM Account
            WHERE Id IN :accounts
        ];
        Assert.areEqual(3, reloaded.size(), 'The batch covers every Account.');
        for (Account acct : reloaded) {
            Assert.areEqual(
                0,
                acct.Closed_Case_Count__c,
                'An Account with no closed Cases must be seeded to 0, not left blank (D3e).'
            );
            Assert.isNull(
                acct.Average_Resolution_Time_Days__c,
                'An Account with no closed Cases must have a blank average (D3e).'
            );
            Assert.isNotNull(
                acct.Case_Metrics_Last_Calculated__c,
                'Every Account the batch touches must be timestamped.'
            );
        }
    }
}
