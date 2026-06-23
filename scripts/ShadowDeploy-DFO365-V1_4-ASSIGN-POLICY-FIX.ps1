
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Performance cache
# Keeps the UI responsive by avoiding repeated live Exchange Online lookups.
$Script:TenantStatusCache = $null
$Script:TenantStatusCacheTime = $null
$Script:AcceptedDomainsCache = $null
$Script:AcceptedDomainsCacheTime = $null
$Script:TenantStatusCacheSeconds = 900
$Script:AcceptedDomainsCacheSeconds = 1800

Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:RequiredModuleName = 'ExchangeOnlineManagement'
$Script:Config = $null
$Script:LoadedConfigPath = $null
$Script:EnableRulesOnDeploy = $false
$Script:ToolDisplayName = 'Shadow Deploy for Defender for Office 365 V1.2'

function Get-ScriptDirectory {
  if ($PSScriptRoot -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
  if ($PSCommandPath -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) { return (Split-Path -Parent $PSCommandPath) }
  if ($MyInvocation.MyCommand.Path -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
  return (Get-Location).Path
}

$Script:ScriptDirectory = Get-ScriptDirectory
$Script:ConfigDirectory = Join-Path (Split-Path -Parent $Script:ScriptDirectory) 'config'
$Script:ZeroTrustConfigPath = Join-Path $Script:ConfigDirectory 'DFO365_ZeroTrust.json'

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)

  $installCommand = "Install-Module $Name -Scope CurrentUser -Force -AllowClobber"

  if (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue) {
    return [pscustomobject]@{
      Success = $true
      Message = "Exchange Online cmdlets are already available."
      InstallCommand = $installCommand
    }
  }

  $available = Get-Module -ListAvailable -Name $Name
  if (-not $available) {
    $msg = "Required module '$Name' is not installed.`r`n`r`nRun:`r`n$installCommand"
    [System.Windows.Forms.MessageBox]::Show(
      $msg,
      "Missing PowerShell Module",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return [pscustomobject]@{
      Success = $false
      Message = $msg
      InstallCommand = $installCommand
    }
  }

  try {
    Import-Module $Name -Force -ErrorAction Stop | Out-Null
    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
      throw "Connect-ExchangeOnline is not available after importing $Name."
    }
    return [pscustomobject]@{
      Success = $true
      Message = "Module '$Name' is available."
      InstallCommand = $installCommand
    }
  }
  catch {
    $msg = "Failed to import module '$Name'. $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
      $msg,
      "Module Import Error",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return [pscustomobject]@{
      Success = $false
      Message = $msg
      InstallCommand = $installCommand
    }
  }
}

function Get-ActiveExchangeOnlineConnection {
  try {
    $connections = @(Get-ConnectionInformation -ErrorAction Stop)
    if (-not $connections) { return $null }

    $active = $connections | Where-Object {
      ($_.PSObject.Properties.Name -notcontains 'State' -or $_.State -eq 'Connected') -and
      ($_.PSObject.Properties.Name -notcontains 'TokenStatus' -or $_.TokenStatus -eq 'Active') -and
      ($_.PSObject.Properties.Name -notcontains 'IsEopSession' -or -not $_.IsEopSession)
    } | Select-Object -First 1

    return $active
  }
  catch {
    return $null
  }
}

function Test-ExchangeOnlineConnection {
  return [bool](Get-ActiveExchangeOnlineConnection)
}

function Get-ConnectedUserPrincipalName {
  $conn = Get-ActiveExchangeOnlineConnection
  if ($conn -and $conn.UserPrincipalName) { return [string]$conn.UserPrincipalName }
  return $null
}

function Get-TenantDisplayName {
  $upn = Get-ConnectedUserPrincipalName
  if ($upn -and ($upn -match '@')) {
    return (($upn -split '@')[-1]).ToLower()
  }
  return $null
}

function Update-ConnectionLabel {
  param([Parameter(Mandatory)][System.Windows.Forms.Label]$Label)

  if (Test-ExchangeOnlineConnection) {
    $who = Get-ConnectedUserPrincipalName
    $tenant = Get-TenantDisplayName
    if ([string]::IsNullOrWhiteSpace($who)) {
      $Label.Text = "Status: Connected"
    } elseif ([string]::IsNullOrWhiteSpace($tenant)) {
      $Label.Text = "Status: Connected as $who"
    } else {
      $Label.Text = "Status: Connected to $tenant as $who"
    }
    $Label.ForeColor = [System.Drawing.Color]::LightGreen
  }
  else {
    $Label.Text = "Status: Not Connected"
    $Label.ForeColor = [System.Drawing.Color]::White
  }
}

function Ensure-ExchangeOnlineAuthenticated {
  param(
    [switch]$ForceReauth,
    [System.Windows.Forms.Label]$ConnectionLabel,
    [scriptblock]$Logger
  )

  $moduleCheck = Ensure-Module -Name $Script:RequiredModuleName
  if (-not $moduleCheck.Success) {
    if ($Logger) { & $Logger "[ERR] $($moduleCheck.Message)" }
    if ($ConnectionLabel) { Update-ConnectionLabel -Label $ConnectionLabel }
    return $false
  }

  try {
    if ($ForceReauth -and (Test-ExchangeOnlineConnection)) {
      Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 300
    }

    if (-not (Test-ExchangeOnlineConnection)) {
      Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
      Start-Sleep -Milliseconds 500
    }

    if (-not (Test-ExchangeOnlineConnection)) {
      throw "Exchange Online connection could not be verified after sign-in."
    }

    if ($ConnectionLabel) { Update-ConnectionLabel -Label $ConnectionLabel }

    if ($Logger) {
      $who = Get-ConnectedUserPrincipalName
      $tenant = Get-TenantDisplayName
      if ($who -and $tenant) {
        & $Logger "[OK] Connected to $tenant as $who"
      } elseif ($who) {
        & $Logger "[OK] Connected as $who"
      } else {
        & $Logger "[OK] Connected"
      }
    }
    return $true
  }
  catch {
    $msg = "Connect failed: $($_.Exception.Message)"
    if ($Logger) { & $Logger "[ERR] $msg" }
    [System.Windows.Forms.MessageBox]::Show(
      $msg,
      "Exchange Online Connection Error",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    if ($ConnectionLabel) { Update-ConnectionLabel -Label $ConnectionLabel }
    return $false
  }
}

function Get-AllAcceptedDomains {
    try {
        if ($Script:AcceptedDomainsCache -and (Test-ShadowCacheFresh -Timestamp $Script:AcceptedDomainsCacheTime -Seconds $Script:AcceptedDomainsCacheSeconds)) {
            return $Script:AcceptedDomainsCache
        }

        $domains = @()
        if (Get-Command Get-AcceptedDomain -ErrorAction SilentlyContinue) {
            $domains = @(Get-AcceptedDomain -ErrorAction Stop | Where-Object { $_.DomainName } | ForEach-Object { [string]$_.DomainName })
        }

        if (-not $domains -or $domains.Count -eq 0) {
            $domains = @("*")
        }

        $Script:AcceptedDomainsCache = $domains
        $Script:AcceptedDomainsCacheTime = Get-Date
        return $domains
    }
    catch {
        Add-Log "[WARN] Could not collect accepted domains. Using wildcard recipient/sender scope. $($_.Exception.Message)"
        $Script:AcceptedDomainsCache = @("*")
        $Script:AcceptedDomainsCacheTime = Get-Date
        return $Script:AcceptedDomainsCache
    }
}

function Ensure-ExchangeCommandAvailable {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [scriptblock]$Logger
  )

  if (Get-Command $CommandName -ErrorAction SilentlyContinue) { return $true }

  if ($Logger) {
    & $Logger "[ERR] Required cmdlet '$CommandName' is not available in the current Exchange Online session."
  }
  return $false
}

function Supports-Param {
  param([string]$CommandName,[string]$ParamName)
  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
  return [bool]($cmd -and $cmd.Parameters.ContainsKey($ParamName))
}

function Write-UiStatus {
  param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Color = 'White'
  )
  try { Write-Host $Message -ForegroundColor $Color } catch {}
  try {
    if (Get-Command Log -ErrorAction SilentlyContinue) { Log $Message }
  } catch {}
}

function Set-RuleEnabled {
  param(
    [Parameter(Mandatory)][string]$CmdletName,
    [Parameter(Mandatory)][hashtable]$BaseParams,
    [bool]$Enabled = $true
  )
  if (Supports-Param $CmdletName 'Enabled') {
    & $CmdletName @BaseParams -Enabled:$Enabled
  }
  elseif (Supports-Param $CmdletName 'State') {
    & $CmdletName @BaseParams -State ($(if ($Enabled) { 'Enabled' } else { 'Disabled' }))
  }
  else {
    & $CmdletName @BaseParams
  }
}

function Disable-RuleOnly {
  param(
    [Parameter(Mandatory)][string]$SetCmdletName,
    [Parameter(Mandatory)][string]$Identity,
    [string]$DisableCmdletName = ''
  )

  if ($DisableCmdletName -and (Get-Command $DisableCmdletName -ErrorAction SilentlyContinue)) {
    & $DisableCmdletName -Identity $Identity -Confirm:$false
    return
  }

  Set-RuleEnabled -CmdletName $SetCmdletName -BaseParams @{ Identity = $Identity } -Enabled:$false
}

function ConvertTo-OrderedHashtable {
  param([Parameter(Mandatory)][object]$InputObject)

  $ordered = [ordered]@{}
  if ($null -eq $InputObject) { return $ordered }

  foreach ($prop in $InputObject.PSObject.Properties) {
    $ordered[$prop.Name] = $prop.Value
  }
  return $ordered
}

function Load-ConfigFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [System.Windows.Forms.Label]$ConfigLabel
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-UiStatus "[ERR] Default config path is empty." 'Red'
    if ($ConfigLabel) {
      $ConfigLabel.Text = "Profile: Zero Trust | Config: Not Loaded"
      $ConfigLabel.ForeColor = [System.Drawing.Color]::Tomato
    }
    return $false
  }

  if (-not (Test-Path $Path)) {
    Write-UiStatus "[ERR] Config file not found: $Path" 'Red'
    if ($ConfigLabel) {
      $ConfigLabel.Text = "Profile: Zero Trust | Config: Not Found"
      $ConfigLabel.ForeColor = [System.Drawing.Color]::Tomato
    }
    return $false
  }

  try {
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $Script:Config = $raw | ConvertFrom-Json -ErrorAction Stop
    $Script:LoadedConfigPath = $Path
    $leaf = Split-Path -Leaf $Path
    if ($ConfigLabel) {
      $ConfigLabel.Text = "Profile: Zero Trust | Config: $leaf"
      $ConfigLabel.ForeColor = [System.Drawing.Color]::LightBlue
    }
    Write-UiStatus "[OK] Config loaded: $leaf" 'Green'
    return $true
  }
  catch {
    Write-UiStatus "[ERR] Failed to load config: $($_.Exception.Message)" 'Red'
    if ($ConfigLabel) {
      $ConfigLabel.Text = "Profile: Zero Trust | Config: Load Failed"
      $ConfigLabel.ForeColor = [System.Drawing.Color]::Tomato
    }
    return $false
  }
}

function Ensure-ConfigLoaded {
  param([System.Windows.Forms.Label]$ConfigLabel)

  if ($null -eq $Script:Config) {
    return (Load-ConfigFile -Path $Script:ZeroTrustConfigPath -ConfigLabel $ConfigLabel)
  }
  return $true
}

function Get-ConfigSection {
  param([Parameter(Mandatory)][string]$SectionName)

  if ($null -eq $Script:Config) { return $null }
  $prop = $Script:Config.PSObject.Properties[$SectionName]
  if ($prop) { return $prop.Value }
  return $null
}

function Get-ConfigValue {
  param(
    [Parameter(Mandatory)][string]$SectionName,
    [Parameter(Mandatory)][string]$Key,
    $DefaultValue = $null
  )

  $section = Get-ConfigSection -SectionName $SectionName
  if ($null -ne $section -and $section.PSObject.Properties[$Key]) {
    return $section.PSObject.Properties[$Key].Value
  }
  return $DefaultValue
}

function Get-NamesMap {
  $namesSection = Get-ConfigSection -SectionName 'Names'
  if ($namesSection) { return (ConvertTo-OrderedHashtable $namesSection) }

  return [ordered]@{
    SafeLinksPolicy        = 'Microsoft-Zero-Trust-SafeLinks-Policy'
    SafeLinksRule          = 'Microsoft-Zero-Trust-SafeLinks-Rule'
    SafeAttachmentsPolicy  = 'Microsoft-Zero-Trust-SafeAttachments'
    SafeAttachmentsRule    = 'Microsoft-Zero-Trust-SafeAttachments-Rule'
    AntiPhishPolicy        = 'Microsoft-Zero-Trust-AntiPhish'
    AntiPhishRule          = 'Microsoft-Zero-Trust-AntiPhish-Rule'
    AntiSpamInboundPolicy  = 'Microsoft-Zero-Trust-AntiSpam-Inbound'
    AntiSpamInboundRule    = 'Microsoft-Zero-Trust-AntiSpam-Inbound-Rule'
    AntiSpamOutboundPolicy = 'Microsoft-Zero-Trust-AntiSpam-Outbound'
    AntiSpamOutboundRule   = 'Microsoft-Zero-Trust-AntiSpam-Outbound-Rule'
    AntiMalwarePolicy      = 'Microsoft-Zero-Trust-AntiMalware'
    AntiMalwareRule        = 'Microsoft-Zero-Trust-AntiMalware-Rule'
  }
}

# NOTE: Some Exchange Online rules may default to Enabled on creation. Rules are explicitly set to Disabled during deployment.

function Ensure-SafeLinksPolicy {
  param([string]$Name)

  $settings = [ordered]@{
    EnableSafeLinksForEmail    = $true
    EnableSafeLinksForTeams    = $true
    EnableForInternalSenders   = $true
    ScanUrls                   = $true
    DeliverMessageAfterScan    = $true
    DisableUrlRewrite          = $false
    TrackClicks                = $true
    AllowClickThrough          = $false
    EnableOrganizationBranding = $false
  }

  $cfg = Get-ConfigSection -SectionName 'SafeLinks'
  if ($cfg) { $settings = ConvertTo-OrderedHashtable $cfg }

  $exists = Get-SafeLinksPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $exists) {
    Write-UiStatus "Safe Links policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    foreach ($kv in $settings.GetEnumerator()) {
      if (Supports-Param 'New-SafeLinksPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-SafeLinksPolicy @p
  }
  else {
    Write-UiStatus "Safe Links policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    foreach ($kv in $settings.GetEnumerator()) {
      if (Supports-Param 'Set-SafeLinksPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-SafeLinksPolicy @p
  }
}

function Ensure-SafeLinksRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$RecipientDomains)
  $rule = Get-SafeLinksRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Safe Links rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      SafeLinksPolicy = $PolicyName
      RecipientDomainIs = $RecipientDomains
    }
    if (Supports-Param 'New-SafeLinksRule' 'Enabled') { $params['Enabled'] = $false }
    New-SafeLinksRule @params
  }
  else {
    Write-UiStatus "Safe Links rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-SafeLinksRule' -Identity $RuleName
}

function Ensure-SafeAttachmentsPolicy {
  param([string]$Name)

  function Add-EnableParam([hashtable]$h,[bool]$on=$true,[string]$newCmd,[string]$setCmd) {
    if ($newCmd -and (Supports-Param $newCmd 'Enable'))      { $h['Enable']  = $on }
    elseif ($newCmd -and (Supports-Param $newCmd 'Enabled')) { $h['Enabled'] = $on }
    elseif ($setCmd -and (Supports-Param $setCmd 'Enable'))  { $h['Enable']  = $on }
    elseif ($setCmd -and (Supports-Param $setCmd 'Enabled')) { $h['Enabled'] = $on }
    return $h
  }

  $settings = [ordered]@{
    Action        = 'Block'
    QuarantineTag = 'AdminOnlyAccessPolicy'
    Redirect      = $false
  }

  $cfg = Get-ConfigSection -SectionName 'SafeAttachments'
  if ($cfg) { $settings = ConvertTo-OrderedHashtable $cfg }

  $existing = Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $existing) {
    Write-UiStatus "Safe Attachments policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    $p = Add-EnableParam $p $true 'New-SafeAttachmentPolicy' $null
    foreach ($kv in $settings.GetEnumerator()) {
      if (Supports-Param 'New-SafeAttachmentPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-SafeAttachmentPolicy @p
  }
  else {
    Write-UiStatus "Safe Attachments policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    $p = Add-EnableParam $p $true $null 'Set-SafeAttachmentPolicy'
    foreach ($kv in $settings.GetEnumerator()) {
      if (Supports-Param 'Set-SafeAttachmentPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-SafeAttachmentPolicy @p
  }
}

function Ensure-SafeAttachmentsRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$RecipientDomains)
  $rule = Get-SafeAttachmentRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Safe Attachments rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      SafeAttachmentPolicy = $PolicyName
      RecipientDomainIs = $RecipientDomains
    }
    if (Supports-Param 'New-SafeAttachmentRule' 'Enabled') { $params['Enabled'] = $false }
    New-SafeAttachmentRule @params
  }
  else {
    Write-UiStatus "Safe Attachments rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-SafeAttachmentRule' -Identity $RuleName
}

function Ensure-AntiPhishPolicy {
  param([string]$Name)

  $vals = [ordered]@{
    EnableMailboxIntelligence            = $true
    EnableMailboxIntelligenceProtection  = $true
    MailboxIntelligenceProtectionAction  = 'Quarantine'
    MailboxIntelligenceQuarantineTag     = 'AdminOnlyAccessPolicy'
    EnableOrganizationDomainsProtection  = $true
    EnableSpoofIntelligence              = $true
    EnableTargetedUserProtection         = $true
    TargetedUserProtectionAction         = 'Quarantine'
    TargetedUserQuarantineTag            = 'AdminOnlyAccessPolicy'
    EnableTargetedDomainsProtection      = $true
    TargetedDomainProtectionAction       = 'Quarantine'
    TargetedDomainQuarantineTag          = 'AdminOnlyAccessPolicy'
    EnableFirstContactSafetyTips         = $true
    EnableSimilarUsersSafetyTips         = $true
    EnableSimilarDomainsSafetyTips       = $true
    EnableUnusualCharactersSafetyTips    = $true
    EnableUnauthenticatedSender          = $true
    EnableViaTag                         = $true
    HonorDmarcPolicy                     = $true
    AuthenticationFailAction             = 'Quarantine'
    SpoofQuarantineTag                   = 'AdminOnlyAccessPolicy'
    PhishThresholdLevel                  = 3
  }

  $cfg = Get-ConfigSection -SectionName 'AntiPhish'
  if ($cfg) { $vals = ConvertTo-OrderedHashtable $cfg }

  $policy = Get-AntiPhishPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $policy) {
    Write-UiStatus "Anti-Phish policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'New-AntiPhishPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-AntiPhishPolicy @p
  }
  else {
    Write-UiStatus "Anti-Phish policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'Set-AntiPhishPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-AntiPhishPolicy @p
  }
}

function Ensure-AntiPhishRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$RecipientDomains)
  $rule = Get-AntiPhishRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Anti-Phish rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      AntiPhishPolicy = $PolicyName
      RecipientDomainIs = $RecipientDomains
    }
    if (Supports-Param 'New-AntiPhishRule' 'Enabled') { $params['Enabled'] = $false }
    New-AntiPhishRule @params
  }
  else {
    Write-UiStatus "Anti-Phish rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-AntiPhishRule' -Identity $RuleName
}

function Ensure-AntiSpamInboundPolicy {
  param([string]$Name)

  $vals = [ordered]@{
    BulkThreshold                        = 5
    SpamAction                           = 'Quarantine'
    SpamQuarantineTag                    = 'DefaultFullAccesswithNotificationPolicy'
    HighConfidenceSpamAction             = 'Quarantine'
    HighConfidenceSpamQuarantineTag      = 'DefaultFullAccesswithNotificationPolicy'
    BulkSpamAction                       = 'Quarantine'
    BulkQuarantineTag                    = 'DefaultFullAccesswithNotificationPolicy'
    PhishSpamAction                      = 'Quarantine'
    PhishQuarantineTag                   = 'AdminOnlyAccessPolicy'
    HighConfidencePhishAction            = 'Quarantine'
    HighConfidencePhishQuarantineTag     = 'AdminOnlyAccessPolicy'
    InlineSafetyTipsEnabled              = $true
    SpamZapEnabled                       = $true
    PhishZapEnabled                      = $true
    IncreaseScoreWithImageLinks          = 'On'
    IncreaseScoreWithNumericIps          = 'On'
    IncreaseScoreWithRedirectToOtherPort = 'On'
    IncreaseScoreWithBizOrInfoUrls       = 'On'
    MarkAsSpamEmptyMessages              = 'On'
    MarkAsSpamEmbedTagsInHtml            = 'On'
    MarkAsSpamJavaScriptInHtml           = 'On'
    MarkAsSpamFormTagsInHtml             = 'On'
    MarkAsSpamFramesInHtml               = 'On'
    MarkAsSpamWebBugsInHtml              = 'On'
    MarkAsSpamObjectTagsInHtml           = 'On'
    MarkAsSpamSensitiveWordList          = 'Off'
    MarkAsSpamSpfRecordHardFail          = 'On'
    MarkAsSpamFromAddressAuthFail        = 'On'
    MarkAsSpamNdrBackscatter             = 'On'
  }

  $cfg = Get-ConfigSection -SectionName 'AntiSpamInbound'
  if ($cfg) { $vals = ConvertTo-OrderedHashtable $cfg }

  $policy = Get-HostedContentFilterPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $policy) {
    Write-UiStatus "Inbound Anti-Spam policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'New-HostedContentFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-HostedContentFilterPolicy @p
  }
  else {
    Write-UiStatus "Inbound Anti-Spam policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'Set-HostedContentFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-HostedContentFilterPolicy @p
  }
}

function Ensure-AntiSpamInboundRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$RecipientDomains)
  $rule = Get-HostedContentFilterRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Inbound Anti-Spam rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      HostedContentFilterPolicy = $PolicyName
      RecipientDomainIs = $RecipientDomains
    }
    if (Supports-Param 'New-HostedContentFilterRule' 'Enabled') { $params['Enabled'] = $false }
    New-HostedContentFilterRule @params
  }
  else {
    Write-UiStatus "Inbound Anti-Spam rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-HostedContentFilterRule' -Identity $RuleName
}

function Ensure-AntiSpamOutboundPolicy {
  param([string]$Name,[string]$NotifyAddress)

  $vals = [ordered]@{
    RecipientLimitExternalPerHour = 400
    RecipientLimitInternalPerHour = 800
    RecipientLimitPerDay          = 800
    ActionWhenThresholdReached    = 'BlockUser'
    AutoForwardingMode            = 'Off'
    BccSuspiciousOutboundMail     = $false
    NotifyOutboundSpam            = $true
    NotifyOutboundSpamRecipients  = $NotifyAddress
  }

  $cfg = Get-ConfigSection -SectionName 'AntiSpamOutbound'
  if ($cfg) {
    $vals = ConvertTo-OrderedHashtable $cfg
    if (-not $vals.Contains('NotifyOutboundSpamRecipients')) {
      $vals['NotifyOutboundSpamRecipients'] = $NotifyAddress
    }
  }

  $policy = Get-HostedOutboundSpamFilterPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $policy) {
    Write-UiStatus "Outbound Anti-Spam policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'New-HostedOutboundSpamFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-HostedOutboundSpamFilterPolicy @p
  }
  else {
    Write-UiStatus "Outbound Anti-Spam policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'Set-HostedOutboundSpamFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-HostedOutboundSpamFilterPolicy @p
  }
}

function Ensure-AntiSpamOutboundRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$SenderDomains)
  $rule = Get-HostedOutboundSpamFilterRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Outbound Anti-Spam rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      HostedOutboundSpamFilterPolicy = $PolicyName
      SenderDomainIs = $SenderDomains
    }
    if (Supports-Param 'New-HostedOutboundSpamFilterRule' 'Enabled') { $params['Enabled'] = $false }
    New-HostedOutboundSpamFilterRule @params
  }
  else {
    Write-UiStatus "Outbound Anti-Spam rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-HostedOutboundSpamFilterRule' -Identity $RuleName -DisableCmdletName 'Disable-HostedOutboundSpamFilterRule'
}

function Ensure-AntiMalwarePolicy {
  param([string]$Name,[string]$AdminNotify)

  $vals = [ordered]@{
    EnableInternalSenderAdminNotifications = $true
    InternalSenderAdminAddress             = $AdminNotify
    Action                                 = 'DeleteMessage'
    EnableZeroHourAutoPurge                = $true
  }

  $cfg = Get-ConfigSection -SectionName 'AntiMalware'
  if ($cfg) {
    $vals = ConvertTo-OrderedHashtable $cfg
    if (-not $vals.Contains('InternalSenderAdminAddress')) {
      $vals['InternalSenderAdminAddress'] = $AdminNotify
    }
  }

  $policy = Get-MalwareFilterPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $Name
  if (-not $policy) {
    Write-UiStatus "Anti-Malware policy '$Name' does not exist. Creating it..." 'Cyan'
    $p = @{ Name = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'New-MalwareFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    New-MalwareFilterPolicy @p
  }
  else {
    Write-UiStatus "Anti-Malware policy '$Name' already exists. Updating settings..." 'Yellow'
    $p = @{ Identity = $Name }
    foreach ($kv in $vals.GetEnumerator()) {
      if (Supports-Param 'Set-MalwareFilterPolicy' $kv.Key) { $p[$kv.Key] = $kv.Value }
    }
    Set-MalwareFilterPolicy @p
  }
}

function Ensure-AntiMalwareRuleGlobal {
  param([string]$RuleName,[string]$PolicyName,[string[]]$RecipientDomains)
  $rule = Get-MalwareFilterRule -ErrorAction SilentlyContinue | Where-Object Name -eq $RuleName
  if (-not $rule) {
    Write-UiStatus "Anti-Malware rule '$RuleName' does not exist. Creating it disabled..." 'Cyan'
    $params = @{
      Name = $RuleName
      MalwareFilterPolicy = $PolicyName
      RecipientDomainIs = $RecipientDomains
    }
    if (Supports-Param 'New-MalwareFilterRule' 'Enabled') { $params['Enabled'] = $false }
    New-MalwareFilterRule @params
  }
  else {
    Write-UiStatus "Anti-Malware rule '$RuleName' already exists. Keeping it disabled..." 'Yellow'
  }
  Disable-RuleOnly -SetCmdletName 'Set-MalwareFilterRule' -Identity $RuleName -DisableCmdletName 'Disable-MalwareFilterRule'
}

function Export-PoliciesJson {
  param([string]$Path)

  $items = @()
  $items += Get-SafeLinksPolicy -ErrorAction SilentlyContinue
  $items += Get-SafeLinksRule -ErrorAction SilentlyContinue
  $items += Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue
  $items += Get-SafeAttachmentRule -ErrorAction SilentlyContinue
  $items += Get-AntiPhishPolicy -ErrorAction SilentlyContinue
  $items += Get-AntiPhishRule -ErrorAction SilentlyContinue
  $items += Get-HostedContentFilterPolicy -ErrorAction SilentlyContinue
  $items += Get-HostedContentFilterRule -ErrorAction SilentlyContinue
  $items += Get-HostedOutboundSpamFilterPolicy -ErrorAction SilentlyContinue
  $items += Get-HostedOutboundSpamFilterRule -ErrorAction SilentlyContinue
  $items += Get-MalwareFilterPolicy -ErrorAction SilentlyContinue
  $items += Get-MalwareFilterRule -ErrorAction SilentlyContinue

  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }

  $i = 0
  foreach ($obj in $items) {
    $i++
    $name = ($obj.Name | ForEach-Object { $_ }) -join '_'
    if (-not $name) { $name = "item$i" }
    $file = Join-Path $Path ("{0}_{1}.json" -f $obj.GetType().Name, ($name -replace '[^\w\-]','_'))
    $obj | ConvertTo-Json -Depth 10 | Out-File -FilePath $file -Encoding UTF8
  }
}

