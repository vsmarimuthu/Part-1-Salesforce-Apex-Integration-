/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadSelector
 * @TestClass       LeadTriggerTest
 * @Purpose         Selector class for Lead SOQL queries. Centralises all Lead data-access logic so that queries
 *                  are defined in one place, making them easier to maintain, audit, and mock.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
public with sharing class LeadSelector {

    /**
     * @description Retrieves Lead records with the fields required for the external API callout payload.
     *              Returns an empty list when the input set is null or empty.
     * @param leadIds Set of Lead record IDs to query
     * @return List<Lead> Leads with FirstName, LastName, Company, Email, LeadSource, and Status
     */
    public List<Lead> selectLeadsForApiCallout(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }

        return [
            SELECT Id, FirstName, LastName, Company, Email, LeadSource, Status, External_Reference_Id__c
            FROM Lead
            WHERE Id IN :leadIds
        ];
    }
}
