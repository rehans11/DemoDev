/**
 * Repair tool. Recomputes Closed_Case_Count__c, Average_Resolution_Time_Days__c and
 * Case_Metrics_Last_Calculated__c for EVERY Account.
 *
 * Operational repair tool. Not executed as part of any deployment. Run only with explicit
 * user approval - it performs DML on production-of-record data. Per D6 in the technical
 * spec. Also the documented remediation for Account merge (research-spec R5).
 *
 * Recommended scope size when invoked: 200.
 * Deliberately NOT Database.Stateful - nothing accumulates across scopes, so heap stays
 * flat however many Accounts exist. It enqueues nothing, so the
 * one-Queueable-per-batch-execute cap is irrelevant.
 *
 * `with sharing` per the .claude/rules/apex.md default: AccountCaseRollupService is the one
 * deliberately `without sharing` class in this feature, and its system-mode aggregate is
 * unaffected by this class's keyword.
 *
 * See technical-spec.md section 3.8.
 */
public with sharing class AccountCaseMetricsRecalcBatch implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM Account]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Set<Id> accountIds = new Set<Id>();
        for (SObject record : scope) {
            accountIds.add((Id) record.get('Id'));
        }
        AccountCaseRollupService.recalculate(accountIds);
    }

    public void finish(Database.BatchableContext bc) {
        // No-op.
    }
}