function Run-Validation {
  param([hashtable]$NamesMap)

  Write-UiStatus "Running validation..." 'Cyan'

  $checks = @(
    @{ Name='Anti-Phish';         RuleCmd='Get-AntiPhishRule';                RuleName=$NamesMap.AntiPhishRule },
    @{ Name='Safe Links';         RuleCmd='Get-SafeLinksRule';                RuleName=$NamesMap.SafeLinksRule },
    @{ Name='Safe Attachments';   RuleCmd='Get-SafeAttachmentRule';           RuleName=$NamesMap.SafeAttachmentsRule },
    @{ Name='Inbound Anti-Spam';  RuleCmd='Get-HostedContentFilterRule';      RuleName=$NamesMap.AntiSpamInboundRule },
    @{ Name='Outbound Anti-Spam'; RuleCmd='Get-HostedOutboundSpamFilterRule'; RuleName=$NamesMap.AntiSpamOutboundRule },
    @{ Name='Anti-Malware';       RuleCmd='Get-MalwareFilterRule';            RuleName=$NamesMap.AntiMalwareRule }
  )

  foreach ($c in $checks) {
    if (-not (Get-Command $c.RuleCmd -ErrorAction SilentlyContinue)) {
      Write-UiStatus "[WARN] Validation skipped for $($c.Name): cmdlet '$($c.RuleCmd)' is not available." 'Yellow'
      continue
    }

    try {
      $rule = & $c.RuleCmd -ErrorAction SilentlyContinue | Where-Object Name -eq $c.RuleName | Select-Object -First 1
      if (-not $rule) {
        Write-UiStatus "[FAIL] $($c.Name) rule '$($c.RuleName)' not found." 'Red'
        continue
      }

      $disabled = $false
      if ($rule.PSObject.Properties.Name -contains 'Enabled') { $disabled = ($rule.Enabled -eq $false) }
      elseif ($rule.PSObject.Properties.Name -contains 'State') { $disabled = ($rule.State -eq 'Disabled') }

      if ($disabled) {
        Write-UiStatus "[PASS] $($c.Name) rule '$($c.RuleName)' is disabled." 'Green'
      }
      else {
        Write-UiStatus "[FAIL] $($c.Name) rule '$($c.RuleName)' is enabled." 'Red'
      }
    }
    catch {
      Write-UiStatus "[ERR] Validation failed for $($c.Name): $($_.Exception.Message)" 'Red'
    }
  }

  Write-UiStatus "[OK] Validation complete." 'Green'
}


function Export-PoliciesHtml {
  param([Parameter(Mandatory)][string]$Path)

  function Convert-ObjectToRows {
    param([object]$InputObject)

    if ($null -eq $InputObject) {
      return '<tr><td colspan="2">No data</td></tr>'
    }

    $rows = foreach ($prop in $InputObject.PSObject.Properties) {
      $value = $prop.Value
      if ($value -is [System.Array]) {
        $value = ($value | ForEach-Object { [string]$_ }) -join ', '
      }
      elseif ($value -is [datetime]) {
        $value = $value.ToString("u")
      }
      elseif ($null -eq $value) {
        $value = ''
      }
      "<tr><th>$($prop.Name)</th><td>$([System.Web.HttpUtility]::HtmlEncode([string]$value))</td></tr>"
    }
    return ($rows -join "`r`n")
  }

  Add-Type -AssemblyName System.Web

  $sections = @(
    @{ Title = 'Safe Links Policies';              Data = @(Get-SafeLinksPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Safe Links Rules';                 Data = @(Get-SafeLinksRule -ErrorAction SilentlyContinue) },
    @{ Title = 'Safe Attachments Policies';        Data = @(Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Safe Attachments Rules';           Data = @(Get-SafeAttachmentRule -ErrorAction SilentlyContinue) },
    @{ Title = 'Anti-Phish Policies';              Data = @(Get-AntiPhishPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Anti-Phish Rules';                 Data = @(Get-AntiPhishRule -ErrorAction SilentlyContinue) },
    @{ Title = 'Inbound Anti-Spam Policies';       Data = @(Get-HostedContentFilterPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Inbound Anti-Spam Rules';          Data = @(Get-HostedContentFilterRule -ErrorAction SilentlyContinue) },
    @{ Title = 'Outbound Anti-Spam Policies';      Data = @(Get-HostedOutboundSpamFilterPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Outbound Anti-Spam Rules';         Data = @(Get-HostedOutboundSpamFilterRule -ErrorAction SilentlyContinue) },
    @{ Title = 'Anti-Malware Policies';            Data = @(Get-MalwareFilterPolicy -ErrorAction SilentlyContinue) },
    @{ Title = 'Anti-Malware Rules';               Data = @(Get-MalwareFilterRule -ErrorAction SilentlyContinue) }
  )

  $generated = (Get-Date).ToString("u")
  $tenant = Get-TenantDisplayName
  $user = Get-ConnectedUserPrincipalName

  $body = New-Object System.Text.StringBuilder
  [void]$body.AppendLine("<html><head><meta charset='utf-8' /><title>DFO365 HTML Report</title>")
  [void]$body.AppendLine("<style>")
  [void]$body.AppendLine("body{font-family:Segoe UI,Arial,sans-serif;background:#1b1f26;color:#f0f0f0;margin:24px;}")
  [void]$body.AppendLine("h1,h2{color:#ffffff;} .meta{color:#c0c0c0;margin-bottom:24px;} .card{background:#20252d;border:1px solid #4a4f57;padding:16px;margin-bottom:18px;} table{width:100%;border-collapse:collapse;margin-top:10px;} th,td{border:1px solid #4a4f57;padding:8px;text-align:left;vertical-align:top;} th{background:#2a3038;width:28%;} .itemtitle{font-size:16px;font-weight:600;margin-bottom:8px;color:#9ecbff;}")
  [void]$body.AppendLine("</style></head><body>")
  [void]$body.AppendLine("<h1>DFO365 Deployment Tool - HTML Report</h1>")
  [void]$body.AppendLine("<div class='meta'>Generated: $generated<br/>Tenant: $([System.Web.HttpUtility]::HtmlEncode([string]$tenant))<br/>Account: $([System.Web.HttpUtility]::HtmlEncode([string]$user))</div>")

  foreach ($section in $sections) {
    [void]$body.AppendLine("<div class='card'><h2>$($section.Title)</h2>")
    if (-not $section.Data -or $section.Data.Count -eq 0) {
      [void]$body.AppendLine("<div>No objects found.</div></div>")
      continue
    }

    foreach ($item in $section.Data) {
      $name = ''
      try { $name = [string]$item.Name } catch {}
      if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Unnamed object' }
      [void]$body.AppendLine("<div class='itemtitle'>$([System.Web.HttpUtility]::HtmlEncode($name))</div>")
      [void]$body.AppendLine("<table>")
      [void]$body.AppendLine((Convert-ObjectToRows -InputObject $item))
      [void]$body.AppendLine("</table><br/>")
    }
    [void]$body.AppendLine("</div>")
  }

  [void]$body.AppendLine("</body></html>")

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $body.ToString(), [System.Text.Encoding]::UTF8)
}


function Set-RuleDesiredState {
  param(
    [Parameter(Mandatory)][string]$SetCmdletName,
    [Parameter(Mandatory)][string]$Identity,
    [string]$EnableCmdletName = '',
    [string]$DisableCmdletName = '',
    [bool]$Enabled = $false
  )

  if ($Enabled) {
    if ($EnableCmdletName -and (Get-Command $EnableCmdletName -ErrorAction SilentlyContinue)) {
      & $EnableCmdletName -Identity $Identity -Confirm:$false
      return
    }
    Set-RuleEnabled -CmdletName $SetCmdletName -BaseParams @{ Identity = $Identity } -Enabled:$true
    return
  }

  if ($DisableCmdletName -and (Get-Command $DisableCmdletName -ErrorAction SilentlyContinue)) {
    & $DisableCmdletName -Identity $Identity -Confirm:$false
    return
  }

  Set-RuleEnabled -CmdletName $SetCmdletName -BaseParams @{ Identity = $Identity } -Enabled:$false
}

function Apply-DesiredRuleState {
  param(
    [Parameter(Mandatory)][hashtable]$NamesMap,
    [bool]$EnableRules = $false
  )

  $rules = @(
    @{ Name = $NamesMap.SafeLinksRule;          Set = 'Set-SafeLinksRule';                 Enable = '';                            Disable = '' },
    @{ Name = $NamesMap.SafeAttachmentsRule;    Set = 'Set-SafeAttachmentRule';            Enable = 'Enable-SafeAttachmentRule';   Disable = 'Disable-SafeAttachmentRule' },
    @{ Name = $NamesMap.AntiPhishRule;          Set = 'Set-AntiPhishRule';                 Enable = '';                            Disable = '' },
    @{ Name = $NamesMap.AntiSpamInboundRule;    Set = 'Set-HostedContentFilterRule';       Enable = '';                            Disable = 'Disable-HostedContentFilterRule' },
    @{ Name = $NamesMap.AntiSpamOutboundRule;   Set = 'Set-HostedOutboundSpamFilterRule';  Enable = 'Enable-HostedOutboundSpamFilterRule'; Disable = 'Disable-HostedOutboundSpamFilterRule' },
    @{ Name = $NamesMap.AntiMalwareRule;        Set = 'Set-MalwareFilterRule';             Enable = 'Enable-MalwareFilterRule';    Disable = 'Disable-MalwareFilterRule' }
  )

  foreach ($rule in $rules) {
    try {
      if (Get-Command $rule.Set -ErrorAction SilentlyContinue) {
        Set-RuleDesiredState -SetCmdletName $rule.Set -Identity $rule.Name -EnableCmdletName $rule.Enable -DisableCmdletName $rule.Disable -Enabled:$EnableRules
      }
    }
    catch {
      Log "[WARN] Could not set final state for rule '$($rule.Name)': $($_.Exception.Message)"
    }
  }
}

function Get-PolicyStatusSnapshot {
    param(
        [Parameter(Mandatory)]$NamesMap,
        [switch]$ForceRefresh
    )

    if (-not $ForceRefresh -and $Script:TenantStatusCache -and (Test-ShadowCacheFresh -Timestamp $Script:TenantStatusCacheTime -Seconds $Script:TenantStatusCacheSeconds)) {
        return $Script:TenantStatusCache
    }

    $snapshot = @{}

    function Get-ShadowPolicyObjectFast {
        param(
            [string]$CommandName,
            [string]$Identity
        )

        try {
            if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) { return $null }

            try {
                return (& $CommandName -Identity $Identity -ErrorAction Stop)
            }
            catch {
                # Fallback for cmdlets/tenants that behave differently with Identity.
                try {
                    return (& $CommandName -ErrorAction Stop | Where-Object { $_.Name -eq $Identity } | Select-Object -First 1)
                }
                catch {
                    return $null
                }
            }
        }
        catch {
            return $null
        }
    }

    function Get-ShadowStatusEntry {
        param(
            [string]$PolicyCommand,
            [string]$RuleCommand,
            [string]$PolicyName,
            [string]$RuleName
        )

        $policy = Get-ShadowPolicyObjectFast -CommandName $PolicyCommand -Identity $PolicyName
        $rule = Get-ShadowPolicyObjectFast -CommandName $RuleCommand -Identity $RuleName

        $status = "Missing"
        if ($policy -and $rule) {
            $status = "Ready"
            if ($null -ne $rule.State -and [string]$rule.State -eq "Enabled") { $status = "Enabled" }
            elseif ($null -ne $rule.Enabled -and [bool]$rule.Enabled) { $status = "Enabled" }
        }
        elseif ($policy -and -not $rule) {
            $status = "Policy Only"
        }

        return [pscustomobject]@{
            PolicyExists = [bool]$policy
            RuleExists   = [bool]$rule
            Status       = $status
        }
    }

    $snapshot["Anti-Phish"] = Get-ShadowStatusEntry -PolicyCommand "Get-AntiPhishPolicy" -RuleCommand "Get-AntiPhishRule" -PolicyName $NamesMap.AntiPhishPolicy -RuleName $NamesMap.AntiPhishRule
    $snapshot["Safe Attachments"] = Get-ShadowStatusEntry -PolicyCommand "Get-SafeAttachmentPolicy" -RuleCommand "Get-SafeAttachmentRule" -PolicyName $NamesMap.SafeAttachmentsPolicy -RuleName $NamesMap.SafeAttachmentsRule
    $snapshot["Safe Links"] = Get-ShadowStatusEntry -PolicyCommand "Get-SafeLinksPolicy" -RuleCommand "Get-SafeLinksRule" -PolicyName $NamesMap.SafeLinksPolicy -RuleName $NamesMap.SafeLinksRule
    $snapshot["Inbound Spam"] = Get-ShadowStatusEntry -PolicyCommand "Get-HostedContentFilterPolicy" -RuleCommand "Get-HostedContentFilterRule" -PolicyName $NamesMap.AntiSpamInboundPolicy -RuleName $NamesMap.AntiSpamInboundRule
    $snapshot["Outbound Spam"] = Get-ShadowStatusEntry -PolicyCommand "Get-HostedOutboundSpamFilterPolicy" -RuleCommand "Get-HostedOutboundSpamFilterRule" -PolicyName $NamesMap.AntiSpamOutboundPolicy -RuleName $NamesMap.AntiSpamOutboundRule
    $snapshot["Anti-Malware"] = Get-ShadowStatusEntry -PolicyCommand "Get-MalwareFilterPolicy" -RuleCommand "Get-MalwareFilterRule" -PolicyName $NamesMap.AntiMalwarePolicy -RuleName $NamesMap.AntiMalwareRule

    $Script:TenantStatusCache = $snapshot
    $Script:TenantStatusCacheTime = Get-Date
    return $snapshot
}

function Update-PolicyIndicators {
  param(
    [hashtable]$NamesMap,
    [hashtable]$IndicatorLabels
  )

  $snapshot = Get-PolicyStatusSnapshot -NamesMap $NamesMap
  foreach ($key in $IndicatorLabels.Keys) {
    $label = $IndicatorLabels[$key]
    if (-not $snapshot.ContainsKey($key)) { continue }
    $item = $snapshot[$key]
    $label.Text = $item.Status

    switch ($item.Status) {
      'Enabled'    { $label.ForeColor = [System.Drawing.Color]::FromArgb(100,181,246) }
      'Ready'      { $label.ForeColor = [System.Drawing.Color]::FromArgb(129,199,132) }
      'Exists'     { $label.ForeColor = [System.Drawing.Color]::FromArgb(255,241,118) }
      'Policy Only'{ $label.ForeColor = [System.Drawing.Color]::FromArgb(255,183,77) }
      default      { $label.ForeColor = [System.Drawing.Color]::FromArgb(239,83,80) }
    }
  }
}

function Invoke-TestMode {
  param(
    [hashtable]$NamesMap,
    [System.Windows.Forms.Label]$ConfigLabel,
    [hashtable]$IndicatorLabels
  )

  if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
  if (-not (Ensure-ConfigLoaded -ConfigLabel $ConfigLabel)) { return }

  Log "[INFO] Running test mode preview..."
  $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
  $dom = Get-AllAcceptedDomains

  if (-not $dom -or $dom.Count -eq 0) {
    Log "[WARN] No accepted domains were returned."
  } else {
    Log "[INFO] Accepted domains: $($dom -join ', ')"
  }

  $checks = @(
    @{ Name='Safe Links';       Policy=$NamesMap.SafeLinksPolicy;       Rule=$NamesMap.SafeLinksRule },
    @{ Name='Safe Attachments'; Policy=$NamesMap.SafeAttachmentsPolicy; Rule=$NamesMap.SafeAttachmentsRule },
    @{ Name='Anti-Phish';       Policy=$NamesMap.AntiPhishPolicy;       Rule=$NamesMap.AntiPhishRule },
    @{ Name='Inbound Spam';     Policy=$NamesMap.AntiSpamInboundPolicy; Rule=$NamesMap.AntiSpamInboundRule },
    @{ Name='Outbound Spam';    Policy=$NamesMap.AntiSpamOutboundPolicy; Rule=$NamesMap.AntiSpamOutboundRule },
    @{ Name='Anti-Malware';     Policy=$NamesMap.AntiMalwarePolicy;     Rule=$NamesMap.AntiMalwareRule }
  )

  $snapshot = Get-PolicyStatusSnapshot -NamesMap $NamesMap
  foreach ($check in $checks) {
    $state = $snapshot[$check.Name]
    if ($null -eq $state) {
      Log "[INFO] $($check.Name): unable to determine current state."
      continue
    }

    if (-not $state.PolicyExists -and -not $state.RuleExists) {
      Log "[TEST] $($check.Name): would create policy '$($check.Policy)' and rule '$($check.Rule)'."
    } elseif ($state.PolicyExists -and -not $state.RuleExists) {
      Log "[TEST] $($check.Name): would update policy '$($check.Policy)' and create rule '$($check.Rule)'."
    } else {
      $targetState = $(if ($Script:EnableRulesOnDeploy) { 'enabled' } else { 'disabled' })
      Log "[TEST] $($check.Name): would update existing policy/rule and leave rule $targetState."
    }
  }

  Log "[INFO] Admin notification address: $AdminNotify"
  Update-PolicyIndicators -NamesMap $NamesMap -IndicatorLabels $IndicatorLabels
  Log "[OK] Test mode preview complete."
}


# -------------------- GUI --------------------
# Shadow Deploy for Defender for Office 365 - Shadow Suite Interface
# UI shell/branding/layout updated to mirror Shadow Deploy MDE style.
# Backend deployment, EXO authentication, config, export, report, status, and rule logic above are preserved.
# Logo expected near the script as: shadowdeployo365.png

# =============================
# Shadow Suite Theme
# =============================

$ShadowTheme = [ordered]@{
    Back        = [System.Drawing.Color]::FromArgb(5, 7, 12)
    Surface     = [System.Drawing.Color]::FromArgb(10, 14, 23)
    SurfaceAlt  = [System.Drawing.Color]::FromArgb(16, 21, 32)
    SurfaceSoft = [System.Drawing.Color]::FromArgb(24, 30, 44)
    Border      = [System.Drawing.Color]::FromArgb(68, 74, 88)
    Purple      = [System.Drawing.Color]::FromArgb(130, 45, 230)
    PurpleSoft  = [System.Drawing.Color]::FromArgb(78, 18, 150)
    Text        = [System.Drawing.Color]::FromArgb(245, 247, 250)
    Muted       = [System.Drawing.Color]::FromArgb(190, 195, 205)
    Blue        = [System.Drawing.Color]::FromArgb(24, 48, 86)
    BlueBright  = [System.Drawing.Color]::FromArgb(66, 165, 245)
    Green       = [System.Drawing.Color]::FromArgb(16, 128, 64)
    GreenBright = [System.Drawing.Color]::FromArgb(67, 160, 71)
    Orange      = [System.Drawing.Color]::FromArgb(198, 76, 0)
    Red         = [System.Drawing.Color]::FromArgb(185, 28, 28)
    Console     = [System.Drawing.Color]::FromArgb(1, 3, 7)
}

function New-ShadowFont {
    param(
        [float]$Size = 9,
        [string]$Weight = "Regular"
    )
    $style = [System.Drawing.FontStyle]::Regular
    if ($Weight -eq "Bold") { $style = [System.Drawing.FontStyle]::Bold }
    return New-Object System.Drawing.Font("Segoe UI", $Size, $style)
}

function New-ShadowLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H = 22,
        [float]$Size = 9,
        [switch]$Bold,
        [switch]$Muted,
        [System.Drawing.Color]$BackColor = $ShadowTheme.Back
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.Font = New-ShadowFont -Size $Size -Weight $(if ($Bold) { "Bold" } else { "Regular" })
    $label.ForeColor = $(if ($Muted) { $ShadowTheme.Muted } else { $ShadowTheme.Text })
    $label.BackColor = $BackColor
    return $label
}

function New-ShadowPanel {
    param(
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [string]$Title = "",
        [string]$Icon = ""
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, $H)
    $panel.BackColor = $ShadowTheme.Surface
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = if ($Icon) { "$Icon  $Title" } else { $Title }
        $label.Location = New-Object System.Drawing.Point(16, 14)
        $label.Size = New-Object System.Drawing.Size(($W - 32), 26)
        $label.Font = New-ShadowFont -Size 11 -Weight Bold
        $label.ForeColor = $ShadowTheme.Text
        $label.BackColor = $ShadowTheme.Surface
        $panel.Controls.Add($label)
    }

    return $panel
}

function New-ShadowButton {
    param(
        [string]$Text,
        [int]$W = 126,
        [int]$H = 36,
        [ValidateSet("Primary","Secondary","Success","Warning","Danger","Blue")]
        [string]$Style = "Secondary"
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.Font = New-ShadowFont -Size 8.5 -Weight Bold
    $button.ForeColor = $ShadowTheme.Text
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $ShadowTheme.Border
    $button.UseVisualStyleBackColor = $false

    switch ($Style) {
        "Primary"   { $button.BackColor = $ShadowTheme.Purple }
        "Success"   { $button.BackColor = $ShadowTheme.Green }
        "Warning"   { $button.BackColor = $ShadowTheme.Orange }
        "Danger"    { $button.BackColor = $ShadowTheme.Red }
        "Blue"      { $button.BackColor = $ShadowTheme.Blue }
        default     { $button.BackColor = $ShadowTheme.SurfaceSoft }
    }

    return $button
}

function New-ShadowStatusPill {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [ValidateSet("Neutral","Good","Warning","Bad","Blue")]
        [string]$State = "Neutral"
    )

    $pill = New-Object System.Windows.Forms.Label
    $pill.Text = "  $Text"
    $pill.Location = New-Object System.Drawing.Point($X, $Y)
    $pill.Size = New-Object System.Drawing.Size($W, 34)
    $pill.Font = New-ShadowFont -Size 9 -Weight Bold
    $pill.ForeColor = $ShadowTheme.Text
    $pill.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $pill.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    switch ($State) {
        "Good"    { $pill.BackColor = $ShadowTheme.Green }
        "Warning" { $pill.BackColor = [System.Drawing.Color]::FromArgb(132, 44, 8) }
        "Bad"     { $pill.BackColor = $ShadowTheme.Red }
        "Blue"    { $pill.BackColor = $ShadowTheme.Blue }
        default   { $pill.BackColor = $ShadowTheme.SurfaceSoft }
    }

    return $pill
}

function Add-RecursiveClickHandler {
    param(
        [System.Windows.Forms.Control]$Control,
        [Parameter(Mandatory)][scriptblock]$Handler
    )

    if ($null -eq $Control) { return }

    $Control.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Control.Add_Click($Handler)

    foreach ($child in $Control.Controls) {
        Add-RecursiveClickHandler -Control $child -Handler $Handler
    }
}

function Set-ShadowGridStyle {
    param([System.Windows.Forms.DataGridView]$Grid)

    $Grid.BackgroundColor = $ShadowTheme.Surface
    $Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $Grid.GridColor = [System.Drawing.Color]::FromArgb(36, 43, 59)
    $Grid.DefaultCellStyle.BackColor = $ShadowTheme.SurfaceAlt
    $Grid.DefaultCellStyle.ForeColor = $ShadowTheme.Text
    $Grid.DefaultCellStyle.SelectionBackColor = $ShadowTheme.PurpleSoft
    $Grid.DefaultCellStyle.SelectionForeColor = $ShadowTheme.Text
    $Grid.DefaultCellStyle.Font = New-ShadowFont -Size 9
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(8, 10, 16)
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = $ShadowTheme.Text
    $Grid.ColumnHeadersDefaultCellStyle.Font = New-ShadowFont -Size 9 -Weight Bold
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.RowHeadersVisible = $false
    $Grid.AllowUserToAddRows = $false
    $Grid.SelectionMode = "FullRowSelect"
    $Grid.MultiSelect = $false
    $Grid.AutoSizeColumnsMode = "Fill"
}

function New-ShadowActionItem {
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Parent,
        [string]$ButtonText,
        [string]$Description,
        [ValidateSet("Primary","Secondary","Success","Warning","Danger","Blue")]
        [string]$Style = "Secondary"
    )

    $container = New-Object System.Windows.Forms.Panel
    $container.Size = New-Object System.Drawing.Size(138, 94)
    $container.BackColor = $ShadowTheme.Surface
    $container.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)

    $button = New-ShadowButton -Text $ButtonText -W 126 -H 36 -Style $Style
    $button.Location = New-Object System.Drawing.Point(6, 0)
    $container.Controls.Add($button)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $Description
    $desc.Location = New-Object System.Drawing.Point(0, 44)
    $desc.Size = New-Object System.Drawing.Size(138, 46)
    $desc.TextAlign = [System.Drawing.ContentAlignment]::TopCenter
    $desc.Font = New-ShadowFont -Size 6.5
    $desc.ForeColor = $ShadowTheme.Muted
    $desc.BackColor = $ShadowTheme.Surface
    $container.Controls.Add($desc)

    $Parent.Controls.Add($container)
    return $button
}

function ConvertTo-ShadowStatusClass {
    param([string]$Status)
    switch ($Status) {
        "Completed"    { return "Good" }
        "Ready"        { return "Blue" }
        "Running"      { return "Warning" }
        "Warning"      { return "Warning" }
        "Needs Review" { return "Warning" }
        "Failed"       { return "Bad" }
        default        { return "Neutral" }
    }
}

function Set-ShadowModuleStatus {
    param(
        [string]$Status,
        [string]$Detail = ""
    )

    if ($script:ModulePill) {
        $script:ModulePill.Text = "  DFO365: $Status"
        switch (ConvertTo-ShadowStatusClass -Status $Status) {
            "Good"    { $script:ModulePill.BackColor = $ShadowTheme.Green }
            "Blue"    { $script:ModulePill.BackColor = $ShadowTheme.Blue }
            "Warning" { $script:ModulePill.BackColor = [System.Drawing.Color]::FromArgb(132, 44, 8) }
            "Bad"     { $script:ModulePill.BackColor = $ShadowTheme.Red }
            default   { $script:ModulePill.BackColor = $ShadowTheme.SurfaceSoft }
        }
    }

    if ($lblLastAction -and $Detail) {
        $lblLastAction.Text = "Last action: $Detail"
    }
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Details
    )

    $row = $gridResults.Rows.Add($Name,$Status,$Details)
    switch ($Status) {
        "Success"   { $gridResults.Rows[$row].DefaultCellStyle.BackColor = $ShadowTheme.Green }
        "Completed" { $gridResults.Rows[$row].DefaultCellStyle.BackColor = $ShadowTheme.Green }
        "Ready"     { $gridResults.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30,64,175) }
        "Warning"   { $gridResults.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(113,63,18) }
        "Skipped"   { $gridResults.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(113,63,18) }
        "Failed"    { $gridResults.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(127,29,29) }
        default      { $gridResults.Rows[$row].DefaultCellStyle.BackColor = $ShadowTheme.SurfaceAlt }
    }
    $gridResults.Rows[$row].DefaultCellStyle.ForeColor = $ShadowTheme.Text
}

function Add-Log {
    param([string]$Message)

    if ($txtLog) {
        $txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:LogsDirectory)) {
            New-Item -ItemType Directory -Path $Script:LogsDirectory -Force | Out-Null
        }
        $logPath = Join-Path $Script:LogsDirectory "shadowdeploy-dfo365.log"
        Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    } catch {}
}

