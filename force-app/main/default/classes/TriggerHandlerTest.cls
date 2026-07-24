/**
 * Tests for the TriggerHandler base framework.
 *
 * See technical-spec.md section 6.5.
 */
@isTest
private class TriggerHandlerTest {
    private static final String CASE_HANDLER = 'CaseTriggerHandler';

    @isTest
    static void bypassRoundTripsAndIsCaseInsensitive() {
        Assert.isFalse(
            TriggerHandler.isBypassed(CASE_HANDLER),
            'Nothing must be bypassed by default.'
        );

        TriggerHandler.bypass(CASE_HANDLER);
        Assert.isTrue(TriggerHandler.isBypassed(CASE_HANDLER), 'bypass must register.');
        Assert.isTrue(
            TriggerHandler.isBypassed('casetriggerhandler'),
            'The bypass lookup must be case-insensitive.'
        );
        Assert.isTrue(
            TriggerHandler.isBypassed('CASETRIGGERHANDLER'),
            'The bypass lookup must be case-insensitive.'
        );

        TriggerHandler.clearBypass('CASETRIGGERHANDLER');
        Assert.isFalse(
            TriggerHandler.isBypassed(CASE_HANDLER),
            'clearBypass must remove the entry regardless of casing.'
        );
    }

    @isTest
    static void clearAllBypassesRemovesEveryEntry() {
        TriggerHandler.bypass(CASE_HANDLER);
        TriggerHandler.bypass('SomeOtherHandler');

        TriggerHandler.clearAllBypasses();

        Assert.isFalse(TriggerHandler.isBypassed(CASE_HANDLER), 'All bypasses must clear.');
        Assert.isFalse(
            TriggerHandler.isBypassed('SomeOtherHandler'),
            'All bypasses must clear.'
        );
    }

    @isTest
    static void bypassedHandlerDoesNoWork() {
        List<Account> accounts = TestDataFactory.createAccounts(1, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 1, true);
        TriggerHandler.bypass(CASE_HANDLER);

        Test.startTest();
        cases[0].Status = TestDataFactory.CLOSED_STATUS;
        update cases[0];
        Test.stopTest();

        TriggerHandler.clearBypass(CASE_HANDLER);
        Case reloaded = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :cases[0].Id];
        Assert.isNull(
            reloaded.Resolution_Time_Days__c,
            'A bypassed handler must do no work at all, so the Case must stay unstamped.'
        );
    }

    @isTest
    static void runOutsideTriggerContextThrows() {
        Boolean threw = false;
        try {
            new CaseTriggerHandler().run();
            Assert.fail('run() outside a trigger must throw TriggerHandlerException.');
        } catch (TriggerHandler.TriggerHandlerException e) {
            threw = true;
            Assert.areEqual(
                'TriggerHandler.run() may only be called from trigger context.',
                e.getMessage(),
                'The exception message must name the misuse precisely.'
            );
        }
        Assert.isTrue(threw, 'A TriggerHandlerException must have been raised.');
    }

    @isTest
    static void maxRunGuardThrowsOnceExceeded() {
        List<Account> accounts = TestDataFactory.createAccounts(1, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 1, true);

        // Drive the counter to the ceiling so the very next trigger pass trips the guard.
        TriggerHandler.runCounts.put('casetriggerhandler', TriggerHandler.MAX_RUNS);

        Boolean threw = false;
        Test.startTest();
        try {
            cases[0].Status = TestDataFactory.CLOSED_STATUS;
            update cases[0];
            Assert.fail('Exceeding MAX_RUNS must throw.');
        } catch (Exception e) {
            threw = true;
            Assert.isTrue(
                e.getMessage().contains('Maximum trigger runs'),
                'The failure must be the MAX_RUNS guard, not something else. Got: '
                    + e.getMessage()
            );
        }
        Test.stopTest();

        TriggerHandler.runCounts.clear();
        Assert.isTrue(threw, 'The max-run guard must have fired.');
    }

    @isTest
    static void runCountsRecordExactlyOneBeforeAndOneAfterPass() {
        // AC14 / no re-entrancy: a single update must produce exactly two handler runs -
        // one before, one after. A third would mean the trigger re-fired itself.
        List<Account> accounts = TestDataFactory.createAccounts(1, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 1, true);
        TriggerHandler.runCounts.clear();

        Test.startTest();
        cases[0].Status = TestDataFactory.CLOSED_STATUS;
        update cases[0];
        Integer runsInsideWindow = TriggerHandler.runCounts.get('casetriggerhandler');
        Test.stopTest();

        Assert.areEqual(
            2,
            runsInsideWindow,
            'Exactly one before pass and one after pass - never a third, which would mean '
                + 'the handler performed DML on Case and re-entered itself.'
        );
    }
}
