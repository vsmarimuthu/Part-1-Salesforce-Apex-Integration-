/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadApiCalloutService
 * @TestClass       LeadTriggerTest
 * @Purpose         Service class responsible for HTTP callouts to the external Lead API. Handles request construction,
 *                  response parsing, and error logging. Authentication and endpoint URL are managed via Named Credential
 *                  (Lead_External_API) backed by an External Credential with Custom auth protocol. The x-api-key header
 *                  is injected automatically by the platform — no secrets in code.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
public with sharing class LeadApiCalloutService {

    @TestVisible
    private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:Lead_External_API/lead';

    // ─── Inner Wrapper Class ──────────────────────────────────────────────

    /**
     * @description Strongly-typed wrapper for the external API JSON response.
     *              Although this particular response is simple enough for JSON.deserializeUntyped(),
     *              a wrapper class is used deliberately to demonstrate proper response parsing,
     *              provide compile-time type safety, and ensure maintainability if the API
     *              response evolves with additional fields in the future.
     *
     *              Expected success response:
     *              { "status": "success", "message": "Lead received successfully", "externalId": "abc123" }
     *
     *              Expected error response:
     *              { "status": "error", "message": "Invalid authentication token" }
     */
    @TestVisible
    private class LeadApiResponse {
        public String status     { get; set; }
        public String message    { get; set; }
        public String externalId { get; set; }
    }

    // ─── Public Methods ───────────────────────────────────────────────────

    /**
     * @description Sends a Lead's data to the external API and returns the externalId from the response.
     *              Returns null if the Lead is invalid, the callout fails, or the response indicates an error.
     *              Catches CalloutException internally so callers receive null instead of an unhandled exception.
     * @param lead The Lead record to send to the external API
     * @return String The externalId from the API response, or null on failure
     */
    public static String sendLeadToExternalApi(Lead lead) {
        if (lead == null || lead.Id == null) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'LeadApiCalloutService: Cannot process null Lead or Lead without Id', (String) null);
            return null;
        }

        try {
            HttpRequest req = buildRequest(buildPayload(lead));
            Http http = new Http();
            HttpResponse res = http.send(req);
            return parseResponse(res, lead.Id);
        } catch (CalloutException e) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'LeadApiCalloutService: Callout failed for Lead ' + lead.Id +
                ' — ' + e.getMessage(), String.valueOf(lead.Id));
            return null;
        }
    }

    // ─── Private Methods ──────────────────────────────────────────────────

    /**
     * @description Constructs the JSON payload from Lead field data. On updates where the Lead already has an
     *              External_Reference_Id__c, includes it as 'externalId' so the external system can identify
     *              the existing record rather than creating a duplicate.
     * @param lead The Lead record to extract field values from
     * @return Map<String, Object> The payload map for JSON serialization
     */
    @TestVisible
    private static Map<String, Object> buildPayload(Lead lead) {
        Map<String, Object> payload = new Map<String, Object>{
            'FirstName'  => lead.FirstName,
            'LastName'   => lead.LastName,
            'Company'    => lead.Company,
            'Email'      => lead.Email,
            'LeadSource' => lead.LeadSource,
            'Status'     => lead.Status
        };

        // On updates, include the existing externalId so the external system can
        // identify and update the record rather than creating a new one
        if (String.isNotBlank(lead.External_Reference_Id__c)) {
            payload.put('externalId', lead.External_Reference_Id__c);
        }

        return payload;
    }

    /**
     * @description Builds the HTTP request using the Named Credential endpoint.
     *              The x-api-key header is auto-injected by the External Credential.
     *
     *              Design Decision — Single POST Endpoint:
     *              The external API exposes only POST /lead. There is no PUT or PATCH endpoint for updates.
     *              Both inserts and updates therefore use the same POST method. If the API were extended with
     *              PATCH /lead/{externalId}, only this method and buildPayload() would need modification —
     *              all other layers (Trigger, Handler, Service, Queueable) remain unchanged. This demonstrates
     *              the extensibility of the layered architecture.
     *
     * @param payload The map of key-value pairs to serialize as the request body
     * @return HttpRequest The configured HTTP request ready to send
     */
    private static HttpRequest buildRequest(Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT);
        // POST for both insert and update — API provides no PATCH/PUT endpoint (see Javadoc above)
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(30000);
        return req;
    }

    /**
     * @description Parses the HTTP response using the strongly-typed LeadApiResponse wrapper class.
     *              Deserialises the JSON body via JSON.deserialize() for compile-time type safety.
     *              Catches JSON parse exceptions for malformed response bodies.
     * @param res The HTTP response from the external API
     * @param leadId The Lead record ID for error logging context
     * @return String The externalId value, or null on failure
     */
    @TestVisible
    private static String parseResponse(HttpResponse res, Id leadId) {
        if (res.getStatusCode() != 200) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'External API HTTP error for Lead ' + leadId +
                ': Status ' + res.getStatusCode() + ' — ' + res.getBody(), String.valueOf(leadId));
            return null;
        }

        try {
            LeadApiResponse apiResponse = (LeadApiResponse) JSON.deserialize(
                res.getBody(), LeadApiResponse.class
            );

            if (apiResponse.status == 'success') {
                return String.isNotBlank(apiResponse.externalId) ? apiResponse.externalId : null;
            }

            AppLog.write(AppLog.LEVEL_ERROR,
                'External API error for Lead ' + leadId + ': ' + apiResponse.message, String.valueOf(leadId));
            return null;
        } catch (Exception e) {
            AppLog.write(AppLog.LEVEL_ERROR,
                'LeadApiCalloutService: Failed to parse response for Lead ' + leadId +
                ' — ' + e.getMessage() + ' | Body: ' + res.getBody(), String.valueOf(leadId));
            return null;
        }
    }
}