function Log($msg) {
    Add-Log -Message $msg
}

function Set-ShadowSessionIdentity {
    try {
        if (Test-ExchangeOnlineConnection) {
            $who = Get-ConnectedUserPrincipalName
            $tenant = Get-TenantDisplayName
            if ($lblSignedIn) { $lblSignedIn.Text = "Signed in: $who" }
            if ($lblTenant) { $lblTenant.Text = "Tenant: $tenant" }
            if ($exoPill) {
                $exoPill.Text = "  EXO: CONNECTED"
                $exoPill.BackColor = $ShadowTheme.Green
            }
            if ($lblConnection) {
                $lblConnection.Text = "Session: Connected to $tenant as $who"
                $lblConnection.ForeColor = $ShadowTheme.Text
            }
        }
        else {
            if ($lblSignedIn) { $lblSignedIn.Text = "Signed in: Not connected" }
            if ($lblTenant) { $lblTenant.Text = "Tenant: Not connected" }
            if ($exoPill) {
                $exoPill.Text = "  EXO: NOT CONNECTED"
                $exoPill.BackColor = [System.Drawing.Color]::FromArgb(132, 44, 8)
            }
            if ($lblConnection) {
                $lblConnection.Text = "Session: Not Connected"
                $lblConnection.ForeColor = $ShadowTheme.Muted
            }
        }
    } catch {}
}


function Update-ShadowCatalogCardStatus {
    try {
        $items = Get-ShadowDeployDfoCategoryCatalog
        foreach ($item in $items) {
            if (-not $script:CardStatusLabels.ContainsKey($item.Key)) { continue }
            $label = $script:CardStatusLabels[$item.Key]
            if (-not $item.Exists) {
                $label.Text = "＋ Add to Catalog"
                $label.ForeColor = [System.Drawing.Color]::FromArgb(255,221,51)
            }
        }
    }
    catch {
        Add-Log "[WARN] Catalog card status update failed: $($_.Exception.Message)"
    }
}

function Refresh-ShadowPolicyCatalog {
    try {
        $gridPolicies.Rows.Clear()
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        $names = Get-NamesMap
        $catalog = @(
            @{ Name='Anti-Phishing';       Key='Anti-Phish';       Policy=$names.AntiPhishPolicy;       Rule=$names.AntiPhishRule },
            @{ Name='Safe Attachments';    Key='Safe Attachments'; Policy=$names.SafeAttachmentsPolicy; Rule=$names.SafeAttachmentsRule },
            @{ Name='Safe Links';          Key='Safe Links';       Policy=$names.SafeLinksPolicy;       Rule=$names.SafeLinksRule },
            @{ Name='Inbound Anti-Spam';   Key='Inbound Spam';     Policy=$names.AntiSpamInboundPolicy; Rule=$names.AntiSpamInboundRule },
            @{ Name='Outbound Anti-Spam';  Key='Outbound Spam';    Policy=$names.AntiSpamOutboundPolicy; Rule=$names.AntiSpamOutboundRule },
            @{ Name='Anti-Malware';        Key='Anti-Malware';     Policy=$names.AntiMalwarePolicy;     Rule=$names.AntiMalwareRule }
        )

        $snapshot = $null
        if (Test-ExchangeOnlineConnection) {
            $snapshot = Get-PolicyStatusSnapshot -NamesMap $names
        }

        foreach ($item in $catalog) {
            $status = "Ready"
            if ($snapshot -and $snapshot.ContainsKey($item.Key)) { $status = $snapshot[$item.Key].Status }
            if ($gridPolicies) { [void]$gridPolicies.Rows.Add($item.Name,$status,$item.Policy,$item.Rule) }
            Set-CardStatus -Key $item.Key -Status $status
        }

        Set-CardStatus -Key 'Quarantine' -Status 'Needs Review'
        Set-CardStatus -Key 'Preset' -Status 'Needs Review'
        Set-CardStatus -Key 'Reporting' -Status 'Ready'

        if ($lblPolicyCount) { $lblPolicyCount.Text = "$($catalog.Count) policy areas" }
        if ($lblQuickConfig) { $lblQuickConfig.Text = "Loaded"; $lblQuickConfig.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95) }
        Update-ShadowDeploymentCardStates
        Add-Log "Loaded DFO365 policy catalog."
    } catch {
        Add-Log "[ERR] Catalog refresh failed: $($_.Exception.Message)"
    }
}

function Update-ShadowMetrics {
    try {
        if ($lblRunStats) {
            $total = $gridResults.Rows.Count
            $success = 0
            $review = 0
            $failed = 0
            foreach ($row in $gridResults.Rows) {
                $status = [string]$row.Cells["Status"].Value
                if ($status -in @("Success","Completed","Ready")) { $success++ }
                elseif ($status -in @("Warning","Skipped","Needs Review")) { $review++ }
                elseif ($status -in @("Failed","Invalid")) { $failed++ }
            }
            $lblRunStats.Text = "Results: $total | Success: $success | Review: $review | Failed: $failed"
        }
    } catch {}
}

function Show-ModalMessageBox {
  param(
    [Parameter(Mandatory)][System.Windows.Forms.Form]$Owner,
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][string]$Caption,
    [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
  )

  $prevTopMost = $Owner.TopMost
  try {
    $Owner.TopMost = $false
    $Owner.Activate() | Out-Null
    return [System.Windows.Forms.MessageBox]::Show($Owner, $Text, $Caption, $Buttons, $Icon)
  }
  finally {
    $Owner.TopMost = $prevTopMost
    $Owner.Activate() | Out-Null
  }
}

function Show-TextInputDialog {
  param(
    [Parameter(Mandatory)][System.Windows.Forms.Form]$Owner,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Prompt,
    [string]$DefaultText = ""
  )

  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = $Title
  $dialog.Size = New-Object System.Drawing.Size(540,190)
  $dialog.StartPosition = 'CenterParent'
  $dialog.FormBorderStyle = 'FixedDialog'
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ShowInTaskbar = $false
  $dialog.BackColor = $ShadowTheme.Surface
  $dialog.ForeColor = $ShadowTheme.Text

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Size = New-Object System.Drawing.Size(490,35)
  $label.Location = New-Object System.Drawing.Point(18,16)
  $label.ForeColor = $ShadowTheme.Text
  $label.Font = New-ShadowFont -Size 9
  $label.BackColor = $ShadowTheme.Surface
  $dialog.Controls.Add($label)

  $textbox = New-Object System.Windows.Forms.TextBox
  $textbox.Size = New-Object System.Drawing.Size(490,25)
  $textbox.Location = New-Object System.Drawing.Point(18,58)
  $textbox.Text = $DefaultText
  $textbox.BackColor = $ShadowTheme.SurfaceAlt
  $textbox.ForeColor = $ShadowTheme.Text
  $textbox.BorderStyle = 'FixedSingle'
  $dialog.Controls.Add($textbox)

  $btnOk = New-ShadowButton -Text "OK" -W 90 -H 32 -Style Success
  $btnOk.Location = New-Object System.Drawing.Point(322,102)
  $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dialog.Controls.Add($btnOk)

  $btnCancel = New-ShadowButton -Text "Cancel" -W 90 -H 32 -Style Secondary
  $btnCancel.Location = New-Object System.Drawing.Point(418,102)
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $dialog.Controls.Add($btnCancel)

  $dialog.AcceptButton = $btnOk
  $dialog.CancelButton = $btnCancel

  $prevTopMost = $Owner.TopMost
  try {
    $Owner.TopMost = $false
    $Owner.Activate() | Out-Null
    $result = $dialog.ShowDialog($Owner)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $textbox.Text }
    return $null
  }
  finally {
    $dialog.Dispose()
    $Owner.TopMost = $prevTopMost
    $Owner.Activate() | Out-Null
  }
}


function New-DeploymentCard {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Icon,
        [int]$X,
        [int]$Y,
        [System.Drawing.Color]$IconColor,
        [string]$StatusKey,
        [string]$DefaultStatus = "Ready"
    )

    if ($null -eq $IconColor) {
        $IconColor = [System.Drawing.Color]::FromArgb(155,75,255)
    }

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X,$Y)
    $card.Size = New-Object System.Drawing.Size(315, 112)
    $card.BackColor = $ShadowTheme.SurfaceAlt
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand

    # Accent strip to make each card look actionable without removing the description/status.
    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0,0)
    $accent.Size = New-Object System.Drawing.Size(315,3)
    $accent.BackColor = $IconColor
    $card.Controls.Add($accent)

    $iconLbl = New-Object System.Windows.Forms.Label
    $iconLbl.Text = $Icon
    $iconLbl.Location = New-Object System.Drawing.Point(16, 23)
    $iconLbl.Size = New-Object System.Drawing.Size(58, 58)
    $iconLbl.Font = New-ShadowFont -Size 27 -Weight Bold
    $iconLbl.ForeColor = $IconColor
    $iconLbl.BackColor = $ShadowTheme.SurfaceAlt
    $iconLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $iconLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($iconLbl)

    # Pronounced inner button around the title text.
    $titleButton = New-Object System.Windows.Forms.Label
    $titleButton.Text = $Icon
    $titleButton.Location = New-Object System.Drawing.Point(88, 15)
    $titleButton.Size = New-Object System.Drawing.Size(44, 31)
    $titleButton.Font = New-ShadowFont -Size 15 -Weight Bold
    $titleButton.ForeColor = $ShadowTheme.Text
    $titleButton.BackColor = $ShadowTheme.SurfaceSoft
    $titleButton.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $titleButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $titleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($titleButton)

    $titleTextLbl = New-ShadowLabel -Text $Title -X 140 -Y 18 -W 158 -H 24 -Size 10.2 -Bold -BackColor $ShadowTheme.SurfaceAlt
    $titleTextLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($titleTextLbl)

    $descLbl = New-ShadowLabel -Text $Description -X 92 -Y 51 -W 200 -H 34 -Size 8.2 -Muted -BackColor $ShadowTheme.SurfaceAlt
    $descLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($descLbl)

    $statusColor = $ShadowTheme.GreenBright
    if ($null -eq $statusColor) {
        $statusColor = [System.Drawing.Color]::FromArgb(102,220,95)
    }

    $statusLbl = New-ShadowLabel -Text "● $DefaultStatus" -X 92 -Y 86 -W 200 -H 20 -Size 8.5 -BackColor $ShadowTheme.SurfaceAlt -Color $statusColor
    $statusLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($statusLbl)

    if (-not $script:CardStatusLabels) {
        $script:CardStatusLabels = @{}
    }

    $script:CardStatusLabels[$StatusKey] = $statusLbl

    return $card
}

function Set-CardStatus {
    param([string]$Key,[string]$Status)

    if ($script:CardStatusLabels -and $script:CardStatusLabels.ContainsKey($Key)) {
        $label = $script:CardStatusLabels[$Key]
        switch ($Status) {
            "Enabled"     { $label.Text = "● Enabled"; $label.ForeColor = [System.Drawing.Color]::FromArgb(66,165,245) }
            "Ready"       { $label.Text = "● Ready"; $label.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95) }
            "Exists"      { $label.Text = "● Exists"; $label.ForeColor = [System.Drawing.Color]::Gold }
            "Policy Only" { $label.Text = "⚠ Policy Only"; $label.ForeColor = [System.Drawing.Color]::Gold }
            "Missing"     { $label.Text = "✖ Missing"; $label.ForeColor = [System.Drawing.Color]::FromArgb(239,83,80) }
            default       { $label.Text = "● $Status"; $label.ForeColor = $ShadowTheme.Muted }
        }
    }
}

# =============================
# Main Form
# =============================

$form = New-Object System.Windows.Forms.Form
$form.AutoScroll = $true
$form.ClientSize = New-Object System.Drawing.Size(1560, 980)
$form.Text = "Shadow Deploy for Defender for Office 365"
$form.Size = New-Object System.Drawing.Size(1580, 1020)
$form.MinimumSize = New-Object System.Drawing.Size(1500, 930)
$form.StartPosition = "CenterScreen"
$form.BackColor = $ShadowTheme.Back
$form.ForeColor = $ShadowTheme.Text
$form.Font = New-ShadowFont -Size 9
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable

# Folder setup preserving existing repo expectations
$Script:RepoRoot = Split-Path -Parent $Script:ScriptDirectory
$Script:ReportsDirectory = Join-Path $Script:RepoRoot "Reports"
$Script:LogsDirectory = Join-Path $Script:RepoRoot "Logs"
$Script:BackupsDirectory = Join-Path $Script:RepoRoot "Backups"
foreach ($dir in @($Script:ReportsDirectory,$Script:LogsDirectory,$Script:BackupsDirectory,$Script:ConfigDirectory)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
}

# Header logo - use your provided Shadow Deploy logo file named shadowdeployo365.png
$logoCandidates = @(
    (Join-Path $PSScriptRoot "shadowdeployo365.png"),
    (Join-Path $Script:ScriptDirectory "shadowdeployo365.png"),
    (Join-Path $Script:RepoRoot "shadowdeployo365.png"),
    (Join-Path $Script:RepoRoot "assets\shadowdeployo365.png"),
    (Join-Path $Script:RepoRoot "Assets\shadowdeployo365.png"),
    (Join-Path $Script:ConfigDirectory "shadowdeployo365.png")
) | Select-Object -Unique
$logoPath = $logoCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($logoPath) {
    try {
        $picLogo = New-Object System.Windows.Forms.PictureBox
        $picLogo.Location = New-Object System.Drawing.Point(60, 34)
        $picLogo.Size = New-Object System.Drawing.Size(225, 130)
        $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $picLogo.BackColor = $ShadowTheme.Back
        $imgTemp = [System.Drawing.Image]::FromFile($logoPath)
        $picLogo.Image = New-Object System.Drawing.Bitmap($imgTemp)
        $imgTemp.Dispose()
        $form.Controls.Add($picLogo)
    }
    catch {
        $form.Controls.Add((New-ShadowLabel -Text "SHADOW DEPLOY" -X 8 -Y 60 -W 690 -H 56 -Size 28 -Bold))
    }
}
else {
    $form.Controls.Add((New-ShadowLabel -Text "SHADOW DEPLOY" -X 8 -Y 60 -W 690 -H 56 -Size 28 -Bold))
}

$form.Controls.Add((New-ShadowLabel -Text "Defender for Office 365`r`nDeployment Module" -X 735 -Y 52 -W 300 -H 68 -Size 16 -Bold))
$form.Controls.Add((New-ShadowLabel -Text "Zero Trust Email Security Deployment,`r`nValidation, Reporting & Backup/Export" -X 737 -Y 126 -W 300 -H 48 -Size 9.5 -Muted))


# Session Summary Card
$sessionPanel = New-ShadowPanel -X 1100 -Y 34 -W 480 -H 184 -Title "SESSION SUMMARY" -Accent $ShadowTheme.Purple
$form.Controls.Add($sessionPanel)

$sessionPanel.Controls.Add((New-ShadowLabel -Text "Connection:" -X 22 -Y 48 -W 120 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface))
$lblConnection = New-ShadowLabel -Text "Not Connected" -X 155 -Y 48 -W 480 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::FromArgb(255,221,51))
$sessionPanel.Controls.Add($lblConnection)
$sessionPanel.Controls.Add((New-ShadowLabel -Text "Account:" -X 22 -Y 76 -W 120 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface))
$lblSignedIn = New-ShadowLabel -Text "Not connected" -X 155 -Y 76 -W 480 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface
$sessionPanel.Controls.Add($lblSignedIn)
$sessionPanel.Controls.Add((New-ShadowLabel -Text "Tenant:" -X 22 -Y 104 -W 120 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface))
$lblTenant = New-ShadowLabel -Text "Not connected" -X 155 -Y 104 -W 480 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface
$sessionPanel.Controls.Add($lblTenant)
$sessionPanel.Controls.Add((New-ShadowLabel -Text "Mode:" -X 22 -Y 132 -W 120 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface))
$lblMode = New-ShadowLabel -Text "Deploy (Rules Disabled)" -X 155 -Y 132 -W 480 -H 22 -Size 8.5 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::FromArgb(255,221,51))
$sessionPanel.Controls.Add($lblMode)
$sessionPanel.Controls.Add((New-ShadowLabel -Text "Config Loaded:" -X 22 -Y 158 -W 120 -H 20 -Size 8.5 -BackColor $ShadowTheme.Surface))
$lblConfig = New-ShadowLabel -Text "Not Loaded" -X 155 -Y 158 -W 480 -H 20 -Size 8.5 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::FromArgb(255,221,51))
$sessionPanel.Controls.Add($lblConfig)


foreach ($lbl in @($lblConnection,$lblSignedIn,$lblTenant,$lblMode,$lblConfig)) {
    try { $lbl.AutoEllipsis = $true } catch {}
}

$script:ModulePill = New-ShadowStatusPill -Text "DFO365: READY" -X 1380 -Y 226 -W 150 -State Blue
$form.Controls.Add($script:ModulePill)
$exoPill = New-ShadowStatusPill -Text "EXO: NOT CONNECTED" -X 1542 -Y 226 -W 150 -State Warning
$form.Controls.Add($exoPill)

# Deployment Areas
$deployPanel = New-ShadowPanel -X 14 -Y 228 -W 1012 -H 420 -Title "DEPLOYMENT AREAS" -Accent $ShadowTheme.Purple
$form.Controls.Add($deployPanel)

$script:CardStatusLabels = @{}

$cardAntiPhish = New-DeploymentCard -Title "Anti-Phishing" -Description "Deploy Anti-Phishing policy`r`nand global rule" -Icon "♙" -X 20 -Y 42 -IconColor $ShadowTheme.Purple -StatusKey "Anti-Phish"
$cardSafeAttachments = New-DeploymentCard -Title "Safe Attachments" -Description "Deploy Safe Attachments`r`npolicy and global rule" -Icon "⛓" -X 350 -Y 42 -IconColor $ShadowTheme.BlueBright -StatusKey "Safe Attachments"
$cardSafeLinks = New-DeploymentCard -Title "Safe Links" -Description "Deploy Safe Links policy`r`nand global rule" -Icon "🔗" -X 680 -Y 42 -IconColor $ShadowTheme.BlueBright -StatusKey "Safe Links"

$cardAntiSpam = New-DeploymentCard -Title "Anti-Spam" -Description "Deploy Inbound and`r`nOutbound Anti-Spam" -Icon "✉" -X 20 -Y 176 -IconColor $ShadowTheme.Orange -StatusKey "Inbound Spam"
$cardAntiMalware = New-DeploymentCard -Title "Anti-Malware" -Description "Deploy Anti-Malware policy`r`nand global rule" -Icon "☣" -X 350 -Y 176 -IconColor $ShadowTheme.Red -StatusKey "Anti-Malware"
$cardQuarantine = New-DeploymentCard -Title "Quarantine" -Description "Quarantine policies`r`nand retention settings" -Icon "⚠" -X 680 -Y 176 -IconColor ([System.Drawing.Color]::FromArgb(255,221,51)) -StatusKey "Quarantine" -DefaultStatus "Needs Review"

$cardPreset = New-DeploymentCard -Title "Assign Policy" -Description "Check scope box above`r`nand enter group first" -Icon "✓" -X 20 -Y 310 -IconColor $ShadowTheme.GreenBright -StatusKey "Preset" -DefaultStatus "Needs Review"
$cardDeployAll = New-DeploymentCard -Title "Deploy All Custom Policies" -Description "Deploy all catalog JSON`r`ncustom policies" -Icon "🚀" -X 350 -Y 310 -IconColor $ShadowTheme.GreenBright -StatusKey "DeployAll"
$cardReporting = New-DeploymentCard -Title "Reporting / Export" -Description "Generate HTML report`r`nand export evidence" -Icon "▤" -X 680 -Y 310 -IconColor $ShadowTheme.Purple -StatusKey "Reporting"

$deployPanel.Controls.AddRange(@(
    $cardAntiPhish,
    $cardSafeAttachments,
    $cardSafeLinks,
    $cardAntiSpam,
    $cardAntiMalware,
    $cardQuarantine,
    $cardPreset,
    $cardDeployAll,
    $cardReporting
))

# Execution Results
$resultsPanel = New-ShadowPanel -X 1038 -Y 242 -W 484 -H 462 -Title "EXECUTION RESULTS" -Accent $ShadowTheme.Purple
$form.Controls.Add($resultsPanel)

$gridResults = New-Object System.Windows.Forms.DataGridView
$gridResults.Location = New-Object System.Drawing.Point(18, 44)
$gridResults.Size = New-Object System.Drawing.Size(448, 280)
Set-ShadowGridStyle -Grid $gridResults
[void]$gridResults.Columns.Add("Name","Name")
[void]$gridResults.Columns.Add("Status","Status")
[void]$gridResults.Columns.Add("Details","Details")
$gridResults.Columns["Details"].FillWeight = 160
$resultsPanel.Controls.Add($gridResults)

$btnGenerateReportSide = New-ShadowButton -Text "Open Logs" -W 140 -H 30 -Style Primary
$btnGenerateReportSide.Location = New-Object System.Drawing.Point(196, 330)
$resultsPanel.Controls.Add($btnGenerateReportSide)


$btnClearResultsSide = New-ShadowButton -Text "Clear Results" -W 120 -H 30 -Style Danger
$btnClearResultsSide.Location = New-Object System.Drawing.Point(346, 330)
$resultsPanel.Controls.Add($btnClearResultsSide)


