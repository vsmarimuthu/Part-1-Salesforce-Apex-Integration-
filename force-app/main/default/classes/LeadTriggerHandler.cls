/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadTriggerHandler
 * @TestClass       LeadTriggerTest
 * @Purpose         Handler class for Lead trigger operations. Extends the TriggerHandler base class for
 *                  standardised event routing, bypass support, and loop-count protection. Manages recursion
 *                  prevention and field-change detection. Delegates business logic to LeadService.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * 1.1          Marimuthu V S       February 26, 2026   Refactored to extend TriggerHandler base class
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
public with sharing class LeadTriggerHandler extends TriggerHandler {

    // Tracks Lead IDs already processed in the current transaction to prevent recursive execution
    @TestVisible
    private static Set<Id> processedLeadIds = new Set<Id>();

    // Test-only hook: verifies the trigger's defensive catch block swallows exceptions
    // and prevents Lead DML rollback. Private — only accessible via @TestVisible in tests.
    @TestVisible
    private static Boolean forceException = false;

    // ─── Overridden Trigger Context Methods ───────────────────────────────

    /**
     * @description Handles the after insert trigger event. All newly inserted Leads are candidates for the
     *              external API sync. Filters out any already-processed IDs and delegates to LeadService.
     */
    public override void afterInsert() {
        if (forceException) {
            throw new HandlerForceTestException('Test-forced exception for trigger catch-block coverage');
        }

        List<Id> leadIdsToProcess = new List<Id>();

        for (Lead lead : (List<Lead>) Trigger.new) {
            if (!processedLeadIds.contains(lead.Id)) {
                leadIdsToProcess.add(lead.Id);
            }
        }

        if (!leadIdsToProcess.isEmpty()) {
            processedLeadIds.addAll(leadIdsToProcess);
            LeadService.processLeadsForExternalApi(leadIdsToProcess);
        }
    }

    /**
     * @description Handles the after update trigger event. Only processes Leads where API-relevant fields
     *              have changed, preventing unnecessary callouts. Skips already-processed IDs to guard
     *              against recursion when the Queueable writes back External_Reference_Id__c.
     */
    public override void afterUpdate() {
        if (forceException) {
            throw new HandlerForceTestException('Test-forced exception for trigger catch-block coverage');
        }

        List<Id> leadIdsToProcess = new List<Id>();
        Map<Id, Lead> oldMap = (Map<Id, Lead>) Trigger.oldMap;

        for (Lead lead : (List<Lead>) Trigger.new) {
            if (processedLeadIds.contains(lead.Id)) {
                continue;
            }

            Lead oldLead = oldMap.get(lead.Id);
            if (oldLead != null && hasRelevantFieldChanged(lead, oldLead)) {
                leadIdsToProcess.add(lead.Id);
            }
        }

        if (!leadIdsToProcess.isEmpty()) {
            processedLeadIds.addAll(leadIdsToProcess);
            LeadService.processLeadsForExternalApi(leadIdsToProcess);
        }
    }

    // ─── Private Methods ──────────────────────────────────────────────────

    /**
     * @description Checks whether any field sent to the external API has changed.
     *              Excludes External_Reference_Id__c to prevent recursive processing
     *              when the Queueable job writes back the API response.
     * @param newLead The updated Lead record
     * @param oldLead The previous version of the Lead record
     * @return Boolean true if any API-relevant field changed
     */
    private static Boolean hasRelevantFieldChanged(Lead newLead, Lead oldLead) {
        return newLead.FirstName  != oldLead.FirstName  ||
               newLead.LastName   != oldLead.LastName   ||
               newLead.Company    != oldLead.Company    ||
               newLead.Email      != oldLead.Email      ||
               newLead.LeadSource != oldLead.LeadSource ||
               newLead.Status     != oldLead.Status;
    }

    // ─── Inner Exception Class ────────────────────────────────────────────

    // Custom exception used exclusively by the @TestVisible forceException flag
    @TestVisible
    private class HandlerForceTestException extends Exception {}
}
