/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadExternalApiQueueable
 * @TestClass       LeadTriggerTest
 * @Purpose         Queueable job that sends Lead data to an external API asynchronously. Processes leads in batches
 *                  respecting the 100-callout governor limit per transaction, and chains additional jobs for any
 *                  remaining records.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
public without sharing class LeadExternalApiQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_CALLOUTS_PER_EXECUTION = 100;
    private List<Id> leadIds;

    /**
     * @description Constructs the Queueable with the given Lead IDs to process.
     *              Handles null input defensively by initialising an empty list.
     * @param leadIds List of Lead record IDs to send to the external API
     */
    public LeadExternalApiQueueable(List<Id> leadIds) {
        this.leadIds = leadIds != null ? leadIds : new List<Id>();
    }

    /**
     * @description Executes callout processing for the current batch of leads.
     *              Chains another Queueable job if leads remain beyond the callout limit.
     * @param context The QueueableContext provided by the platform
     */
    public void execute(QueueableContext context) {
        if (this.leadIds.isEmpty()) {
            return;
        }

        try {
            List<Id> currentBatch  = new List<Id>();
            List<Id> remainingIds  = new List<Id>();

            for (Integer i = 0; i < leadIds.size(); i++) {
                if (i < MAX_CALLOUTS_PER_EXECUTION) {
                    currentBatch.add(leadIds[i]);
                } else {
                    remainingIds.add(leadIds[i]);
                }
            }

            List<Lead> leads = new LeadSelector().selectLeadsForApiCallout(new Set<Id>(currentBatch));

            List<Lead> leadsToUpdate = processCallouts(leads);

            if (!leadsToUpdate.isEmpty()) {
                performPartialUpdate(leadsToUpdate);
            }

            // Chain next batch for any remaining leads
            if (!remainingIds.isEmpty()
                    && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new LeadExternalApiQueueable(remainingIds));
            }
        } catch (Exception e) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'LeadExternalApiQueueable: Unexpected error during execution — ' +
                e.getMessage() + ' | Stack: ' + e.getStackTraceString(), (String) null);
        }
    }

    /**
     * @description Sends each lead to the external API and collects successful responses. Checks the callout
     *              governor limit before each request. Individual failures are logged but do not halt processing.
     * @param leads List of Lead records to process
     * @return List<Lead> Leads with updated External_Reference_Id__c ready for DML
     */
    private List<Lead> processCallouts(List<Lead> leads) {
        List<Lead> leadsToUpdate = new List<Lead>();

        for (Lead lead : leads) {
            // Respect the callout governor limit even if other code made callouts in this transaction
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
                break;
            }

            try {
                String externalId = LeadApiCalloutService.sendLeadToExternalApi(lead);
                if (String.isNotBlank(externalId)) {
                    leadsToUpdate.add(new Lead(
                        Id = lead.Id,
                        External_Reference_Id__c = externalId
                    ));
                }
            } catch (Exception e) {
                AppLog.write(AppLog.LEVEL_ERROR,
                    'LeadExternalApiQueueable: Callout failed for Lead ' + lead.Id +
                    ' — ' + e.getMessage(), String.valueOf(lead.Id));
            }
        }

        return leadsToUpdate;
    }

    /**
     * @description Updates leads using partial success mode (allOrNone = false)
     *              so that one record's failure does not block the rest.
     * @param leadsToUpdate List of Lead records to update with External_Reference_Id__c
     */
    private void performPartialUpdate(List<Lead> leadsToUpdate) {
        List<Database.SaveResult> results = Database.update(leadsToUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    AppLog.write(AppLog.LEVEL_ERROR,
                        'LeadExternalApiQueueable: DML failed for Lead ' + leadsToUpdate[i].Id +
                        ' — ' + err.getMessage(), String.valueOf(leadsToUpdate[i].Id));
                }
            }
        }
    }
}