$resultsPanel.Controls.Add((New-ShadowLabel -Text "Ready To Deploy:" -X 24 -Y 336 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblReadyCount = New-ShadowLabel -Text "6" -X 430 -Y 336 -W 32 -H 22 -Size 10 -Bold -BackColor $ShadowTheme.Surface -Color $ShadowTheme.Purple
$resultsPanel.Controls.Add($lblReadyCount)
$resultsPanel.Controls.Add((New-ShadowLabel -Text "Completed:" -X 24 -Y 362 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblCompletedCount = New-ShadowLabel -Text "0" -X 430 -Y 362 -W 32 -H 22 -Size 10 -Bold -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::FromArgb(102,220,95))
$resultsPanel.Controls.Add($lblCompletedCount)
$resultsPanel.Controls.Add((New-ShadowLabel -Text "Warning / Review:" -X 24 -Y 388 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblWarningCount = New-ShadowLabel -Text "0" -X 430 -Y 388 -W 32 -H 22 -Size 10 -Bold -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::Gold)
$resultsPanel.Controls.Add($lblWarningCount)
$resultsPanel.Controls.Add((New-ShadowLabel -Text "Failed:" -X 24 -Y 414 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblFailedCount = New-ShadowLabel -Text "0" -X 430 -Y 414 -W 32 -H 22 -Size 10 -Bold -BackColor $ShadowTheme.Surface -Color $ShadowTheme.Red
$resultsPanel.Controls.Add($lblFailedCount)

# Main Workflow
$workflowPanel = New-ShadowPanel -X 14 -Y 656 -W 1012 -H 154 -Title "MAIN WORKFLOW" -Accent $ShadowTheme.Purple
$form.Controls.Add($workflowPanel)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Location = New-Object System.Drawing.Point(14, 44)
$buttonPanel.Size = New-Object System.Drawing.Size(980, 104)
$buttonPanel.BackColor = $ShadowTheme.Surface
$buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$buttonPanel.WrapContents = $true
$buttonPanel.AutoScroll = $false
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$workflowPanel.Controls.Add($buttonPanel)

$btnConnect     = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Connect" -Description "Connect EXO" -Style Primary
$btnDisconnect  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Disconnect" -Description "End EXO" -Style Danger
$btnLoadConfig  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Config" -Description "Load JSON" -Style Blue
$btnBackup      = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Backup" -Description "Backup policies" -Style Warning
$btnQuickBuild = New-ShadowButton -Text "Deploy Hidden" -W 1 -H 1 -Style Success
$btnQuickBuild.Visible = $false
$form.Controls.Add($btnQuickBuild)
$btnTestMode    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Test" -Description "Preview mode" -Style Secondary
$btnValidate    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Validate" -Description "Validate rules" -Style Secondary
$btnRuleMode    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Enable" -Description "Enable rules" -Style Warning
$btnExportHtml  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Generate Report" -Description "HTML report" -Style Primary
$btnRescanState = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Rescan State" -Description "Refresh cards" -Style Warning
$btnExportJson  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "JSON" -Description "Export JSON" -Style Secondary
$btnOpenReports = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Reports" -Description "Open reports" -Style Secondary
$btnOpenLogs    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Logs" -Description "Open logs" -Style Secondary
$btnOpenConfig  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "OpenCfg" -Description "Open config" -Style Secondary
$btnClearResults = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Clear" -Description "Clear output" -Style Danger
$btnExit = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Exit" -Description "Close tool" -Style Danger

# Hidden individual buttons preserved for backend-specific workflows
$btnAPh = New-ShadowButton -Text "Anti-Phishing" -W 1 -H 1 -Style Primary
$btnSA = New-ShadowButton -Text "Safe Attachments" -W 1 -H 1 -Style Blue
$btnSL = New-ShadowButton -Text "Safe Links" -W 1 -H 1 -Style Blue
$btnASp = New-ShadowButton -Text "Anti-Spam" -W 1 -H 1 -Style Warning
$btnAMw = New-ShadowButton -Text "Anti-Malware" -W 1 -H 1 -Style Danger
$btnSLUrls = New-ShadowButton -Text "Safe Links URLs" -W 1 -H 1 -Style Secondary
$btnQuar = New-ShadowButton -Text "Quarantine" -W 1 -H 1 -Style Secondary
$btnPreset = New-ShadowButton -Text "Preset Policies" -W 1 -H 1 -Style Secondary
foreach ($b in @($btnAPh,$btnSA,$btnSL,$btnASp,$btnAMw,$btnSLUrls,$btnQuar,$btnPreset)) { $b.Visible = $false; $form.Controls.Add($b) }

# Hidden catalog grid preserved for existing refresh/status logic
$gridPolicies = New-Object System.Windows.Forms.DataGridView
$gridPolicies.Visible = $false
[void]$gridPolicies.Columns.Add("Name","Area")
[void]$gridPolicies.Columns.Add("Status","Status")
[void]$gridPolicies.Columns.Add("Policy","Policy")
[void]$gridPolicies.Columns.Add("Rule","Rule")
$form.Controls.Add($gridPolicies)

# Quick Status
$quickPanel = New-ShadowPanel -X 1038 -Y 742 -W 484 -H 242 -Title "QUICK STATUS" -Accent $ShadowTheme.Purple
$form.Controls.Add($quickPanel)
$quickPanel.Controls.Add((New-ShadowLabel -Text "Exchange Online:" -X 22 -Y 54 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblQuickExchange = New-ShadowLabel -Text "Not Connected" -X 190 -Y 54 -W 230 -H 22 -Size 9 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::Gold)
$quickPanel.Controls.Add($lblQuickExchange)
$quickPanel.Controls.Add((New-ShadowLabel -Text "Configuration:" -X 22 -Y 86 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblQuickConfig = New-ShadowLabel -Text "Not Loaded" -X 190 -Y 86 -W 230 -H 22 -Size 9 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::Gold)
$quickPanel.Controls.Add($lblQuickConfig)
$quickPanel.Controls.Add((New-ShadowLabel -Text "Deployment Mode:" -X 22 -Y 118 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblQuickMode = New-ShadowLabel -Text "Deploy (Rules Disabled)" -X 190 -Y 118 -W 230 -H 22 -Size 9 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::Gold)
$quickPanel.Controls.Add($lblQuickMode)
$quickPanel.Controls.Add((New-ShadowLabel -Text "Last Action:" -X 22 -Y 150 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblQuickLastAction = New-ShadowLabel -Text "Ready" -X 190 -Y 150 -W 230 -H 22 -Size 9 -BackColor $ShadowTheme.Surface -Color ([System.Drawing.Color]::FromArgb(102,220,95))
$quickPanel.Controls.Add($lblQuickLastAction)
$quickPanel.Controls.Add((New-ShadowLabel -Text "Last Run Time:" -X 22 -Y 182 -W 150 -H 22 -Size 9 -BackColor $ShadowTheme.Surface))
$lblLastRunTime = New-ShadowLabel -Text "-" -X 190 -Y 182 -W 230 -H 22 -Size 9 -BackColor $ShadowTheme.Surface -Color $ShadowTheme.Muted
$quickPanel.Controls.Add($lblLastRunTime)

# Operational Log
$logPanel = New-ShadowPanel -X 14 -Y 820 -W 1012 -H 164 -Title "OPERATIONAL LOG" -Accent $ShadowTheme.Purple
$form.Controls.Add($logPanel)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 44)
$txtLog.Size = New-Object System.Drawing.Size(976, 102)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = $ShadowTheme.Console
$txtLog.ForeColor = $ShadowTheme.Text
$txtLog.Font = New-Object System.Drawing.Font("Consolas",9)
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$logPanel.Controls.Add($txtLog)

# Hidden labels to satisfy existing Update-PolicyIndicators flow
$script:PolicyIndicatorLabels = @{}
function New-HiddenIndicatorLabel { $label = New-Object System.Windows.Forms.Label; $label.Text = "Unknown"; $label.Visible = $false; $form.Controls.Add($label); return $label }
$script:PolicyIndicatorLabels['Anti-Phish']       = New-HiddenIndicatorLabel
$script:PolicyIndicatorLabels['Safe Attachments'] = New-HiddenIndicatorLabel
$script:PolicyIndicatorLabels['Safe Links']       = New-HiddenIndicatorLabel
$script:PolicyIndicatorLabels['Inbound Spam']     = New-HiddenIndicatorLabel
$script:PolicyIndicatorLabels['Outbound Spam']    = New-HiddenIndicatorLabel
$script:PolicyIndicatorLabels['Anti-Malware']     = New-HiddenIndicatorLabel

# Footer
$footerPanel = New-Object System.Windows.Forms.Panel
$footerPanel.Location = New-Object System.Drawing.Point(18, 945)
$footerPanel.Size = New-Object System.Drawing.Size(1490, 30)
$footerPanel.BackColor = $ShadowTheme.Surface
$footerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($footerPanel)
$footerPanel.Controls.Add((New-ShadowLabel -Text "Shadow Deploy for Defender for Office 365  |  Zero Trust Email Security  |  Secure • Compliant • Protected" -X 18 -Y 7 -W 680 -H 20 -Size 8.5 -Muted -BackColor $ShadowTheme.Surface))
$footerPanel.Controls.Add((New-ShadowLabel -Text "© Shadow Suite  |  Built for Security Operators" -X 1300 -Y 7 -W 360 -H 20 -Size 8.5 -Muted -BackColor $ShadowTheme.Surface))

# Dialogs
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$saveHtmlDialog = New-Object System.Windows.Forms.SaveFileDialog
$saveHtmlDialog.Filter = 'HTML Files (*.html)|*.html'
$saveHtmlDialog.Title = 'Save Shadow Deploy for Defender for Office 365 Report'
$saveHtmlDialog.FileName = ('ShadowDeploy-DFO365-Report-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Export-ShadowDeployDfoHtmlReport {
    param([Parameter(Mandatory)][string]$Path)
    Export-PoliciesHtml -Path $Path
    try {
        $html = Get-Content -Path $Path -Raw -Encoding UTF8
        $html = $html -replace 'DFO365 Deployment Tool - HTML Report','Shadow Deploy for Defender for Office 365 - Deployment Report'
        $html = $html -replace 'DFO365 HTML Report','Shadow Deploy for Defender for Office 365 Report'
        $html = $html -replace 'background:#1b1f26','background:#05070c'
        $html = $html -replace 'background:#20252d','background:#0a0e17'
        $html = $html -replace 'background:#2a3038','background:#101520'
        $html = $html -replace 'border:1px solid #4a4f57','border:1px solid #444a58'
        $summaryBlock = @"
<div class='card'>
<h2>Executive Summary</h2>
<p>This Shadow Suite report summarizes Defender for Office 365 policy and rule inventory collected by Shadow Deploy for Defender for Office 365.</p>
</div>
<div class='card'>
<h2>Deployment Summary</h2>
<p>Review Safe Links, Safe Attachments, Anti-Phishing, Anti-Spam, and Anti-Malware policy state before enabling enforcement in production.</p>
</div>
<div class='card'>
<h2>Recommendations</h2>
<ul>
<li>Validate in a pilot tenant or pilot domain scope before production enforcement.</li>
<li>Export JSON before and after deployment to preserve configuration evidence.</li>
<li>Review policy status indicators and quarantine behavior before enabling services.</li>
</ul>
</div>
"@
        $html = $html -replace '(<h1>Shadow Deploy for Defender for Office 365 - Deployment Report</h1>)', "`$1`n$summaryBlock"
        [System.IO.File]::WriteAllText($Path, $html, [System.Text.Encoding]::UTF8)
    } catch { Add-Log "[WARN] Report generated, but Shadow branding update failed: $($_.Exception.Message)" }
}

function Get-ShadowDeployDfoCategoryCatalog {
    $catalogRoot = Join-Path $Script:ConfigDirectory "Catalog"
    if (-not (Test-Path -LiteralPath $catalogRoot)) {
        try { New-Item -ItemType Directory -Path $catalogRoot -Force | Out-Null } catch {}
    }

    $items = @(
        [pscustomobject]@{ Key='Anti-Phish';       Name='Anti-Phishing';            File='DFO365_AntiPhish.json';               Sections=@('AntiPhish') },
        [pscustomobject]@{ Key='Safe Attachments'; Name='Safe Attachments';         File='DFO365_SafeAttachments.json';         Sections=@('SafeAttachments') },
        [pscustomobject]@{ Key='Safe Links';       Name='Safe Links';               File='DFO365_SafeLinks.json';               Sections=@('SafeLinks') },
        [pscustomobject]@{ Key='Inbound Spam';     Name='Anti-Spam';                File='DFO365_AntiSpam.json';                Sections=@('AntiSpamInbound','AntiSpamOutbound') },
        [pscustomobject]@{ Key='Anti-Malware';     Name='Anti-Malware';             File='DFO365_AntiMalware.json';             Sections=@('AntiMalware') },
        [pscustomobject]@{ Key='Quarantine';       Name='Quarantine';               File='DFO365_Quarantine.json';              Sections=@('Quarantine') },
        [pscustomobject]@{ Key='Preset';           Name='Assign Policy'; File='DFO365_PresetSecurityPolicies.json';  Sections=@('PresetSecurityPolicies') }
    )

    foreach ($item in $items) {
        $item | Add-Member -NotePropertyName Path -NotePropertyValue (Join-Path $catalogRoot $item.File) -Force
        $item | Add-Member -NotePropertyName Exists -NotePropertyValue (Test-Path -LiteralPath (Join-Path $catalogRoot $item.File)) -Force
    }

    return $items
}

function Add-ShadowCategoryJsonToCatalog {
    param(
        [Parameter(Mandatory)][string]$CategoryKey
    )

    $catalogRoot = Join-Path $Script:ConfigDirectory "Catalog"
    if (-not (Test-Path -LiteralPath $catalogRoot)) {
        New-Item -ItemType Directory -Path $catalogRoot -Force | Out-Null
    }

    $templates = @{
        'Anti-Phish' = @{
            File='DFO365_AntiPhish.json'
            Body=[ordered]@{
                Category='AntiPhish'
                MicrosoftAlignment='Zero Trust / Strict'
                AntiPhish=[ordered]@{
                    Enabled=$true
                    PhishThresholdLevel=3
                    EnableMailboxIntelligence=$true
                    EnableMailboxIntelligenceProtection=$true
                    EnableSpoofIntelligence=$true
                    EnableTargetedUserProtection=$true
                    EnableTargetedDomainsProtection=$true
                    EnableOrganizationDomainsProtection=$true
                    AuthenticationFailAction='Quarantine'
                    MailboxIntelligenceProtectionAction='Quarantine'
                    TargetedUserProtectionAction='Quarantine'
                    TargetedDomainProtectionAction='Quarantine'
                    HonorDmarcPolicy=$true
                }
            }
        }
        'Safe Attachments' = @{
            File='DFO365_SafeAttachments.json'
            Body=[ordered]@{
                Category='SafeAttachments'
                MicrosoftAlignment='Zero Trust / Strict'
                SafeAttachments=[ordered]@{
                    Enabled=$true
                    Action='Block'
                    Redirect=$false
                    EnableOrganizationBranding=$true
                    QuarantineTag='AdminOnlyAccessPolicy'
                }
            }
        }
        'Safe Links' = @{
            File='DFO365_SafeLinks.json'
            Body=[ordered]@{
                Category='SafeLinks'
                MicrosoftAlignment='Zero Trust / Strict'
                SafeLinks=[ordered]@{
                    Enabled=$true
                    IsEnabled=$true
                    EnableSafeLinksForEmail=$true
                    EnableSafeLinksForTeams=$true
                    EnableSafeLinksForOffice=$true
                    TrackClicks=$true
                    AllowClickThrough=$false
                    ScanUrls=$true
                    EnableForInternalSenders=$true
                    DeliverMessageAfterScan=$true
                    DisableUrlRewrite=$false
                    DoNotRewriteUrls=@()
                    BlockedUrls=@()
                    DisabledUrls=@()
                }
            }
        }
        'Inbound Spam' = @{
            File='DFO365_AntiSpam.json'
            Body=[ordered]@{
                Category='AntiSpam'
                MicrosoftAlignment='Zero Trust / Standard-Strict'
                AntiSpamInbound=[ordered]@{
                    Enabled=$true
                    SpamAction='MoveToJmf'
                    HighConfidenceSpamAction='Quarantine'
                    PhishSpamAction='Quarantine'
                    HighConfidencePhishAction='Quarantine'
                    BulkSpamAction='Quarantine'
                    ZapEnabled=$true
                    EnableEndUserSpamNotifications=$true
                }
                AntiSpamOutbound=[ordered]@{
                    Enabled=$true
                    AutoForwardingMode='Off'
                    ActionWhenThresholdReached='BlockUser'
                    NotifyOutboundSpam=$true
                    RecipientLimitExternalPerHour=400
                    RecipientLimitInternalPerHour=800
                    RecipientLimitPerDay=800
                }
            }
        }
        'Anti-Malware' = @{
            File='DFO365_AntiMalware.json'
            Body=[ordered]@{
                Category='AntiMalware'
                MicrosoftAlignment='Zero Trust / Standard'
                AntiMalware=[ordered]@{
                    Enabled=$true
                    EnableFileFilter=$true
                    EnableInternalSenderAdminNotifications=$true
                    EnableExternalSenderAdminNotifications=$true
                    ZapEnabled=$true
                    Action='DeleteMessage'
                }
            }
        }
        'Quarantine' = @{
            File='DFO365_Quarantine.json'
            Body=[ordered]@{
                Category='Quarantine'
                MicrosoftAlignment='Needs Review'
                Quarantine=[ordered]@{
                    Enabled=$false
                    Status='AdvisoryOnly'
                    Notes='No backend quarantine deployment is executed in the current release.'
                }
            }
        }
        'Preset' = @{
            File='DFO365_PresetSecurityPolicies.json'
            Body=[ordered]@{
                Category='PresetSecurityPolicies'
                MicrosoftAlignment='Needs Review'
                PresetSecurityPolicies=[ordered]@{
                    Enabled=$false
                    Status='AdvisoryOnly'
                    Notes='No backend preset policy deployment is executed in the current release.'
                }
            }
        }
    }

    if (-not $templates.ContainsKey($CategoryKey)) {
        Add-Log "[WARN] No catalog template exists for $CategoryKey"
        return $null
    }

    $template = $templates[$CategoryKey]
    $path = Join-Path $catalogRoot $template.File

    if (-not (Test-Path -LiteralPath $path)) {
        $template.Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
        Add-Result "Catalog" "Success" "Added catalog file: $($template.File)"
        Add-Log "[OK] Added catalog file: $path"
    }
    else {
        Add-Result "Catalog" "Skipped" "Catalog file already exists: $($template.File)"
        Add-Log "[INFO] Catalog file already exists: $path"
    }

    return $path
}

function Merge-ShadowCatalogIntoActiveConfig {
    try {
        $items = Get-ShadowDeployDfoCategoryCatalog
        foreach ($item in $items) {
            if (-not (Test-Path -LiteralPath $item.Path)) { continue }
            $raw = Get-Content -LiteralPath $item.Path -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $json = $raw | ConvertFrom-Json

            foreach ($section in $item.Sections) {
                if ($json.PSObject.Properties[$section]) {
                    if ($null -eq $Script:Config) { $Script:Config = [pscustomobject]@{} }
                    if ($Script:Config.PSObject.Properties[$section]) {
                        $Script:Config.PSObject.Properties.Remove($section)
                    }
                    $Script:Config | Add-Member -NotePropertyName $section -NotePropertyValue $json.PSObject.Properties[$section].Value -Force
                }
            }
        }
        Add-Log "[OK] Catalog sections merged into active configuration."
    }
    catch {
        Add-Log "[WARN] Catalog merge failed: $($_.Exception.Message)"
    }
}

function Get-ShadowAlignmentScore {
    try {
        $score = [ordered]@{
            Strict = 0
            Standard = 0
            NeedsReview = 0
            Total = 0
        }

        $checks = @(
            @{Section='SafeLinks'; Key='AllowClickThrough'; Strict=$false; Standard=$false},
            @{Section='SafeLinks'; Key='TrackClicks'; Strict=$true; Standard=$true},
            @{Section='SafeLinks'; Key='ScanUrls'; Strict=$true; Standard=$true},
            @{Section='SafeAttachments'; Key='Action'; Strict='Block'; Standard='DynamicDelivery'},
            @{Section='AntiPhish'; Key='PhishThresholdLevel'; Strict=3; Standard=2},
            @{Section='AntiPhish'; Key='EnableMailboxIntelligence'; Strict=$true; Standard=$true},
            @{Section='AntiSpamOutbound'; Key='AutoForwardingMode'; Strict='Off'; Standard='Automatic'}
        )

        foreach ($c in $checks) {
            $score.Total++
            $value = Get-ConfigValue -SectionName $c.Section -Key $c.Key -DefaultValue $null
            if ($null -eq $value) {
                $score.NeedsReview++
            }
            elseif ([string]$value -eq [string]$c.Strict) {
                $score.Strict++
            }
            elseif ([string]$value -eq [string]$c.Standard) {
                $score.Standard++
            }
            else {
                $score.NeedsReview++
            }
        }

        return [pscustomobject]$score
    }
    catch {
        return [pscustomobject]@{ Strict=0; Standard=0; NeedsReview=1; Total=1 }
    }
}

function Add-ShadowAlignmentToReport {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $alignment = Get-ShadowAlignmentScore
        $total = [Math]::Max(1, [int]$alignment.Total)
        $strictPct = [Math]::Round(([int]$alignment.Strict / $total) * 100, 0)
        $standardPct = [Math]::Round(([int]$alignment.Standard / $total) * 100, 0)
        $reviewPct = [Math]::Round(([int]$alignment.NeedsReview / $total) * 100, 0)

        $block = @"
<div class='card'>
<h2>Microsoft Alignment Snapshot</h2>
<p>This section estimates whether active baseline settings align closer to Microsoft Zero Trust / Strict, Standard, or Needs Review based on selected high-impact controls.</p>
<div style='display:flex;gap:14px;margin-top:12px;'>
  <div style='flex:1;background:#0a0e17;border:1px solid #444a58;border-radius:10px;padding:12px;'>
    <div style='font-size:26px;font-weight:700;color:#66dc5f;'>$strictPct%</div>
    <div>Strict / Zero Trust</div>
  </div>
  <div style='flex:1;background:#0a0e17;border:1px solid #444a58;border-radius:10px;padding:12px;'>
    <div style='font-size:26px;font-weight:700;color:#3498f5;'>$standardPct%</div>
    <div>Standard</div>
  </div>
  <div style='flex:1;background:#0a0e17;border:1px solid #444a58;border-radius:10px;padding:12px;'>
    <div style='font-size:26px;font-weight:700;color:#ffdd33;'>$reviewPct%</div>
    <div>Needs Review</div>
  </div>
</div>
<div style='margin-top:14px;background:#111827;border-radius:999px;overflow:hidden;border:1px solid #444a58;height:22px;'>
  <div style='width:$strictPct%;height:22px;background:#169148;float:left;'></div>
  <div style='width:$standardPct%;height:22px;background:#18417d;float:left;'></div>
  <div style='width:$reviewPct%;height:22px;background:#da6712;float:left;'></div>
</div>
</div>
"@

        $html = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $html = $html -replace "(<body[^>]*>)", "`$1`n$block"
        Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
    }
    catch {
        Add-Log "[WARN] Alignment report block failed: $($_.Exception.Message)"
    }
}


function Import-ShadowCategoryJsonToConfig {
    param(
        [Parameter(Mandatory)][string]$CategoryKey,
        [switch]$Required
    )

    try {
        $items = Get-ShadowDeployDfoCategoryCatalog
        $item = $items | Where-Object { $_.Key -eq $CategoryKey } | Select-Object -First 1

        if (-not $item) {
            $msg = "Unknown catalog category: $CategoryKey"
            if ($Required) { throw $msg }
            Add-Log "[WARN] $msg"
            return $false
        }

        if (-not (Test-Path -LiteralPath $item.Path)) {
            $msg = "Catalog JSON missing for $($item.Name): $($item.Path)"
            if ($Required) { throw $msg }
            Add-Log "[WARN] $msg"
            return $false
        }

        $raw = Get-Content -LiteralPath $item.Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $msg = "Catalog JSON is empty: $($item.Path)"
            if ($Required) { throw $msg }
            Add-Log "[WARN] $msg"
            return $false
        }

        $json = $raw | ConvertFrom-Json

        if ($null -eq $Script:Config) {
            $Script:Config = [pscustomobject]@{}
        }

        foreach ($section in $item.Sections) {
            if ($json.PSObject.Properties[$section]) {
                if ($Script:Config.PSObject.Properties[$section]) {
                    $Script:Config.PSObject.Properties.Remove($section)
                }

                $Script:Config | Add-Member -NotePropertyName $section -NotePropertyValue $json.PSObject.Properties[$section].Value -Force
                Add-Log "[OK] Loaded $section from catalog JSON: $($item.File)"
            }
            else {
                Add-Log "[WARN] Section '$section' not found in $($item.File)"
            }
        }

        $Script:LoadedConfigPath = $item.Path
        if ($lblConfig) {
            $lblConfig.Text = "Catalog: $($item.File)"
            $lblConfig.ForeColor = $ShadowTheme.GreenBright
        }
        if ($lblQuickConfig) {
            $lblQuickConfig.Text = "Catalog Loaded"
            $lblQuickConfig.ForeColor = $ShadowTheme.GreenBright
        }

        return $true
    }
    catch {
        Add-Result "Catalog Load" "Failed" $_.Exception.Message
        Add-Log "[ERR] Catalog load failed: $($_.Exception.Message)"
        return $false
    }
}

function Import-AllShadowCatalogJsonToConfig {
    try {
        $items = Get-ShadowDeployDfoCategoryCatalog
        foreach ($item in $items) {
            if ($item.Key -in @('Quarantine','Preset')) { continue }
            [void](Import-ShadowCategoryJsonToConfig -CategoryKey $item.Key)
        }
        Add-Log "[OK] JSON-first catalog import complete."
        return $true
    }
    catch {
        Add-Log "[ERR] Catalog import failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-ShadowJsonFirstDeployment {
    param(
        [Parameter(Mandatory)][string]$CategoryKey,
        [Parameter(Mandatory)][scriptblock]$DeployAction
    )

    $items = Get-ShadowDeployDfoCategoryCatalog
    $item = $items | Where-Object { $_.Key -eq $CategoryKey } | Select-Object -First 1

    if ($item -and -not $item.Exists) {
        [void](Add-ShadowCategoryJsonToCatalog -CategoryKey $CategoryKey)
        Refresh-ShadowPolicyCatalog
        Update-ShadowMetrics
        return
    }

    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey $CategoryKey -Required)) {
        return
    }

    & $DeployAction
}


function Get-ShadowCategoryTenantStatus {
    param([Parameter(Mandatory)][string]$CategoryKey)

    try {
        $names = Get-NamesMap
        $snapshot = $null
        if (Test-ExchangeOnlineConnection) {
            $snapshot = Get-PolicyStatusSnapshot -NamesMap $names
        }

        $items = Get-ShadowDeployDfoCategoryCatalog
        $item = $items | Where-Object { $_.Key -eq $CategoryKey } | Select-Object -First 1

        if ($item -and -not $item.Exists) {
            return [pscustomobject]@{ Status='Add to Catalog'; Color='Yellow'; Detail='Category JSON missing' }
        }

        if ($CategoryKey -in @('Quarantine','Preset')) {
            return [pscustomobject]@{ Status='Needs Review'; Color='Yellow'; Detail='Advisory workflow' }
        }

        if (-not (Test-ExchangeOnlineConnection)) {
            return [pscustomobject]@{ Status='Ready to Deploy'; Color='Blue'; Detail='Catalog exists; tenant not connected' }
        }

        if ($snapshot -and $snapshot.ContainsKey($CategoryKey)) {
            $s = [string]$snapshot[$CategoryKey].Status
            switch ($s) {
                'Missing'     { return [pscustomobject]@{ Status='Ready to Deploy'; Color='Blue'; Detail='Catalog exists; tenant object missing' } }
                'Policy Only' { return [pscustomobject]@{ Status='Ready to Update'; Color='Orange'; Detail='Policy exists but rule missing' } }
                'Exists'      { return [pscustomobject]@{ Status='Ready to Update'; Color='Orange'; Detail='Policy/rule exists; verify catalog drift' } }
                'Ready'       { return [pscustomobject]@{ Status='Deployed'; Color='Green'; Detail='Policy/rule deployed and disabled' } }
                'Enabled'     { return [pscustomobject]@{ Status='Deployed'; Color='Green'; Detail='Policy/rule deployed and enabled' } }
                default       { return [pscustomobject]@{ Status='Needs Review'; Color='Red'; Detail=$s } }
            }
        }

        return [pscustomobject]@{ Status='Ready to Deploy'; Color='Blue'; Detail='Catalog exists' }
    }
    catch {
        return [pscustomobject]@{ Status='Needs Review'; Color='Red'; Detail=$_.Exception.Message }
    }
}

function Set-ShadowCardDashboardStatus {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Status,
        [string]$Color = 'Blue'
    )

    if (-not $script:CardStatusLabels) { return }
    if (-not $script:CardStatusLabels.ContainsKey($Key)) { return }

    $label = $script:CardStatusLabels[$Key]
    switch ($Color) {
        'Green'  { $label.ForeColor = $ShadowTheme.GreenBright }
        'Orange' { $label.ForeColor = $ShadowTheme.Orange }
        'Yellow' { $label.ForeColor = [System.Drawing.Color]::FromArgb(255,221,51) }
        'Red'    { $label.ForeColor = $ShadowTheme.Red }
        'Blue'   { $label.ForeColor = $ShadowTheme.BlueBright }
        default  { $label.ForeColor = $ShadowTheme.Muted }
    }

    switch ($Status) {
        'Add to Catalog'  { $label.Text = "＋ Add to Catalog" }
        'Ready to Deploy' { $label.Text = "● Ready to Deploy" }
        'Ready to Update' { $label.Text = "● Ready to Update" }
        'Deployed'        { $label.Text = "● Deployed" }
        'Needs Review'    { $label.Text = "⚠ Needs Review" }
        'Failed'          { $label.Text = "✖ Failed" }
        default           { $label.Text = "● $Status" }
    }
}

function Update-ShadowDeploymentCardStates {
    try {
        foreach ($key in @('Anti-Phish','Safe Attachments','Safe Links','Inbound Spam','Anti-Malware','Quarantine','Preset')) {
            $state = Get-ShadowCategoryTenantStatus -CategoryKey $key
            Set-ShadowCardDashboardStatus -Key $key -Status $state.Status -Color $state.Color
        }

        Set-ShadowCardDashboardStatus -Key 'DeployAll' -Status 'Ready to Deploy' -Color 'Green'
        Set-ShadowCardDashboardStatus -Key 'Reporting' -Status 'Ready to Deploy' -Color 'Blue'
    }
    catch {
        Add-Log "[WARN] Deployment card state update failed: $($_.Exception.Message)"
    }
}

function Invoke-ShadowDeployAllCustomPolicies {
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying all custom catalog policies...'
        Add-Log "[INFO] Deploy All Custom Policies started."

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        [void](Import-AllShadowCatalogJsonToConfig)
        $btnQuickBuild.PerformClick()

        Update-ShadowDeploymentCardStates
        Add-Result "Deploy All Custom Policies" "Success" "All catalog-backed DFO365 policies processed."
        Add-Log "[OK] Deploy All Custom Policies completed."
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Deploy All failed.'
        Add-Result "Deploy All Custom Policies" "Failed" $_.Exception.Message
        Add-Log "[ERR] Deploy All Custom Policies failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
}

function Add-ShadowDriftAndAlignmentReportBlock {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $items = Get-ShadowDeployDfoCategoryCatalog
        $rows = New-Object System.Text.StringBuilder

        foreach ($key in @('Anti-Phish','Safe Attachments','Safe Links','Inbound Spam','Anti-Malware','Quarantine','Preset')) {
            $item = $items | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            $state = Get-ShadowCategoryTenantStatus -CategoryKey $key
            $file = if ($item) { $item.File } else { 'N/A' }
            $alignment = if ($key -in @('Anti-Phish','Safe Attachments','Safe Links')) { 'Zero Trust / Strict' }
                         elseif ($key -in @('Inbound Spam','Anti-Malware')) { 'Standard / Strict' }
                         else { 'Needs Review' }

            [void]$rows.AppendLine("<tr><td>$($item.Name)</td><td>$($state.Status)</td><td>$alignment</td><td>$file</td><td>$($state.Detail)</td></tr>")
        }

        $alignment = Get-ShadowAlignmentScore
        $total = [Math]::Max(1, [int]$alignment.Total)
        $strictPct = [Math]::Round(([int]$alignment.Strict / $total) * 100, 0)
        $standardPct = [Math]::Round(([int]$alignment.Standard / $total) * 100, 0)
        $reviewPct = [Math]::Round(([int]$alignment.NeedsReview / $total) * 100, 0)

        $block = @"
<div class='card' style='border-left:5px solid #9b4bff;'>
<h2>Shadow Suite Deployment Dashboard</h2>
<p>This section compares catalog-backed policy intent against tenant deployment state and Microsoft baseline alignment.</p>
<div style='display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:12px;'>
  <div style='background:#0a0e17;border:1px solid #444a58;border-radius:12px;padding:14px;'><div style='font-size:30px;font-weight:800;color:#66dc5f;'>$strictPct%</div><div>Zero Trust / Strict</div></div>
  <div style='background:#0a0e17;border:1px solid #444a58;border-radius:12px;padding:14px;'><div style='font-size:30px;font-weight:800;color:#3498f5;'>$standardPct%</div><div>Microsoft Standard</div></div>
  <div style='background:#0a0e17;border:1px solid #444a58;border-radius:12px;padding:14px;'><div style='font-size:30px;font-weight:800;color:#ffdd33;'>$reviewPct%</div><div>Needs Review / Custom</div></div>
</div>
<div style='margin-top:16px;background:#111827;border-radius:999px;overflow:hidden;border:1px solid #444a58;height:24px;'>
  <div style='width:$strictPct%;height:24px;background:#169148;float:left;'></div>
  <div style='width:$standardPct%;height:24px;background:#18417d;float:left;'></div>
  <div style='width:$reviewPct%;height:24px;background:#da6712;float:left;'></div>
</div>
</div>
<div class='card'>
<h2>Catalog Drift / Deployment State</h2>
<table>
<tr><th>Policy Area</th><th>Status</th><th>Microsoft Alignment</th><th>Catalog File</th><th>Detail</th></tr>
$($rows.ToString())
</table>
</div>
"@

        $html = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $html = $html -replace "(<body[^>]*>)", "`$1`n$block"
        Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
    }
    catch {
        Add-Log "[WARN] Shadow dashboard report block failed: $($_.Exception.Message)"
    }
}


function Set-ShadowCardDeployed {
    param([Parameter(Mandatory)][string]$Key,[string]$Status = 'Deployed')
    try {
        if ($script:CardStatusLabels -and $script:CardStatusLabels.ContainsKey($Key)) {
            $label = $script:CardStatusLabels[$Key]
            $label.Text = "● $Status"
            $label.ForeColor = $ShadowTheme.GreenBright
        }
    } catch {}
}

function Set-ShadowCardRunning {
    param([Parameter(Mandatory)][string]$Key)
    try {
        if ($script:CardStatusLabels -and $script:CardStatusLabels.ContainsKey($Key)) {
            $label = $script:CardStatusLabels[$Key]
            $label.Text = "● Running"
            $label.ForeColor = $ShadowTheme.Orange
        }
    } catch {}
}

function Set-ShadowCardFailed {
    param([Parameter(Mandatory)][string]$Key,[string]$Message = 'Failed')
    try {
        if ($script:CardStatusLabels -and $script:CardStatusLabels.ContainsKey($Key)) {
            $label = $script:CardStatusLabels[$Key]
            $label.Text = "✖ $Message"
            $label.ForeColor = $ShadowTheme.Red
        }
    } catch {}
}

function Invoke-ShadowDeployCatalogPolicy {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Anti-Phish','Safe Attachments','Safe Links','Inbound Spam','Anti-Malware')]
        [string]$CategoryKey
    )

    try {
        Clear-ShadowDfoCache
        Set-ShadowCardRunning -Key $CategoryKey
        Set-ShadowModuleStatus -Status 'Running' -Detail "Deploying $CategoryKey from catalog JSON..."
        Add-Log "[INFO] Deploying $CategoryKey using JSON-first catalog."

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return $false }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return $false }

        if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey $CategoryKey -Required)) {
            Set-ShadowCardFailed -Key $CategoryKey -Message 'Catalog Error'
            return $false
        }

        $Names = Get-NamesMap
        $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
        $dom = Get-AllAcceptedDomains

        switch ($CategoryKey) {
            'Anti-Phish' {
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-AntiPhishPolicy' -Logger ${function:Log})) { throw "Anti-Phish cmdlets unavailable." }
                Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy
                Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom
                Add-Result "Anti-Phishing" "Success" "Deployment completed."
            }
            'Safe Attachments' {
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeAttachmentPolicy' -Logger ${function:Log})) { throw "Safe Attachment cmdlets unavailable." }
                Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy
                Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom
                Add-Result "Safe Attachments" "Success" "Deployment completed."
            }
            'Safe Links' {
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { throw "Safe Links cmdlets unavailable." }
                Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy
                Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom
                Add-Result "Safe Links" "Success" "Deployment completed."
            }
            'Inbound Spam' {
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedContentFilterPolicy' -Logger ${function:Log})) { throw "Inbound Anti-Spam cmdlets unavailable." }
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedOutboundSpamFilterPolicy' -Logger ${function:Log})) { throw "Outbound Anti-Spam cmdlets unavailable." }
                Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy
                Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom
                Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify
                Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom
                Add-Result "Anti-Spam" "Success" "Inbound and outbound deployment completed."
            }
            'Anti-Malware' {
                if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-MalwareFilterPolicy' -Logger ${function:Log})) { throw "Anti-Malware cmdlets unavailable." }
                Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify
                Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom
                Add-Result "Anti-Malware" "Success" "Deployment completed."
            }
        }

        Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
        Clear-ShadowDfoCache
        Set-ShadowCardDeployed -Key $CategoryKey
        Set-ShadowModuleStatus -Status 'Completed' -Detail "$CategoryKey deployed."
        Add-Log "[OK] $CategoryKey deployment completed."
        Update-ShadowMetrics
        return $true
    }
    catch {
        Set-ShadowCardFailed -Key $CategoryKey
        Set-ShadowModuleStatus -Status 'Failed' -Detail "$CategoryKey failed."
        Add-Result $CategoryKey "Failed" $_.Exception.Message
        Add-Log "[ERR] $CategoryKey deployment failed: $($_.Exception.Message)"
        Update-ShadowMetrics
        return $false
    }
}

