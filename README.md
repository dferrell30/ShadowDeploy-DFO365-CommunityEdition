# 🏰 Shadow Deploy – Defender for Office 365

Shadow Deploy – Defender for Office 365 is a PowerShell-based deployment, validation, and reporting framework designed to simplify Microsoft Defender for Office 365 policy deployment using a guided operational interface.

The tool provides a repeatable method for deploying, validating, documenting, and reporting on Defender for Office 365 security controls while maintaining a professional operator experience and executive-ready reporting.

---

## Features

### Core Deployment

* Anti-Phishing deployment
* Safe Attachments deployment
* Safe Links deployment
* Inbound Anti-Spam deployment
* Anti-Malware deployment
* Deploy All Custom Policies workflow

### Operational Features

* Exchange Online connectivity validation
* Configuration validation
* JSON-driven policy deployment
* Policy status tracking
* Execution logging
* Deployment evidence collection
* HTML reporting
* JSON export support
* Backup support
* Open Logs functionality

### Reporting Features

* Executive Summary
* Deployment Status Dashboard
* Protection Level Comparison
* Security Heat Map
* Policy Inventory
* Deployment Timeline
* Recommendations
* Operational Evidence

### Assign Scope Capability

Shadow Deploy supports optional policy scoping using a mail-enabled Microsoft 365 group.

When enabled:

1. Check **Enable Policy Scoping**
2. Enter a valid mail-enabled Microsoft 365 group name
3. Deploy policies
4. Optionally run Assign Policy

The tool applies supported Defender for Office 365 policy rules to the specified target group.

---

## Requirements

### Supported Platforms

* Windows PowerShell 5.1+
* PowerShell 7+

### Required Module

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
```

### Required Permissions

One of the following:

* Global Administrator
* Security Administrator
* Exchange Administrator

---

## Installation

```powershell
git clone https://github.com/<YOUR-REPOSITORY>.git
```

Navigate to:

```powershell
cd .\scripts
```

Install required module:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
```

Run:

```powershell
.\ShadowDeploy-DFO365.ps1
```

---

## Project Structure

```text
ShadowDeploy-DFO365
│
├── Assets
│   └── shadowdeployo365.png
│
├── Config
│   ├── DFO365_ZeroTrust.json
│   └── SettingsCatalog
│
├── Exports
│
├── Logs
│
├── Reports
│
└── Scripts
    └── ShadowDeploy-DFO365.ps1
```

---

## Shadow Suite Identity

Shadow Deploy – Defender for Office 365 serves as the Email Gatekeeper within the Shadow Suite ecosystem.

Theme:

* Fortress Defender
* Email Security Guardian
* Zero Trust Deployment Framework
* Microsoft Defender Operational Toolkit

---

## Current Release Baseline

Current Stable Baseline:

**Shadow Deploy – Defender for Office 365 V1.4**

This release includes:

* Updated Shadow Suite branding
* Assign Scope functionality
* Open Logs integration
* Executive reporting
* Protection comparison reporting
* Heat Map visualization
* Deployment evidence export
* Improved deployment workflow

---

## Disclaimer

Always validate changes in a non-production environment before deploying to production tenants.

This tool is provided as-is without warranty.

---

## License

MIT License
