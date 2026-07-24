/**
 * All SOQL for the Case resolution-time feature lives here.
 *
 * `inherited sharing` so each caller decides the sharing mode: when called from
 * AccountCaseRollupService (without sharing) the aggregate deliberately runs in system mode,
 * because a user-mode aggregate would make a stored Account average depend on which user
 * saved the Case. See AccountCaseRollupService for the full justification.
 *
 * See technical-spec.md section 3.6.
 */
public inherited sharing class CaseSelector {
    /**
     * Statically cached so the CaseStatus lookup costs at most one SOQL per transaction,
     * however many times CaseTrigger fires.
     */
    @TestVisible
    private static Set<String> cachedClosedStatuses;

    /**
     * Master labels of every Case Status flagged IsClosed.
     * Queried rather than hardcoded so the feature keeps working if an admin adds another
     * closed status later.
     */
    public static Set<String> getClosedStatusLabels() {
        if (cachedClosedStatuses == null) {
            cachedClosedStatuses = new Set<String>();
            for (CaseStatus cs : [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = true]) {
                cachedClosedStatuses.add(cs.MasterLabel);
            }
        }
        return cachedClosedStatuses;
    }

    /**
     * Closed-Case count and average resolution time, grouped by Account.
     *
     * Deliberately has no WITH USER_MODE - see the sharing justification on
     * AccountCaseRollupService. AVG() ignores nulls, which is exactly how a Case with no
     * valid resolution time is counted but not averaged (D3b).
     */
    public static List<AggregateResult> aggregateClosedCaseMetrics(List<Id> accountIds) {
        return [
            SELECT AccountId accId, COUNT(Id) caseCount, AVG(Resolution_Time_Days__c) avgDays
            FROM Case
            WHERE AccountId IN :accountIds AND IsClosed = true
            GROUP BY AccountId
        ];
    }

    /**
     * Locator for CaseResolutionBackfillBatch.
     *
     * Selects ALL Cases, not just closed ones, so the batch can also clear a stale value on
     * a Case that was reopened while the trigger was inactive.
     */
    public static Database.QueryLocator closedCaseBackfillLocator() {
        return Database.getQueryLocator([
            SELECT Id, AccountId, IsClosed, CreatedDate, ClosedDate, Resolution_Time_Days__c
            FROM Case
        ]);
    }
}