function Invoke-ShadowDeployAllCustomPoliciesFixed {
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying all custom catalog policies...'
        Add-Log "[INFO] Deploy All Custom Policies started."

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        $order = @('Anti-Phish','Safe Attachments','Safe Links','Inbound Spam','Anti-Malware')
        $success = 0
        $failed = 0

        foreach ($key in $order) {
            $result = Invoke-ShadowDeployCatalogPolicy -CategoryKey $key
            if ($result) { $success++ } else { $failed++ }
        }

        if ($failed -eq 0) {
            Set-ShadowCardDeployed -Key 'DeployAll' -Status 'Deployed'
            Set-ShadowModuleStatus -Status 'Completed' -Detail 'All custom policies deployed.'
            Add-Result "Deploy All Custom Policies" "Success" "Completed. Success: $success Failed: $failed"
            Add-Log "[OK] Deploy All Custom Policies completed. Success: $success Failed: $failed"
        }
        else {
            Set-ShadowCardFailed -Key 'DeployAll' -Message 'Needs Review'
            Set-ShadowModuleStatus -Status 'Warning' -Detail 'Deploy All completed with warnings.'
            Add-Result "Deploy All Custom Policies" "Warning" "Completed with issues. Success: $success Failed: $failed"
            Add-Log "[WARN] Deploy All completed with issues. Success: $success Failed: $failed"
        }

        Update-ShadowMetrics
    }
    catch {
        Set-ShadowCardFailed -Key 'DeployAll'
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Deploy All failed.'
        Add-Result "Deploy All Custom Policies" "Failed" $_.Exception.Message
        Add-Log "[ERR] Deploy All Custom Policies failed: $($_.Exception.Message)"
        Update-ShadowMetrics
    }
}


function ConvertTo-ShadowHtmlEncoded {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ShadowConfigValueString {
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [object]$Default = $null
    )
    try {
        $v = Get-ConfigValue -SectionName $Section -Key $Key -DefaultValue $Default
        if ($null -eq $v) { return "" }
        return [string]$v
    }
    catch {
        return ""
    }
}

function Get-ShadowDfoTenantPolicyState {
    try {
        $names = Get-NamesMap
        $state = New-Object System.Collections.Generic.List[object]

        $checks = @(
            @{ Area='Anti-Phishing'; Policy=$names.AntiPhishPolicy; Rule=$names.AntiPhishRule; PolicyCmd='Get-AntiPhishPolicy'; RuleCmd='Get-AntiPhishRule' },
            @{ Area='Safe Attachments'; Policy=$names.SafeAttachmentsPolicy; Rule=$names.SafeAttachmentsRule; PolicyCmd='Get-SafeAttachmentPolicy'; RuleCmd='Get-SafeAttachmentRule' },
            @{ Area='Safe Links'; Policy=$names.SafeLinksPolicy; Rule=$names.SafeLinksRule; PolicyCmd='Get-SafeLinksPolicy'; RuleCmd='Get-SafeLinksRule' },
            @{ Area='Inbound Anti-Spam'; Policy=$names.AntiSpamInboundPolicy; Rule=$names.AntiSpamInboundRule; PolicyCmd='Get-HostedContentFilterPolicy'; RuleCmd='Get-HostedContentFilterRule' },
            @{ Area='Outbound Anti-Spam'; Policy=$names.AntiSpamOutboundPolicy; Rule=$names.AntiSpamOutboundRule; PolicyCmd='Get-HostedOutboundSpamFilterPolicy'; RuleCmd='Get-HostedOutboundSpamFilterRule' },
            @{ Area='Anti-Malware'; Policy=$names.AntiMalwarePolicy; Rule=$names.AntiMalwareRule; PolicyCmd='Get-MalwareFilterPolicy'; RuleCmd='Get-MalwareFilterRule' }
        )

        foreach ($c in $checks) {
            $policyExists = $false
            $ruleExists = $false
            $ruleEnabled = "Unknown"
            $detail = ""

            try {
                if (Get-Command $c.PolicyCmd -ErrorAction SilentlyContinue) {
                    $p = & $c.PolicyCmd -Identity $c.Policy -ErrorAction SilentlyContinue
                    if ($p) { $policyExists = $true }
                }
                else {
                    $detail += "Policy cmdlet unavailable. "
                }
            } catch { $detail += "Policy lookup failed. " }

            try {
                if (Get-Command $c.RuleCmd -ErrorAction SilentlyContinue) {
                    $r = & $c.RuleCmd -Identity $c.Rule -ErrorAction SilentlyContinue
                    if ($r) {
                        $ruleExists = $true
                        if ($null -ne $r.State) { $ruleEnabled = [string]$r.State }
                        elseif ($null -ne $r.Enabled) { $ruleEnabled = [string]$r.Enabled }
                    }
                }
                else {
                    $detail += "Rule cmdlet unavailable. "
                }
            } catch { $detail += "Rule lookup failed. " }

            $status = "Ready to Deploy"
            if ($policyExists -and $ruleExists) { $status = "Deployed / Ready to Update" }
            elseif ($policyExists -and -not $ruleExists) { $status = "Policy Exists / Rule Missing" }

            $state.Add([pscustomobject]@{
                Area = $c.Area
                Policy = $c.Policy
                Rule = $c.Rule
                PolicyExists = $policyExists
                RuleExists = $ruleExists
                RuleState = $ruleEnabled
                Status = $status
                Detail = $detail.Trim()
            }) | Out-Null
        }

        return $state
    }
    catch {
        try { Add-Log "[WARN] Tenant policy state collection failed: $($_.Exception.Message)" } catch {}
        return @()
    }
}

function Get-ShadowDfoConfigAssessment {
    try {
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) {
            return @()
        }

        $items = New-Object System.Collections.Generic.List[object]

        $checks = @(
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='PhishThresholdLevel'; Strict='4'; Standard='2'; Recommendation='Use threshold 4 for stricter phishing protection; standard baseline remains 2.'; Weight=3 },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='EnableMailboxIntelligence'; Strict='True'; Standard='True'; Recommendation='Keep mailbox intelligence enabled.'; Weight=2 },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='EnableMailboxIntelligenceProtection'; Strict='True'; Standard='False'; Recommendation='Enable mailbox intelligence protection for stricter impersonation coverage.'; Weight=2 },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='EnableSpoofIntelligence'; Strict='True'; Standard='True'; Recommendation='Keep spoof intelligence enabled.'; Weight=2 },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='EnableTargetedUserProtection'; Strict='True'; Standard='False'; Recommendation='Enable targeted user protection for executives and high-risk users.'; Weight=2 },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; Key='EnableTargetedDomainsProtection'; Strict='True'; Standard='False'; Recommendation='Enable targeted domain protection for partner/vendor impersonation risk.'; Weight=2 },

            @{ Area='Safe Links'; Section='SafeLinks'; Key='EnableSafeLinksForEmail'; Strict='True'; Standard='True'; Recommendation='Enable Safe Links for email.'; Weight=3 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='EnableSafeLinksForTeams'; Strict='True'; Standard='True'; Recommendation='Enable Safe Links for Teams where licensed.'; Weight=2 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='EnableSafeLinksForOffice'; Strict='True'; Standard='True'; Recommendation='Enable Safe Links for Office apps where licensed.'; Weight=2 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='TrackClicks'; Strict='True'; Standard='True'; Recommendation='Track clicks for investigation and visibility.'; Weight=2 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='AllowClickThrough'; Strict='False'; Standard='False'; Recommendation='Keep click-through disabled for higher protection.'; Weight=3 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='ScanUrls'; Strict='True'; Standard='True'; Recommendation='Enable URL scanning.'; Weight=3 },
            @{ Area='Safe Links'; Section='SafeLinks'; Key='EnableForInternalSenders'; Strict='True'; Standard='False'; Recommendation='Consider enabling Safe Links for internal senders for lateral phishing protection.'; Weight=1 },

            @{ Area='Safe Attachments'; Section='SafeAttachments'; Key='Action'; Strict='Block'; Standard='DynamicDelivery'; Recommendation='Use Block for strict posture or Dynamic Delivery for standard productivity balance.'; Weight=3 },
            @{ Area='Safe Attachments'; Section='SafeAttachments'; Key='Redirect'; Strict='False'; Standard='False'; Recommendation='Avoid redirecting malicious attachments unless there is a monitored mailbox process.'; Weight=1 },
            @{ Area='Safe Attachments'; Section='SafeAttachments'; Key='EnableOrganizationBranding'; Strict='True'; Standard='True'; Recommendation='Use organization branding for user trust.'; Weight=1 },

            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; Key='HighConfidenceSpamAction'; Strict='Quarantine'; Standard='MoveToJmf'; Recommendation='Quarantine high confidence spam for stricter handling.'; Weight=2 },
            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; Key='HighConfidencePhishAction'; Strict='Quarantine'; Standard='Quarantine'; Recommendation='Quarantine high confidence phish.'; Weight=3 },
            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; Key='BulkSpamAction'; Strict='Quarantine'; Standard='MoveToJmf'; Recommendation='Consider quarantine for bulk spam in stricter baselines.'; Weight=1 },
            @{ Area='Anti-Spam Outbound'; Section='AntiSpamOutbound'; Key='AutoForwardingMode'; Strict='Off'; Standard='Automatic'; Recommendation='Disable automatic external forwarding for stricter data exfiltration control.'; Weight=3 },
            @{ Area='Anti-Spam Outbound'; Section='AntiSpamOutbound'; Key='ActionWhenThresholdReached'; Strict='BlockUser'; Standard='BlockUser'; Recommendation='Block users when outbound spam thresholds are reached.'; Weight=3 },

            @{ Area='Anti-Malware'; Section='AntiMalware'; Key='ZapEnabled'; Strict='True'; Standard='True'; Recommendation='Keep ZAP enabled for malware remediation.'; Weight=3 },
            @{ Area='Anti-Malware'; Section='AntiMalware'; Key='EnableFileFilter'; Strict='True'; Standard='True'; Recommendation='Enable file filtering for high-risk file types.'; Weight=2 },
            @{ Area='Anti-Malware'; Section='AntiMalware'; Key='Action'; Strict='DeleteMessage'; Standard='DeleteMessage'; Recommendation='Delete malware messages.'; Weight=3 }
        )

        foreach ($c in $checks) {
            $value = Get-ShadowConfigValueString -Section $c.Section -Key $c.Key
            $alignment = "Needs Review"
            $score = 0

            if ($value -eq [string]$c.Strict) {
                $alignment = "Strict"
                $score = [int]$c.Weight
            }
            elseif ($value -eq [string]$c.Standard) {
                $alignment = "Standard"
                $score = [Math]::Max(1, [int]([int]$c.Weight * 0.7))
            }

            $items.Add([pscustomobject]@{
                Area = $c.Area
                Section = $c.Section
                Setting = $c.Key
                CurrentValue = $value
                StandardValue = [string]$c.Standard
                StrictValue = [string]$c.Strict
                Alignment = $alignment
                Weight = [int]$c.Weight
                Score = $score
                Recommendation = $c.Recommendation
            }) | Out-Null
        }

        return $items
    }
    catch {
        try { Add-Log "[ERR] Config assessment failed: $($_.Exception.Message)" } catch {}
        return @()
    }
}

function Get-ShadowDfoSecureScoreAdvisor {
    try {
        $notes = New-Object System.Collections.Generic.List[string]

        if (Get-Command Get-MgSecuritySecureScore -ErrorAction SilentlyContinue) {
            try {
                $score = Get-MgSecuritySecureScore -Top 1 -ErrorAction Stop | Select-Object -First 1
                if ($score) {
                    $notes.Add("Microsoft Secure Score detected. Current score object was available through Graph; review Defender for Office 365 improvement actions in Microsoft Secure Score for tenant-specific recommendations.") | Out-Null
                }
            }
            catch {
                $notes.Add("Microsoft Graph Secure Score cmdlet was available, but Secure Score collection failed. Continue using setting-based recommendations in this report.") | Out-Null
            }
        }
        else {
            $notes.Add("Microsoft Secure Score was not queried because Graph Secure Score cmdlets are not loaded in this Exchange-focused deployment session. Recommendations below are based on deployed configuration and Microsoft-style Standard/Strict alignment checks.") | Out-Null
        }

        return $notes
    }
    catch {
        return @("Secure Score advisory unavailable. Recommendations are based on configuration posture.")
    }
}


function Get-ShadowDfoTenantPolicyObject {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$Identity
    )

    try {
        if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) { return $null }

        try {
            return (& $CommandName -Identity $Identity -ErrorAction Stop)
        }
        catch {
            try {
                return (& $CommandName -ErrorAction Stop | Where-Object { $_.Name -eq $Identity } | Select-Object -First 1)
            }
            catch {
                return $null
            }
        }
    }
    catch {
        return $null
    }
}

function Get-ShadowDfoTenantValue {
    param(
        [object]$Object,
        [string]$PropertyName
    )

    try {
        if ($null -eq $Object) { return "" }
        if ($Object.PSObject.Properties[$PropertyName]) {
            $v = $Object.PSObject.Properties[$PropertyName].Value
            if ($null -eq $v) { return "" }
            if ($v -is [array]) { return (($v | ForEach-Object { [string]$_ }) -join ", ") }
            return [string]$v
        }
        return ""
    }
    catch {
        return ""
    }
}

function Get-ShadowDfoTenantComparison {
    try {
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return @() }

        $names = Get-NamesMap
        $policyObjects = @{
            AntiPhish = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-AntiPhishPolicy' -Identity $names.AntiPhishPolicy
            SafeLinks = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeLinksPolicy' -Identity $names.SafeLinksPolicy
            SafeAttachments = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeAttachmentPolicy' -Identity $names.SafeAttachmentsPolicy
            AntiSpamInbound = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedContentFilterPolicy' -Identity $names.AntiSpamInboundPolicy
            AntiSpamOutbound = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedOutboundSpamFilterPolicy' -Identity $names.AntiSpamOutboundPolicy
            AntiMalware = Get-ShadowDfoTenantPolicyObject -CommandName 'Get-MalwareFilterPolicy' -Identity $names.AntiMalwarePolicy
        }

        $map = @(
            @{ Area='Anti-Phishing'; Section='AntiPhish'; TenantObject='AntiPhish'; ConfigKey='PhishThresholdLevel'; TenantProperty='PhishThresholdLevel' },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; TenantObject='AntiPhish'; ConfigKey='EnableMailboxIntelligence'; TenantProperty='EnableMailboxIntelligence' },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; TenantObject='AntiPhish'; ConfigKey='EnableMailboxIntelligenceProtection'; TenantProperty='EnableMailboxIntelligenceProtection' },
            @{ Area='Anti-Phishing'; Section='AntiPhish'; TenantObject='AntiPhish'; ConfigKey='EnableSpoofIntelligence'; TenantProperty='EnableSpoofIntelligence' },

            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='EnableSafeLinksForEmail'; TenantProperty='EnableSafeLinksForEmail' },
            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='EnableSafeLinksForTeams'; TenantProperty='EnableSafeLinksForTeams' },
            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='EnableSafeLinksForOffice'; TenantProperty='EnableSafeLinksForOffice' },
            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='TrackClicks'; TenantProperty='TrackClicks' },
            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='AllowClickThrough'; TenantProperty='AllowClickThrough' },
            @{ Area='Safe Links'; Section='SafeLinks'; TenantObject='SafeLinks'; ConfigKey='ScanUrls'; TenantProperty='ScanUrls' },

            @{ Area='Safe Attachments'; Section='SafeAttachments'; TenantObject='SafeAttachments'; ConfigKey='Action'; TenantProperty='Action' },
            @{ Area='Safe Attachments'; Section='SafeAttachments'; TenantObject='SafeAttachments'; ConfigKey='Redirect'; TenantProperty='Redirect' },

            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; TenantObject='AntiSpamInbound'; ConfigKey='SpamAction'; TenantProperty='SpamAction' },
            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; TenantObject='AntiSpamInbound'; ConfigKey='HighConfidenceSpamAction'; TenantProperty='HighConfidenceSpamAction' },
            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; TenantObject='AntiSpamInbound'; ConfigKey='HighConfidencePhishAction'; TenantProperty='HighConfidencePhishAction' },
            @{ Area='Anti-Spam Inbound'; Section='AntiSpamInbound'; TenantObject='AntiSpamInbound'; ConfigKey='BulkSpamAction'; TenantProperty='BulkSpamAction' },

            @{ Area='Anti-Spam Outbound'; Section='AntiSpamOutbound'; TenantObject='AntiSpamOutbound'; ConfigKey='AutoForwardingMode'; TenantProperty='AutoForwardingMode' },
            @{ Area='Anti-Spam Outbound'; Section='AntiSpamOutbound'; TenantObject='AntiSpamOutbound'; ConfigKey='ActionWhenThresholdReached'; TenantProperty='ActionWhenThresholdReached' },

            @{ Area='Anti-Malware'; Section='AntiMalware'; TenantObject='AntiMalware'; ConfigKey='ZapEnabled'; TenantProperty='ZapEnabled' },
            @{ Area='Anti-Malware'; Section='AntiMalware'; TenantObject='AntiMalware'; ConfigKey='EnableFileFilter'; TenantProperty='EnableFileFilter' },
            @{ Area='Anti-Malware'; Section='AntiMalware'; TenantObject='AntiMalware'; ConfigKey='Action'; TenantProperty='Action' }
        )

        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($m in $map) {
            $desired = Get-ShadowConfigValueString -Section $m.Section -Key $m.ConfigKey
            $tenantObj = $policyObjects[$m.TenantObject]
            $current = Get-ShadowDfoTenantValue -Object $tenantObj -PropertyName $m.TenantProperty

            $status = "Not Found"
            if ($tenantObj) {
                if ([string]::IsNullOrWhiteSpace($desired) -and [string]::IsNullOrWhiteSpace($current)) {
                    $status = "No Value"
                }
                elseif ([string]$desired -eq [string]$current) {
                    $status = "Match"
                }
                else {
                    $status = "Drift"
                }
            }

            $rows.Add([pscustomobject]@{
                Area=$m.Area
                Section=$m.Section
                Setting=$m.ConfigKey
                DesiredValue=$desired
                TenantValue=$current
                Status=$status
            }) | Out-Null
        }

        return $rows
    }
    catch {
        try { Add-Log "[WARN] Tenant comparison failed: $($_.Exception.Message)" } catch {}
        return @()
    }
}


function ConvertTo-ShadowDfoPropertyRows {
    param(
        [Parameter(Mandatory)][string]$Area,
        [object]$Object
    )

    $rows = New-Object System.Collections.Generic.List[object]

    if ($null -eq $Object) {
        $rows.Add([pscustomobject]@{
            Area=$Area
            Property='PolicyObject'
            Value='Not found or unavailable'
        }) | Out-Null
        return $rows
    }

    $skip = @(
        'RunspaceId','ObjectState','IsValid','ExchangeVersion','DistinguishedName',
        'Guid','Identity','Id','OriginatingServer','WhenChangedUTC','WhenCreatedUTC'
    )

    foreach ($p in ($Object.PSObject.Properties | Sort-Object Name)) {
        if ($skip -contains $p.Name) { continue }

        $value = $p.Value
        if ($null -eq $value) { $value = '' }
        elseif ($value -is [array]) { $value = (($value | ForEach-Object { [string]$_ }) -join ', ') }
        else { $value = [string]$value }

        if ($value.Length -gt 500) {
            $value = $value.Substring(0,500) + '...'
        }

        $rows.Add([pscustomobject]@{
            Area=$Area
            Property=$p.Name
            Value=$value
        }) | Out-Null
    }

    return $rows
}

