/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadTrigger
 * @TestClass       LeadTriggerTest
 * @Purpose         Trigger on Lead that fires after insert and after update. Delegates all logic to
 *                  LeadTriggerHandler via the TriggerHandler base class — no business logic here.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * 1.1          Marimuthu V S       February 26, 2026   Refactored to use TriggerHandler.run() framework
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
trigger LeadTrigger on Lead (after insert, after update) {
    try {
        new LeadTriggerHandler().run();
    } catch (Exception e) {
        // Catch all exceptions so the Lead DML is never rolled back due to integration issues.
        AppLog.write(AppLog.LEVEL_ERROR,
            'LeadTrigger: Unhandled exception — ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString(), (String) null);
    }
}
