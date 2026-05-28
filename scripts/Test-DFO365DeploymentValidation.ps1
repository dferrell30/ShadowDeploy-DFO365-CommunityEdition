# Test-DFO365DeploymentValidation.ps1

Write-Host "Running Defender for Office 365 Validation..." -ForegroundColor Cyan

function Test-RuleDisabled {
    param($Rule, $Name)

    if (-not $Rule) {
        Write-Host "[FAIL] $Name rule not found" -ForegroundColor Red
        return
    }

    if ($Rule.Enabled -eq $false -or $Rule.State -eq "Disabled") {
        Write-Host "[PASS] $Name rule is disabled" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Name rule is ENABLED" -ForegroundColor Red
    }
}

# Anti-Phish
$ap = Get-AntiPhishRule -ErrorAction SilentlyContinue | Where-Object Name -like "*AntiPhish*"
Test-RuleDisabled $ap "Anti-Phish"

# Safe Links
$sl = Get-SafeLinksRule -ErrorAction SilentlyContinue | Where-Object Name -like "*SafeLinks*"
Test-RuleDisabled $sl "Safe Links"

# Safe Attachments
$sa = Get-SafeAttachmentRule -ErrorAction SilentlyContinue | Where-Object Name -like "*SafeAttachments*"
Test-RuleDisabled $sa "Safe Attachments"

# Inbound Spam
$isp = Get-HostedContentFilterRule -ErrorAction SilentlyContinue | Where-Object Name -like "*Inbound*"
Test-RuleDisabled $isp "Inbound Spam"

# Outbound Spam
$osp = Get-HostedOutboundSpamFilterRule -ErrorAction SilentlyContinue | Where-Object Name -like "*Outbound*"
Test-RuleDisabled $osp "Outbound Spam"

# Malware
$mw = Get-MalwareFilterRule -ErrorAction SilentlyContinue | Where-Object Name -like "*Malware*"
Test-RuleDisabled $mw "Malware"

Write-Host "`nValidation Complete." -ForegroundColor Cyan
