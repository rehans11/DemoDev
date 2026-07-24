/**
 * Async hop for the Account case-metrics rollup (D4).
 *
 * Enqueued from CaseTriggerHandler's after contexts so the rollup runs in its own
 * transaction, after the Case save has committed. Retries ONLY row-lock contention, and
 * only up to MAX_ATTEMPTS; anything else is rethrown so it surfaces in Setup > Apex Jobs
 * (technical-spec A2). Never swallows an exception.
 *
 * No Database.AllowsCallouts - there are no callouts.
 *
 * `inherited sharing` to satisfy the "sharing keyword present on every class" item in
 * technical-spec.md section 3.10. It is behaviour-neutral here: this class performs no SOQL
 * and no DML of its own, and AccountCaseRollupService is declared `without sharing`, which
 * governs the actual data access regardless of this keyword.
 *
 * See technical-spec.md section 3.7.
 */
public inherited sharing class AccountCaseRollupQueueable implements Queueable {
    @TestVisible
    private static final Integer MAX_ATTEMPTS = 3;

    /**
     * Set when execute() decides a retry is warranted. Exists solely so tests can assert
     * the retry decision: Apex forbids chaining Queueables inside a test context, so the
     * chain itself cannot be observed there.
     */
    @TestVisible
    private static Boolean retryScheduled = false;

    private final Set<Id> accountIds;
    private final Integer attempt;

    public AccountCaseRollupQueueable(Set<Id> accountIds) {
        this(accountIds, 1);
    }

    public AccountCaseRollupQueueable(Set<Id> accountIds, Integer attempt) {
        this.accountIds = accountIds;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        try {
            AccountCaseRollupService.recalculate(accountIds);
        } catch (Exception e) {
            if (attempt < MAX_ATTEMPTS && isRetryable(e)) {
                retryScheduled = true;
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new AccountCaseRollupQueueable(accountIds, attempt + 1));
                }
            } else {
                // Surface in Setup > Apex Jobs. A validation-rule or FLS failure must fail
                // loudly rather than be retried forever.
                throw e;
            }
        }
    }

    /**
     * Only lock contention is retryable (technical-spec A4).
     */
    @TestVisible
    private static Boolean isRetryable(Exception e) {
        if (e == null || e.getMessage() == null) {
            return false;
        }
        String message = e.getMessage().toUpperCase();
        return message.contains('UNABLE_TO_LOCK_ROW') || message.contains('ROW_LOCK');
    }
}
