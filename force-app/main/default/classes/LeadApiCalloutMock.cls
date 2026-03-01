/**
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @Name            LeadApiCalloutMock
 * @TestClass       LeadTriggerTest
 * @Purpose         Mock HTTP response generator for Lead API callout testing. Provides configurable status code
 *                  and body, plus factory methods for common scenarios.
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 * @History
 * VERSION      AUTHOR              DATE                DETAIL DESCRIPTION
 * 1.0          Marimuthu V S       February 26, 2026   Initial Development
 * ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 */
@isTest
public class LeadApiCalloutMock implements HttpCalloutMock {

    private Integer statusCode;
    private String  responseBody;

    /**
     * @description Constructs a mock with the specified HTTP status code and response body.
     * @param statusCode The HTTP status code to return
     * @param responseBody The response body string to return
     */
    public LeadApiCalloutMock(Integer statusCode, String responseBody) {
        this.statusCode   = statusCode;
        this.responseBody = responseBody;
    }

    /**
     * @description Returns the configured mock HTTP response for the given request.
     * @param req The HTTP request being mocked
     * @return HttpResponse The configured mock response
     */
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(this.statusCode);
        res.setBody(this.responseBody);
        return res;
    }

    /**
     * @description Simulates a successful API response with an externalId.
     * @return LeadApiCalloutMock A mock configured for a success scenario
     */
    public static LeadApiCalloutMock successMock() {
        return new LeadApiCalloutMock(200, JSON.serialize(new Map<String, Object>{
            'status'     => 'success',
            'message'    => 'Lead received successfully',
            'externalId' => 'ext-ref-001'
        }));
    }

    /**
     * @description Simulates an API-level error (HTTP 200 but status = error).
     * @return LeadApiCalloutMock A mock configured for an API error scenario
     */
    public static LeadApiCalloutMock apiErrorMock() {
        return new LeadApiCalloutMock(200, JSON.serialize(new Map<String, Object>{
            'status'  => 'error',
            'message' => 'Invalid authentication token'
        }));
    }

    /**
     * @description Simulates an HTTP server error (500).
     * @return LeadApiCalloutMock A mock configured for an HTTP error scenario
     */
    public static LeadApiCalloutMock httpErrorMock() {
        return new LeadApiCalloutMock(500, 'Internal Server Error');
    }
}
