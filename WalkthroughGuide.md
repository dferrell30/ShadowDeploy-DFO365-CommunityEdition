# 🚀 Shadow Deploy – Defender for Office 365 Walkthrough Guide

## Step 1 – Launch the Tool

Open PowerShell and launch:

```powershell
.\ShadowDeploy-DFO365.ps1
```

Verify:

* Configuration loaded successfully
* UI displays Connected / Ready status

---

## Step 2 – Connect to Exchange Online

Click:

**Connect Exchange Online**

Authenticate with an account that has:

* Exchange Administrator
* Security Administrator
* Global Administrator

permissions.

Once connected:

* Tenant information populates
* Connection status updates
* Deployment controls become available

---

## Step 3 – Review Configuration

Confirm:

* Configuration Loaded = Yes
* Deployment mode is correct
* Target policies appear available

If configuration fails:

* Verify Config folder exists
* Verify JSON files are present
* Relaunch tool

---

## Step 4 – Deploy Individual Policies

Individual deployment options:

### Anti-Phishing

Deploys:

* Anti-Phishing Policy
* Anti-Phishing Rule

### Safe Attachments

Deploys:

* Safe Attachments Policy
* Safe Attachments Rule

### Safe Links

Deploys:

* Safe Links Policy
* Safe Links Rule

### Inbound Anti-Spam

Deploys:

* Inbound Spam Policy
* Spam Rule Configuration

### Anti-Malware

Deploys:

* Anti-Malware Policy
* Anti-Malware Rule

---

## Step 5 – Deploy Everything

Click:

**Deploy All Custom Policies**

This deploys:

* Anti-Phishing
* Safe Attachments
* Safe Links
* Anti-Spam
* Anti-Malware

using the configured JSON baseline.

---

## Step 6 – Optional Policy Scoping

To scope policies to a mail-enabled Microsoft 365 group:

### Enable Scoping

Check:

```text
Enable Policy Scoping
```

### Enter Group

Example:

```text
M365-Executives
```

or

```text
M365-VIPUsers
```

### Deploy

Run:

```text
Deploy All Custom Policies
```

The deployment engine applies supported policy rules to the specified group.

---

## Step 7 – Review Results

Review:

### Execution Results

Shows:

* Success
* Warning
* Failed

status for each action.

### Operational Log

Shows:

* Commands executed
* Validation results
* Assignment actions
* Deployment outcomes

---

## Step 8 – Generate Report

Click:

```text
Reporting / Export
```

The report includes:

* Executive Summary
* Protection Comparison
* Heat Map
* Deployment Results
* Policy Inventory
* Recommendations
* Evidence Collection

---

## Step 9 – Open Logs

Click:

```text
Open Logs
```

This opens the Logs folder containing:

* Deployment logs
* Operational logs
* Troubleshooting information

---

## Troubleshooting

### Configuration Not Loaded

Verify:

```text
\Config\
```

contains required JSON files.

---

### Exchange Connection Failure

Verify:

* Internet access
* Correct permissions
* ExchangeOnlineManagement module installed

---

### Assign Scope Not Working

Verify:

1. Enable Policy Scoping is checked
2. Mail-enabled Microsoft 365 group name is entered correctly
3. Group exists in Exchange Online
4. User has permissions to update policy rules

---

## Recommended Workflow

1. Connect Exchange Online
2. Validate Configuration
3. Deploy All Custom Policies
4. Verify Results
5. Apply Policy Scoping (if required)
6. Generate Report
7. Export Evidence
8. Review Logs

This workflow is the recommended operational path for testing and lab environments.