function Get-ShadowDfoActualTenantConfiguration {
    try {
        $names = Get-NamesMap

        $objects = @(
            @{ Area='Anti-Phishing Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-AntiPhishPolicy' -Identity $names.AntiPhishPolicy) },
            @{ Area='Anti-Phishing Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-AntiPhishRule' -Identity $names.AntiPhishRule) },

            @{ Area='Safe Links Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeLinksPolicy' -Identity $names.SafeLinksPolicy) },
            @{ Area='Safe Links Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeLinksRule' -Identity $names.SafeLinksRule) },

            @{ Area='Safe Attachments Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeAttachmentPolicy' -Identity $names.SafeAttachmentsPolicy) },
            @{ Area='Safe Attachments Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-SafeAttachmentRule' -Identity $names.SafeAttachmentsRule) },

            @{ Area='Inbound Anti-Spam Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedContentFilterPolicy' -Identity $names.AntiSpamInboundPolicy) },
            @{ Area='Inbound Anti-Spam Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedContentFilterRule' -Identity $names.AntiSpamInboundRule) },

            @{ Area='Outbound Anti-Spam Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedOutboundSpamFilterPolicy' -Identity $names.AntiSpamOutboundPolicy) },
            @{ Area='Outbound Anti-Spam Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-HostedOutboundSpamFilterRule' -Identity $names.AntiSpamOutboundRule) },

            @{ Area='Anti-Malware Policy'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-MalwareFilterPolicy' -Identity $names.AntiMalwarePolicy) },
            @{ Area='Anti-Malware Rule'; Object=(Get-ShadowDfoTenantPolicyObject -CommandName 'Get-MalwareFilterRule' -Identity $names.AntiMalwareRule) }
        )

        $allRows = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $objects) {
            $rows = ConvertTo-ShadowDfoPropertyRows -Area $entry.Area -Object $entry.Object
            foreach ($r in $rows) { $allRows.Add($r) | Out-Null }
        }

        return $allRows
    }
    catch {
        try { Add-Log "[WARN] Actual tenant configuration collection failed: $($_.Exception.Message)" } catch {}
        return @([pscustomobject]@{ Area='Tenant Configuration'; Property='Collection'; Value="Failed: $($_.Exception.Message)" })
    }
}


function ConvertTo-ShadowDfoDisplayValue {
    param([object]$Value)

    try {
        if ($null -eq $Value) { return "" }
        if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ", ") }
        if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
            $vals = @()
            foreach ($v in $Value) { $vals += [string]$v }
            return ($vals -join ", ")
        }
        return [string]$Value
    }
    catch {
        return ""
    }
}

function Get-ShadowDfoConfigValueForReport {
    param(
        [string]$Section,
        [string]$Key
    )

    try {
        return (Get-ShadowConfigValueString -Section $Section -Key $Key)
    }
    catch {
        return ""
    }
}

function Get-ShadowDfoPolicyPropertyRows {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$ObjectType,
        [object]$TenantObject,
        [object]$DefaultObject = $null,
        [array]$Mappings = @()
    )

    $rows = New-Object System.Collections.Generic.List[object]

    if ($null -eq $TenantObject) {
        $rows.Add([pscustomobject]@{
            Area=$Area
            ObjectType=$ObjectType
            Setting="Policy object"
            Desired=""
            Current="Not found or unavailable"
            DefaultValue=""
            Status="Not Found"
            Recommendation="Confirm the policy/rule exists or run deployment."
            Source="Tenant"
        }) | Out-Null
        return @($rows)
    }

    foreach ($m in @($Mappings)) {
        $current = ""
        $default = ""

        try {
            if ($TenantObject.PSObject.Properties[$m.TenantProperty]) {
                $current = ConvertTo-ShadowDfoDisplayValue -Value $TenantObject.PSObject.Properties[$m.TenantProperty].Value
            }
        } catch {}

        try {
            if ($DefaultObject -and $DefaultObject.PSObject.Properties[$m.TenantProperty]) {
                $default = ConvertTo-ShadowDfoDisplayValue -Value $DefaultObject.PSObject.Properties[$m.TenantProperty].Value
            }
        } catch {}

        $desired = ""
        if ($m.Section -and $m.ConfigKey) {
            $desired = Get-ShadowDfoConfigValueForReport -Section $m.Section -Key $m.ConfigKey
        }

        $status = "Observed"
        if (-not [string]::IsNullOrWhiteSpace($desired)) {
            if ([string]$desired -eq [string]$current) { $status = "Match" }
            else { $status = "Drift" }
        }

        $rows.Add([pscustomobject]@{
            Area=$Area
            ObjectType=$ObjectType
            Setting=[string]$m.Label
            Desired=[string]$desired
            Current=[string]$current
            DefaultValue=[string]$default
            Status=[string]$status
            Recommendation=if ($status -eq "Drift") { "Review tenant value against JSON deployment intent." } else { "" }
            Source="Mapped"
        }) | Out-Null
    }

    $skip = @(
        'RunspaceId','ObjectState','IsValid','ExchangeVersion','DistinguishedName',
        'Guid','Identity','Id','OriginatingServer','WhenChangedUTC','WhenCreatedUTC',
        'PSComputerName','PSShowComputerName'
    )

    $already = @{}
    foreach ($m in @($Mappings)) {
        if ($m.TenantProperty) { $already[[string]$m.TenantProperty] = $true }
    }

    foreach ($p in @($TenantObject.PSObject.Properties | Sort-Object Name)) {
        if ($skip -contains $p.Name) { continue }
        if ($already.ContainsKey($p.Name)) { continue }

        $value = ""
        try { $value = ConvertTo-ShadowDfoDisplayValue -Value $p.Value } catch {}
        if ($value.Length -gt 700) { $value = $value.Substring(0,700) + "..." }

        $rows.Add([pscustomobject]@{
            Area=$Area
            ObjectType=$ObjectType
            Setting=[string]$p.Name
            Desired=""
            Current=[string]$value
            DefaultValue=""
            Status="Observed"
            Recommendation=""
            Source="Actual"
        }) | Out-Null
    }

    return @($rows)
}

function Get-ShadowDfoLiveThreatPolicyReportData {
    try {
        $names = Get-NamesMap

        $definitions = @(
            [pscustomobject]@{
                Area='Anti-Phishing'
                PolicyCommand='Get-AntiPhishPolicy'
                DefaultPolicyCommand='Get-AntiPhishPolicy'
                RuleCommand='Get-AntiPhishRule'
                PolicyIdentity=$names.AntiPhishPolicy
                RuleIdentity=$names.AntiPhishRule
                Mappings=@(
                    @{ Label='Phish threshold level'; Section='AntiPhish'; ConfigKey='PhishThresholdLevel'; TenantProperty='PhishThresholdLevel' },
                    @{ Label='Mailbox intelligence'; Section='AntiPhish'; ConfigKey='EnableMailboxIntelligence'; TenantProperty='EnableMailboxIntelligence' },
                    @{ Label='Mailbox intelligence protection'; Section='AntiPhish'; ConfigKey='EnableMailboxIntelligenceProtection'; TenantProperty='EnableMailboxIntelligenceProtection' },
                    @{ Label='Spoof intelligence'; Section='AntiPhish'; ConfigKey='EnableSpoofIntelligence'; TenantProperty='EnableSpoofIntelligence' },
                    @{ Label='Targeted user protection'; Section='AntiPhish'; ConfigKey='EnableTargetedUserProtection'; TenantProperty='EnableTargetedUserProtection' },
                    @{ Label='Targeted domain protection'; Section='AntiPhish'; ConfigKey='EnableTargetedDomainsProtection'; TenantProperty='EnableTargetedDomainsProtection' },
                    @{ Label='Honor DMARC policy'; Section='AntiPhish'; ConfigKey='HonorDmarcPolicy'; TenantProperty='HonorDmarcPolicy' }
                )
            }
            [pscustomobject]@{
                Area='Safe Links'
                PolicyCommand='Get-SafeLinksPolicy'
                DefaultPolicyCommand='Get-SafeLinksPolicy'
                RuleCommand='Get-SafeLinksRule'
                PolicyIdentity=$names.SafeLinksPolicy
                RuleIdentity=$names.SafeLinksRule
                Mappings=@(
                    @{ Label='Safe Links for email'; Section='SafeLinks'; ConfigKey='EnableSafeLinksForEmail'; TenantProperty='EnableSafeLinksForEmail' },
                    @{ Label='Safe Links for Teams'; Section='SafeLinks'; ConfigKey='EnableSafeLinksForTeams'; TenantProperty='EnableSafeLinksForTeams' },
                    @{ Label='Safe Links for Office'; Section='SafeLinks'; ConfigKey='EnableSafeLinksForOffice'; TenantProperty='EnableSafeLinksForOffice' },
                    @{ Label='Track clicks'; Section='SafeLinks'; ConfigKey='TrackClicks'; TenantProperty='TrackClicks' },
                    @{ Label='Allow click through'; Section='SafeLinks'; ConfigKey='AllowClickThrough'; TenantProperty='AllowClickThrough' },
                    @{ Label='Scan URLs'; Section='SafeLinks'; ConfigKey='ScanUrls'; TenantProperty='ScanUrls' },
                    @{ Label='Enable internal senders'; Section='SafeLinks'; ConfigKey='EnableForInternalSenders'; TenantProperty='EnableForInternalSenders' },
                    @{ Label='Disable URL rewrite'; Section='SafeLinks'; ConfigKey='DisableUrlRewrite'; TenantProperty='DisableUrlRewrite' }
                )
            }
            [pscustomobject]@{
                Area='Safe Attachments'
                PolicyCommand='Get-SafeAttachmentPolicy'
                DefaultPolicyCommand='Get-SafeAttachmentPolicy'
                RuleCommand='Get-SafeAttachmentRule'
                PolicyIdentity=$names.SafeAttachmentsPolicy
                RuleIdentity=$names.SafeAttachmentsRule
                Mappings=@(
                    @{ Label='Attachment action'; Section='SafeAttachments'; ConfigKey='Action'; TenantProperty='Action' },
                    @{ Label='Redirect'; Section='SafeAttachments'; ConfigKey='Redirect'; TenantProperty='Redirect' },
                    @{ Label='Quarantine tag'; Section='SafeAttachments'; ConfigKey='QuarantineTag'; TenantProperty='QuarantineTag' },
                    @{ Label='Organization branding'; Section='SafeAttachments'; ConfigKey='EnableOrganizationBranding'; TenantProperty='EnableOrganizationBranding' }
                )
            }
            [pscustomobject]@{
                Area='Inbound Anti-Spam'
                PolicyCommand='Get-HostedContentFilterPolicy'
                DefaultPolicyCommand='Get-HostedContentFilterPolicy'
                RuleCommand='Get-HostedContentFilterRule'
                PolicyIdentity=$names.AntiSpamInboundPolicy
                RuleIdentity=$names.AntiSpamInboundRule
                Mappings=@(
                    @{ Label='Spam action'; Section='AntiSpamInbound'; ConfigKey='SpamAction'; TenantProperty='SpamAction' },
                    @{ Label='High confidence spam action'; Section='AntiSpamInbound'; ConfigKey='HighConfidenceSpamAction'; TenantProperty='HighConfidenceSpamAction' },
                    @{ Label='Phish spam action'; Section='AntiSpamInbound'; ConfigKey='PhishSpamAction'; TenantProperty='PhishSpamAction' },
                    @{ Label='High confidence phish action'; Section='AntiSpamInbound'; ConfigKey='HighConfidencePhishAction'; TenantProperty='HighConfidencePhishAction' },
                    @{ Label='Bulk spam action'; Section='AntiSpamInbound'; ConfigKey='BulkSpamAction'; TenantProperty='BulkSpamAction' },
                    @{ Label='ZAP enabled'; Section='AntiSpamInbound'; ConfigKey='ZapEnabled'; TenantProperty='ZapEnabled' }
                )
            }
            [pscustomobject]@{
                Area='Outbound Anti-Spam'
                PolicyCommand='Get-HostedOutboundSpamFilterPolicy'
                DefaultPolicyCommand='Get-HostedOutboundSpamFilterPolicy'
                RuleCommand='Get-HostedOutboundSpamFilterRule'
                PolicyIdentity=$names.AntiSpamOutboundPolicy
                RuleIdentity=$names.AntiSpamOutboundRule
                Mappings=@(
                    @{ Label='Auto forwarding mode'; Section='AntiSpamOutbound'; ConfigKey='AutoForwardingMode'; TenantProperty='AutoForwardingMode' },
                    @{ Label='Action when threshold reached'; Section='AntiSpamOutbound'; ConfigKey='ActionWhenThresholdReached'; TenantProperty='ActionWhenThresholdReached' },
                    @{ Label='Notify outbound spam'; Section='AntiSpamOutbound'; ConfigKey='NotifyOutboundSpam'; TenantProperty='NotifyOutboundSpam' },
                    @{ Label='External hourly recipient limit'; Section='AntiSpamOutbound'; ConfigKey='RecipientLimitExternalPerHour'; TenantProperty='RecipientLimitExternalPerHour' },
                    @{ Label='Internal hourly recipient limit'; Section='AntiSpamOutbound'; ConfigKey='RecipientLimitInternalPerHour'; TenantProperty='RecipientLimitInternalPerHour' },
                    @{ Label='Daily recipient limit'; Section='AntiSpamOutbound'; ConfigKey='RecipientLimitPerDay'; TenantProperty='RecipientLimitPerDay' }
                )
            }
            [pscustomobject]@{
                Area='Anti-Malware'
                PolicyCommand='Get-MalwareFilterPolicy'
                DefaultPolicyCommand='Get-MalwareFilterPolicy'
                RuleCommand='Get-MalwareFilterRule'
                PolicyIdentity=$names.AntiMalwarePolicy
                RuleIdentity=$names.AntiMalwareRule
                Mappings=@(
                    @{ Label='ZAP enabled'; Section='AntiMalware'; ConfigKey='ZapEnabled'; TenantProperty='ZapEnabled' },
                    @{ Label='File filter enabled'; Section='AntiMalware'; ConfigKey='EnableFileFilter'; TenantProperty='EnableFileFilter' },
                    @{ Label='Malware action'; Section='AntiMalware'; ConfigKey='Action'; TenantProperty='Action' },
                    @{ Label='Internal sender admin notifications'; Section='AntiMalware'; ConfigKey='EnableInternalSenderAdminNotifications'; TenantProperty='EnableInternalSenderAdminNotifications' },
                    @{ Label='External sender admin notifications'; Section='AntiMalware'; ConfigKey='EnableExternalSenderAdminNotifications'; TenantProperty='EnableExternalSenderAdminNotifications' }
                )
            }
        )

        $areas = New-Object System.Collections.Generic.List[object]
        $allRows = New-Object System.Collections.Generic.List[object]

        foreach ($def in $definitions) {
            $policy = Get-ShadowDfoTenantPolicyObject -CommandName $def.PolicyCommand -Identity $def.PolicyIdentity
            $rule = Get-ShadowDfoTenantPolicyObject -CommandName $def.RuleCommand -Identity $def.RuleIdentity
            $defaultPolicy = Get-ShadowDfoDefaultPolicyObject -CommandName $def.DefaultPolicyCommand

            $policyRows = @(Get-ShadowDfoPolicyPropertyRows -Area $def.Area -ObjectType 'Policy' -TenantObject $policy -DefaultObject $defaultPolicy -Mappings $def.Mappings)

            $ruleRows = @(Get-ShadowDfoPolicyPropertyRows -Area $def.Area -ObjectType 'Rule' -TenantObject $rule -Mappings @(
                @{ Label='Rule state'; Section=''; ConfigKey=''; TenantProperty='State' },
                @{ Label='Rule priority'; Section=''; ConfigKey=''; TenantProperty='Priority' },
                @{ Label='Recipient domains'; Section=''; ConfigKey=''; TenantProperty='RecipientDomainIs' },
                @{ Label='Sender domains'; Section=''; ConfigKey=''; TenantProperty='SenderDomainIs' }
            ))

            foreach ($r in @($policyRows)) { $allRows.Add($r) | Out-Null }
            foreach ($r in @($ruleRows)) { $allRows.Add($r) | Out-Null }

            $mapped = @($policyRows | Where-Object { $_.Source -eq 'Mapped' })
            $drift = @($mapped | Where-Object { $_.Status -eq 'Drift' }).Count
            $match = @($mapped | Where-Object { $_.Status -eq 'Match' }).Count
            $combinedRows = @($policyRows) + @($ruleRows)
            $observed = @($combinedRows).Count

            $areas.Add([pscustomobject]@{
                Area=$def.Area
                PolicyFound=[bool]$policy
                RuleFound=[bool]$rule
                MatchCount=$match
                DriftCount=$drift
                ObservedCount=$observed
                Rows=@($combinedRows)
            }) | Out-Null
        }

        return [pscustomobject]@{
            Areas=$areas
            Rows=$allRows
            Generated=Get-Date
        }
    }
    catch {
        try { Add-Log "[WARN] Live threat policy report collection failed: $($_.Exception.Message)" } catch {}
        return [pscustomobject]@{ Areas=@(); Rows=@(); Generated=Get-Date }
    }
}

function New-ShadowDfoLivePolicySectionsHtml {
    param([array]$Areas)

    $sb = New-Object System.Text.StringBuilder

    foreach ($area in $Areas) {
        $statusClass = if ($area.PolicyFound -and $area.RuleFound) { "strict" } elseif ($area.PolicyFound) { "standard" } else { "review" }
        $statusText = if ($area.PolicyFound -and $area.RuleFound) { "Policy and rule found" } elseif ($area.PolicyFound) { "Policy found / rule missing" } else { "Policy not found" }

        [void]$sb.AppendLine("<section class='card policy-section'>")
        [void]$sb.AppendLine("<h2>$(ConvertTo-ShadowHtmlEncoded $area.Area)</h2>")
        [void]$sb.AppendLine("<div class='summary-line'><span class='pill $statusClass'>$statusText</span><span class='badge'>Matches: <strong>$($area.MatchCount)</strong></span><span class='badge'>Drift: <strong>$($area.DriftCount)</strong></span><span class='badge'>Settings observed: <strong>$($area.ObservedCount)</strong></span></div>")
        [void]$sb.AppendLine("<table>")
        [void]$sb.AppendLine("<tr><th>Object</th><th>Setting</th><th>Default Tenant</th><th>Shadow Deploy Policy</th><th>JSON Intent</th><th>Status</th><th>Recommendation</th></tr>")

        foreach ($row in @($area.Rows)) {
            $cls = "info"
            if ($row.Status -eq "Match") { $cls = "strict" }
            elseif ($row.Status -eq "Drift" -or $row.Status -eq "Not Found") { $cls = "review" }

            $defaultValue = ""
            try { $defaultValue = [string]$row.DefaultValue } catch {}

            [void]$sb.AppendLine("<tr><td>$(ConvertTo-ShadowHtmlEncoded $row.ObjectType)</td><td>$(ConvertTo-ShadowHtmlEncoded $row.Setting)</td><td>$(ConvertTo-ShadowHtmlEncoded $defaultValue)</td><td>$(ConvertTo-ShadowHtmlEncoded $row.Current)</td><td>$(ConvertTo-ShadowHtmlEncoded $row.Desired)</td><td><span class='pill $cls'>$(ConvertTo-ShadowHtmlEncoded $row.Status)</span></td><td>$(ConvertTo-ShadowHtmlEncoded $row.Recommendation)</td></tr>")
        }

        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("</section>")
    }

    return $sb.ToString()
}


function Get-ShadowDfoBusinessFriendlySettingName {
    param([string]$Setting)
    switch -Regex ($Setting) {
        'PhishThreshold|Threshold' { return 'Increase phishing detection sensitivity' }
        'MailboxIntelligence|Impersonation|TargetedUser|TargetedDomain|Spoof' { return 'Harden impersonation and spoof protection' }
        'Safe Links|SafeLinks|URL|Click|ScanUrls' { return 'Strengthen malicious link protection' }
        'Safe Attach|Attachment|Malware|FileFilter|Zap' { return 'Strengthen malware and attachment protection' }
        'Spam|Bulk|Forwarding|Outbound' { return 'Improve spam and outbound abuse controls' }
        default { return $Setting }
    }
}

function Get-ShadowDfoMaturityLevel {
    param([int]$Score)
    if ($Score -ge 95) { return [pscustomobject]@{ Level='Shadow Suite Hardened'; Class='tier-purple'; Next='Maintain and monitor' } }
    elseif ($Score -ge 85) { return [pscustomobject]@{ Level='Microsoft Strict'; Class='tier-blue'; Next='Shadow Suite Hardened' } }
    elseif ($Score -ge 70) { return [pscustomobject]@{ Level='Microsoft Standard'; Class='tier-green'; Next='Microsoft Strict' } }
    else { return [pscustomobject]@{ Level='Default / Basic'; Class='tier-yellow'; Next='Microsoft Standard' } }
}

