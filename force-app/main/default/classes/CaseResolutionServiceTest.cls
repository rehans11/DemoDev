/**
 * Unit tests for CaseResolutionService.
 *
 * Every method here is a PURE in-memory call: no DML, no SOQL, no org data. That is only
 * possible because the service takes the closed-status set and the "now" instant as
 * injected arguments (invariant 3) - Case.CreatedDate / ClosedDate cannot be set on a
 * record, so the arithmetic could not otherwise be exercised at the boundaries.
 *
 * See technical-spec.md section 6.1.
 */
@isTest
private class CaseResolutionServiceTest {
    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Closed' };
    private static final Datetime FIXED_NOW = Datetime.newInstanceGmt(2026, 7, 23, 12, 0, 0);

    // ---------------------------------------------------------------- calculateResolutionDays

    @isTest
    static void calculateResolutionDaysReturnsWholeDaysForThreeDayGap() {
        Datetime closed = FIXED_NOW;
        Datetime created = FIXED_NOW.addDays(-3);

        Decimal result = CaseResolutionService.calculateResolutionDays(created, closed);

        Assert.areEqual(3.00, result, 'A three day gap must be exactly 3.00 days.');
    }

    @isTest
    static void calculateResolutionDaysRoundsHalfUpToTwoDecimals() {
        // 36 minutes = 0.025 days, which must round HALF_UP to 0.03.
        Decimal result = CaseResolutionService.calculateResolutionDays(
            FIXED_NOW,
            FIXED_NOW.addMinutes(36)
        );

        Assert.areEqual(0.03, result, '36 minutes must round HALF_UP to 0.03 days.');
    }

    @isTest
    static void calculateResolutionDaysReturnsZeroForIdenticalInstants() {
        Decimal result = CaseResolutionService.calculateResolutionDays(FIXED_NOW, FIXED_NOW);

        Assert.areEqual(0.00, result, 'Identical instants must yield exactly 0.00 days.');
    }

    @isTest
    static void calculateResolutionDaysReturnsNullWhenClosedPrecedesCreated() {
        // This is the D3b / research-spec E32 guard: all 23 seeded closed Cases in this org
        // have ClosedDate about 13.5 months BEFORE CreatedDate.
        Decimal result = CaseResolutionService.calculateResolutionDays(
            FIXED_NOW,
            FIXED_NOW.addDays(-410)
        );

        Assert.isNull(result, 'A negative duration must be stored as null, never negative.');
    }

    @isTest
    static void calculateResolutionDaysReturnsNullForOneMillisecondNegative() {
        Decimal result = CaseResolutionService.calculateResolutionDays(
            FIXED_NOW,
            FIXED_NOW.addSeconds(-1)
        );

        Assert.isNull(result, 'Even a one second negative gap must yield null.');
    }

    @isTest
    static void calculateResolutionDaysReturnsNullForNullArguments() {
        Assert.isNull(
            CaseResolutionService.calculateResolutionDays(null, FIXED_NOW),
            'Null createdDate must yield null.'
        );
        Assert.isNull(
            CaseResolutionService.calculateResolutionDays(FIXED_NOW, null),
            'Null closedDate must yield null.'
        );
        Assert.isNull(
            CaseResolutionService.calculateResolutionDays(null, null),
            'Two null arguments must yield null.'
        );
    }

    // ----------------------------------------------------------------- applyResolutionTimes
    // The transition matrix. This is where invariant 1 lives.

    @isTest
    static void applyResolutionTimesLeavesOpenCaseOnInsertNull() {
        List<Case> newCases = new List<Case>{ new Case(Status = 'New') };

        CaseResolutionService.applyResolutionTimes(newCases, null, CLOSED_STATUSES, FIXED_NOW);

        Assert.isNull(
            newCases[0].Resolution_Time_Days__c,
            'A Case inserted open must have no resolution time.'
        );
    }

    @isTest
    static void applyResolutionTimesStampsZeroForCaseInsertedAlreadyClosed() {
        // On before insert CreatedDate is not yet assigned: created and closed in the same
        // instant is definitionally 0.00 days.
        List<Case> newCases = new List<Case>{ new Case(Status = 'Closed') };

        CaseResolutionService.applyResolutionTimes(newCases, null, CLOSED_STATUSES, FIXED_NOW);

        Assert.areEqual(
            0.00,
            newCases[0].Resolution_Time_Days__c,
            'A Case created already-closed must be stamped 0.00.'
        );
    }

