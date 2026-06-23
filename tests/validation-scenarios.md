# 🧪 Shadow Deploy – Defender for Office 365 Validation Scenarios

This guide provides recommended validation activities after deploying Microsoft Defender for Office 365 protections using Shadow Deploy.

The goal is to confirm that deployed policies are functioning as expected and that users receive the intended protections.

---

# 🎯 Validation Objectives

Validate:

* Anti-Phishing Protection
* Safe Links Protection
* Safe Attachments Protection
* Anti-Spam Protection
* Anti-Malware Protection
* Policy Scope Assignments
* Mail Flow Impact
* Reporting & Visibility

---

# ⚠️ Before You Begin

Validation should be performed:

* In a test tenant whenever possible
* Using dedicated test accounts
* During approved testing windows
* After deployment completes successfully

---

# 🛡️ Anti-Phishing Validation

## Scenario 1 – Display Name Impersonation

### Goal

Confirm anti-phishing protection detects impersonation attempts.

### Test

Send a message using:

```text
Display Name: CEO Name
Email: external-test@contoso-test.com
```

to:

```text
testuser@company.com
```

### Expected Result

* Message quarantined, blocked, or tagged
* Anti-Phishing policy triggered
* Alert visible in Defender portal

### Validation Location

```text
Microsoft Defender Portal
Email & Collaboration
Review
Threat Explorer
```

---

## Scenario 2 – Domain Spoof Attempt

### Goal

Validate spoof intelligence protections.

### Test

Send mail from a domain intentionally configured to mimic a trusted sender.

### Expected Result

* Spoof detection triggered
* Message marked suspicious
* User warning displayed

---

# 🔗 Safe Links Validation

## Scenario 1 – Known Test URL

### Goal

Validate Safe Links URL rewriting and scanning.

### Test

Send a message containing:

```text
https://www.amtso.org/check-desktop-phishing-page/
```

### Expected Result

* URL rewritten by Safe Links
* User redirected through Safe Links service
* Click tracked by Defender

### Validation Location

```text
Microsoft Defender Portal
Email & Collaboration
Explorer
```

---

## Scenario 2 – User Click Tracking

### Goal

Validate click telemetry.

### Test

Click a Safe Links protected URL.

### Expected Result

* Click recorded
* URL evaluation performed
* Event visible in reporting

---

# 📎 Safe Attachments Validation

## Scenario 1 – AMTSO Test File

### Goal

Validate Safe Attachments scanning.

### Test

Download:

```text
https://www.amtso.org/security-features-check/
```

and send the provided test file through email.

### Expected Result

* Attachment detonated
* Safe Attachments policy evaluated
* Delivery action follows configured policy

---

## Scenario 2 – Malware Simulation

### Goal

Validate malware inspection workflow.

### Test

Use:

```text
EICAR Test File
```

### Expected Result

* File blocked or quarantined
* Detection visible in Defender

### EICAR

```text
https://www.eicar.org/download-anti-malware-testfile/
```

---

# 📧 Anti-Spam Validation

## Scenario 1 – Bulk Mail Detection

### Goal

Validate spam filtering.

### Test

Send multiple repetitive messages containing:

```text
FREE
LIMITED TIME OFFER
CLICK NOW
```

### Expected Result

* Spam confidence increased
* Message filtered appropriately

---

## Scenario 2 – External Sender Controls

### Goal

Validate external mail handling.

### Test

Send mail from an external account.

### Expected Result

* External tags displayed
* Policy actions applied

---

# ☣️ Anti-Malware Validation

## Scenario 1 – EICAR Validation

### Goal

Validate malware detection.

### Test

Email the EICAR test file.

### Expected Result

* Malware detection triggered
* Message blocked or quarantined

---

# 🎯 Policy Scoping Validation

## Scenario 1 – Scoped Group Deployment

### Goal

Validate group-based policy targeting.

### Test

1. Enable Policy Scoping
2. Enter test mail-enabled Microsoft 365 group
3. Deploy policy

### Expected Result

* Rule scoped to specified group
* Non-members excluded
* Members receive policy coverage

### Verification

```powershell
Get-SafeLinksRule
Get-SafeAttachmentRule
Get-AntiPhishRule
```

Review:

```text
SentToMemberOf
RecipientDomainIs
IncludedRecipients
```

properties.

---

# 📊 Reporting Validation

## Scenario 1 – Report Generation

### Goal

Validate reporting engine.

### Test

Generate a report after deployment.

### Expected Result

Report contains:

* Executive Summary
* Protection Comparison
* Security Heat Map
* Policy Inventory
* Deployment Results
* Recommendations

---

# 📜 Log Validation

## Scenario 1 – Operational Logs

### Goal

Confirm deployment logging.

### Test

Open:

```text
Logs\
```

### Expected Result

Logs contain:

* Connection activity
* Deployment actions
* Validation results
* Errors and warnings
* Scope assignment actions

---

# 🧪 Full End-to-End Validation

Recommended sequence:

1. Connect Exchange Online
2. Deploy All Custom Policies
3. Validate Anti-Phishing
4. Validate Safe Links
5. Validate Safe Attachments
6. Validate Anti-Spam
7. Validate Anti-Malware
8. Validate Group Scoping
9. Generate Report
10. Review Logs

---

# ✅ Validation Success Criteria

Deployment is considered successful when:

* Policies exist
* Rules exist
* Rules are enabled
* Protection actions function as expected
* Scope assignments are correct
* Reports generate successfully
* Logs contain no critical errors

---

# 🏰 Shadow Deploy Validation Philosophy

Shadow Deploy focuses on:

* Repeatable deployment
* Repeatable validation
* Operational visibility
* Executive-ready reporting
* Evidence collection for assessments and audits

Validation should always be performed before production sign-off.