function Export-ShadowDfoHtmlReport {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return $null }

        Add-Log "[INFO] Generating Shadow Deploy for Defender for Office 365 V1.4 Executive Posture Report. This may take a few seconds..."

        $assessment = @(Get-ShadowDfoConfigAssessment)
        $tenantState = @(Get-ShadowDfoTenantPolicyState)
        $livePolicyData = Get-ShadowDfoLiveThreatPolicyReportData
        $secureScoreNotes = @(Get-ShadowDfoSecureScoreAdvisor)

        $totalWeight = [Math]::Max(1, ($assessment | Measure-Object -Property Weight -Sum).Sum)
        $score = ($assessment | Measure-Object -Property Score -Sum).Sum
        $scorePct = [int][Math]::Round(($score / $totalWeight) * 100, 0)
        $scorePctCss = [int][Math]::Max(0, [Math]::Min(100, [int]$scorePct))

        $strictCount = @($assessment | Where-Object { $_.Alignment -eq 'Strict' }).Count
        $standardCount = @($assessment | Where-Object { $_.Alignment -eq 'Standard' }).Count
        $reviewCount = @($assessment | Where-Object { $_.Alignment -eq 'Needs Review' }).Count
        $matchCount = @($livePolicyData.Rows | Where-Object { $_.Status -eq 'Match' }).Count
        $driftCount = @($livePolicyData.Rows | Where-Object { $_.Status -eq 'Drift' }).Count
        $notFoundCount = @($livePolicyData.Rows | Where-Object { $_.Status -eq 'Not Found' }).Count
        $policyDeployedCount = @($livePolicyData.Areas | Where-Object { $_.PolicyFound -and $_.RuleFound }).Count
        $policyMissingCount = @($livePolicyData.Areas | Where-Object { -not $_.PolicyFound -or -not $_.RuleFound }).Count
        $policiesAssessed = @($livePolicyData.Areas).Count

        $criticalGaps = [int]$notFoundCount
        $highGaps = [int]$driftCount
        $mediumGaps = [int]$reviewCount

        $maturity = Get-ShadowDfoMaturityLevel -Score $scorePct
        $overall = $maturity.Level
        $nextLevel = $maturity.Next

        $strictImprovement = [int][Math]::Max(0, (95 - [int]$scorePct))
        $standardImprovement = [int][Math]::Max(0, (70 - [int]$scorePct))
        $jsonImprovement = [int][Math]::Max(0, (90 - [int]$scorePct))

        $generated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $tenant = "Unavailable"
        $account = "Unavailable"
        try { $tenant = Get-TenantDisplayName } catch {}
        try { $account = Get-ConnectedUserPrincipalName } catch {}

        $tenantRows = New-Object System.Text.StringBuilder
        foreach ($t in $tenantState) {
            $cls = "info"
            if ($t.Status -match "Deployed|Ready to Update") { $cls = "strict" }
            elseif ($t.Status -match "Missing|Ready to Deploy|Rule Missing") { $cls = "review" }
            [void]$tenantRows.AppendLine("<tr><td>$(ConvertTo-ShadowHtmlEncoded $t.Area)</td><td>$(ConvertTo-ShadowHtmlEncoded $t.Policy)</td><td>$(ConvertTo-ShadowHtmlEncoded $t.Rule)</td><td><span class='pill $cls'>$(ConvertTo-ShadowHtmlEncoded $t.Status)</span></td><td>$(ConvertTo-ShadowHtmlEncoded $t.RuleState)</td></tr>")
        }

        $policySections = New-ShadowDfoLivePolicySectionsHtml -Areas $livePolicyData.Areas

        $rows = New-Object System.Text.StringBuilder
        foreach ($a in $assessment) {
            $cls = "review"
            if ($a.Alignment -eq "Strict") { $cls = "strict" }
            elseif ($a.Alignment -eq "Standard") { $cls = "standard" }
            [void]$rows.AppendLine("<tr><td>$(ConvertTo-ShadowHtmlEncoded $a.Area)</td><td>$(ConvertTo-ShadowHtmlEncoded $a.Section)</td><td>$(ConvertTo-ShadowHtmlEncoded $a.Setting)</td><td>$(ConvertTo-ShadowHtmlEncoded $a.CurrentValue)</td><td>$(ConvertTo-ShadowHtmlEncoded $a.StandardValue)</td><td>$(ConvertTo-ShadowHtmlEncoded $a.StrictValue)</td><td><span class='pill $cls'>$(ConvertTo-ShadowHtmlEncoded $a.Alignment)</span></td></tr>")
        }

        $heatRows = New-Object System.Text.StringBuilder

        foreach ($area in @($livePolicyData.Areas)) {
            $areaMapped = @($area.Rows | Where-Object { $_.Source -eq 'Mapped' })
            if (@($areaMapped).Count -gt 0) {
                $areaTotal = [Math]::Max(1, @($areaMapped).Count)
                $areaMatches = @($areaMapped | Where-Object { $_.Status -eq 'Match' }).Count
                $areaPct = [int][Math]::Round(($areaMatches / $areaTotal) * 100, 0)
                $barClass = if ($areaPct -ge 85) { "bar-good" } elseif ($areaPct -ge 70) { "bar-warn" } else { "bar-bad" }
                [void]$heatRows.AppendLine("<div class='heat-row'><span>$(ConvertTo-ShadowHtmlEncoded $area.Area)</span><div class='heat-bar'><div class='$barClass' style='width:$areaPct%'></div></div><strong>$areaPct%</strong></div>")
            }
        }

        # Fallback: if live mapped rows were unavailable, build the heat map from Standard/Strict assessment data.
        if ($heatRows.Length -eq 0) {
            $assessmentAreas = @($assessment | Group-Object Area)
            foreach ($grp in $assessmentAreas) {
                $areaName = [string]$grp.Name
                $items = @($grp.Group)
                $areaTotal = [Math]::Max(1, $items.Count)
                $areaAligned = @($items | Where-Object { $_.Alignment -eq 'Strict' -or $_.Alignment -eq 'Standard' }).Count
                $areaPct = [int][Math]::Round(($areaAligned / $areaTotal) * 100, 0)
                $barClass = if ($areaPct -ge 85) { "bar-good" } elseif ($areaPct -ge 70) { "bar-warn" } else { "bar-bad" }
                [void]$heatRows.AppendLine("<div class='heat-row'><span>$(ConvertTo-ShadowHtmlEncoded $areaName)</span><div class='heat-bar'><div class='$barClass' style='width:$areaPct%'></div></div><strong>$areaPct%</strong></div>")
            }
        }

        if ($heatRows.Length -eq 0) {
            [void]$heatRows.AppendLine("<div class='heat-row'><span>No heat map data</span><div class='heat-bar'><div class='bar-bad' style='width:0%'></div></div><strong>0%</strong></div>")
        }

        $ztEmail = if ($scorePct -ge 80) { "Good" } elseif ($scorePct -ge 65) { "Moderate" } else { "Needs Improvement" }
        $ztUrl = if (@($livePolicyData.Rows | Where-Object { $_.Area -match 'Safe Links' -and $_.Status -eq 'Match' }).Count -ge 3) { "Good" } else { "Needs Improvement" }
        $ztAttach = if (@($livePolicyData.Rows | Where-Object { $_.Area -match 'Safe Attachments|Anti-Malware' -and $_.Status -eq 'Match' }).Count -ge 2) { "Good" } else { "Moderate" }
        $ztImpersonation = if (@($livePolicyData.Rows | Where-Object { $_.Area -match 'Anti-Phishing' -and $_.Status -eq 'Match' }).Count -ge 4) { "Good" } else { "Needs Improvement" }
        $ztAutomation = if ($scorePct -ge 85) { "Good" } else { "Needs Improvement" }

        function New-ZtRowHtml {
            param([string]$Name,[string]$Value)
            $cls = if ($Value -eq 'Good') { 'strict' } elseif ($Value -eq 'Moderate') { 'review' } else { 'bad' }
            return "<div class='zt-row'><span>$Name</span><span class='pill $cls'>$Value</span></div>"
        }

        $ztRows = @(
            New-ZtRowHtml -Name 'Email Threat Protection' -Value $ztEmail
            New-ZtRowHtml -Name 'URL Protection' -Value $ztUrl
            New-ZtRowHtml -Name 'Attachment & Malware Protection' -Value $ztAttach
            New-ZtRowHtml -Name 'Anti-Impersonation' -Value $ztImpersonation
            New-ZtRowHtml -Name 'Automation & Response' -Value $ztAutomation
        ) -join "`n"

        $recItems = New-Object System.Text.StringBuilder
        $topItems = New-Object System.Text.StringBuilder
        $rank = 1

        foreach ($d in ($livePolicyData.Rows | Where-Object { $_.Status -eq 'Drift' } | Select-Object -First 10)) {
            $defVal = ""
            try { if ($d.PSObject.Properties['DefaultValue']) { $defVal = [string]$d.DefaultValue } } catch {}
            $friendly = Get-ShadowDfoBusinessFriendlySettingName -Setting ([string]$d.Setting)
            [void]$recItems.AppendLine("<div class='recommendation high'><div class='rec-title'>High Priority — Tenant drift</div><div><strong>$(ConvertTo-ShadowHtmlEncoded $friendly)</strong></div><div class='muted'>Technical setting: $(ConvertTo-ShadowHtmlEncoded $d.Area) / $(ConvertTo-ShadowHtmlEncoded $d.Setting)</div><div class='muted'>Default: $(ConvertTo-ShadowHtmlEncoded $defVal) | Current: $(ConvertTo-ShadowHtmlEncoded $d.Current) | JSON target: $(ConvertTo-ShadowHtmlEncoded $d.Desired)</div><div class='business-impact'>Business impact: Reduces exposure to phishing, impersonation, malware delivery, or unwanted mail flow depending on the setting.</div></div>")
            if ($rank -le 5) {
                [void]$topItems.AppendLine("<div class='top-item'><span>$rank</span><div><strong>$(ConvertTo-ShadowHtmlEncoded $friendly)</strong><br><em>$(ConvertTo-ShadowHtmlEncoded $d.Area)</em></div></div>")
                $rank++
            }
        }

        foreach ($r in ($assessment | Where-Object { $_.Alignment -eq 'Needs Review' } | Select-Object -First 8)) {
            $friendly = Get-ShadowDfoBusinessFriendlySettingName -Setting ([string]$r.Setting)
            [void]$recItems.AppendLine("<div class='recommendation medium'><div class='rec-title'>Medium Priority — Configuration tuning</div><div><strong>$(ConvertTo-ShadowHtmlEncoded $friendly)</strong></div><div class='muted'>Technical setting: $(ConvertTo-ShadowHtmlEncoded $r.Area) / $(ConvertTo-ShadowHtmlEncoded $r.Setting)</div><div class='muted'>Current JSON: $(ConvertTo-ShadowHtmlEncoded $r.CurrentValue) | Standard: $(ConvertTo-ShadowHtmlEncoded $r.StandardValue) | Strict: $(ConvertTo-ShadowHtmlEncoded $r.StrictValue)</div></div>")
            if ($rank -le 5) {
                [void]$topItems.AppendLine("<div class='top-item warn'><span>$rank</span><div><strong>$(ConvertTo-ShadowHtmlEncoded $friendly)</strong><br><em>$(ConvertTo-ShadowHtmlEncoded $r.Area)</em></div></div>")
                $rank++
            }
        }

        if ($recItems.Length -eq 0) {
            [void]$recItems.AppendLine("<div class='recommendation low'><div class='rec-title'>No major findings</div><div>No major configuration gaps or tenant drift items were identified by the built-in checks.</div></div>")
        }
        if ($topItems.Length -eq 0) {
            [void]$topItems.AppendLine("<div class='top-item ok'><span>✓</span><div><strong>No top improvements found</strong><br><em>Current checks are aligned.</em></div></div>")
        }

        $secureScoreHtml = New-Object System.Text.StringBuilder
        foreach ($n in $secureScoreNotes) { [void]$secureScoreHtml.AppendLine("<li>$(ConvertTo-ShadowHtmlEncoded $n)</li>") }
        [void]$secureScoreHtml.AppendLine("<li>If Microsoft Secure Score does not populate, verify Microsoft Graph connection and Security Reader or equivalent permissions. The report still uses live Exchange Online policy data.</li>")

        $shadowSuiteLogoDataUri = "data:image/png;base64,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"

        $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Shadow Deploy for Defender for Office 365 Executive Posture Report</title>
<style>
:root{--bg:#05050a;--panel:#090a12;--border:#2e263d;--text:#f4f0ff;--muted:#aaa0bc;--purple:#9b4bff;--purple2:#b86cff;--green:#41d950;--yellow:#ffcc33;--orange:#ff8c1a;--red:#ff3b30}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at top left,#1a0b2d 0,#08070d 38%,#030409 100%);color:var(--text);font-family:'Segoe UI',Arial,sans-serif}.report{padding:14px}.header{display:grid;grid-template-columns:360px minmax(520px,1fr) 330px;align-items:center;border:1px solid var(--border);background:linear-gradient(90deg,#090812,#0d0b18,#060711);box-shadow:0 0 40px rgba(155,75,255,.18)}.brand{padding:14px 20px;border-right:1px solid var(--border);display:flex;align-items:center;gap:14px;min-height:104px;overflow:hidden}.logo-img{width:74px;height:74px;object-fit:contain;flex:0 0 74px;border-radius:10px;filter:drop-shadow(0 0 12px rgba(155,75,255,.45))}.logo-mark{display:none}.brand-title{display:inline-block;vertical-align:middle;font-weight:800;font-size:20px;line-height:1.15;min-width:0}.brand-title small{display:block;color:var(--purple2);font-size:13px;margin-top:4px}.title{text-align:center;padding:14px 22px;min-width:0}.title h1{font-size:24px;margin:0;text-transform:uppercase;line-height:1.18;white-space:normal}.title h2{font-size:15px;margin:8px 0 0;color:var(--purple2);line-height:1.3;white-space:normal}.meta{padding:16px 22px;border-left:1px solid var(--border);font-size:13px;line-height:1.8}.card{background:rgba(8,8,15,.92);border:1px solid var(--border);border-radius:8px;box-shadow:0 0 24px rgba(155,75,255,.08);overflow:hidden}.card h3{margin:0;padding:12px 14px;color:var(--purple2);text-transform:uppercase;font-size:15px;border-bottom:1px solid var(--border);background:linear-gradient(90deg,#0d0b18,#130b22)}.card-body,.brief-main,.brief-actions{padding:16px}.executive-brief{display:grid;grid-template-columns:minmax(420px,1.25fr) minmax(260px,1fr) minmax(320px,1fr);gap:12px;margin-top:10px;align-items:stretch}.brief-main h2{margin:0 0 8px;font-size:24px;color:var(--purple2)}.brief-main p{line-height:1.55;color:#ddd5ec}.big-callout{font-size:34px;font-weight:900;color:var(--green);margin:8px 0}.top-grid{display:grid;grid-template-columns:minmax(320px,1.05fr) minmax(340px,1fr) minmax(380px,1.35fr);gap:10px;margin-top:10px;align-items:stretch}.score-ring{width:150px;height:150px;border-radius:50%;margin:8px auto;background:conic-gradient(var(--purple2) 0 $scorePctCss%,#263040 $scorePctCss% 100%);display:flex;align-items:center;justify-content:center}.score-ring-inner{width:112px;height:112px;border-radius:50%;background:#05050a;display:flex;align-items:center;justify-content:center;text-align:center;font-size:30px;font-weight:800}.score-ring-inner small{display:block;font-size:14px;font-weight:400;color:var(--muted)}.posture{display:flex;align-items:center;gap:12px;margin:6px 0 12px}.shield{width:48px;height:48px;border-radius:14px;background:linear-gradient(135deg,var(--purple),#3a135c);display:flex;align-items:center;justify-content:center;font-size:26px}.big-status{text-transform:uppercase;font-size:22px;font-weight:800;color:var(--purple2);line-height:1.18;word-break:normal}.metric-line{display:flex;justify-content:space-between;border-top:1px solid var(--border);padding:8px 0;font-size:13px}.metric-line strong{font-size:18px;color:var(--purple2)}.pill{display:inline-block;border-radius:999px;padding:4px 8px;font-size:11px;font-weight:800;border:1px solid #4b405c;white-space:nowrap}.strict{background:#0e2d14;color:var(--green)}.standard{background:#10233d;color:#72bdff}.review{background:#3b2608;color:var(--yellow)}.info{background:#1d1230;color:#c99cff}.bad{background:#3a0b0b;color:#ff7777}.top-item{display:flex;gap:10px;padding:10px 0;border-bottom:1px solid var(--border);min-width:0;overflow-wrap:anywhere}.top-item span{width:26px;height:26px;border-radius:50%;display:flex;align-items:center;justify-content:center;background:var(--red);font-weight:800;flex:0 0 26px}.top-item.warn span{background:var(--orange)}.top-item.ok span{background:var(--green)}.top-item em{color:var(--yellow);font-style:normal;font-size:12px}.ladder{display:grid;gap:8px;padding:12px}.tier{display:grid;grid-template-columns:1fr auto;align-items:center;padding:11px;border:1px solid var(--border);border-radius:8px;background:#0a0910}.tier small{color:var(--muted)}.tier-purple{border-color:var(--purple);background:linear-gradient(90deg,#281241,#12091f)}.tier-blue{border-color:#24598c;background:linear-gradient(90deg,#0e2542,#0b1020)}.tier-green{border-color:#1e6328;background:linear-gradient(90deg,#0e2d14,#0b130d)}.tier-yellow{border-color:#705d0f;background:linear-gradient(90deg,#3a3007,#120f06)}.you{box-shadow:0 0 0 2px var(--purple2),0 0 22px rgba(155,75,255,.45)}.why{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:10px 0}.why ul{margin:0;padding-left:18px;line-height:1.7}.overview{display:grid;grid-template-columns:repeat(7,1fr);margin:10px 0;border:1px solid var(--border);border-radius:8px;overflow:hidden}.overview div{background:rgba(10,10,18,.92);padding:12px;text-align:center;border-right:1px solid var(--border)}.overview div:last-child{border-right:0}.overview b{display:block;font-size:24px;margin-top:5px;color:var(--purple2)}.section-title{color:var(--purple2);text-transform:uppercase;margin:16px 0 8px;font-size:17px}.heat-row{display:grid;grid-template-columns:165px 1fr 45px;align-items:center;gap:10px;margin:11px 0}.heat-bar{height:16px;background:#25222e;border-radius:999px;overflow:hidden}.bar-good,.bar-warn,.bar-bad{height:100%;border-radius:999px}.bar-good{background:var(--green)}.bar-warn{background:var(--yellow)}.bar-bad{background:var(--red)}.zt-row{display:flex;justify-content:space-between;border-bottom:1px solid var(--border);padding:10px 0}.policy-section{margin-bottom:14px;border-left:4px solid var(--purple)}.policy-section h2{font-size:18px;color:var(--purple2);padding:12px 14px;margin:0;border-bottom:1px solid var(--border);background:#0c0a16}.summary-line{display:flex;gap:10px;flex-wrap:wrap;padding:10px 14px}.badge{display:inline-block;border:1px solid #4b405c;background:#11101b;border-radius:999px;padding:6px 9px;font-size:12px;color:#d7cced}table{width:100%;border-collapse:collapse}th{background:#11101b;color:#f7f0ff;text-align:left;padding:9px;border:1px solid #342744;font-size:12px}td{padding:8px;border:1px solid #2a2334;color:#ddd5ec;font-size:12px;vertical-align:top;word-break:break-word}.recommendation{border:1px solid var(--border);border-left-width:5px;border-radius:8px;background:#0d0b18;padding:12px;margin:10px}.recommendation.high{border-left-color:var(--red)}.recommendation.medium{border-left-color:var(--yellow)}.recommendation.low{border-left-color:var(--green)}.rec-title{text-transform:uppercase;font-size:11px;color:var(--muted);font-weight:800;margin-bottom:5px}.business-impact{margin-top:6px;color:#efe7ff}.footer{color:#8d829e;font-size:12px;border-top:1px solid var(--border);margin-top:18px;padding:14px;text-align:center}@media print{body{background:white;color:black}.executive-brief,.top-grid,.why{grid-template-columns:1fr}}
</style></head>
<body><div class="report">
  <div class="header"><div class="brand"><img class="logo-img" src="$shadowSuiteLogoDataUri" alt="Shadow Suite logo" /><span class="brand-title">SHADOW DEPLOY FOR DEFENDER FOR OFFICE 365<small>Shadow Suite</small></span></div><div class="title"><h1>Defender for Office 365 Security Posture Assessment</h1><h2>Current Configuration vs Microsoft Baselines vs Shadow Deploy Standards</h2></div><div class="meta"><div><strong>Tenant:</strong> $(ConvertTo-ShadowHtmlEncoded $tenant)</div><div><strong>Account:</strong> $(ConvertTo-ShadowHtmlEncoded $account)</div><div><strong>Report Date:</strong> $generated</div></div></div>
  <div class="executive-brief"><div class="card brief-main"><h2>30-Second Executive Brief</h2><p>Your Defender for Office 365 configuration currently aligns closest with:</p><div class="big-callout">$overall</div><p>You are currently at <strong>$scorePct / 100</strong>. The next recommended maturity step is <strong>$nextLevel</strong>. The highest-value improvements are listed to the right and validated by live tenant policy data below.</p></div><div class="card"><h3>Security Posture Score</h3><div class="card-body"><div class="score-ring"><div class="score-ring-inner">$scorePct<small>/ 100</small></div></div><div style="text-align:center;color:var(--muted)">Live tenant + JSON intent checks</div></div></div><div class="card brief-actions"><h3>Top Actions</h3>$($topItems.ToString())</div></div>
  <div class="top-grid"><div class="card"><h3>Current Tenant Position</h3><div class="card-body"><div class="posture"><div class="shield">🛡</div><div><div>Current Maturity Level</div><div class="big-status">$overall</div></div></div><div class="metric-line"><span>Next Level</span><strong>$nextLevel</strong></div><div class="metric-line"><span>Estimated Strict Improvement</span><strong>+$strictImprovement%</strong></div><div class="metric-line"><span>Mapped Drift</span><strong style="color:var(--orange)">$driftCount</strong></div></div></div><div class="card"><h3>Protection Maturity Ladder</h3><div class="ladder"><div class="tier tier-purple $(if($maturity.Class -eq 'tier-purple'){'you'}else{''})"><div><strong>Shadow Suite Hardened</strong><br><small>95–100% | Zero Trust optimized</small></div><span>🟣</span></div><div class="tier tier-blue $(if($maturity.Class -eq 'tier-blue'){'you'}else{''})"><div><strong>Microsoft Strict</strong><br><small>85–94% | Maximum protection</small></div><span>🔵</span></div><div class="tier tier-green $(if($maturity.Class -eq 'tier-green'){'you'}else{''})"><div><strong>Microsoft Standard</strong><br><small>70–84% | Recommended baseline</small></div><span>🟢</span></div><div class="tier tier-yellow $(if($maturity.Class -eq 'tier-yellow'){'you'}else{''})"><div><strong>Default / Basic</strong><br><small>0–69% | Minimal protection</small></div><span>🟡</span></div></div></div><div class="card"><h3>Security Gap Heat Map</h3><div class="card-body">$($heatRows.ToString())</div></div></div>
  <div class="overview"><div>Policies Assessed<b>$policiesAssessed</b></div><div>Policy Areas Found<b>$policyDeployedCount</b></div><div>Needs Review<b>$policyMissingCount</b></div><div>Mapped Matches<b>$matchCount</b></div><div>Mapped Drift<b>$driftCount</b></div><div>Strict Settings<b>$strictCount</b></div><div>Standard Settings<b>$standardCount</b></div></div>
  <div class="why"><div class="card"><h3>What You Gain Moving Default → Standard</h3><div class="card-body"><ul><li>Higher phishing sensitivity and better malicious email detection</li><li>Improved impersonation controls for executive/vendor fraud scenarios</li><li>Better spam and high-confidence threat handling</li><li>Safer URL handling and stronger attachment processing</li></ul></div></div><div class="card"><h3>Why Step Up To Strict?</h3><div class="card-body"><ul><li>Anti-phishing threshold 4 for maximum phishing detection</li><li>More aggressive impersonation and spoof protection</li><li>Stronger Safe Links and malware handling</li><li>Reduced business email compromise and ransomware exposure</li></ul></div></div></div>
  <div class="top-grid"><div class="card"><h3>Zero Trust Email Protection Alignment</h3><div class="card-body">$ztRows</div></div><div class="card"><h3>Microsoft Secure Score Context</h3><div class="card-body"><ul>$($secureScoreHtml.ToString())</ul></div></div><div class="card"><h3>Shadow Deploy Recommendation</h3><div class="card-body"><p><strong>Recommended target:</strong> $nextLevel</p><p>Prioritize settings that reduce phishing, impersonation, malicious URL, and attachment-based risk. The detailed evidence below shows Default Tenant, Shadow Deploy Policy, JSON Intent, Standard, and Strict context.</p></div></div></div>
  <h2 class="section-title">Detailed Policy Comparison</h2><div id="live">$policySections</div>
  <h2 class="section-title">Policy and Rule State</h2><div class="card"><table><tr><th>Area</th><th>Policy</th><th>Rule</th><th>Status</th><th>Rule State</th></tr>$($tenantRows.ToString())</table></div>
  <h2 class="section-title">Standard / Strict Technical Reference</h2><div class="card"><table><tr><th>Area</th><th>Section</th><th>Setting</th><th>Current JSON</th><th>Standard Target</th><th>Strict Target</th><th>Alignment</th></tr>$($rows.ToString())</table></div>
  <h2 class="section-title">Recommendations and Evidence</h2><div class="card">$($recItems.ToString())</div>
  <div class="footer">Shadow Suite Community Edition | Shadow Deploy for Defender for Office 365 V1.4 Executive Posture Report | Generated by local PowerShell using live Exchange Online policy data</div>
</div></body></html>
"@

        Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
        Add-Log "[OK] Shadow Deploy for Defender for Office 365 V1.4 Executive Posture Report generated: $Path"
        return $Path
    }
    catch {
        Add-Log "[ERR] HTML report generation failed: $($_.Exception.Message)"
        throw
    }
}
function New-ShadowDeployDfoReportAndOpen {
    try {
        if (-not (Test-Path -LiteralPath $Script:ReportsDirectory)) {
            New-Item -ItemType Directory -Path $Script:ReportsDirectory -Force | Out-Null
        }

        $reportPath = Join-Path $Script:ReportsDirectory ("ShadowDeploy-DFO365-Report-{0}.html" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        [void](Export-ShadowDfoHtmlReport -Path $reportPath)

        Add-Result "Export Report" "Success" "Generated: $reportPath"
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'HTML report generated.'
        Update-ShadowMetrics

        Start-Process $reportPath
        return $reportPath
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'HTML report failed.'
        Add-Result "Export Report" "Failed" $_.Exception.Message
        Add-Log "[ERR] HTML report failed: $($_.Exception.Message)"
        Update-ShadowMetrics
        return $null
    }
}


function Clear-ShadowDfoCache {
    $Script:TenantStatusCache = $null
    $Script:TenantStatusCacheTime = $null
    $Script:AcceptedDomainsCache = $null
    $Script:AcceptedDomainsCacheTime = $null
}

function Test-ShadowCacheFresh {
    param(
        [datetime]$Timestamp,
        [int]$Seconds
    )

    if ($null -eq $Timestamp) { return $false }
    return (((Get-Date) - $Timestamp).TotalSeconds -lt $Seconds)
}


function Invoke-ShadowDeploymentStatusRefreshOnce {
    param([switch]$ForceTenantRefresh)

    try {
        if ($ForceTenantRefresh) {
            Clear-ShadowDfoCache
            if (Test-ExchangeOnlineConnection) {
                Refresh-ShadowPolicyCatalog
            }
            else {
                try { Update-ShadowCatalogCardStatus } catch {}
            }
            return
        }

        # Fast path: do not call Exchange Online.
        # Keeps Deployment Areas from feeling sluggish after startup/connect.
        try { Update-ShadowCatalogCardStatus } catch {}
    }
    catch {
        try { Add-Log "[WARN] Deployment status refresh failed: $($_.Exception.Message)" } catch {}
    }
}


function Invoke-ShadowAuthWindowFocus {
    try {
        if ($form) {
            $form.TopMost = $true
            $form.Activate()
            $form.BringToFront()
            Start-Sleep -Milliseconds 200
            $form.TopMost = $false
        }
    }
    catch {
        try { Add-Log "[WARN] Could not bring authentication prompt forward: $($_.Exception.Message)" } catch {}
    }
}


function Set-ShadowUiTextWrapSafety {
    try {
        $names = @('lblTitle','lblModuleTitle','lblModuleSubtitle','lblLastAction','lblSession','lblAccount','lblTenant','lblMode','lblConfig')
        foreach ($n in $names) {
            try {
                $v = Get-Variable -Name $n -ErrorAction SilentlyContinue
                if ($v -and $v.Value -is [System.Windows.Forms.Label]) {
                    $v.Value.AutoSize = $false
                    $v.Value.UseCompatibleTextRendering = $true
                    if ($v.Value.Width -lt 320) { $v.Value.Width = 380 }
                    if ($v.Value.Height -lt 28) { $v.Value.Height = 34 }
                }
            } catch {}
        }
    } catch {}
}


function Show-ShadowAssignPolicyGroupPrompt {
    try {
        $prompt = New-Object System.Windows.Forms.Form
        $prompt.Text = "Assign Policy Target Group"
        $prompt.Size = New-Object System.Drawing.Size(540, 220)
        $prompt.StartPosition = "CenterParent"
        $prompt.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $prompt.MaximizeBox = $false
        $prompt.MinimizeBox = $false
        $prompt.BackColor = [System.Drawing.Color]::FromArgb(7,10,18)
        $prompt.ForeColor = [System.Drawing.Color]::White

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Enter the group name, mail-enabled security group, or recipient target for policy assignment:"
        $lbl.Location = New-Object System.Drawing.Point(18, 18)
        $lbl.Size = New-Object System.Drawing.Size(490, 44)
        $lbl.AutoSize = $false
        $lbl.ForeColor = [System.Drawing.Color]::White
        $prompt.Controls.Add($lbl)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(20, 72)
        $txt.Size = New-Object System.Drawing.Size(482, 26)
        $txt.BackColor = [System.Drawing.Color]::FromArgb(18,22,32)
        $txt.ForeColor = [System.Drawing.Color]::White
        $txt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $prompt.Controls.Add($txt)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "Assign"
        $btnOk.Location = New-Object System.Drawing.Point(302, 126)
        $btnOk.Size = New-Object System.Drawing.Size(95, 32)
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnOk.BackColor = [System.Drawing.Color]::FromArgb(132,44,230)
        $btnOk.ForeColor = [System.Drawing.Color]::White
        $prompt.Controls.Add($btnOk)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"
        $btnCancel.Location = New-Object System.Drawing.Point(407, 126)
        $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(35,39,52)
        $btnCancel.ForeColor = [System.Drawing.Color]::White
        $prompt.Controls.Add($btnCancel)

        $prompt.AcceptButton = $btnOk
        $prompt.CancelButton = $btnCancel

        if ($prompt.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $txt.Text.Trim()
        }

        return $null
    }
    catch {
        Add-Log "[ERR] Assign Policy prompt failed: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-ShadowAssignPolicyToGroup {
    param([string]$TargetGroup)

    try {
        if ([string]::IsNullOrWhiteSpace($TargetGroup)) {
            Add-Log "[WARN] Assign Policy cancelled or group name was blank."
            return
        }

        Set-ShadowModuleStatus -Status 'Running' -Detail "Assigning policies to $TargetGroup..."
        Add-Result "Assign Policy" "Running" "Assigning policies to target group: $TargetGroup"
        Add-Log "[INFO] Assign Policy started for target group: $TargetGroup"

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        $names = Get-NamesMap

        $assignmentMap = @(
            @{ Area='Anti-Phishing'; Rule=$names.AntiPhishRule; Cmd='Set-AntiPhishRule' },
            @{ Area='Safe Attachments'; Rule=$names.SafeAttachmentsRule; Cmd='Set-SafeAttachmentRule' },
            @{ Area='Safe Links'; Rule=$names.SafeLinksRule; Cmd='Set-SafeLinksRule' },
            @{ Area='Inbound Anti-Spam'; Rule=$names.AntiSpamInboundRule; Cmd='Set-HostedContentFilterRule' },
            @{ Area='Outbound Anti-Spam'; Rule=$names.AntiSpamOutboundRule; Cmd='Set-HostedOutboundSpamFilterRule' },
            @{ Area='Anti-Malware'; Rule=$names.AntiMalwareRule; Cmd='Set-MalwareFilterRule' }
        )

        $success = 0
        $warn = 0

        foreach ($item in $assignmentMap) {
            try {
                if (-not (Get-Command $item.Cmd -ErrorAction SilentlyContinue)) {
                    Add-Result $item.Area "Warning" "$($item.Cmd) not available in this session."
                    $warn++
                    continue
                }

                & $item.Cmd -Identity $item.Rule -SentToMemberOf $TargetGroup -ErrorAction Stop
                Add-Result $item.Area "Success" "Assigned rule to group: $TargetGroup"
                Add-Log "[OK] $($item.Area) assigned to group: $TargetGroup"
                $success++
            }
            catch {
                Add-Result $item.Area "Warning" "Could not assign $($item.Rule) to $TargetGroup. $($_.Exception.Message)"
                Add-Log "[WARN] Could not assign $($item.Area) rule to ${TargetGroup}: $($_.Exception.Message)"
                $warn++
            }
        }

        Clear-ShadowDfoCache
        Set-ShadowModuleStatus -Status 'Completed' -Detail "Assign Policy completed: $success updated, $warn warnings."
        Add-Log "[OK] Assign Policy completed. Updated: $success. Warnings: $warn."
        Update-ShadowMetrics
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Assign Policy failed.'
        Add-Result "Assign Policy" "Failed" $_.Exception.Message
        Add-Log "[ERR] Assign Policy failed: $($_.Exception.Message)"
        Update-ShadowMetrics
    }
}


function Get-ShadowAssignScopeTarget {
    try {
        if ($script:chkAssignScope -and $script:chkAssignScope.Checked -and $script:txtAssignScopeGroup) {
            $target = $script:txtAssignScopeGroup.Text.Trim()
            $placeholders = @(
                "Mail-enabled group name",
                "Mail-enabled M365 group name",
                "Mail-enabled group",
                "Group name"
            )

            if (-not [string]::IsNullOrWhiteSpace($target) -and ($placeholders -notcontains $target)) {
                return $target
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Invoke-ShadowApplyPolicyScope {
    param([string]$TargetGroup)

    try {
        if ([string]::IsNullOrWhiteSpace($TargetGroup)) {
            Add-Log "[WARN] Assign Scope enabled but no group name was provided."
            Add-Result "Assign Scope" "Warning" "Assign Scope was enabled, but no group name was provided."
            return
        }

        Add-Log "[INFO] Applying policy scope to mail-enabled group: $TargetGroup"
        Add-Result "Assign Scope" "Running" "Applying policy rule scope to $TargetGroup"

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        $names = Get-NamesMap
        $assignmentMap = @(
            @{ Area='Anti-Phishing'; Rule=$names.AntiPhishRule; Cmd='Set-AntiPhishRule' },
            @{ Area='Safe Attachments'; Rule=$names.SafeAttachmentsRule; Cmd='Set-SafeAttachmentRule' },
            @{ Area='Safe Links'; Rule=$names.SafeLinksRule; Cmd='Set-SafeLinksRule' },
            @{ Area='Inbound Anti-Spam'; Rule=$names.AntiSpamInboundRule; Cmd='Set-HostedContentFilterRule' },
            @{ Area='Outbound Anti-Spam'; Rule=$names.AntiSpamOutboundRule; Cmd='Set-HostedOutboundSpamFilterRule' },
            @{ Area='Anti-Malware'; Rule=$names.AntiMalwareRule; Cmd='Set-MalwareFilterRule' }
        )

        $success = 0
        $warn = 0

        foreach ($item in $assignmentMap) {
            try {
                if (-not (Get-Command $item.Cmd -ErrorAction SilentlyContinue)) {
                    Add-Result $item.Area "Warning" "$($item.Cmd) not available in this session."
                    $warn++
                    continue
                }

                & $item.Cmd -Identity $item.Rule -SentToMemberOf $TargetGroup -ErrorAction Stop
                Add-Result $item.Area "Success" "Scoped rule to group: $TargetGroup"
                Add-Log "[OK] $($item.Area) scoped to group: $TargetGroup"
                $success++
            }
            catch {
                Add-Result $item.Area "Warning" "Could not scope $($item.Rule) to ${TargetGroup}: $($_.Exception.Message)"
                Add-Log "[WARN] Could not scope $($item.Area) rule to ${TargetGroup}: $($_.Exception.Message)"
                $warn++
            }
        }

        Clear-ShadowDfoCache
        Add-Log "[OK] Assign Scope completed. Updated: $success. Warnings: $warn."
        Add-Result "Assign Scope" "Completed" "Updated: $success; Warnings: $warn; Target: $TargetGroup"
        Update-ShadowMetrics
    }
    catch {
        Add-Result "Assign Scope" "Failed" $_.Exception.Message
        Add-Log "[ERR] Assign Scope failed: $($_.Exception.Message)"
        Update-ShadowMetrics
    }
}


# Assign Scope guarded panel
$assignScopePanel = New-Object System.Windows.Forms.Panel
$assignScopePanel.BackColor = [System.Drawing.Color]::FromArgb(9,13,22)
$assignScopePanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$assignScopePanel.Location = New-Object System.Drawing.Point(35, 170)
$assignScopePanel.Size = New-Object System.Drawing.Size(610, 42)

$lblAssignScopeTitle = New-Object System.Windows.Forms.Label
$lblAssignScopeTitle.Text = "ASSIGN SCOPE"
$lblAssignScopeTitle.Location = New-Object System.Drawing.Point(12, 4)
$lblAssignScopeTitle.Size = New-Object System.Drawing.Size(130, 22)
$lblAssignScopeTitle.AutoSize = $false
$lblAssignScopeTitle.ForeColor = $ShadowTheme.Text
$lblAssignScopeTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$assignScopePanel.Controls.Add($lblAssignScopeTitle)

$script:chkAssignScope = New-Object System.Windows.Forms.CheckBox
$script:chkAssignScope.Text = "Enable policy scoping"
$script:chkAssignScope.Location = New-Object System.Drawing.Point(150, 10)
$script:chkAssignScope.Size = New-Object System.Drawing.Size(165, 24)
$script:chkAssignScope.AutoSize = $false
$script:chkAssignScope.ForeColor = [System.Drawing.Color]::Gold
$script:chkAssignScope.BackColor = $assignScopePanel.BackColor
$assignScopePanel.Controls.Add($script:chkAssignScope)

$script:txtAssignScopeGroup = New-Object System.Windows.Forms.TextBox
$script:txtAssignScopeGroup.Location = New-Object System.Drawing.Point(325, 9)
$script:txtAssignScopeGroup.Size = New-Object System.Drawing.Size(265, 24)
$script:txtAssignScopeGroup.BackColor = [System.Drawing.Color]::FromArgb(18,22,32)
$script:txtAssignScopeGroup.ForeColor = [System.Drawing.Color]::FromArgb(170,170,170)
$script:txtAssignScopeGroup.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:txtAssignScopeGroup.Enabled = $false
$script:txtAssignScopeGroup.Text = "Mail-enabled group name"
$assignScopePanel.Controls.Add($script:txtAssignScopeGroup)

$script:chkAssignScope.Add_CheckedChanged({
    try {
        $script:txtAssignScopeGroup.Enabled = $script:chkAssignScope.Checked
        if ($script:chkAssignScope.Checked) {
            $script:txtAssignScopeGroup.ForeColor = $ShadowTheme.Text
            if ($script:txtAssignScopeGroup.Text -eq "Mail-enabled group name") { $script:txtAssignScopeGroup.Text = "" }
            Add-Log "[INFO] Assign Scope enabled. Deploy All will scope deployed rules to the named group."
        }
        else {
            $script:txtAssignScopeGroup.ForeColor = [System.Drawing.Color]::FromArgb(170,170,170)
            if ([string]::IsNullOrWhiteSpace($script:txtAssignScopeGroup.Text)) { $script:txtAssignScopeGroup.Text = "Mail-enabled group name" }
            Add-Log "[INFO] Assign Scope disabled."
        }
    } catch {}
})

$form.Controls.Add($assignScopePanel)


function Set-ShadowDfoStartupLayoutSize {
    try {
        if ($form) {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
            $form.ClientSize = New-Object System.Drawing.Size(1560, 980)
            $form.MinimumSize = New-Object System.Drawing.Size(1500, 930)
        }

        foreach ($candidate in @('logoBox','picLogo','pbLogo','pictureLogo','imgLogo','logoImage','logoPicture','picHeaderLogo')) {
            try {
                $v = Get-Variable -Name $candidate -ErrorAction SilentlyContinue
                if ($v -and $v.Value -is [System.Windows.Forms.PictureBox]) {
                    $v.Value.Location = New-Object System.Drawing.Point(60, 34)
                    $v.Value.Size = New-Object System.Drawing.Size(225, 130)
                    $v.Value.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
                }
            } catch {}
        }
    } catch {}
}

# =============================
# Event Bindings - DFO365 backend preserved
# =============================

$btnConnect.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Connecting to Exchange Online...'
        if (Test-ExchangeOnlineConnection) {
            Update-ConnectionLabel -Label $lblConnection
            Set-ShadowSessionIdentity
            Set-ShadowModuleStatus -Status 'Ready' -Detail 'Already connected.'
            return
        }

        if (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log}) {
            Set-ShadowSessionIdentity
            Invoke-ShadowDeploymentStatusRefreshOnce
            Set-ShadowModuleStatus -Status 'Ready' -Detail 'Exchange Online connected.'
            Add-Result "Exchange Online" "Success" "Connected session validated."
            Update-ShadowMetrics
        }
    } catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Connection failed.'
        Add-Result "Exchange Online" "Failed" $_.Exception.Message
        Add-Log "[ERR] Connect failed: $($_.Exception.Message)"
        Update-ShadowMetrics
    }
})


$btnDisconnect.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Disconnecting Exchange Online session...'
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop
            Clear-ShadowDfoCache
            Add-Result "Exchange Online" "Success" "Disconnected session."
            Add-Log "[OK] Exchange Online session disconnected."
        }
        catch {
            Add-Log "[WARN] Disconnect attempted but no active Exchange Online session was found or disconnect failed: $($_.Exception.Message)"
            Add-Result "Exchange Online" "Warning" "Disconnect attempted; review log."
        }

        Set-ShadowSessionIdentity
        if ($lblConnection) {
            $lblConnection.Text = "Not Connected"
            $lblConnection.ForeColor = [System.Drawing.Color]::FromArgb(255,221,51)
        }
        if ($lblSignedIn) { $lblSignedIn.Text = "Not connected" }
        if ($lblTenant) { $lblTenant.Text = "Not connected" }
        if ($exoPill) {
            $exoPill.Text = "EXO: NOT CONNECTED"
            $exoPill.BackColor = [System.Drawing.Color]::FromArgb(132, 44, 8)
        }

        Update-ShadowDeploymentCardStates
        Set-ShadowModuleStatus -Status 'Ready' -Detail 'Disconnected.'
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Disconnect failed.'
        Add-Result "Exchange Online" "Failed" $_.Exception.Message
        Add-Log "[ERR] Disconnect failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
})


