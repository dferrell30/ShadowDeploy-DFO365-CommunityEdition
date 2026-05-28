# Validation Scenarios — Defender for Office 365 (V1)

## Purpose

Validate security controls behave as expected after enabling rules.

---

## ⚠️ Important

Rules are deployed **disabled by default**.
Enable rules before running these tests.

---

## Scenario 1 — Phishing Detection

**Test:**

* Send simulated phishing email (spoofed domain or suspicious link)

**Expected:**

* Email is quarantined
* Quarantine policy = AdminOnlyAccessPolicy

---

## Scenario 2 — Safe Links Protection

**Test:**

* Send email containing a known malicious URL

**Expected:**

* URL rewritten
* Click triggers warning/block page

---

## Scenario 3 — Safe Attachments Protection

**Test:**

* Send email with malicious attachment (test file)

**Expected:**

* Attachment detonated
* Message blocked or quarantined

---

## Scenario 4 — Spam Filtering

**Test:**

* Send bulk/spam-like email

**Expected:**

* Message quarantined
* Correct spam policy applied

---

## Scenario 5 — Outbound Spam Protection

**Test:**

* Send high-volume outbound emails

**Expected:**

* Throttling or blocking triggered
* Admin notification generated

---

## Scenario 6 — Anti-Malware Protection

**Test:**

* Send EICAR test file

**Expected:**

* Message blocked or deleted

---

## Scenario 7 — Idempotent Deployment

**Test:**

* Re-run deployment tool

**Expected:**

* No duplication
* No errors
* Rules remain disabled

---

## Result Tracking

| Scenario         | Status    | Notes |
| ---------------- | --------- | ----- |
| Phishing         | Pass/Fail |       |
| Safe Links       | Pass/Fail |       |
| Safe Attachments | Pass/Fail |       |
| Spam             | Pass/Fail |       |
| Outbound Spam    | Pass/Fail |       |
| Malware          | Pass/Fail |       |
| Idempotency      | Pass/Fail |       |
