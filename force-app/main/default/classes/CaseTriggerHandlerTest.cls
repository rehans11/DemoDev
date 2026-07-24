/**
 * End-to-end tests for CaseTrigger / CaseTriggerHandler, including the bulk scenario.
 *
 * See technical-spec.md sections 6.2 and 6.6.
 */
@isTest
private class CaseTriggerHandlerTest {
    private static final Decimal TOLERANCE = 0.01;

    // ------------------------------------------------------------------------ stamping (AC1)

    @isTest
    static void closingAnAgedCaseStampsResolutionTime() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        Test.setCreatedDate(c.Id, Datetime.now().addDays(-3));

        Test.startTest();
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Test.stopTest();

        Decimal stamped = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;
        Assert.isNotNull(stamped, 'Closing a Case must stamp a resolution time.');
        Assert.isTrue(
            Math.abs(stamped - 3.00) < TOLERANCE,
            'A Case aged three days must stamp approximately 3.00; got ' + stamped
        );
    }

    @isTest
    static void insertingAnAlreadyClosedCaseStampsZero() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];

        Test.startTest();
        Case c = new Case(
            AccountId = acct.Id,
            Subject = 'Closed on create',
            Status = TestDataFactory.CLOSED_STATUS,
            Origin = 'Phone'
        );
        insert c;
        Test.stopTest();

        Decimal stamped = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;
        Assert.areEqual(
            0.00,
            stamped,
            'A Case created already-closed was created and closed in the same instant.'
        );
    }

    @isTest
    static void reopeningAClosedCaseClearsResolutionTime() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        Test.setCreatedDate(c.Id, Datetime.now().addDays(-2));
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Assert.isNotNull(
            [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id].Resolution_Time_Days__c,
            'Precondition: the Case must be stamped before we reopen it.'
        );

        Test.startTest();
        update new Case(Id = c.Id, Status = TestDataFactory.WORKING_STATUS);
        Test.stopTest();

        Assert.isNull(
            [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id].Resolution_Time_Days__c,
            'Reopening must clear the resolution time (D2).'
        );
    }

    @isTest
    static void reclosingRecomputesAgainstTheLatestClose() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        Test.setCreatedDate(c.Id, Datetime.now().addDays(-6));
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Decimal firstValue = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;
        update new Case(Id = c.Id, Status = TestDataFactory.WORKING_STATUS);

        Test.startTest();
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Test.stopTest();

        Decimal secondValue = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;
        Assert.isNotNull(secondValue, 'Re-closing must stamp a value again.');
        Assert.isTrue(
            Math.abs(secondValue - 6.00) < TOLERANCE,
            'Re-close must measure CreatedDate to the LATEST close; got ' + secondValue
        );
        Assert.isTrue(
            Math.abs(secondValue - firstValue) < TOLERANCE,
            'Both closes happened within the same test, so both measure ~6.00 days.'
        );
    }

    @isTest
    static void editingAnAlreadyClosedCaseLeavesTheValueUnchanged() {
        // AC15 / invariant 1 end-to-end. If this ever fails, every routine edit to a closed
        // Case is silently inflating the metric.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        Test.setCreatedDate(c.Id, Datetime.now().addDays(-9));
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Decimal valueAfterClose = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;

        Test.startTest();
        update new Case(Id = c.Id, Subject = 'Subject edited after closure');
        update new Case(Id = c.Id, Subject = 'Edited a second time');
        Test.stopTest();

        Decimal valueAfterEdits = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :c.Id]
            .Resolution_Time_Days__c;
        Assert.areEqual(
            valueAfterClose,
            valueAfterEdits,
            'Saving an already-closed Case must never move the number (invariant 1).'
        );
    }

    @isTest
    static void caseWithNoAccountIsStampedAndCausesNoRollup() {
        // AC9 / D3d.
        Case orphan = new Case(Subject = 'No account', Status = TestDataFactory.OPEN_STATUS);
        insert orphan;
        Test.setCreatedDate(orphan.Id, Datetime.now().addDays(-4));
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        update new Case(Id = orphan.Id, Status = TestDataFactory.CLOSED_STATUS);
        Integer jobsEnqueued = Limits.getQueueableJobs();
        Test.stopTest();

        Decimal stamped = [SELECT Resolution_Time_Days__c FROM Case WHERE Id = :orphan.Id]
            .Resolution_Time_Days__c;
        Assert.isNotNull(stamped, 'An orphan Case must still be stamped (D3d).');
        Assert.isTrue(
            Math.abs(stamped - 4.00) < TOLERANCE,
            'The orphan Case must be stamped correctly; got ' + stamped
        );
        Assert.areEqual(
            0,
            jobsEnqueued,
            'A Case with no Account must roll up nowhere, so nothing may be enqueued.'
        );
    }

    // ------------------------------------------------------- invariant 2: zero DML on Case

    @isTest
    static void triggerPerformsNoDmlOnCase() {
        // AC14. The test's own update must be the ONLY DML statement in the window.
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];

        Test.startTest();
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        Integer dmlInsideWindow = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(
            1,
            dmlInsideWindow,
            'The trigger must add zero DML. Anything above 1 means a self-update crept back '
                + 'in and the before/after split is broken.'
        );
    }

    @isTest
    static void editingAnOpenCaseEnqueuesNothing() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];

        Test.startTest();
        update new Case(Id = c.Id, Subject = 'Just an ordinary edit');
        Integer jobsEnqueued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(
            0,
            jobsEnqueued,
            'Editing an open Case changes no closed-case metric, so no job may be enqueued. '
                + 'This is what keeps ordinary Case editing from flooding the queue.'
        );
    }

    // ----------------------------------------------------------- rollup dispatch paths (AC5)

    @isTest
    static void closingACaseRollsUpToTheAccount() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);

        Test.startTest();
        update new List<Case>{
            new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS),
            new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS)
        };
        Test.stopTest();

        Account reloaded = [
            SELECT Closed_Case_Count__c, Average_Resolution_Time_Days__c,
                Case_Metrics_Last_Calculated__c
            FROM Account
            WHERE Id = :acct.Id
        ];
        Assert.areEqual(2, reloaded.Closed_Case_Count__c, 'Both closed Cases must be counted.');
        Assert.isNotNull(
            reloaded.Average_Resolution_Time_Days__c,
            'Both Cases have a valid resolution time, so the average must be populated.'
        );
        Assert.isNotNull(
            reloaded.Case_Metrics_Last_Calculated__c,
            'The rollup must stamp Case_Metrics_Last_Calculated__c (D3c).'
        );
    }

    @isTest
    static void reparentingAClosedCaseUpdatesBothAccounts() {
        List<Account> accounts = TestDataFactory.createAccounts(2, true);
        Case c = TestDataFactory.createCases(accounts[0].Id, 1, true)[0];
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        AccountCaseRollupService.recalculate(
            new Set<Id>{ accounts[0].Id, accounts[1].Id }
        );
        Assert.areEqual(
            1,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :accounts[0].Id]
                .Closed_Case_Count__c,
            'Precondition: the original Account owns the closed Case.'
        );
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        update new Case(Id = c.Id, AccountId = accounts[1].Id);
        Test.stopTest();

        Map<Id, Account> byId = new Map<Id, Account>(
            [
                SELECT Id, Closed_Case_Count__c
                FROM Account
                WHERE Id IN :new List<Id>{ accounts[0].Id, accounts[1].Id }
            ]
        );
        Assert.areEqual(
            0,
            byId.get(accounts[0].Id).Closed_Case_Count__c,
            'The old Account must lose the re-parented Case - this is why both Ids are '
                + 'collected on update.'
        );
        Assert.areEqual(
            1,
            byId.get(accounts[1].Id).Closed_Case_Count__c,
            'The new Account must gain the re-parented Case.'
        );
    }

    @isTest
    static void deletingAClosedCaseDecrementsTheAccountCount() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        update new List<Case>{
            new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS),
            new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS)
        };
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Assert.areEqual(
            2,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'Precondition: the Account has two closed Cases.'
        );
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        delete new Case(Id = cases[0].Id);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'Deleting a closed Case must drop the Account count by one.'
        );
    }

    @isTest
    static void undeletingAClosedCaseRestoresTheAccountCount() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        Case c = TestDataFactory.createCases(acct.Id, 1, true)[0];
        update new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS);
        delete new Case(Id = c.Id);
        AccountCaseRollupService.recalculate(new Set<Id>{ acct.Id });
        Assert.areEqual(
            0,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'Precondition: the Account has lost its only closed Case.'
        );
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        undelete new Case(Id = c.Id);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'Undeleting must restore the Account count; field values survive a delete so no '
                + 're-stamp is needed.'
        );
    }

    @isTest
    static void insertingAlreadyClosedCasesRollsUpImmediately() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];

        Test.startTest();
        insert new List<Case>{
            new Case(
                AccountId = acct.Id,
                Subject = 'A',
                Status = TestDataFactory.CLOSED_STATUS,
                Origin = 'Phone'
            ),
            new Case(
                AccountId = acct.Id,
                Subject = 'B',
                Status = TestDataFactory.CLOSED_STATUS,
                Origin = 'Phone'
            )
        };
        Test.stopTest();

        Assert.areEqual(
            2,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'Cases inserted already closed must roll up on after insert.'
        );
    }

    @isTest
    static void repeatedDispatchesForTheSameAccountAreDeduped() {
        Account acct = TestDataFactory.createAccounts(1, true)[0];
        List<Case> cases = TestDataFactory.createCases(acct.Id, 2, true);
        CaseTriggerHandler.enqueuedAccountIds.clear();

        Test.startTest();
        update new Case(Id = cases[0].Id, Status = TestDataFactory.CLOSED_STATUS);
        update new Case(Id = cases[1].Id, Status = TestDataFactory.CLOSED_STATUS);
        Integer jobsEnqueued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(
            1,
            jobsEnqueued,
            'Two separate DML statements touching the same Account must enqueue only one '
                + 'job - the per-transaction dedupe (A3).'
        );
        Assert.areEqual(
            2,
            [SELECT Closed_Case_Count__c FROM Account WHERE Id = :acct.Id].Closed_Case_Count__c,
            'The single job must still produce the correct final count.'
        );
    }

    // ---------------------------------------------------------------------- bulk (AC6, 6.6)

    @isTest
    static void bulkCloseOf250CasesAcross5AccountsIsConstantCost() {
        List<Account> accounts = TestDataFactory.createAccounts(5, true);
        List<Case> cases = new List<Case>();
        for (Account acct : accounts) {
            cases.addAll(TestDataFactory.createCases(acct.Id, 50, false));
        }
        insert cases;
        Assert.areEqual(250, cases.size(), 'Arrange: 5 Accounts x 50 Cases.');

        List<Case> closures = new List<Case>();
        for (Case c : cases) {
            closures.add(new Case(Id = c.Id, Status = TestDataFactory.CLOSED_STATUS));
        }

        Test.startTest();
        update closures;
        Integer dmlInsideWindow = Limits.getDmlStatements();
        Integer queriesInsideWindow = Limits.getQueries();
        Integer jobsInsideWindow = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(
            1,
            dmlInsideWindow,
            'The trigger must contribute ZERO DML however many records are in scope - this '
                + 'assertion is the proof of invariant 2.'
        );
        Assert.isTrue(
            queriesInsideWindow <= 2,
            'The cached CaseStatus lookup must not repeat per record or per trigger pass; '
                + 'got ' + queriesInsideWindow
        );
        // SPEC DISCREPANCY, FLAGGED FOR REVIEW - technical-spec 6.6 asserts exactly 1
        // Queueable here, but that is arithmetically impossible for 250 records: the
        // platform processes a DML statement in chunks of 200, so the trigger fires TWICE
        // (200 + 50) and each pass sees a disjoint set of Accounts (1-4, then 5). The
        // dedupe cannot merge them because they never overlap. The spec's own governor
        // table (3.0.4) is explicit that the "1 Queueable" figure applies to "1 or 200
        // records". 2 is therefore the correct expectation and the design is sound.
        //
        // What the assertion must actually prove is that cost is driven by DML chunks, not
        // by record or Account count - so it is asserted against that formula, not a
        // literal.
        Integer expectedDmlChunks = 2;
        Assert.areEqual(
            expectedDmlChunks,
            jobsInsideWindow,
            'One Queueable per 200-record DML chunk, NOT one per Case (250) or one per '
                + 'Account (5) - the per-transaction dedupe held within each pass.'
        );
        Assert.isTrue(
            jobsInsideWindow < accounts.size(),
            'Job count must not scale with the number of Accounts touched.'
        );

        Integer unstamped = [
            SELECT COUNT()
            FROM Case
            WHERE Id IN :cases AND Resolution_Time_Days__c = NULL
        ];
        Assert.areEqual(0, unstamped, 'All 250 Cases must carry a resolution time.');

        List<Account> reloaded = [
            SELECT Id, Closed_Case_Count__c, Average_Resolution_Time_Days__c
            FROM Account
            WHERE Id IN :accounts
        ];
        Assert.areEqual(5, reloaded.size(), 'All five Accounts must be returned.');
        for (Account acct : reloaded) {
            Assert.areEqual(
                50,
                acct.Closed_Case_Count__c,
                'Each Account must count its own 50 closed Cases.'
            );
            Assert.isNotNull(
                acct.Average_Resolution_Time_Days__c,
                'Each Account must have a computed average.'
            );
            Assert.isTrue(
                acct.Average_Resolution_Time_Days__c < TOLERANCE,
                'Cases created and closed within the test measure ~0 days; got '
                    + acct.Average_Resolution_Time_Days__c
            );
        }
    }
}