$btnLoadConfig.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Loading configuration...'
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "JSON Files (*.json)|*.json"
        $ofd.InitialDirectory = $Script:ConfigDirectory

        if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Load-ConfigFile -Path $ofd.FileName -ConfigLabel $lblConfig) {
                $lblConfig.Text = $lblConfig.Text -replace '^Profile: Zero Trust \| Config: ', ''
    $lblConfig.Text = $lblConfig.Text -replace '^Config: ', ''
                Add-Result "Configuration" "Success" "Loaded: $($ofd.FileName)"
                Merge-ShadowCatalogIntoActiveConfig
                Refresh-ShadowPolicyCatalog
                Set-ShadowModuleStatus -Status 'Ready' -Detail 'Configuration loaded.'
            }
        }
    } catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Configuration load failed.'
        Add-Result "Configuration" "Failed" $_.Exception.Message
        Add-Log "[ERR] Config load failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
})

$btnValidate.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Running validation...'
        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
        $Names = Get-NamesMap
        Run-Validation -NamesMap $Names
        Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
        Invoke-ShadowDeploymentStatusRefreshOnce
        Add-Result "Validation" "Completed" "Validation completed. Review operational log."
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'Validation complete.'
    } catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Validation failed.'
        Add-Result "Validation" "Failed" $_.Exception.Message
    }
    Update-ShadowMetrics
})

$btnTestMode.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Running test mode preview...'
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
        $Names = Get-NamesMap
        Invoke-TestMode -NamesMap $Names -ConfigLabel $lblConfig -IndicatorLabels $script:PolicyIndicatorLabels
        Refresh-ShadowPolicyCatalog
        Add-Result "Test Mode" "Completed" "Preview completed. No policy changes were executed."
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'Test mode preview complete.'
    } catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Test mode failed.'
        Add-Result "Test Mode" "Failed" $_.Exception.Message
    }
    Update-ShadowMetrics
})

$btnQuickBuild.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying DFO365 baseline...'
        Add-Log '[INFO] Starting Shadow Deploy for Defender for Office 365 baseline deployment...'

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
        [void](Import-AllShadowCatalogJsonToConfig)

        $Names = Get-NamesMap
        $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'

        foreach ($cmd in @('Get-SafeLinksPolicy','Get-SafeAttachmentPolicy','Get-AntiPhishPolicy','Get-HostedContentFilterPolicy','Get-HostedOutboundSpamFilterPolicy','Get-MalwareFilterPolicy')) {
          if (-not (Ensure-ExchangeCommandAvailable -CommandName $cmd -Logger ${function:Log})) {
            Set-ShadowModuleStatus -Status 'Failed' -Detail "Missing cmdlet: $cmd"
            Add-Result "Deploy All" "Failed" "Missing cmdlet: $cmd"
            return
          }
        }

        $dom = Get-AllAcceptedDomains
        Add-Log "[INFO] Accepted domain scope: $($dom -join ', ')"

        Add-Log '[INFO] Deploying Safe Links...'
        Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy
        Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom

        Add-Log '[INFO] Deploying Safe Attachments...'
        Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy
        Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom

        Add-Log '[INFO] Deploying Anti-Phishing...'
        Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy
        Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom

        Add-Log '[INFO] Deploying Inbound Anti-Spam...'
        Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy
        Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom

        Add-Log '[INFO] Deploying Outbound Anti-Spam...'
        Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify
        Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom

        Add-Log '[INFO] Deploying Anti-Malware...'
        Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify
        Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom

        Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
        Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
        Invoke-ShadowDeploymentStatusRefreshOnce

        Add-Result "Deploy All" "Success" "Shadow Deploy for Defender for Office 365 baseline deployment completed."
        Add-Log "[OK] Shadow Deploy for Defender for Office 365 deployment complete."
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'Deployment complete.'
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Deployment failed.'
        Add-Result "Deploy All" "Failed" $_.Exception.Message
        Add-Log "[ERR] Deploy All error: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
})

$btnRuleMode.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Applying service enablement state...'
        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }

        $Script:EnableRulesOnDeploy = -not $Script:EnableRulesOnDeploy
        $Names = Get-NamesMap
        Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
        Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
        Refresh-ShadowPolicyCatalog

        if ($Script:EnableRulesOnDeploy) {
            $btnRuleMode.Text = 'Disable'
            $btnRuleMode.BackColor = $ShadowTheme.Red
            $lblMode.Text = 'Deploy (Rules Enabled)'
            $lblMode.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95)
      if ($lblQuickMode) { $lblQuickMode.Text = 'Deploy (Rules Enabled)'; $lblQuickMode.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95) }Bright
            Add-Result "Enable Services" "Success" "Policy rules enabled where supported."
            Add-Log '[OK] Services enabled.'
            Set-ShadowModuleStatus -Status 'Completed' -Detail 'Services enabled.'
        }
        else {
            $btnRuleMode.Text = 'Enable'
            $btnRuleMode.BackColor = $ShadowTheme.Orange
            $lblMode.Text = 'Deploy (Rules Disabled)'
            $lblMode.ForeColor = [System.Drawing.Color]::Gold
      if ($lblQuickMode) { $lblQuickMode.Text = 'Deploy (Rules Disabled)'; $lblQuickMode.ForeColor = [System.Drawing.Color]::Gold }
            Add-Result "Enable Services" "Success" "Policy rules disabled where supported."
            Add-Log '[OK] Services disabled.'
            Set-ShadowModuleStatus -Status 'Completed' -Detail 'Services disabled.'
        }
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Service toggle failed.'
        Add-Result "Enable Services" "Failed" $_.Exception.Message
        Add-Log "[ERR] Enable Services failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
})

$btnBackup.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Backing up current policy inventory...'
        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
        $backupPath = Join-Path $Script:BackupsDirectory ("DFO365-Backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Export-PoliciesJson -Path $backupPath
        Add-Result "Backup" "Success" "Backup exported to $backupPath"
        Add-Log "[OK] Backup exported to $backupPath"
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'Backup complete.'
    } catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Backup failed.'
        Add-Result "Backup" "Failed" $_.Exception.Message
        Add-Log "[ERR] Backup failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
})

$btnAPh.Add_Click({
    [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Anti-Phish')
})

$btnSL.Add_Click({
    [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Safe Links')
})

$btnASp.Add_Click({
    [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Inbound Spam')
})

$btnSA.Add_Click({
    [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Safe Attachments')
})

$btnAMw.Add_Click({
    [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Anti-Malware')
})

$btnSLUrls.Add_Click({
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Updating Safe Links URL list...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { return }

    $Names = Get-NamesMap
    $policyName = $Names.SafeLinksPolicy
    $mode = Show-ModalMessageBox -Owner $form -Text "Choose YES=Block, NO=DoNotRewrite, Cancel=Disabled list" -Caption "Safe Links URL List" -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNoCancel) -Icon ([System.Windows.Forms.MessageBoxIcon]::Question)

    if ($mode -eq [System.Windows.Forms.DialogResult]::Cancel)      { $target = 'DisabledUrls' }
    elseif ($mode -eq [System.Windows.Forms.DialogResult]::Yes)    { $target = 'BlockedUrls' }
    else                                                           { $target = 'DoNotRewriteUrls' }

    $urls = Show-TextInputDialog -Owner $form -Title "Safe Links URLs" -Prompt "Enter URLs separated by commas" -DefaultText "http://example.com"

    if (-not [string]::IsNullOrWhiteSpace($urls)) {
      $arr = $urls -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
      $current = Get-SafeLinksPolicy -Identity $policyName -ErrorAction Stop | Select-Object -ExpandProperty $target -ErrorAction SilentlyContinue
      $new = @()
      if ($current) { $new += $current }
      $new += $arr
      $new = $new | Sort-Object -Unique
      $p = @{ Identity = $policyName }
      $p[$target] = $new
      Set-SafeLinksPolicy @p
      Add-Result "Safe Links URLs" "Success" "$target updated on $policyName"
      Add-Log ("[OK] {0} updated on '{1}'." -f $target, $policyName)
      Set-ShadowModuleStatus -Status 'Completed' -Detail 'Safe Links URL list updated.'
    }
  }
  catch {
    Set-ShadowModuleStatus -Status 'Failed' -Detail 'Safe Links URL update failed.'
    Add-Result "Safe Links URLs" "Failed" $_.Exception.Message
    Add-Log "[ERR] Safe Links list update error: $($_.Exception.Message)"
  }
  Update-ShadowMetrics
})

$btnQuar.Add_Click({
    Set-ShadowModuleStatus -Status 'Needs Review' -Detail 'Quarantine workflow is advisory in this release.'
    Add-Result "Quarantine" "Skipped" "No quarantine backend changes executed. Existing deployment functionality preserved."
    Add-Log "[INFO] Quarantine selected. No backend change executed in this release."
    Update-ShadowMetrics
})

$btnPreset.Add_Click({
    Set-ShadowModuleStatus -Status 'Needs Review' -Detail 'Assign Policy workflow is advisory in this release.'
    Add-Result "Assign Policy" "Skipped" "No preset policy backend changes executed. Existing deployment functionality preserved."
    Add-Log "[INFO] Assign Policy selected. No backend change executed in this release."
    Update-ShadowMetrics
})


function Invoke-ShadowCardAction {
    param(
        [Parameter(Mandatory)][string]$CategoryKey,
        [Parameter(Mandatory)][scriptblock]$DeployAction
    )

    Invoke-ShadowJsonFirstDeployment -CategoryKey $CategoryKey -DeployAction $DeployAction
}

# Deployment area card click bindings
# These visible cards now directly execute the preserved backend deployment functions through JSON-first wrappers.
Add-RecursiveClickHandler -Control $cardAntiPhish -Handler { [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Anti-Phish') }
Add-RecursiveClickHandler -Control $cardSafeAttachments -Handler { [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Safe Attachments') }
Add-RecursiveClickHandler -Control $cardSafeLinks -Handler { [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Safe Links') }
Add-RecursiveClickHandler -Control $cardAntiSpam -Handler { [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Inbound Spam') }
Add-RecursiveClickHandler -Control $cardAntiMalware -Handler { [void](Invoke-ShadowDeployCatalogPolicy -CategoryKey 'Anti-Malware') }
Add-RecursiveClickHandler -Control $cardQuarantine -Handler { Invoke-ShadowCardAction -CategoryKey 'Quarantine' -DeployAction { $btnQuar.PerformClick() } }
Add-RecursiveClickHandler -Control $cardPreset -Handler {
    $target = Get-ShadowAssignScopeTarget
    if (-not $target) {
        Add-Log "[WARN] Assign Policy requires the Enable policy scoping checkbox to be checked and a mail-enabled Microsoft 365 group name entered above."
        Add-Result "Assign Policy" "Warning" "Check Enable policy scoping and enter a mail-enabled Microsoft 365 group name first."
        Update-ShadowMetrics
        return
    }

    Add-Log "[INFO] Assign Policy using scoped target from top field: $target"
    Invoke-ShadowAssignPolicyToGroup -TargetGroup $target
}
Add-RecursiveClickHandler -Control $cardDeployAll -Handler { Invoke-ShadowDeployAllCustomPoliciesFixed; $scopeTarget = Get-ShadowAssignScopeTarget; if ($scopeTarget) { Invoke-ShadowApplyPolicyScope -TargetGroup $scopeTarget } }
Add-RecursiveClickHandler -Control $cardReporting -Handler { [void](New-ShadowDeployDfoReportAndOpen) }
$btnExportJson.Add_Click({
  if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    try {
      Set-ShadowModuleStatus -Status 'Running' -Detail 'Exporting JSON inventory...'
      if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
      Export-PoliciesJson -Path $folderDialog.SelectedPath
      Add-Result "Export JSON" "Success" "Exported to $($folderDialog.SelectedPath)"
      Add-Log "[OK] Exported JSON to $($folderDialog.SelectedPath)"
      Set-ShadowModuleStatus -Status 'Completed' -Detail 'JSON export completed.'
    }
    catch {
      Set-ShadowModuleStatus -Status 'Failed' -Detail 'JSON export failed.'
      Add-Result "Export JSON" "Failed" $_.Exception.Message
      Add-Log "[ERR] Export failed: $($_.Exception.Message)"
    }
    Update-ShadowMetrics
  }
})


$btnRescanState.Add_Click({
    try {
        Set-ShadowModuleStatus -Status 'Running' -Detail 'Rescanning catalog deployment state...'
        Add-Log "[INFO] Rescan State started."

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }

        Clear-ShadowDfoCache
        Invoke-ShadowDeploymentStatusRefreshOnce -ForceTenantRefresh

        Add-Result "Rescan State" "Success" "Deployment area status refreshed."
        Add-Log "[OK] Rescan State completed."
        Set-ShadowModuleStatus -Status 'Completed' -Detail 'Deployment state refreshed.'
        Update-ShadowMetrics
    }
    catch {
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Rescan State failed.'
        Add-Result "Rescan State" "Failed" $_.Exception.Message
        Add-Log "[ERR] Rescan State failed: $($_.Exception.Message)"
        Update-ShadowMetrics
    }
})

$btnExportHtml.Add_Click({
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Generating Shadow Deploy for Defender for Office 365 HTML report...'
    [void](New-ShadowDeployDfoReportAndOpen)
})

$btnOpenConfig.Add_Click({
    try { Start-Process $Script:ConfigDirectory } catch { Add-Log "[WARN] Could not open config folder: $($_.Exception.Message)" }
})

$btnOpenReports.Add_Click({
    try { Start-Process $Script:ReportsDirectory } catch { Add-Log "[WARN] Could not open reports folder: $($_.Exception.Message)" }
})

$btnOpenLogs.Add_Click({
    try { Start-Process $Script:LogsDirectory } catch { Add-Log "[WARN] Could not open logs folder: $($_.Exception.Message)" }
})

$btnClearResults.Add_Click({
    $gridResults.Rows.Clear()
    $txtLog.Clear()
    Add-Log "Results and operational log cleared."
    Update-ShadowMetrics
    Set-ShadowModuleStatus -Status 'Ready' -Detail 'Results cleared.'
})


$btnExit.Add_Click({
    try { Add-Log "[INFO] Exit selected. Closing Shadow Deploy for Defender for Office 365." } catch {}
    $form.Close()
})


$btnClearResultsSide.Add_Click({
    try {
        if ($gridResults) { $gridResults.Rows.Clear() }
        Add-Log "[INFO] Execution results cleared."
        Update-ShadowMetrics
        Set-ShadowModuleStatus -Status 'Ready' -Detail 'Execution results cleared.'
    }
    catch {
        Add-Log "[WARN] Could not clear execution results: $($_.Exception.Message)"
    }
})


$btnGenerateReportSide.Add_Click({
    try {
        Add-Log "[INFO] Opening logs folder..."
        if (-not (Test-Path -LiteralPath $Script:LogsDirectory)) {
            New-Item -ItemType Directory -Path $Script:LogsDirectory -Force | Out-Null
        }
        Start-Process explorer.exe $Script:LogsDirectory
        Add-Result "Open Logs" "Success" "Opened logs folder."
        Set-ShadowModuleStatus -Status 'Ready' -Detail 'Logs folder opened.'
        Update-ShadowMetrics
    }
    catch {
        Add-Result "Open Logs" "Failed" $_.Exception.Message
        Add-Log "[ERR] Open Logs failed: $($_.Exception.Message)"
        Set-ShadowModuleStatus -Status 'Failed' -Detail 'Open Logs failed.'
        Update-ShadowMetrics
    }
})

$form.TopMost = $false
$form.Add_Shown({
    $form.Activate()
    Set-ShadowModuleStatus -Status 'Ready' -Detail 'Shadow Deploy for Defender for Office 365 ready.'
    Set-ShadowSessionIdentity

    [void](Load-ConfigFile -Path $Script:ZeroTrustConfigPath -ConfigLabel $lblConfig)
    $lblConfig.Text = $lblConfig.Text -replace '^Profile: Zero Trust \| Config: ', ''
                $lblConfig.Text = $lblConfig.Text -replace '^Config: ', ''
    Refresh-ShadowPolicyCatalog

    if ($Script:Config) { $lblQuickConfig.Text = 'Loaded'; $lblQuickConfig.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95) }
    Add-Log "Shadow Deploy for Defender for Office 365 initialized."
    if ($logoPath) {
        Add-Log "Logo loaded: $logoPath"
    } else {
        Add-Log "Logo not found. Expected file name: shadowdeployo365.png under repo-root assets folder or script folder."
    }
})

Set-ShadowUiTextWrapSafety
Set-ShadowDfoStartupLayoutSize
[void]$form.ShowDialog()
