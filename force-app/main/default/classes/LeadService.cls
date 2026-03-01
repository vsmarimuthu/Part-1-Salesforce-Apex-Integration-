/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadService
 * @TestClass       LeadTriggerTest
 * @Purpose         Service class for Lead-related business operations. Orchestrates asynchronous external API
 *                  processing for Lead records.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
public with sharing class LeadService {

    /**
     * @description Enqueues Lead records for asynchronous external API processing. Uses Queueable to perform
     *              callouts outside the trigger transaction context. Guards against enqueuing when already in an
     *              async context or at governor limits. Catches exceptions from System.enqueueJob to prevent
     *              failures from propagating to the calling trigger.
     * @param leadIds List of Lead record IDs to process
     */
    public static void processLeadsForExternalApi(List<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return;
        }

        // Guard: Queueable cannot be enqueued from batch or future contexts
        if (System.isBatch() || System.isFuture()) {
            return;
        }

        // Guard: Respect Queueable governor limit
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }

        try {
            System.enqueueJob(new LeadExternalApiQueueable(leadIds));
        } catch (Exception e) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'LeadService: Failed to enqueue Queueable — ' + e.getMessage(), (String) null);
        }
    }
}
