/**
 * Operational repair tool. Not executed as part of any deployment. Run only with explicit
 * user approval - it performs DML on production-of-record data. Per D6 in the technical
 * spec.
 *
 * Stage 1 of a two-stage repair: recompute Resolution_Time_Days__c on every Case from its
 * stored CreatedDate / ClosedDate, then chain AccountCaseMetricsRecalcBatch so that every
 * Case stamp is committed before any Account is aggregated.
 *
 * `with sharing` per the .claude/rules/apex.md default; AccountCaseRollupService is the one
 * deliberately `without sharing` class in this feature.
 * Deliberately NOT Database.Stateful.
 *
 * See technical-spec.md section 3.9.
 */
public with sharing class CaseResolutionBackfillBatch implements Database.Batchable<SObject> {
    private static final String CASE_HANDLER_NAME = 'CaseTriggerHandler';
    private static final Integer RECALC_SCOPE_SIZE = 200;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return CaseSelector.closedCaseBackfillLocator();
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        // The bypass is LOAD-BEARING, not hygiene, for two independent reasons:
        //  1. Each scope's update fires the after contexts, which would enqueue a Queueable
        //     - and a Batch execute() may enqueue only ONE (technical-spec A3). Scope 2
        //     onward would throw.
        //  2. It also fires before update, where applyResolutionTimes would see an
        //     already-closed Case staying closed and, correctly per invariant 1, leave the
        //     value alone. That is harmless, but relying on it would couple this batch to
        //     the trigger's transition logic. The bypass makes this batch authoritative.
        TriggerHandler.bypass(CASE_HANDLER_NAME);
        try {
            List<Case> updates = CaseResolutionService.buildResolutionUpdates((List<Case>) scope);
            if (!updates.isEmpty()) {
                update updates;
            }
        } finally {
            TriggerHandler.clearBypass(CASE_HANDLER_NAME);
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Chaining stage 2 is what makes the two-stage repair correct.
        Database.executeBatch(new AccountCaseMetricsRecalcBatch(), RECALC_SCOPE_SIZE);
    }
}
