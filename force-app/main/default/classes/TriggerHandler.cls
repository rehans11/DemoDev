/**
 * Project-standard base class for Apex trigger handlers.
 *
 * A trigger body must contain no business logic: it constructs its handler and calls run().
 * run() dispatches to the matching virtual method for Trigger.operationType.
 *
 * Provides:
 *  - a bypass API, so batch/integration code can suppress a handler deliberately;
 *  - a MAX_RUNS safety net against runaway re-entrancy.
 *
 * `inherited sharing` because this is a reusable base that must not impose a sharing mode
 * on its subclasses (.claude/rules/apex.md).
 *
 * See technical-spec.md section 3.1.
 */
public inherited sharing virtual class TriggerHandler {
    @TestVisible
    private static Set<String> bypassedHandlers = new Set<String>();

    @TestVisible
    private static Map<String, Integer> runCounts = new Map<String, Integer>();

    @TestVisible
    private static final Integer MAX_RUNS = 10;

    public class TriggerHandlerException extends Exception {}

    public static void bypass(String handlerName) {
        bypassedHandlers.add(handlerName.toLowerCase());
    }

    public static void clearBypass(String handlerName) {
        bypassedHandlers.remove(handlerName.toLowerCase());
    }

    public static void clearAllBypasses() {
        bypassedHandlers.clear();
    }

    public static Boolean isBypassed(String handlerName) {
        return bypassedHandlers.contains(handlerName.toLowerCase());
    }

    /**
     * Dispatches the current trigger context to the matching virtual method.
     * May only be called from a trigger.
     */
    public void run() {
        String handlerName = String.valueOf(this).split(':')[0];

        if (!Trigger.isExecuting) {
            throw new TriggerHandlerException(
                'TriggerHandler.run() may only be called from trigger context.'
            );
        }

        if (isBypassed(handlerName)) {
            return;
        }

        String runKey = handlerName.toLowerCase();
        Integer currentCount = runCounts.containsKey(runKey) ? runCounts.get(runKey) : 0;
        if (currentCount >= MAX_RUNS) {
            throw new TriggerHandlerException(
                'Maximum trigger runs (' + MAX_RUNS + ') exceeded for ' + handlerName
            );
        }
        runCounts.put(runKey, currentCount + 1);

        switch on Trigger.operationType {
            when BEFORE_INSERT {
                this.beforeInsert();
            }
            when BEFORE_UPDATE {
                this.beforeUpdate();
            }
            when BEFORE_DELETE {
                this.beforeDelete();
            }
            when AFTER_INSERT {
                this.afterInsert();
            }
            when AFTER_UPDATE {
                this.afterUpdate();
            }
            when AFTER_DELETE {
                this.afterDelete();
            }
            when AFTER_UNDELETE {
                this.afterUndelete();
            }
            when else {
                // No dispatch for any other operation type.
            }
        }
    }

    protected virtual void beforeInsert() {
    }

    protected virtual void beforeUpdate() {
    }

    protected virtual void beforeDelete() {
    }

    protected virtual void afterInsert() {
    }

    protected virtual void afterUpdate() {
    }

    protected virtual void afterDelete() {
    }

    protected virtual void afterUndelete() {
    }
}
