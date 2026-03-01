# Part 1 — Lead External API Integration

Salesforce Apex solution that synchronises Lead data with an external REST API whenever a Lead is created or updated. The external system responds with a JSON payload containing an `externalId`, which is written back to the Lead's `External_Reference_Id__c` field — all asynchronously, bulk-safe, and without ever risking a transaction rollback.

> **API Version:** 65.0 &nbsp;|&nbsp; **Logging:** AppLog managed package &nbsp;|&nbsp; **Auth:** Named Credential (no secrets in code)

---

## Table of Contents

1. [High-Level Architecture](#high-level-architecture)
2. [Execution Flow](#execution-flow)
3. [Class-by-Class Breakdown](#class-by-class-breakdown)
4. [Design Patterns & Why We Chose Them](#design-patterns--why-we-chose-them)
5. [Governor Limit Strategy](#governor-limit-strategy)
6. [Recursion Prevention (Two Layers)](#recursion-prevention-two-layers)
7. [Authentication Approach](#authentication-approach)
8. [Error Handling Matrix](#error-handling-matrix)
9. [Test Coverage (13 Tests)](#test-coverage-13-tests)
10. [Metadata Definitions](#metadata-definitions)
11. [Project Structure](#project-structure)
12. [Deployment](#deployment)

---

## High-Level Architecture

```
┌─────────────────────────────────────────┐
│           LeadTrigger                   │
│      after insert · after update        │
└──────────────────┬──────────────────────┘
                   │ delegates
                   ▼
┌─────────────────────────────────────────┐
│        LeadTriggerHandler               │
│   Recursion guard · Field-change filter │
└──────────────────┬──────────────────────┘
                   │ List<Id>
                   ▼
┌─────────────────────────────────────────┐
│            LeadService                  │
│   Async orchestration · Context guards  │
└──────────────────┬──────────────────────┘
                   │ System.enqueueJob()
                   ▼
┌─────────────────────────────────────────┐
│      LeadExternalApiQueueable           │
│      Batch processing · Chaining        │◄──┐
└───┬──────────────┬──────────────────────┘   │
    │              │ per-Lead callout          │ chains remaining IDs
    │ SOQL via     ▼                          │
    │   ┌─────────────────────────────────┐   │
    │   │    LeadApiCalloutService        │   │
    │   │   HTTP callout · Response parse │   │
    │   └──────────────┬──────────────────┘   │
    ▼                  │ callout:Lead_External_API/lead
┌────────────┐         ▼                      │
│ LeadSelector│  ┌──────────────────────┐      │
│ Centralised │  │   Named Credential   │      │
│    SOQL     │  │  Lead_External_API   │      │
└────────────┘  └──────────┬───────────┘      │
                           │ POST + x-api-key │
                           ▼                  │
                ┌──────────────────────┐      │
                │  External REST API   │      │
                │ Postman Mock Server  │      │
                └──────────────────────┘      │
                           │                  │
                  JSON response (externalId)  │
                           │                  │
                           ▼                  │
               Database.update(leads, false) ─┘
```

| Layer | Class | Responsibility |
|-------|-------|----------------|
| **Trigger** | `LeadTrigger` | Entry point — calls `new LeadTriggerHandler().run()`; contains **zero business logic**. Wraps in try-catch so Lead DML is never rolled back. |
| **Handler** | `LeadTriggerHandler` | Extends `TriggerHandler` base class. Overrides `afterInsert()` and `afterUpdate()`. Recursion guard (`static Set<Id>`), field-change detection, delegates to service. |
| **Service** | `LeadService` | Orchestration — validates inputs, checks async context guards, enqueues the Queueable. |
| **Selector** | `LeadSelector` | Centralised SOQL — single source of truth for Lead queries. Keeps queries out of business logic. |
| **Queueable** | `LeadExternalApiQueueable` | Async execution — batches ≤ 100 callouts per transaction, chains for overflow, partial DML. |
| **Callout** | `LeadApiCalloutService` | HTTP request construction via Named Credential, JSON response parsing, error logging. |
| **Mock** | `LeadApiCalloutMock` | Test helper — implements `HttpCalloutMock` with configurable responses and factory methods. |

---

## Execution Flow

### Happy Path — Single Lead Insert

```
Happy Path — Single Lead Insert

 User
  │
  │ insert Lead
  ▼
 LeadTrigger
  │  new LeadTriggerHandler().run()
  ▼
 LeadTriggerHandler                        [TriggerHandler.run() → afterInsert()]
  │  Check processedLeadIds → not found
  │  Add to processedLeadIds
  │  processLeadsForExternalApi([leadId])
  ▼
 LeadService
  │  Guards pass (not null, not empty, not batch/future)
  │  System.enqueueJob(new Queueable([leadId]))
  │
  │  ── Transaction commits — Lead is saved ✓ ──
  ▼
 LeadExternalApiQueueable
  ├──► LeadSelector.selectLeadsForApiCallout({leadId})
  │        └── returns List<Lead> with 6 fields
  │
  ├──► LeadApiCalloutService.sendLeadToExternalApi(lead)
  │        ├── buildPayload(lead) → JSON map
  │        ├── buildRequest(payload) → HttpRequest
  │        ├── callout:Lead_External_API/lead
  │        │       │
  │        │       ▼  Named Credential
  │        │       │   POST + x-api-key (auto-injected)
  │        │       ▼
  │        │   External API
  │        │       └── {"status":"success","externalId":"abc123"}
  │        │
  │        └── parseResponse → returns "abc123"
  │
  └── Database.update(lead, false) → External_Reference_Id__c = "abc123"

 ── Trigger fires again for the update ──

 LeadTrigger → LeadTriggerHandler
  │  afterUpdate()
  │  processedLeadIds.contains(id) → true → SKIP ✓
```

### Bulk Path — 500 Leads (Queueable Chaining)

```
Bulk Path — 500 Leads (Queueable Chaining)

 Trigger
  │  processLeadsForExternalApi([500 IDs])
  ▼
 Service
  │  enqueueJob(new Queueable([500 IDs]))     ← uses 1 of 50 Queueable slots
  ▼
 Queueable ①
  │  Process IDs 1–100 (100 callouts)
  │  chain remaining [400 IDs]
  ▼
 Queueable ②
  │  Process IDs 101–200 (100 callouts)
  │  chain remaining [300 IDs]
  ▼
 Queueable ③
  │  Process IDs 201–300 (100 callouts)
  │  chain remaining [200 IDs]
  ▼
 Queueable ④–⑤
  │  ...continues until all processed
  ▼
  Done ✓
```

---

## Class-by-Class Breakdown

### 1. `LeadTrigger` (Trigger)

```
fires: after insert, after update
```

- **Zero business logic** — only `new LeadTriggerHandler().run()` inside a try-catch.
- The `run()` method is provided by the `TriggerHandler` base class (Kevin O'Hara framework), which automatically detects the trigger context and dispatches to the correct handler method (`afterInsert()` or `afterUpdate()`).
- The `catch` block logs via `AppLog.write()` and **swallows** the exception, ensuring the Lead's DML (insert/update) is **never rolled back** due to integration failures.
- This follows the **thin trigger** anti-pattern avoidance: all logic lives in testable classes.

### 2. `LeadTriggerHandler` (Handler)

**Extends:** `TriggerHandler` (Kevin O'Hara trigger framework)

**Responsibilities:**
- **Event routing** — overrides `afterInsert()` and `afterUpdate()` separately. The base class's `run()` method dispatches to the correct override automatically.
- **Recursion prevention** — `static Set<Id> processedLeadIds` tracks IDs already handled in the current transaction.
- **Field-change detection** — `hasRelevantFieldChanged()` compares 6 API-relevant fields (FirstName, LastName, Company, Email, LeadSource, Status). Deliberately **excludes** `External_Reference_Id__c` to prevent recursive processing when the Queueable writes back the API response.
- **Delegation** — passes a lightweight `List<Id>` (not full records) to the Service layer.
- **Test support** — `@TestVisible forceException` flag + inner `HandlerForceTestException` class enables testing the trigger's catch block without needing a real failure scenario.
- **Framework benefits** — inherits `TriggerHandler.bypass('LeadTriggerHandler')` / `clearBypass()` for programmatic trigger control, `setMaxLoopCount()` for recursion limits, and `DisabledTrigger__mdt` for declarative handler deactivation.

### 3. `LeadService` (Service Layer)

**Responsibilities:**
- **Input validation** — returns silently for null or empty input.
- **Async context guard** — checks `System.isBatch()` and `System.isFuture()` to avoid enqueuing from unsupported contexts.
- **Governor limit guard** — checks `Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()` before enqueuing.
- **Exception isolation** — wraps `System.enqueueJob()` in try-catch so a platform failure never propagates back to the trigger.

**Why a separate Service class?**

The Handler deals with *trigger mechanics* (recursion, event routing). The Service deals with *business orchestration* (what async mechanism to use, when to skip). This separation means the Service can be called from other entry points (Flow, REST, Batch) without duplicating the trigger-specific logic.

### 4. `LeadSelector` (Selector Pattern)

**Responsibilities:**
- **Centralised SOQL** — all Lead queries live in one class, making them easy to find, maintain, and audit.
- **Null/empty guard** — returns an empty list immediately when input is null or empty (no wasted SOQL).
- Queries exactly the 6 fields needed for the API payload + `Id`.

**Why a Selector class?**

| Without Selector | With Selector |
|------------------|---------------|
| SOQL scattered across Queueable, Service, etc. | Single source of truth for Lead queries |
| Field additions require hunting through multiple files | Add the field once in `LeadSelector` |
| Harder to mock in unit tests | Can override/mock the Selector |
| Risk of inconsistent field lists | Guaranteed consistency |

### 5. `LeadExternalApiQueueable` (Queueable + Chaining)

**Responsibilities:**
- **Implements** `Queueable` and `Database.AllowsCallouts` — allows HTTP callouts in async context.
- **Batch sizing** — processes up to `MAX_CALLOUTS_PER_EXECUTION = 100` leads per execution (matching the callout governor limit).
- **Chaining** — if more than 100 IDs remain, chains a new Queueable with the remainder (`System.enqueueJob`). Each chained job gets fresh governor limits.
- **Per-lead isolation** — individual callout failures are caught and logged; processing continues for remaining leads.
- **Partial DML** — uses `Database.update(leadsToUpdate, false)` so one record's failure doesn't block others.
- **Callout limit check** — checks `Limits.getCallouts() >= Limits.getLimitCallouts()` before each callout in case external code consumed callouts.
- **`without sharing`** — Queueable runs in system context to ensure it can update Lead records regardless of the enqueuing user's permissions.

**Why Queueable over other async approaches?**

| Approach | Limitation | Why Not |
|----------|-----------|---------|
| `@future` | No chaining, no complex params (only primitives), no `Limits.getCallouts()` visibility | Can't handle >100 leads or pass SObject lists |
| Batch Apex | Heavy-weight, designed for millions of records, slower startup | Overkill for trigger-initiated callouts |
| Platform Events | Eventual consistency, separate subscriber, more infrastructure | Over-engineered for a direct callout pattern |
| **Queueable** ✓ | Max 1 chain per execution | Perfect — chaining naturally handles overflow. Supports `List<Id>` params, `Database.AllowsCallouts`, and each job gets fresh limits. |

### 6. `LeadApiCalloutService` (Callout Service)

**Responsibilities:**
- **Request construction** — `buildPayload()` creates a `Map<String, Object>` from 6 Lead fields; `buildRequest()` serialises it to JSON and configures the `HttpRequest` with Named Credential endpoint, POST method, Content-Type header, and 30-second timeout.
- **Named Credential integration** — endpoint is `callout:Lead_External_API/lead`. The `x-api-key` header is auto-injected by the platform via the External Credential. No secrets in code.
- **Response parsing** — `parseResponse()` handles:
  - HTTP non-200 → log error, return null
  - `{"status":"success"}` → extract `externalId` (handles both String and Number types via `String.valueOf()`)
  - `{"status":"error"}` → log the `message` field, return null
  - Malformed/non-JSON body → catch `Exception`, log raw body, return null
- **CalloutException handling** — `sendLeadToExternalApi()` catches `CalloutException` (timeouts, DNS failures) and returns null, so callers never receive an unhandled exception.
- **Input validation** — rejects null Lead or Lead without Id.

### 7. `LeadApiCalloutMock` (Test Mock)

**Responsibilities:**
- Implements `HttpCalloutMock` with configurable `statusCode` and `responseBody`.
- **Factory methods** for common scenarios:
  - `successMock()` → HTTP 200, `{"status":"success","externalId":"ext-ref-001"}`
  - `apiErrorMock()` → HTTP 200, `{"status":"error","message":"Invalid authentication token"}`
  - `httpErrorMock()` → HTTP 500, server error
- Direct constructor for custom scenarios (e.g., malformed JSON body).

---

## Design Patterns & Why We Chose Them

```
Separation of Concerns

┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌────────────┐
│ Trigger  │──▶│ Handler  │──▶│ Service  │──▶│  Queueable   │──▶│  Selector  │
│ Entry    │   │ Trigger  │   │ Business │   │    Async     │   │ Data Access│
│ point    │   │ mechanics│   │ orchestr.│   │  execution   │   │   (SOQL)   │
└──────────┘   └──────────┘   └──────────┘   └──────┬───────┘   └────────────┘
                                                    │
                                                    ▼
                                             ┌──────────────┐
                                             │   Callout    │
                                             │   Service    │
                                             │ HTTP + parse │
                                             └──────────────┘
```

| Pattern | Applied Where | Benefit |
|---------|---------------|---------|
| **Thin Trigger** | `LeadTrigger` | Zero logic in trigger → `new Handler().run()` → all testable through handler/service classes |
| **TriggerHandler Framework** | `LeadTriggerHandler extends TriggerHandler` | Kevin O'Hara base class — standardised event routing, bypass support, loop-count protection, `DisabledTrigger__mdt` declarative control |
| **Service Layer** | `LeadService` | Business orchestration independent of entry point (Trigger, Flow, REST, Batch) |
| **Selector Pattern** | `LeadSelector` | Centralised SOQL → single place for field additions, easier to maintain and mock |
| **Queueable + Chaining** | `LeadExternalApiQueueable` | Async callouts with built-in overflow handling via chaining |
| **Named Credential** | External/Named Credential metadata | No secrets in code, encrypted at rest, admin-manageable |
| **Partial DML** | `Database.update(leads, false)` | One record's failure doesn't block the batch |
| **HttpCalloutMock + Factory** | `LeadApiCalloutMock` | Reusable mock with `successMock()` / `apiErrorMock()` / `httpErrorMock()` factory methods |
| **AppLog (Error Logging)** | All classes | Structured, persistent error logging via managed package — replaces `System.debug` |

### Design Decision — Single POST Endpoint for Insert & Update

The external API provides a single `POST /lead` endpoint. There is no separate `PUT` or `PATCH` endpoint for updating an existing external Lead record.

In a production REST API, the standard convention would be:

| Operation | HTTP Method | Endpoint | Payload |
|-----------|-------------|----------|---------|
| **Create** | `POST` | `/lead` | Lead fields |
| **Update** | `PATCH` / `PUT` | `/lead/{externalId}` | Lead fields + externalId |

Since the assessment's mock API only exposes `POST /lead`, our implementation sends the same payload structure for both insert and update triggers. The trigger still correctly fires on both `after insert` and `after update` events — a relevant field change on an existing Lead re-POSTs the current data to the same endpoint.

**If the API were extended** with a `PATCH /lead/{externalId}` endpoint, the enhancement would be straightforward:
1. The `LeadSelector` SOQL already queries `External_Reference_Id__c`
2. `LeadApiCalloutService.sendLeadToExternalApi()` would check `lead.External_Reference_Id__c`:
   - **Null** → `POST /lead` (new record)
   - **Non-null** → `PATCH /lead/{externalId}` (existing record, include externalId in payload)
3. No changes needed in the trigger, handler, service, or queueable layers

This demonstrates the extensibility of the layered architecture — only the callout service layer would need modification.

---

## Governor Limit Strategy

### Limits at Play

| Governor Limit | Value | Where We Handle It |
|---------------|-------|--------------------|
| **Callouts per transaction** | 100 | `MAX_CALLOUTS_PER_EXECUTION = 100` in Queueable; also checks `Limits.getCallouts()` before each callout |
| **`System.enqueueJob()` from synchronous context** | 50 per transaction | We enqueue only **1** Queueable from the trigger — uses 1 of 50 slots |
| **`System.enqueueJob()` from Queueable (chaining)** | 1 per execution | Each Queueable chains at most **1** next job; checked via `Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()` |
| **SOQL queries** | 100 per transaction | Selector runs **1** SOQL per Queueable execution (up to 100 IDs per batch) |
| **DML rows** | 10,000 per transaction | Queueable updates at most 100 rows per execution |

### How 500 Leads Are Processed

```
Trigger transaction (synchronous)
└─ Handler collects 500 IDs → Service enqueues 1 Queueable
   └─ Uses 1 of 50 enqueueJob() slots ✓
   └─ Transaction commits — all 500 Leads saved ✓

Queueable ① (async — fresh limits)
├─ Processes Lead IDs 1–100 (100 callouts)
├─ Database.update() for successful leads
└─ Chains Queueable ② with remaining 400 IDs
   └─ Uses 1 of 1 chain slot ✓

Queueable ② (async — fresh limits)
├─ Processes Lead IDs 101–200 (100 callouts)
├─ Database.update() for successful leads
└─ Chains Queueable ③ with remaining 300 IDs

... continues until all leads are processed
```

**Key insight:** Each chained Queueable runs in its **own transaction** with **completely fresh governor limits**. The 50-Queueable-per-transaction limit only applies to the *synchronous* trigger context — and we only ever use 1 slot there. Chaining uses the separate 1-per-Queueable limit.

### Data Loader Scenario (10,000 Leads)

Data Loader sends records in batches (default 200 per API call). Each batch is a separate Salesforce transaction:

```
DML Batch 1 (200 leads) → Trigger → 1 Queueable → chains 1 more
DML Batch 2 (200 leads) → Trigger → 1 Queueable → chains 1 more
...
DML Batch 50 (200 leads) → Trigger → 1 Queueable → chains 1 more
```

Each trigger transaction is independent — no risk of hitting the 50-Queueable limit.

---

## Recursion Prevention (Two Layers)

When the Queueable updates `External_Reference_Id__c`, the trigger fires again. Two independent guards prevent infinite loops:

```
 Lead updated with External_Reference_Id__c
                    │
                    ▼
       LeadTrigger fires (after update)
                    │
                    ▼
   ┌────────────────────────────────────┐
   │  Guard 1: processedLeadIds        │
   │  contains this Lead ID?           │
   └──────┬────────────────┬───────────┘
          │ YES             │ NO (edge case)
          ▼                 ▼
  ┌──────────────┐  ┌──────────────────────────┐
  │ SKIP ✓       │  │ Guard 2: hasRelevant     │
  │ already      │  │ FieldChanged? (6 fields) │
  │ processed    │  └─────┬──────────┬─────────┘
  └──────────────┘        │ NO       │ YES (won't happen)
                          ▼          ▼
               ┌──────────────┐  ┌──────────────┐
               │ SKIP ✓       │  │ Would process│
               │ no relevant  │  │ again        │
               │ change       │  └──────────────┘
               └──────────────┘
```

| Guard | Mechanism | Protects Against |
|-------|-----------|------------------|
| **Layer 1** — `processedLeadIds` | Static `Set<Id>` — populated when leads are first processed. Checked at the top of the handler loop. | Same-transaction re-entry (primary defense) |
| **Layer 2** — `hasRelevantFieldChanged()` | Compares only 6 API fields (FirstName, LastName, Company, Email, LeadSource, Status). **Excludes** `External_Reference_Id__c`. | Cross-transaction scenarios, defence-in-depth |

**Why both?** The static set covers the common case (same transaction). The field-change check is defence-in-depth — even if the static set were cleared (e.g., in a different execution context), writing back only `External_Reference_Id__c` would still not trigger a callout because it's not a "relevant" field.

---

## Authentication Approach

The external API requires an `x-api-key` header for authentication.

### Named Credential Architecture (API v65.0)

```
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌──────────────────┐
│    Apex Code     │──▶│ Named Credential │──▶│External Credential│──▶│  Principal   │──▶│  External API    │
│ callout:Lead_    │   │ Lead_External_API│   │ Lead_External_API │   │ x-api-key    │   │ Postman Mock     │
│ External_API/lead│   │ (endpoint URL)   │   │ (Custom protocol) │   │ (encrypted)  │   │ Server           │
└──────────────────┘   └──────────────────┘   └───────────────────┘   └──────────────┘   └──────────────────┘
                                                                          POST + x-api-key ──────▶
```

| Component | API Name | Purpose |
|-----------|----------|---------|
| **External Credential** | `Lead_External_API` | Defines `Custom` auth protocol. The `x-api-key` header is configured on the Principal via Setup — **never in source code**. |
| **Named Credential** | `Lead_External_API` | Binds External Credential to endpoint URL (`https://756f4bd0-50db-4e3e-b3ef-5f021491de57.mock.pstmn.io`). `generateAuthorizationHeader = false`. |

### Why Named Credentials Over Custom Metadata / Hardcoded Values?

| Concern | Named Credential | Custom Metadata | Hardcoded |
|---------|-----------------|-----------------|-----------|
| **Secret storage** | Encrypted at rest ✓ | Plain text in metadata ✗ | In source code ✗ |
| **Source control safety** | Key never committed ✓ | Key in XML files ✗ | Key in Apex ✗ |
| **Admin editable** | Yes, via Setup UI ✓ | Yes, but requires deploy ✓ | Requires code change ✗ |
| **Remote Site Setting needed** | No ✓ | Yes ✗ | Yes ✗ |
| **Audit trail** | Platform-level ✓ | Limited ✗ | None ✗ |

### Post-Deployment Setup (One-Time)

1. **Setup → Named Credentials → External Credentials** → `Lead External API`
2. Create a **Principal** named `Api-Key` (Identity Type: Named Principal)
3. Add an **Authentication Parameter**:
   - **Name:** `x-api-key`
   - **Value:** *(your Postman API key)*
4. Add a **Custom Header** on the External Credential:
   - **Name:** `x-api-key`
   - **Value:** `{!$Credential.Lead_External_API.x-api-key}`
5. **Permission Set Mapping:** Assign the principal to a Permission Set used by the running user

---

## Error Handling Matrix

Every layer has dedicated error handling. No exception ever reaches the user or rolls back Lead DML.

| # | Scenario | Layer | Behaviour | Logged Via |
|---|----------|-------|-----------|------------|
| 1 | HTTP non-200 status code | CalloutService | `External_Reference_Id__c` left blank, Lead persists | `AppLog.write(ERROR)` with status code + body |
| 2 | API returns `{"status":"error"}` | CalloutService | Field left blank, processing continues for remaining leads | `AppLog.write(ERROR)` with API message |
| 3 | Malformed / non-JSON response body | CalloutService | JSON parse `Exception` caught; field left blank | `AppLog.write(ERROR)` with raw body |
| 4 | Callout exception (timeout, DNS) | CalloutService | `CalloutException` caught; returns null | `AppLog.write(ERROR)` with exception message |
| 5 | Callout governor limit reached | Queueable | `Limits.getCallouts()` checked before each callout; loop breaks if at limit | N/A — graceful exit |
| 6 | Individual lead callout failure | Queueable | Caught per-lead; other leads continue processing | `AppLog.write(ERROR)` with Lead ID |
| 7 | DML update failure | Queueable | `Database.update(leads, false)` — partial success mode | `AppLog.write(ERROR)` per failed record |
| 8 | Queueable execution crashes | Queueable | Top-level try-catch in `execute()` with stack trace | `AppLog.write(ERROR)` with stack trace |
| 9 | `System.enqueueJob()` failure | Service | Caught in `LeadService`; trigger transaction unaffected | `AppLog.write(ERROR)` |
| 10 | Handler throws exception | Trigger | Top-level try-catch in `LeadTrigger` swallows exception | `AppLog.write(ERROR)` with stack trace |
| 11 | Trigger recursion | Handler | `processedLeadIds` static set + `hasRelevantFieldChanged()` | N/A — prevented by design |
| 12 | Called from Batch or Future | Service | `System.isBatch()` / `System.isFuture()` guard — silently skips | N/A — guard returns early |
| 13 | Null or empty Lead IDs | Service + Selector | Early return — no Queueable enqueued, no SOQL executed | N/A — guard returns early |

---

## Test Coverage (13 Tests)

All tests live in `LeadTriggerTest` and use `LeadApiCalloutMock` (implements `HttpCalloutMock`) with factory methods.

### Success Scenarios
| Test | What It Proves |
|------|---------------|
| `testInsert_SuccessPopulatesExternalId` | Insert → callout succeeds → `External_Reference_Id__c = "ext-ref-001"` |
| `testUpdate_RelevantFieldChangeTriggersSyncCallout` | Email changed → callout fires → field updated |

### Failure Scenarios
| Test | What It Proves |
|------|---------------|
| `testInsert_ApiErrorLeavesFieldNull` | API returns `{"status":"error"}` → field stays null |
| `testInsert_HttpErrorLeavesFieldNull` | HTTP 500 → field stays null |
| `testInsert_TransactionDoesNotFailOnApiError` | Lead record persists even when API fails |
| `testInsert_MalformedJsonResponseLeavesFieldNull` | Non-JSON body → parse exception caught → field null |

### Bulk Scenarios
| Test | What It Proves |
|------|---------------|
| `testBulkInsert_200Leads` | 200 leads inserted — no governor limit exceptions |
| `testBulkUpdate_200Leads` | 200 leads updated — no governor limit exceptions |

### Edge Cases
| Test | What It Proves |
|------|---------------|
| `testUpdate_IrrelevantFieldChangeDoesNotTriggerCallout` | Only `Description` changed → no callout → `External_Reference_Id__c` unchanged |

### Service Guard Tests
| Test | What It Proves |
|------|---------------|
| `testService_NullInputReturnsGracefully` | `null` input → no Queueable, no exception |
| `testService_EmptyListReturnsGracefully` | Empty list → no Queueable, no exception |
| `testService_FutureContextSkipsEnqueue` | `@future` context → `System.isFuture()` guard skips enqueue |

### Trigger Infrastructure Tests
| Test | What It Proves |
|------|---------------|
| `testTrigger_CatchBlockPreventsRollback` | Handler forced to throw → trigger catch block prevents Lead DML rollback |

---

## Metadata Definitions

| Metadata Type | API Name | Description |
|---------------|----------|-------------|
| **Custom Field** (Lead) | `External_Reference_Id__c` | Text(50), External ID, Unique. Stores the `externalId` returned by the API. Includes description and inline help text. |
| **External Credential** | `Lead_External_API` | Custom auth protocol — holds the `x-api-key` header parameter (configured via Setup, encrypted at rest). |
| **Named Credential** | `Lead_External_API` | SecuredEndpoint binding the External Credential to the Postman Mock Server URL. `generateAuthorizationHeader = false`. |
| **Custom Metadata Type** | `DisabledTrigger__mdt` | Used by the `TriggerHandler` base class. Allows handlers to be disabled declaratively (via `HandlerName__c` + `IsDisabled__c`) without deploying code. |

---

## Project Structure

```
force-app/main/default/
├── triggers/
│   └── LeadTrigger.trigger                   # Entry point — new LeadTriggerHandler().run()
├── classes/
│   ├── TriggerHandler.cls                    # Base class — Kevin O'Hara framework (event routing, bypass, loop count)
│   ├── LeadTriggerHandler.cls                # Handler — extends TriggerHandler; recursion guard, field-change filter
│   ├── LeadService.cls                       # Service — async orchestration, context guards
│   ├── LeadSelector.cls                      # Selector — centralised Lead SOQL queries
│   ├── LeadExternalApiQueueable.cls          # Queueable — batch callouts, chaining, partial DML
│   ├── LeadApiCalloutService.cls             # Callout — HTTP request, Named Credential, response parsing
│   ├── LeadApiCalloutMock.cls                # Mock — HttpCalloutMock with factory methods
│   └── LeadTriggerTest.cls                   # Tests — 13 methods covering all scenarios
├── externalCredentials/
│   └── Lead_External_API.externalCredential-meta.xml
├── namedCredentials/
│   └── Lead_External_API.namedCredential-meta.xml
└── objects/
    ├── Lead/
    │   └── fields/
    │       └── External_Reference_Id__c.field-meta.xml
    └── DisabledTrigger__mdt/                 # Custom Metadata Type for TriggerHandler framework
        ├── DisabledTrigger__mdt.object-meta.xml
        └── fields/
            ├── HandlerName__c.field-meta.xml
            └── IsDisabled__c.field-meta.xml
```

---

