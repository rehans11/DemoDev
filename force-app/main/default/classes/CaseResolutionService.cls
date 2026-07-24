/**
 * Resolution-time arithmetic and the reopen / negative-duration rules for Case.
 *
 * PURITY INVARIANT (technical-spec.md section 3.0.6, invariant 3): this class performs
 * NO SOQL, NO DML, and calls NO System.now() of its own. The closed-status set and the
 * "now" instant are injected by the caller. That is the only reason the negative,
 * rounding and transition cases can be unit-tested directly - Case.CreatedDate and
 * Case.ClosedDate are createable=false, updateable=false and cannot be set by a test.
 *
 * `inherited sharing`: this class touches no records of its own; the sharing decision
 * belongs to its callers.
 *
 * See technical-spec.md section 3.4.
 */
public inherited sharing class CaseResolutionService {
    @TestVisible
    private static final Long MILLIS_PER_DAY = 86400000L;

    /**
     * Calendar days between two instants, to 2 decimal places, HALF_UP.
     *
     * Returns null when either argument is null, or when closedDate precedes createdDate.
     * The negative guard is mandatory, not defensive padding: every closed Case seeded in
     * this org has ClosedDate roughly 13.5 months BEFORE CreatedDate (research-spec E32).
     * Without the guard every Account would show a negative average.
     *
     * Never throws.
     */
    public static Decimal calculateResolutionDays(Datetime createdDate, Datetime closedDate) {
        if (createdDate == null || closedDate == null) {
            return null;
        }
        Long elapsedMillis = closedDate.getTime() - createdDate.getTime();
        if (elapsedMillis < 0) {
            return null;
        }
        return (Decimal.valueOf(elapsedMillis) / MILLIS_PER_DAY)
            .setScale(2, System.RoundingMode.HALF_UP);
    }

    /**
     * The before insert / before update path. Mutates newCases IN PLACE - there is no
     * return value and the caller performs no DML (invariant 2).
     *
     * Closed-ness is derived from Status against the injected closedStatuses set.
     * IsClosed and ClosedDate are NEVER read here: they are platform-derived and not
     * reliably populated in a before context (invariant 4).
     *
     * @param newCases       Trigger.new
     * @param oldMap         Trigger.oldMap, or null on insert
     * @param closedStatuses master labels of the statuses that mean "closed"
     * @param nowInstant     the save instant, captured once by the caller
     */
    public static void applyResolutionTimes(
        List<Case> newCases,
        Map<Id, Case> oldMap,
        Set<String> closedStatuses,
        Datetime nowInstant
    ) {
        if (newCases == null || newCases.isEmpty()) {
            return;
        }
        Set<String> effectiveClosedStatuses = (closedStatuses == null)
            ? new Set<String>()
            : closedStatuses;

        for (Case c : newCases) {
            Boolean nowClosed = c.Status != null && effectiveClosedStatuses.contains(c.Status);
            Case oldCase = (oldMap != null && c.Id != null) ? oldMap.get(c.Id) : null;
            Boolean wasClosed = oldCase != null
                && oldCase.Status != null
                && effectiveClosedStatuses.contains(oldCase.Status);

            if (!nowClosed) {
                // Open, or just reopened (D2) - an open Case has no resolution time.
                c.Resolution_Time_Days__c = null;
            } else if (!wasClosed) {
                // TRANSITION into a closed status: first close, or a re-close after reopen.
                // On before insert CreatedDate is not yet assigned, so a Case created
                // already-closed is 0.00 - created and closed in the same instant.
                c.Resolution_Time_Days__c = (c.CreatedDate == null)
                    ? 0.00
                    : calculateResolutionDays(c.CreatedDate, nowInstant);
            }
            // else: already closed and staying closed -> leave the existing value untouched.
            // This is invariant 1 and the single most important branch in this class.
            // Without it, every later save of a closed Case would re-stamp against a fresh
            // nowInstant and silently inflate the metric. It mirrors the platform, which
            // does not rewrite ClosedDate when you edit an already-closed Case either.
        }
    }

    /**
     * The BACKFILL path only (CaseResolutionBackfillBatch).
     *
     * Historical records already carry a committed ClosedDate and System.now() is
     * meaningless for them, so this variant computes from the stored fields. Reading
     * IsClosed / ClosedDate is safe here: the batch queries committed records, not a
     * before-trigger view.
     *
     * Returns ONLY the Cases whose value actually changes, so unchanged records are never
     * re-DML'd. Performs no SOQL and no DML - the caller owns the DML.
     */
    public static List<Case> buildResolutionUpdates(List<Case> cases) {
        List<Case> updates = new List<Case>();
        if (cases == null || cases.isEmpty()) {
            return updates;
        }
        for (Case c : cases) {
            Decimal desired = (c.IsClosed == true)
                ? calculateResolutionDays(c.CreatedDate, c.ClosedDate)
                : null;
            Decimal current = c.Resolution_Time_Days__c;

            Boolean changed = (desired == null)
                ? (current != null)
                : (current == null || desired != current);

            if (changed) {
                updates.add(new Case(Id = c.Id, Resolution_Time_Days__c = desired));
            }
        }
        return updates;
    }
}
