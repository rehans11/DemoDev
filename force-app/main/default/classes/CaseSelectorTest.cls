/**
 * Tests for CaseSelector.
 *
 * See technical-spec.md section 6.5.
 */
@isTest
private class CaseSelectorTest {
    @isTest
    static void getClosedStatusLabelsReturnsTheOrgsClosedStatuses() {
        CaseSelector.cachedClosedStatuses = null;

        Set<String> closedStatuses = CaseSelector.getClosedStatusLabels();

        Assert.isFalse(
            closedStatuses.isEmpty(),
            'The whole before-context design depends on CaseStatus returning at least one '
                + 'closed status. An empty set means the feature would silently never stamp.'
        );
        Assert.isTrue(
            closedStatuses.contains('Closed'),
            'This org has exactly one closed status, master label "Closed".'
        );
        Assert.isFalse(
            closedStatuses.contains('New'),
            'Open statuses must never appear in the closed set.'
        );
        Assert.isFalse(
            closedStatuses.contains('Working'),
            'Open statuses must never appear in the closed set.'
        );
    }

    @isTest
    static void getClosedStatusLabelsIsStaticallyCached() {
        CaseSelector.cachedClosedStatuses = null;

        Set<String> firstCall = CaseSelector.getClosedStatusLabels();
        Integer queriesAfterFirstCall = Limits.getQueries();
        Set<String> secondCall = CaseSelector.getClosedStatusLabels();

        Assert.areEqual(
            queriesAfterFirstCall,
            Limits.getQueries(),
            'The second call must be served from the static cache and issue no SOQL (AC16).'
        );
        Assert.areEqual(firstCall, secondCall, 'The cache must return the same set.');
    }

    @isTest
    static void getClosedStatusLabelsHonoursAnInjectedCache() {
        // The @TestVisible cache is the seam that lets a test inject a synthetic set.
        CaseSelector.cachedClosedStatuses = new Set<String>{ 'Synthetic Closed' };

        Set<String> result = CaseSelector.getClosedStatusLabels();

        Assert.areEqual(
            new Set<String>{ 'Synthetic Closed' },
            result,
            'An injected cache must be returned untouched.'
        );
        CaseSelector.cachedClosedStatuses = null;
    }

    @isTest
    static void aggregateClosedCaseMetricsGroupsByAccount() {
        List<Account> accounts = TestDataFactory.createAccounts(2, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 3, false);
        cases.addAll(TestDataFactory.createCases(accounts[1].Id, 1, false));
        insert cases;
        for (Case c : cases) {
            c.Status = TestDataFactory.CLOSED_STATUS;
        }

        Test.startTest();
        update cases;
        Test.stopTest();

        List<AggregateResult> results = CaseSelector.aggregateClosedCaseMetrics(
            new List<Id>{ accounts[0].Id, accounts[1].Id }
        );

        Map<Id, Integer> countByAccount = new Map<Id, Integer>();
        for (AggregateResult ar : results) {
            countByAccount.put((Id) ar.get('accId'), (Integer) ar.get('caseCount'));
        }
        Assert.areEqual(2, countByAccount.size(), 'Both Accounts must appear in the aggregate.');
        Assert.areEqual(3, countByAccount.get(accounts[0].Id), 'First Account has 3 closed.');
        Assert.areEqual(1, countByAccount.get(accounts[1].Id), 'Second Account has 1 closed.');
    }

    @isTest
    static void aggregateClosedCaseMetricsExcludesOpenCases() {
        List<Account> accounts = TestDataFactory.createAccounts(1, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 4, true);
        cases[0].Status = TestDataFactory.CLOSED_STATUS;

        Test.startTest();
        update cases[0];
        Test.stopTest();

        List<AggregateResult> results = CaseSelector.aggregateClosedCaseMetrics(
            new List<Id>{ accounts[0].Id }
        );

        Assert.areEqual(1, results.size(), 'One group for the one Account.');
        Assert.areEqual(
            1,
            (Integer) results[0].get('caseCount'),
            'Only the closed Case may be counted; the three open ones must be excluded.'
        );
    }

    @isTest
    static void closedCaseBackfillLocatorSelectsAllCasesIncludingOpenOnes() {
        List<Account> accounts = TestDataFactory.createAccounts(1, true);
        List<Case> cases = TestDataFactory.createCases(accounts[0].Id, 3, true);
        cases[0].Status = TestDataFactory.CLOSED_STATUS;
        update cases[0];

        Test.startTest();
        Database.QueryLocator locator = CaseSelector.closedCaseBackfillLocator();
        Database.QueryLocatorIterator iterator = locator.iterator();
        Integer rowCount = 0;
        while (iterator.hasNext()) {
            iterator.next();
            rowCount++;
        }
        Test.stopTest();

        Assert.areEqual(
            3,
            rowCount,
            'The backfill locator must select ALL Cases, not just closed ones, so a reopened '
                + 'Case can have its stale value cleared.'
        );
    }
}
