/**
 * The only trigger on Case. Logic-free by design - it delegates to CaseTriggerHandler,
 * which dispatches by Trigger.operationType via the TriggerHandler base class.
 *
 * before insert / before update : stamp Resolution_Time_Days__c in memory (zero DML).
 * after  insert / update / delete / undelete : dispatch the Account rollup.
 *
 * There is deliberately no `before delete` context and no DML on Case anywhere.
 *
 * See technical-spec.md section 3.2.
 */
trigger CaseTrigger on Case (
    before insert,
    before update,
    after insert,
    after update,
    after delete,
    after undelete
) {
    new CaseTriggerHandler().run();
}
