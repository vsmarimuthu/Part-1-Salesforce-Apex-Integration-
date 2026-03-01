/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadTriggerTest
 * @TestClass       LeadTriggerTest
 * @Purpose         Comprehensive test class for the Lead external API integration. Covers success, failure, and
 *                  bulk processing scenarios using HttpCalloutMock.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class LeadTriggerTest {

    // ─── Helpers ──────────────────────────────────────────────────────────

    /**
     * @description Creates a test Lead record with the given first and last name and default field values.
     * @param firstName The first name for the test Lead
     * @param lastName The last name for the test Lead
     * @return Lead A new Lead record (not yet inserted)
     */
    private static Lead createTestLead(String firstName, String lastName) {
        return new Lead(
            FirstName  = firstName,
            LastName   = lastName,
            Company    = 'Test Company',
            Email      = firstName.toLowerCase() + '.' + lastName.toLowerCase() + '@test.com',
            LeadSource = 'Web',
            Status     = 'Open - Not Contacted'
        );
    }

    // ─── Success Scenarios ──────────────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies that inserting a Lead populates External_Reference_Id__c with the externalId from
     *              a successful API response.
     */
    @isTest
    static void testInsert_SuccessPopulatesExternalId() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        Lead testLead = createTestLead('John', 'Doe');

        Test.startTest();
        insert testLead;
        Test.stopTest();

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual('ext-ref-001', result.External_Reference_Id__c,
            'External Reference Id should match the externalId from the API response');
    }

    /**
     * @description Verifies that updating a relevant Lead field (e.g. Email) triggers the external API callout
     *              and populates External_Reference_Id__c.
     */
    @isTest
    static void testUpdate_RelevantFieldChangeTriggersSyncCallout() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        Lead testLead = createTestLead('Alice', 'Johnson');
        insert testLead;

        // Allow the update to be processed independently
        LeadTriggerHandler.processedLeadIds.clear();

        Test.startTest();
        testLead.Email = 'alice.new@test.com';
        update testLead;
        Test.stopTest();

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual('ext-ref-001', result.External_Reference_Id__c,
            'External Reference Id should be populated after a relevant field update');
    }

    // ─── Failure Scenarios ──────────────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies that External_Reference_Id__c remains null when the API returns an error status
     *              (HTTP 200 with status = error).
     */
    @isTest
    static void testInsert_ApiErrorLeavesFieldNull() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.apiErrorMock());

        Lead testLead = createTestLead('Jane', 'Smith');

        Test.startTest();
        insert testLead;
        Test.stopTest();

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual(null, result.External_Reference_Id__c,
            'External Reference Id should remain null when API returns an error status');
    }

    /**
     * @description Verifies that External_Reference_Id__c remains null when the API returns an HTTP server
     *              error (500).
     */
    @isTest
    static void testInsert_HttpErrorLeavesFieldNull() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.httpErrorMock());

        Lead testLead = createTestLead('Bob', 'Wilson');

        Test.startTest();
        insert testLead;
        Test.stopTest();

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual(null, result.External_Reference_Id__c,
            'External Reference Id should remain null on HTTP server error');
    }

    /**
     * @description Verifies that the Lead record persists in the database even when the external API call fails,
     *              ensuring the API error does not roll back the transaction.
     */
    @isTest
    static void testInsert_TransactionDoesNotFailOnApiError() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.httpErrorMock());

        Lead testLead = createTestLead('Error', 'Test');

        Test.startTest();
        insert testLead;
        Test.stopTest();

        // Lead should still exist despite API failure
        Integer count = [SELECT COUNT() FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual(1, count,
            'Lead record should persist even when the external API call fails');
    }

    // ─── Bulk Scenarios ─────────────────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies that inserting 200 Leads in bulk completes without governor limit exceptions and that
     *              at least some leads are processed by the first Queueable batch.
     */
    @isTest
    static void testBulkInsert_200Leads() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(createTestLead('Bulk' + i, 'Lead' + i));
        }

        Test.startTest();
        insert leads;
        Test.stopTest();

        List<Lead> results = [
            SELECT Id, External_Reference_Id__c
            FROM Lead
            WHERE Id IN :leads
        ];
        Assert.areEqual(200, results.size(),
            'All 200 leads should be inserted without governor limit exceptions');

        // Verify at least some leads were processed by the first Queueable batch
        Integer processedCount = 0;
        for (Lead l : results) {
            if (l.External_Reference_Id__c != null) {
                processedCount++;
            }
        }
        Assert.isTrue(processedCount > 0,
            'At least some leads should have their External Reference Id populated');
    }

    /**
     * @description Verifies that updating 200 Leads in bulk with a relevant field change completes without
     *              governor limit exceptions.
     */
    @isTest
    static void testBulkUpdate_200Leads() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(createTestLead('BulkUp' + i, 'Lead' + i));
        }
        insert leads;

        LeadTriggerHandler.processedLeadIds.clear();

        for (Lead l : leads) {
            l.Company = 'Updated Company';
        }

        Test.startTest();
        update leads;
        Test.stopTest();

        List<Lead> results = [SELECT Id FROM Lead WHERE Id IN :leads];
        Assert.areEqual(200, results.size(),
            'Bulk update of 200 leads should complete without exceptions');
    }

    // ─── Edge Cases ───────────────────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies that updating only irrelevant fields (e.g. Description) does not trigger the external
     *              API callout and does not overwrite the existing External_Reference_Id__c.
     */
    @isTest
    static void testUpdate_IrrelevantFieldChangeDoesNotTriggerCallout() {
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        Lead testLead = createTestLead('Charlie', 'Brown');

        // Insert lead and flush the initial-insert Queueable so its callout completes first
        Test.startTest();
        insert testLead;
        Test.stopTest();

        // Re-query to get the current state after the insert callout
        testLead = [SELECT Id, External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];

        // Set a known External Reference Id to verify it is NOT overwritten
        testLead.External_Reference_Id__c = 'original-ref';
        LeadTriggerHandler.processedLeadIds.clear();
        update testLead;

        // Update only Description — not a field sent to the API
        LeadTriggerHandler.processedLeadIds.clear();
        testLead.Description = 'Updated description';
        update testLead;

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual('original-ref', result.External_Reference_Id__c,
            'External Reference Id should not change when only irrelevant fields are updated');
    }

    /**
     * @description Verifies that External_Reference_Id__c remains null when the API returns a 200 status with
     *              a malformed (non-JSON) response body, exercising the JSON parse exception handling.
     */
    @isTest
    static void testInsert_MalformedJsonResponseLeavesFieldNull() {
        Test.setMock(HttpCalloutMock.class, new LeadApiCalloutMock(200, '<html>Bad Gateway</html>'));

        Lead testLead = createTestLead('Malformed', 'Response');

        Test.startTest();
        insert testLead;
        Test.stopTest();

        Lead result = [SELECT External_Reference_Id__c FROM Lead WHERE Id = :testLead.Id];
        Assert.areEqual(null, result.External_Reference_Id__c,
            'External Reference Id should remain null when API returns malformed JSON');
    }

    // ─── Service Guard Tests ──────────────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies LeadService handles null input gracefully without throwing an exception
     *              and without enqueuing any Queueable job.
     */
    @isTest
    static void testService_NullInputReturnsGracefully() {
        LeadService.processLeadsForExternalApi(null);
        Assert.areEqual(0, Limits.getQueueableJobs(),
            'No Queueable should be enqueued for null input');
    }

    /**
     * @description Verifies LeadService handles an empty list gracefully without throwing an exception
     *              and without enqueuing any Queueable job.
     */
    @isTest
    static void testService_EmptyListReturnsGracefully() {
        LeadService.processLeadsForExternalApi(new List<Id>());
        Assert.areEqual(0, Limits.getQueueableJobs(),
            'No Queueable should be enqueued for empty list');
    }

    /**
     * @description Verifies that LeadService gracefully skips the Queueable enqueue when called from a @future
     *              context, exercising the System.isFuture() guard.
     */
    @isTest
    static void testService_FutureContextSkipsEnqueue() {
        // Mock needed because the insert enqueues a Queueable that executes at Test.stopTest()
        Test.setMock(HttpCalloutMock.class, LeadApiCalloutMock.successMock());

        Lead testLead = createTestLead('Future', 'Test');
        insert testLead;

        Test.startTest();
        invokeServiceFromFuture(testLead.Id);
        Test.stopTest();

        Lead result = [SELECT Id FROM Lead WHERE Id = :testLead.Id];
        Assert.isNotNull(result.Id, 'Lead should persist — service handled future context gracefully');
    }

    /**
     * @description Helper method to invoke LeadService from a @future context.
     *              Inside this execution, System.isFuture() returns true, exercising the async guard.
     * @param leadId The Lead Id to pass to the service
     */
    @future
    private static void invokeServiceFromFuture(Id leadId) {
        LeadService.processLeadsForExternalApi(new List<Id>{ leadId });
    }

    // ─── Trigger Infrastructure Tests ─────────────────────────────────────────────────────────────────────────────────

    /**
     * @description Verifies that the trigger's defensive catch block prevents Lead DML from rolling back when the
     *              handler throws an unhandled exception. Uses the @TestVisible forceException flag in
     *              LeadTriggerHandler to simulate an unexpected failure.
     */
    @isTest
    static void testTrigger_CatchBlockPreventsRollback() {
        LeadTriggerHandler.forceException = true;

        Lead testLead = createTestLead('Catch', 'Test');
        insert testLead;

        LeadTriggerHandler.forceException = false;

        Lead result = [SELECT Id FROM Lead WHERE Id = :testLead.Id];
        Assert.isNotNull(result.Id,
            'Lead DML should not roll back when the handler throws an exception');
    }
}