    @isTest
    static void applyResolutionTimesStampsOnFirstCloseFromNew() {
        Id caseId = fakeCaseId(1);
        Case oldCase = new Case(Id = caseId, Status = 'New');
        Case newCase = buildAgedCase(caseId, 'Closed', FIXED_NOW.addDays(-5), null);

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ newCase },
            new Map<Id, Case>{ caseId => oldCase },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(
            5.00,
            newCase.Resolution_Time_Days__c,
            'New -> Closed must compute from CreatedDate to the injected now instant.'
        );
    }

    @isTest
    static void applyResolutionTimesStampsOnCloseFromWorking() {
        Id caseId = fakeCaseId(2);
        Case oldCase = new Case(Id = caseId, Status = 'Working');
        Case newCase = buildAgedCase(caseId, 'Closed', FIXED_NOW.addDays(-2), null);

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ newCase },
            new Map<Id, Case>{ caseId => oldCase },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(
            2.00,
            newCase.Resolution_Time_Days__c,
            'Closing from any open status must stamp the value.'
        );
    }

    @isTest
    static void applyResolutionTimesLeavesAlreadyClosedCaseUntouched() {
        // INVARIANT 1. Without this branch every later save of a closed Case would re-stamp
        // against a fresh now instant and silently inflate the metric forever.
        Id caseId = fakeCaseId(3);
        Case oldCase = new Case(Id = caseId, Status = 'Closed');
        Case newCase = buildAgedCase(caseId, 'Closed', FIXED_NOW.addDays(-400), 99.99);

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ newCase },
            new Map<Id, Case>{ caseId => oldCase },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(
            99.99,
            newCase.Resolution_Time_Days__c,
            'Closed -> Closed must leave the existing value completely untouched.'
        );
    }

    @isTest
    static void applyResolutionTimesClearsValueOnReopen() {
        Id caseId = fakeCaseId(4);
        Case oldCase = new Case(Id = caseId, Status = 'Closed');
        Case newCase = buildAgedCase(caseId, 'Working', FIXED_NOW.addDays(-7), 7.00);

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ newCase },
            new Map<Id, Case>{ caseId => oldCase },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.isNull(
            newCase.Resolution_Time_Days__c,
            'Reopening a Case must clear the resolution time (D2).'
        );
    }

    @isTest
    static void applyResolutionTimesRecomputesOnRecloseAgainstLatestInstant() {
        Id caseId = fakeCaseId(5);
        Datetime created = FIXED_NOW.addDays(-10);

        // 1. First close, three days after creation.
        Case firstClose = buildAgedCase(caseId, 'Closed', created, null);
        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ firstClose },
            new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'New') },
            CLOSED_STATUSES,
            created.addDays(3)
        );
        Assert.areEqual(3.00, firstClose.Resolution_Time_Days__c, 'First close is 3.00 days.');

        // 2. Reopen.
        Case reopened = buildAgedCase(caseId, 'Working', created, 3.00);
        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ reopened },
            new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'Closed') },
            CLOSED_STATUSES,
            created.addDays(5)
        );
        Assert.isNull(reopened.Resolution_Time_Days__c, 'Reopen clears the value.');

        // 3. Re-close, ten days after creation.
        Case reclosed = buildAgedCase(caseId, 'Closed', created, null);
        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ reclosed },
            new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'Working') },
            CLOSED_STATUSES,
            created.addDays(10)
        );

        Assert.areEqual(
            10.00,
            reclosed.Resolution_Time_Days__c,
            'Re-close must recompute to the LATEST close, not freeze the first (D2).'
        );
    }

    @isTest
    static void applyResolutionTimesStoresNullWhenCreatedDateIsAfterNow() {
        // The negative guard reached through the real entry point rather than the pure method.
        Id caseId = fakeCaseId(6);
        Case newCase = buildAgedCase(caseId, 'Closed', FIXED_NOW.addDays(410), null);

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ newCase },
            new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'New') },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.isNull(
            newCase.Resolution_Time_Days__c,
            'CreatedDate after the close instant must store null, not a negative number.'
        );
    }

    @isTest
    static void applyResolutionTimesHonoursEveryInjectedClosedStatus() {
        // Proves nothing hardcodes the literal 'Closed' (AC16).
        Set<String> multipleClosed = new Set<String>{ 'Closed', 'Closed - No Response' };
        Id firstId = fakeCaseId(7);
        Id secondId = fakeCaseId(8);
        Case standardClose = buildAgedCase(firstId, 'Closed', FIXED_NOW.addDays(-1), null);
        Case customClose = buildAgedCase(
            secondId,
            'Closed - No Response',
            FIXED_NOW.addDays(-4),
            null
        );

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ standardClose, customClose },
            new Map<Id, Case>{
                firstId => new Case(Id = firstId, Status = 'New'),
                secondId => new Case(Id = secondId, Status = 'New')
            },
            multipleClosed,
            FIXED_NOW
        );

        Assert.areEqual(1.00, standardClose.Resolution_Time_Days__c, 'Closed must stamp.');
        Assert.areEqual(
            4.00,
            customClose.Resolution_Time_Days__c,
            'Any status in the injected closed set must stamp, not just the literal Closed.'
        );
    }

    @isTest
    static void applyResolutionTimesHandlesNullAndEmptyInputWithoutException() {
        CaseResolutionService.applyResolutionTimes(null, null, CLOSED_STATUSES, FIXED_NOW);
        CaseResolutionService.applyResolutionTimes(
            new List<Case>(),
            null,
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(
            0,
            Limits.getDmlStatements(),
            'Null / empty input must be a complete no-op.'
        );
    }

    @isTest
    static void applyResolutionTimesPerformsNoSoqlAndNoDml() {
        // Invariant 3: the service is pure.
        Id caseId = fakeCaseId(9);
        List<Case> newCases = new List<Case>{
            buildAgedCase(caseId, 'Closed', FIXED_NOW.addDays(-1), null)
        };
        Integer dmlBefore = Limits.getDmlStatements();
        Integer queriesBefore = Limits.getQueries();

        CaseResolutionService.applyResolutionTimes(
            newCases,
            new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'New') },
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'The service must issue no DML.');
        Assert.areEqual(queriesBefore, Limits.getQueries(), 'The service must issue no SOQL.');
    }

    @isTest
    static void applyResolutionTimesHasNoHiddenClock() {
        // Two calls with the same injected instant must produce identical values, proving
        // the service never calls System.now() of its own.
        Id caseId = fakeCaseId(10);
        Datetime created = FIXED_NOW.addDays(-6);
        Case first = buildAgedCase(caseId, 'Closed', created, null);
        Case second = buildAgedCase(caseId, 'Closed', created, null);
        Map<Id, Case> oldMap = new Map<Id, Case>{ caseId => new Case(Id = caseId, Status = 'New') };

        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ first },
            oldMap,
            CLOSED_STATUSES,
            FIXED_NOW
        );
        CaseResolutionService.applyResolutionTimes(
            new List<Case>{ second },
            oldMap,
            CLOSED_STATUSES,
            FIXED_NOW
        );

        Assert.areEqual(
            first.Resolution_Time_Days__c,
            second.Resolution_Time_Days__c,
            'The same injected instant must always produce the same value.'
        );
        Assert.areEqual(6.00, first.Resolution_Time_Days__c, 'Six days elapsed.');
    }

    // ---------------------------------------------------------------- buildResolutionUpdates

    @isTest
    static void buildResolutionUpdatesComputesFromStoredClosedDate() {
        Id caseId = fakeCaseId(11);
        Case historical = buildBackfillCase(caseId, true, FIXED_NOW.addDays(-8), FIXED_NOW, null);

        List<Case> updates = CaseResolutionService.buildResolutionUpdates(
            new List<Case>{ historical }
        );

        Assert.areEqual(1, updates.size(), 'A Case needing a value must be returned.');
        Assert.areEqual(
            8.00,
            updates[0].Resolution_Time_Days__c,
            'The backfill variant must compute from the stored ClosedDate.'
        );
        Assert.areEqual(caseId, updates[0].Id, 'The returned record must carry the Case Id.');
    }

    @isTest
    static void buildResolutionUpdatesReturnsNullForNegativeStoredDuration() {
        Id caseId = fakeCaseId(12);
        Case dirty = buildBackfillCase(
            caseId,
            true,
            FIXED_NOW,
            FIXED_NOW.addDays(-410),
            42.00
        );

        List<Case> updates = CaseResolutionService.buildResolutionUpdates(new List<Case>{ dirty });

        Assert.areEqual(1, updates.size(), 'The stale value must be scheduled for clearing.');
        Assert.isNull(
            updates[0].Resolution_Time_Days__c,
            'ClosedDate before CreatedDate must backfill to null (D3b).'
        );
    }

    @isTest
    static void buildResolutionUpdatesClearsStaleValueOnOpenCase() {
        Id caseId = fakeCaseId(13);
        Case reopened = buildBackfillCase(caseId, false, FIXED_NOW.addDays(-3), null, 3.00);

        List<Case> updates = CaseResolutionService.buildResolutionUpdates(
            new List<Case>{ reopened }
        );

        Assert.areEqual(1, updates.size(), 'An open Case holding a value must be corrected.');
        Assert.isNull(
            updates[0].Resolution_Time_Days__c,
            'An open Case must have its stale resolution time cleared.'
        );
    }

    @isTest
    static void buildResolutionUpdatesSkipsCasesAlreadyCorrect() {
        Id closedId = fakeCaseId(14);
        Id openId = fakeCaseId(15);
        Case alreadyCorrect = buildBackfillCase(
            closedId,
            true,
            FIXED_NOW.addDays(-2),
            FIXED_NOW,
            2.00
        );
        Case openAndBlank = buildBackfillCase(openId, false, FIXED_NOW.addDays(-2), null, null);

        List<Case> updates = CaseResolutionService.buildResolutionUpdates(
            new List<Case>{ alreadyCorrect, openAndBlank }
        );

        Assert.areEqual(
            0,
            updates.size(),
            'Cases already holding the correct value must not be re-DMLd.'
        );
    }

    @isTest
    static void buildResolutionUpdatesHandlesNullAndEmptyInput() {
        Integer dmlBefore = Limits.getDmlStatements();

        Assert.areEqual(
            0,
            CaseResolutionService.buildResolutionUpdates(null).size(),
            'Null input must return an empty list.'
        );
        Assert.areEqual(
            0,
            CaseResolutionService.buildResolutionUpdates(new List<Case>()).size(),
            'Empty input must return an empty list.'
        );
        Assert.areEqual(
            dmlBefore,
            Limits.getDmlStatements(),
            'buildResolutionUpdates must perform no DML of its own.'
        );
    }

    // ------------------------------------------------------------------------------ helpers

    /**
     * Builds an in-memory Case with a populated CreatedDate. CreatedDate is not writable via
     * the constructor, so the record is round-tripped through JSON - the standard technique
     * for exercising audit fields in a pure unit test.
     */
    private static Case buildAgedCase(
        Id caseId,
        String status,
        Datetime createdDate,
        Decimal existingValue
    ) {
        Map<String, Object> fields = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Case' },
            'Id' => caseId,
            'Status' => status,
            'CreatedDate' => createdDate
        };
        if (existingValue != null) {
            fields.put('Resolution_Time_Days__c', existingValue);
        }
        return (Case) JSON.deserialize(JSON.serialize(fields), Case.class);
    }

    private static Case buildBackfillCase(
        Id caseId,
        Boolean isClosed,
        Datetime createdDate,
        Datetime closedDate,
        Decimal existingValue
    ) {
        Map<String, Object> fields = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Case' },
            'Id' => caseId,
            'IsClosed' => isClosed,
            'CreatedDate' => createdDate
        };
        if (closedDate != null) {
            fields.put('ClosedDate', closedDate);
        }
        if (existingValue != null) {
            fields.put('Resolution_Time_Days__c', existingValue);
        }
        return (Case) JSON.deserialize(JSON.serialize(fields), Case.class);
    }

    private static Id fakeCaseId(Integer seed) {
        String suffix = String.valueOf(seed).leftPad(12, '0');
        return Id.valueOf(Case.SObjectType.getDescribe().getKeyPrefix() + suffix);
    }
}
