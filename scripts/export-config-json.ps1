$export = @{
    AntiPhishPolicies  = Get-AntiPhishPolicy
    AntiPhishRules     = Get-AntiPhishRule

    AntiSpamInboundPolicies = Get-HostedContentFilterPolicy
    AntiSpamInboundRules    = Get-HostedContentFilterRule

    AntiSpamOutboundPolicies = Get-HostedOutboundSpamFilterPolicy
    AntiSpamOutboundRules    = Get-HostedOutboundSpamFilterRule

    SafeLinksPolicies  = Get-SafeLinksPolicy
    SafeLinksRules     = Get-SafeLinksRule

    SafeAttachmentPolicies = Get-SafeAttachmentPolicy
    SafeAttachmentRules    = Get-SafeAttachmentRule

    MalwarePolicies = Get-MalwareFilterPolicy
    MalwareRules    = Get-MalwareFilterRule
}

$path = ".\examples\tenant-export.json"

$export | ConvertTo-Json -Depth 5 | Out-File $path

Write-Host "Export completed: $path" -ForegroundColor Green
