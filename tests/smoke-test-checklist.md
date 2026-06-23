# 🧪 Shadow Deploy – Defender for Office 365 Smoke Test Checklist

## Objective

Verify that Shadow Deploy is functioning correctly after installation, update, or release packaging.

This smoke test validates:

* Exchange Online connectivity
* Configuration loading
* Policy deployment workflows
* Optional policy scoping
* Logging
* Reporting
* Export functionality

This checklist is intended to verify tool functionality and deployment operations without performing extensive Defender validation.

---

# Environment Validation

## Startup Validation

* [ ] Tool launches successfully
* [ ] UI renders correctly
* [ ] Shadow Deploy branding loads correctly
* [ ] No PowerShell errors during startup
* [ ] Configuration loads successfully

---

## Module Validation

* [ ] ExchangeOnlineManagement module installed
* [ ] Module imports successfully
* [ ] No module warnings displayed

---

## Tenant Validation

* [ ] Connected to correct Microsoft 365 tenant
* [ ] Tenant name displays correctly
* [ ] Signed-in account displays correctly
* [ ] Exchange Online connection successful

---

# Deployment Validation

## Anti-Phishing

* [ ] Anti-Phishing deployment completes
* [ ] No deployment errors
* [ ] Policy exists
* [ ] Rule exists

---

## Safe Attachments

* [ ] Safe Attachments deployment completes
* [ ] No deployment errors
* [ ] Policy exists
* [ ] Rule exists

---

## Safe Links

* [ ] Safe Links deployment completes
* [ ] No deployment errors
* [ ] Policy exists
* [ ] Rule exists

---

## Anti-Spam

* [ ] Anti-Spam deployment completes
* [ ] No deployment errors
* [ ] Policy exists
* [ ] Rule exists

---

## Anti-Malware

* [ ] Anti-Malware deployment completes
* [ ] No deployment errors
* [ ] Policy exists
* [ ] Rule exists

---

# Deploy All Validation

## Deploy All Custom Policies

* [ ] Deploy All completes successfully
* [ ] Execution Results panel updates correctly
* [ ] Operational Log updates correctly
* [ ] No unhandled exceptions occur

---

# Assign Scope Validation

## Enable Policy Scoping

* [ ] Checkbox can be enabled
* [ ] Group name field accepts input
* [ ] Valid mail-enabled group entered

Example:

```text
M365-TestGroup
```

---

## Policy Scope Assignment

* [ ] Assignment executes successfully
* [ ] No UI errors
* [ ] No prompt failures
* [ ] Scope assignment appears in log output

---

# Idempotency Validation

## Re-Run Deployment

* [ ] Deploy All executed a second time
* [ ] Existing policies detected
* [ ] Existing rules detected
* [ ] No duplicate objects created
* [ ] No fatal errors generated

---

# Reporting Validation

## HTML Report

* [ ] Report generates successfully
* [ ] Executive Summary visible
* [ ] Protection Comparison visible
* [ ] Security Heat Map visible
* [ ] Deployment Results visible
* [ ] Policy Inventory visible
* [ ] Recommendations visible

---

## Report Accessibility

* [ ] Report opens automatically
* [ ] Report displays correctly in browser
* [ ] Navigation works
* [ ] No broken sections

---

# Logging Validation

## Operational Logs

* [ ] Logs folder opens successfully
* [ ] Current deployment session recorded
* [ ] Warnings captured
* [ ] Errors captured

---

# Export Validation

## Export Operations

* [ ] Export completes successfully
* [ ] Output files created
* [ ] Export location accessible

---

# UI Validation

## General UI

* [ ] Buttons render correctly
* [ ] Deployment cards display correctly
* [ ] Session Summary displays correctly
* [ ] No overlapping controls
* [ ] No text clipping

---

## Small Screen Validation

* [ ] UI usable on 1366x768 display
* [ ] Scroll bars function correctly (if enabled)
* [ ] No inaccessible controls

---

# Release Readiness

## Pass Criteria

Release is considered ready when:

* [ ] Tool launches successfully
* [ ] Exchange connection succeeds
* [ ] Deploy All succeeds
* [ ] Scope assignment succeeds
* [ ] Report generation succeeds
* [ ] Logging succeeds
* [ ] No critical UI defects exist
* [ ] No unhandled exceptions occur

---

# Result

## Smoke Test Outcome

* [ ] PASS

or

* [ ] FAIL

### Notes

```text
______________________________________

______________________________________

______________________________________
```

---

# Shadow Deploy Release Philosophy

A release should only proceed when:

* Deployment functionality is operational
* Reporting is operational
* Logging is operational
* Scope assignment is operational
* No critical UI defects exist
* No deployment-blocking errors are present

Smoke testing validates the tool.

Validation testing validates Microsoft Defender for Office 365.
