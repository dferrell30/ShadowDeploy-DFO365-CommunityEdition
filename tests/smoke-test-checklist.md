# Smoke Test Checklist — DFO365 Deployment Tool (V1)

## Objective

Verify successful deployment without impacting mail flow.

---

## Pre-Checks

* [ ] Connected to correct tenant (verify in tool UI)
* [ ] ExchangeOnlineManagement module installed
* [ ] Admin account has required permissions

---

## Deployment

* [ ] Run **Quick Build: All Baselines**
* [ ] No errors in UI log

---

## Policy Verification

* [ ] Anti-Phish policy exists
* [ ] Anti-Spam (Inbound & Outbound) policies exist
* [ ] Safe Links policy exists
* [ ] Safe Attachments policy exists
* [ ] Anti-Malware policy exists

---

## Rule Verification

* [ ] All rules exist
* [ ] All rules are **Disabled**

---

## Idempotency Check

* [ ] Run Quick Build again
* [ ] No errors
* [ ] Output shows "already exists"
* [ ] Rules remain disabled

---

## Export Check

* [ ] Export JSON runs successfully
* [ ] Files are generated

---

## Result

* [ ] PASS
* [ ] FAIL (capture errors/logs)

