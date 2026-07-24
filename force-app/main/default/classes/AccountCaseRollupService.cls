/**
 * Recalculates Closed_Case_Count__c, Average_Resolution_Time_Days__c and
 * Case_Metrics_Last_Calculated__c for a set of Accounts.
 *
 * SHARING JUSTIFICATION - `without sharing` is deliberate.
 * .claude/rules/security.md prefers WITH USER_MODE. It is deliberately NOT used here.
 * Case OWD is ReadWriteTransfer with externalSharingModel = Private (research-spec E22), so
 * a user-mode aggregate would compute each Account's average from only the Cases the *saving
 * user* can see - making a stored value depend on who clicked Save. That violates AC7. The
 * rollup therefore runs in system mode. The security boundary for this feature is the
 * **read** boundary instead: all four fields are read-only FLS (CaseResolutionMetrics_Read)
 * and Readonly on the layouts, so no user can write a derived value.
 *
 * See technical-spec.md section 3.5.
 */
public without sharing class AccountCaseRollupService {
    private static final Integer ACCOUNTS_PER_QUERY = 500;

    /**
     * One DML + ceil(n/500) SOQL per invocation, whatever n is.
     * Deliberately contains no try/catch: failures must reach
     * AccountCaseRollupQueueable, which decides whether to retry or fail loudly.
     */
    public static void recalculate(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }

        Datetime calcTime = System.now();

        // Deterministic Account update order across concurrent jobs reduces deadlock
        // probability (technical-spec A4 / research-spec R8).
        List<Id> sortedIds = new List<Id>(accountIds);
        sortedIds.sort();

        // Seed every requested Account with the "no closed Cases" state. Seeding is what
        // makes an Account that just lost its last closed Case correctly fall back to
        // 0 / null instead of keeping a stale figure (D3e, AC5).
        Map<Id, Account> accountsById = new Map<Id, Account>();
        List<Account> accountsToUpdate = new List<Account>();
        for (Id accountId : sortedIds) {
            Account acct = new Account(
                Id = accountId,
                Closed_Case_Count__c = 0,
                Average_Resolution_Time_Days__c = null,
                Case_Metrics_Last_Calculated__c = calcTime
            );
            accountsById.put(accountId, acct);
            accountsToUpdate.add(acct);
        }

        // Chunked so each aggregate query stays well under the 2,000 AggregateResult row
        // cap however many Accounts a backfill passes in (research-spec R6).
        for (Integer offset = 0; offset < sortedIds.size(); offset += ACCOUNTS_PER_QUERY) {
            Integer endIndex = Math.min(offset + ACCOUNTS_PER_QUERY, sortedIds.size());
            List<Id> chunk = new List<Id>();
            for (Integer i = offset; i < endIndex; i++) {
                chunk.add(sortedIds[i]);
            }

            for (AggregateResult ar : CaseSelector.aggregateClosedCaseMetrics(chunk)) {
                Id accId = (Id) ar.get('accId');
                Integer caseCount = (Integer) ar.get('caseCount');
                Object rawAvg = ar.get('avgDays');
                // AVG() may surface as a Double, so a hard (Decimal) cast would throw.
                Decimal avgDays = (rawAvg == null)
                    ? null
                    : Decimal.valueOf(String.valueOf(rawAvg));

                Account acct = accountsById.get(accId);
                if (acct != null) {
                    acct.Closed_Case_Count__c = caseCount;
                    acct.Average_Resolution_Time_Days__c = (avgDays == null)
                        ? null
                        : avgDays.setScale(2, System.RoundingMode.HALF_UP);
                }
            }
        }

        // One DML, all-or-none, in sortedIds order. Deliberately NOT Database.update(list,
        // false): a partial success would silently leave skewed metrics.
        update accountsToUpdate;
    }
}
