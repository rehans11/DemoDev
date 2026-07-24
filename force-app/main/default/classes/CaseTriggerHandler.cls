/**
 * The only Case trigger handler. Two jobs, cleanly split across the before/after boundary:
 *
 *  - BEFORE insert/update: stamp Resolution_Time_Days__c directly onto Trigger.new.
 *    In-memory write, ZERO DML, so nothing re-fires (invariant 2). Closed-ness is derived
 *    from Status against CaseSelector.getClosedStatusLabels(); IsClosed and ClosedDate are
 *    never read here because they are not reliably populated in a before context
 *    (invariant 4).
 *
 *  - AFTER insert/update/delete/undelete: collect the affected Account Ids and dispatch the
 *    rollup. IsClosed / ClosedDate are the committed values here and are safe to read.
 *
 * There is deliberately NO recursion / re-entrancy flag in this class. Both became
 * unnecessary when the stamp moved to a before context - there is no DML on Case, so there
 * is nothing to re-enter. TriggerHandler's MAX_RUNS counter remains only as a generic
 * safety net.
 *
 * `inherited sharing`: the handler does no unqualified querying of its own; the sharing
 * decision belongs to the services it calls.
 *
 * See technical-spec.md sections 3.0 and 3.3.
 */
public inherited sharing class CaseTriggerHandler extends TriggerHandler {
    /** Per-transaction dedupe, so the same Account is not enqueued twice (technical-spec A3). */
    @TestVisible
    private static Set<Id> enqueuedAccountIds = new Set<Id>();

    /** True when the last dispatch fell back to a synchronous rollup for lack of a slot. */
    @TestVisible
    private static Boolean lastRunUsedSyncFallback = false;

    protected override void beforeInsert() {
        stamp((List<Case>) Trigger.new, null);
    }

    protected override void beforeUpdate() {
        stamp((List<Case>) Trigger.new, (Map<Id, Case>) Trigger.oldMap);
    }

    protected override void afterInsert() {
        dispatchRollup((List<Case>) Trigger.new, null);
    }

    protected override void afterUpdate() {
        dispatchRollup((List<Case>) Trigger.new, (Map<Id, Case>) Trigger.oldMap);
    }

    protected override void afterDelete() {
        dispatchRollup(null, (Map<Id, Case>) Trigger.oldMap);
    }

    protected override void afterUndelete() {
        dispatchRollup((List<Case>) Trigger.new, null);
    }

    /**
     * System.now() is captured once here and injected, so every Case in the batch shares one
     * consistent instant and CaseResolutionService stays pure (invariant 3).
     * The service mutates newCases in place - no DML, no return value to write back.
     */
    private void stamp(List<Case> newCases, Map<Id, Case> oldMap) {
        CaseResolutionService.applyResolutionTimes(
            newCases,
            oldMap,
            CaseSelector.getClosedStatusLabels(),
            System.now()
        );
    }

    private void dispatchRollup(List<Case> newCases, Map<Id, Case> oldMap) {
        Set<Id> affected = new Set<Id>();

        if (newCases != null && oldMap == null) {
            // insert / undelete - an inserted OPEN Case changes no closed-case metric.
            for (Case c : newCases) {
                if (c.IsClosed == true && c.AccountId != null) {
                    affected.add(c.AccountId);
                }
            }
        } else if (newCases != null) {
            // update
            for (Case c : newCases) {
                Case o = oldMap.get(c.Id);
                if (o == null) {
                    continue;
                }
                Boolean relevant = (c.IsClosed == true || o.IsClosed == true)
                    && (c.IsClosed != o.IsClosed
                        || c.ClosedDate != o.ClosedDate
                        || c.AccountId != o.AccountId);
                // Deliberately does nothing when an OPEN Case is edited or re-parented -
                // neither Account's closed-case metrics can change. That is what keeps
                // ordinary Case editing from flooding the queue.
                if (relevant) {
                    // Adding BOTH is what makes re-parenting correct: the old Account must
                    // lose the Case.
                    if (c.AccountId != null) {
                        affected.add(c.AccountId);
                    }
                    if (o.AccountId != null) {
                        affected.add(o.AccountId);
                    }
                }
            }
        } else if (oldMap != null) {
            // delete
            for (Case o : oldMap.values()) {
                if (o.IsClosed == true && o.AccountId != null) {
                    affected.add(o.AccountId);
                }
            }
        }

        if (affected.isEmpty()) {
            return;
        }

        Set<Id> toProcess = new Set<Id>(affected);
        toProcess.removeAll(enqueuedAccountIds);
        if (toProcess.isEmpty()) {
            return;
        }
        enqueuedAccountIds.addAll(toProcess);

        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new AccountCaseRollupQueueable(toProcess));
        } else {
            // System.enqueueJob is capped at 1 inside a Batch execute() and 50 per
            // transaction. Correctness must not depend on a slot being available. SOQL in
            // this transaction sees this transaction's own uncommitted DML, so the inline
            // rollup is still correct. Do not remove, and do not swallow exceptions from it.
            lastRunUsedSyncFallback = true;
            AccountCaseRollupService.recalculate(toProcess);
        }
    }
}
