/**
 * Tests for AccountCaseRollupQueueable.
 *
 * See technical-spec.md section 6.4.
 */
@isTest
private class AccountCaseRollupQueueableTest {
    @isTest
    static void enqueuedJobPopulatesAccountMetrics() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        Test.setCreatedDate(cases[0].Id, Datetime.now().addDays(-1));
        Test.setCreatedDate(cases[1].Id, Datetime.now().addDays(-3));
        update new List<Case>{
            new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS),
            new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS)
        };
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        System.enqueueJob(new AccountCaseRollupQueueable(new Set<Id>{ acct.Id }));
        Test.stopTest();

        Account reloaded = [
            SELECT Closed_Case_Count__c, Average_Resolution_Time_Days__c,
                Case_Metrics_Last_Calculated__c
            FROM Account
            WHERE Id = :acct.Id
        ];
        Assert.areEqual(2, reloaded.Closed_Case_Count__c, 'The job must roll up both Cases.');
        Assert.isTrue(
            Math.abs(reloaded.Average_Resolution_Time_Days__c - 2.00) < 0.01,
            'The average of 1 and 3 days must be ~2.00; got '
                + reloaded.Average_Resolution_Time_Days__c
        );
        Assert.isNotNull(
            reloaded.Case_Metrics_Last_Calculated__c,
            'The job must stamp the calculation timestamp.'
        );
    }

    @isTest
    static void isRetryableRecognisesOnlyLockErrors() {
        Assert.isTrue(
            AccountCaseRollupQueueable.isRetryable(
                buildException('First error: UNABLE_TO_LOCK_ROW, unable to obtain exclusive access')
            ),
            'UNABLE_TO_LOCK_ROW must be retryable - it is transient contention (A4).'
        );
        Assert.isTrue(
            AccountCaseRollupQueueable.isRetryable(
                buildException('unable_to_lock_row lower case variant')
            ),
            'The lock check must be case-insensitive.'
        );
        Assert.isTrue(
            AccountCaseRollupQueueable.isRetryable(buildException('ROW_LOCK contention detected')),
            'ROW_LOCK must be retryable.'
        );
        Assert.isFalse(
            AccountCaseRollupQueueable.isRetryable(
                buildException('FIELD_CUSTOM_VALIDATION_EXCEPTION: not allowed')
            ),
            'A validation failure must NOT be retried - it must fail loudly.'
        );
        Assert.isFalse(
            AccountCaseRollupQueueable.isRetryable(null),
            'A null exception must not be treated as retryable.'
        );
    }

    @isTest
    static void nonRetryableExceptionIsRethrown() {
        AccountCaseRollupQueueable.retryScheduled = false;
        // A syntactically valid Account Id that does not exist: the update fails with a
        // non-lock error, which must propagate rather than be retried or swallowed.
        Set<Id> missingAccount = new Set<Id>{ fakeAccountId(1) };
        Boolean threw = false;

        Test.startTest();
        try {
            new AccountCaseRollupQueueable(missingAccount).execute(null);
            Assert.fail('A non-retryable exception must propagate out of execute().');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The exception must reach the caller, never be swallowed.');
        Assert.isFalse(
            AccountCaseRollupQueueable.retryScheduled,
            'A non-lock failure must not schedule a retry.'
        );
    }

    @isTest
    static void exhaustedAttemptsRethrowRatherThanLoop() {
        AccountCaseRollupQueueable.retryScheduled = false;
        Set<Id> missingAccount = new Set<Id>{ fakeAccountId(2) };
        Boolean threw = false;

        Test.startTest();
        try {
            new AccountCaseRollupQueueable(
                    missingAccount,
                    AccountCaseRollupQueueable.MAX_ATTEMPTS
                )
                .execute(null);
            Assert.fail('The final attempt must throw rather than schedule another retry.');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'MAX_ATTEMPTS must bound the retry loop.');
        Assert.isFalse(
            AccountCaseRollupQueueable.retryScheduled,
            'No retry may be scheduled once MAX_ATTEMPTS is reached.'
        );
    }

    @isTest
    static void emptyAccountSetIsAHarmlessNoOp() {
        Test.startTest();
        System.enqueueJob(new AccountCaseRollupQueueable(new Set<Id>()));
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Account WHERE Case_Metrics_Last_Calculated__c != NULL],
            'An empty Account set must touch nothing.'
        );
    }

    // ------------------------------------------------------------------------------ helpers

    private static Exception buildException(String message) {
        return new IllegalArgumentException(message);
    }

    private static Id fakeAccountId(Integer seed) {
        String suffix = String.valueOf(seed).leftPad(12, '0');
        return Id.valueOf(Account.SObjectType.getDescribe().getKeyPrefix() + suffix);
    }
}
