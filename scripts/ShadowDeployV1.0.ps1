
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:RequiredModuleName = 'ExchangeOnlineManagement'
$Script:Config = $null
$Script:LoadedConfigPath = $null
$Script:EnableRulesOnDeploy = $false
$Script:ToolDisplayName = 'Shadow Deploy DFO365 V1.2'

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
    return @(Get-AcceptedDomain -ErrorAction Stop |
      ForEach-Object { $_.DomainName.ToString() } |
      Where-Object { $_ } |
      Sort-Object -Unique)
  }
  catch {
    return @()
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
  param([hashtable]$NamesMap)

  $items = @(
    @{ Key='Anti-Phish';       PolicyCmd='Get-AntiPhishPolicy';              PolicyName=$NamesMap.AntiPhishPolicy;       RuleCmd='Get-AntiPhishRule';                RuleName=$NamesMap.AntiPhishRule },
    @{ Key='Safe Links';       PolicyCmd='Get-SafeLinksPolicy';              PolicyName=$NamesMap.SafeLinksPolicy;       RuleCmd='Get-SafeLinksRule';                RuleName=$NamesMap.SafeLinksRule },
    @{ Key='Safe Attachments'; PolicyCmd='Get-SafeAttachmentPolicy';         PolicyName=$NamesMap.SafeAttachmentsPolicy; RuleCmd='Get-SafeAttachmentRule';           RuleName=$NamesMap.SafeAttachmentsRule },
    @{ Key='Inbound Spam';     PolicyCmd='Get-HostedContentFilterPolicy';    PolicyName=$NamesMap.AntiSpamInboundPolicy; RuleCmd='Get-HostedContentFilterRule';      RuleName=$NamesMap.AntiSpamInboundRule },
    @{ Key='Outbound Spam';    PolicyCmd='Get-HostedOutboundSpamFilterPolicy'; PolicyName=$NamesMap.AntiSpamOutboundPolicy; RuleCmd='Get-HostedOutboundSpamFilterRule'; RuleName=$NamesMap.AntiSpamOutboundRule },
    @{ Key='Anti-Malware';     PolicyCmd='Get-MalwareFilterPolicy';          PolicyName=$NamesMap.AntiMalwarePolicy;     RuleCmd='Get-MalwareFilterRule';            RuleName=$NamesMap.AntiMalwareRule }
  )

  $result = @{}
  foreach ($item in $items) {
    $policyExists = $false
    $ruleExists = $false
    $ruleEnabled = $null

    if (Get-Command $item.PolicyCmd -ErrorAction SilentlyContinue) {
      try {
        $policy = & $item.PolicyCmd -ErrorAction SilentlyContinue | Where-Object Name -eq $item.PolicyName | Select-Object -First 1
        $policyExists = ($null -ne $policy)
      } catch {}
    }

    if (Get-Command $item.RuleCmd -ErrorAction SilentlyContinue) {
      try {
        $rule = & $item.RuleCmd -ErrorAction SilentlyContinue | Where-Object Name -eq $item.RuleName | Select-Object -First 1
        $ruleExists = ($null -ne $rule)
        if ($ruleExists) {
          if ($rule.PSObject.Properties.Name -contains 'Enabled') {
            $ruleEnabled = [bool]$rule.Enabled
          } elseif ($rule.PSObject.Properties.Name -contains 'State') {
            $ruleEnabled = ([string]$rule.State -eq 'Enabled')
          }
        }
      } catch {}
    }

    $statusText = 'Missing'
    if ($policyExists -and $ruleExists) {
      if ($ruleEnabled -eq $true) { $statusText = 'Enabled' }
      elseif ($ruleEnabled -eq $false) { $statusText = 'Ready' }
      else { $statusText = 'Exists' }
    } elseif ($policyExists) {
      $statusText = 'Policy Only'
    }

    $result[$item.Key] = [pscustomobject]@{
      PolicyExists = $policyExists
      RuleExists   = $ruleExists
      RuleEnabled  = $ruleEnabled
      Status       = $statusText
    }
  }

  return $result
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
# Shadow Deploy DFO365 - Shadow Suite Interface
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

    $iconLbl = New-Object System.Windows.Forms.Label
    $iconLbl.Text = $Icon
    $iconLbl.Location = New-Object System.Drawing.Point(18, 20)
    $iconLbl.Size = New-Object System.Drawing.Size(58, 58)
    $iconLbl.Font = New-ShadowFont -Size 28 -Weight Bold
    $iconLbl.ForeColor = $IconColor
    $iconLbl.BackColor = $ShadowTheme.SurfaceAlt
    $iconLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $iconLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($iconLbl)

    $titleLbl = New-ShadowLabel -Text $Title -X 92 -Y 20 -W 200 -H 24 -Size 11 -Bold -BackColor $ShadowTheme.SurfaceAlt
    $titleLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($titleLbl)

    $descLbl = New-ShadowLabel -Text $Description -X 92 -Y 48 -W 200 -H 38 -Size 8.5 -Muted -BackColor $ShadowTheme.SurfaceAlt
    $descLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($descLbl)

    $statusColor = $ShadowTheme.GreenBright
    if ($null -eq $statusColor) {
        $statusColor = [System.Drawing.Color]::FromArgb(102,220,95)
    }

    $statusLbl = New-ShadowLabel -Text "● $DefaultStatus" -X 92 -Y 84 -W 200 -H 20 -Size 8.5 -BackColor $ShadowTheme.SurfaceAlt -Color $statusColor
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
$form.Text = "Shadow Deploy | DFO365"
$form.Size = New-Object System.Drawing.Size(1720, 1068)
$form.MinimumSize = New-Object System.Drawing.Size(1720, 1068)
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
        $picLogo.Location = New-Object System.Drawing.Point(18, 14)
        $picLogo.Size = New-Object System.Drawing.Size(684, 186)
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
$lblLastAction = New-ShadowLabel -Text "Last action: Ready    |    Version: 1.2.0" -X 737 -Y 182 -W 300 -H 22 -Size 8.5 -Muted
$form.Controls.Add($lblLastAction)

# Session Summary Card
$sessionPanel = New-ShadowPanel -X 1040 -Y 34 -W 660 -H 184 -Title "SESSION SUMMARY" -Accent $ShadowTheme.Purple
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

$cardPreset = New-DeploymentCard -Title "Preset Security Policies" -Description "Microsoft recommended`r`nZero Trust baseline" -Icon "✓" -X 20 -Y 310 -IconColor $ShadowTheme.GreenBright -StatusKey "Preset" -DefaultStatus "Needs Review"
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
$btnLoadConfig  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Config" -Description "Load JSON" -Style Blue
$btnBackup      = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Backup" -Description "Backup policies" -Style Warning
$btnQuickBuild = New-ShadowButton -Text "Deploy Hidden" -W 1 -H 1 -Style Success
$btnQuickBuild.Visible = $false
$form.Controls.Add($btnQuickBuild)
$btnTestMode    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Test" -Description "Preview mode" -Style Secondary
$btnValidate    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Validate" -Description "Validate rules" -Style Secondary
$btnRuleMode    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Enable" -Description "Enable rules" -Style Warning
$btnExportHtml  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Report" -Description "HTML report" -Style Primary
$btnExportJson  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "JSON" -Description "Export JSON" -Style Secondary
$btnOpenReports = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Reports" -Description "Open reports" -Style Secondary
$btnOpenLogs    = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Logs" -Description "Open logs" -Style Secondary
$btnOpenConfig  = New-ShadowActionItem -Parent $buttonPanel -ButtonText "OpenCfg" -Description "Open config" -Style Secondary
$btnClearResults = New-ShadowActionItem -Parent $buttonPanel -ButtonText "Clear" -Description "Clear output" -Style Danger

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
$footerPanel.Location = New-Object System.Drawing.Point(14, 1012)
$footerPanel.Size = New-Object System.Drawing.Size(1686, 34)
$footerPanel.BackColor = $ShadowTheme.Surface
$footerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($footerPanel)
$footerPanel.Controls.Add((New-ShadowLabel -Text "Shadow Deploy DFO365  |  Zero Trust Email Security  |  Secure • Compliant • Protected" -X 18 -Y 7 -W 680 -H 20 -Size 8.5 -Muted -BackColor $ShadowTheme.Surface))
$footerPanel.Controls.Add((New-ShadowLabel -Text "© Shadow Suite  |  Built for Security Operators" -X 1300 -Y 7 -W 360 -H 20 -Size 8.5 -Muted -BackColor $ShadowTheme.Surface))

# Dialogs
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$saveHtmlDialog = New-Object System.Windows.Forms.SaveFileDialog
$saveHtmlDialog.Filter = 'HTML Files (*.html)|*.html'
$saveHtmlDialog.Title = 'Save Shadow Deploy DFO365 Report'
$saveHtmlDialog.FileName = ('ShadowDeploy-DFO365-Report-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Export-ShadowDeployDfoHtmlReport {
    param([Parameter(Mandatory)][string]$Path)
    Export-PoliciesHtml -Path $Path
    try {
        $html = Get-Content -Path $Path -Raw -Encoding UTF8
        $html = $html -replace 'DFO365 Deployment Tool - HTML Report','Shadow Deploy DFO365 - Deployment Report'
        $html = $html -replace 'DFO365 HTML Report','Shadow Deploy DFO365 Report'
        $html = $html -replace 'background:#1b1f26','background:#05070c'
        $html = $html -replace 'background:#20252d','background:#0a0e17'
        $html = $html -replace 'background:#2a3038','background:#101520'
        $html = $html -replace 'border:1px solid #4a4f57','border:1px solid #444a58'
        $summaryBlock = @"
<div class='card'>
<h2>Executive Summary</h2>
<p>This Shadow Suite report summarizes Defender for Office 365 policy and rule inventory collected by Shadow Deploy DFO365.</p>
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
        $html = $html -replace '(<h1>Shadow Deploy DFO365 - Deployment Report</h1>)', "`$1`n$summaryBlock"
        [System.IO.File]::WriteAllText($Path, $html, [System.Text.Encoding]::UTF8)
    } catch { Add-Log "[WARN] Report generated, but Shadow branding update failed: $($_.Exception.Message)" }
}

function New-ShadowDeployDfoReportAndOpen {
    try {
        if (-not (Test-Path -LiteralPath $Script:ReportsDirectory)) {
            New-Item -ItemType Directory -Path $Script:ReportsDirectory -Force | Out-Null
        }

        $reportPath = Join-Path $Script:ReportsDirectory ("ShadowDeploy-DFO365-Report-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

        if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return $null }

        Export-ShadowDeployDfoHtmlReport -Path $reportPath
        Add-ShadowDriftAndAlignmentReportBlock -Path $reportPath

        Add-Result "Export Report" "Success" "Generated: $reportPath"
        Add-Log "[OK] Shadow Deploy DFO365 HTML report generated: $reportPath"
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
        [pscustomobject]@{ Key='Preset';           Name='Preset Security Policies'; File='DFO365_PresetSecurityPolicies.json';  Sections=@('PresetSecurityPolicies') }
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
            Refresh-ShadowPolicyCatalog
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
        Refresh-ShadowPolicyCatalog
        Update-ShadowDeploymentCardStates
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
        Add-Log '[INFO] Starting Shadow Deploy DFO365 baseline deployment...'

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
        Refresh-ShadowPolicyCatalog
        Update-ShadowDeploymentCardStates

        Add-Result "Deploy All" "Success" "Shadow Deploy DFO365 baseline deployment completed."
        Add-Log "[OK] Shadow Deploy DFO365 deployment complete."
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
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying Anti-Phishing...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey 'Anti-Phish' -Required)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-AntiPhishPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy
    Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Refresh-ShadowPolicyCatalog
    Update-ShadowDeploymentCardStates
    Add-Result "Anti-Phishing" "Success" "Deployment completed."
    Set-ShadowModuleStatus -Status 'Completed' -Detail 'Anti-Phishing complete.'
  } catch { Set-ShadowModuleStatus -Status 'Failed' -Detail 'Anti-Phishing failed.'; Add-Result "Anti-Phishing" "Failed" $_.Exception.Message; Add-Log "[ERR] Anti-Phishing error: $($_.Exception.Message)" }
  Update-ShadowMetrics
})

$btnSL.Add_Click({
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying Safe Links...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey 'Safe Links' -Required)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy
    Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Refresh-ShadowPolicyCatalog
    Update-ShadowDeploymentCardStates
    Add-Result "Safe Links" "Success" "Deployment completed."
    Set-ShadowModuleStatus -Status 'Completed' -Detail 'Safe Links complete.'
  } catch { Set-ShadowModuleStatus -Status 'Failed' -Detail 'Safe Links failed.'; Add-Result "Safe Links" "Failed" $_.Exception.Message; Add-Log "[ERR] Safe Links error: $($_.Exception.Message)" }
  Update-ShadowMetrics
})

$btnASp.Add_Click({
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying Anti-Spam...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey 'Inbound Spam' -Required)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedContentFilterPolicy' -Logger ${function:Log})) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedOutboundSpamFilterPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
    $dom = Get-AllAcceptedDomains
    Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy
    Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom
    Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify
    Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Refresh-ShadowPolicyCatalog
    Update-ShadowDeploymentCardStates
    Add-Result "Anti-Spam" "Success" "Deployment completed."
    Set-ShadowModuleStatus -Status 'Completed' -Detail 'Anti-Spam complete.'
  } catch { Set-ShadowModuleStatus -Status 'Failed' -Detail 'Anti-Spam failed.'; Add-Result "Anti-Spam" "Failed" $_.Exception.Message; Add-Log "[ERR] Anti-Spam error: $($_.Exception.Message)" }
  Update-ShadowMetrics
})

$btnSA.Add_Click({
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying Safe Attachments...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey 'Safe Attachments' -Required)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeAttachmentPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy
    Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Refresh-ShadowPolicyCatalog
    Update-ShadowDeploymentCardStates
    Add-Result "Safe Attachments" "Success" "Deployment completed."
    Set-ShadowModuleStatus -Status 'Completed' -Detail 'Safe Attachments complete.'
  } catch { Set-ShadowModuleStatus -Status 'Failed' -Detail 'Safe Attachments failed.'; Add-Result "Safe Attachments" "Failed" $_.Exception.Message; Add-Log "[ERR] Safe Attachments error: $($_.Exception.Message)" }
  Update-ShadowMetrics
})

$btnAMw.Add_Click({
  try {
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Deploying Anti-Malware...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Import-ShadowCategoryJsonToConfig -CategoryKey 'Anti-Malware' -Required)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-MalwareFilterPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
    $dom = Get-AllAcceptedDomains
    Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify
    Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Refresh-ShadowPolicyCatalog
    Update-ShadowDeploymentCardStates
    Add-Result "Anti-Malware" "Success" "Deployment completed."
    Set-ShadowModuleStatus -Status 'Completed' -Detail 'Anti-Malware complete.'
  } catch { Set-ShadowModuleStatus -Status 'Failed' -Detail 'Anti-Malware failed.'; Add-Result "Anti-Malware" "Failed" $_.Exception.Message; Add-Log "[ERR] Anti-Malware error: $($_.Exception.Message)" }
  Update-ShadowMetrics
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
    Set-ShadowModuleStatus -Status 'Needs Review' -Detail 'Preset Security Policies workflow is advisory in this release.'
    Add-Result "Preset Security Policies" "Skipped" "No preset policy backend changes executed. Existing deployment functionality preserved."
    Add-Log "[INFO] Preset Security Policies selected. No backend change executed in this release."
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
# These visible cards are now JSON-first. If a catalog file is missing, the card creates it.
# If catalog exists, the same card deploys or updates the corresponding policy.
Add-RecursiveClickHandler -Control $cardAntiPhish -Handler { Invoke-ShadowCardAction -CategoryKey 'Anti-Phish' -DeployAction { $btnAPh.PerformClick() } }
Add-RecursiveClickHandler -Control $cardSafeAttachments -Handler { Invoke-ShadowCardAction -CategoryKey 'Safe Attachments' -DeployAction { $btnSA.PerformClick() } }
Add-RecursiveClickHandler -Control $cardSafeLinks -Handler { Invoke-ShadowCardAction -CategoryKey 'Safe Links' -DeployAction { $btnSL.PerformClick() } }
Add-RecursiveClickHandler -Control $cardAntiSpam -Handler { Invoke-ShadowCardAction -CategoryKey 'Inbound Spam' -DeployAction { $btnASp.PerformClick() } }
Add-RecursiveClickHandler -Control $cardAntiMalware -Handler { Invoke-ShadowCardAction -CategoryKey 'Anti-Malware' -DeployAction { $btnAMw.PerformClick() } }
Add-RecursiveClickHandler -Control $cardQuarantine -Handler { Invoke-ShadowCardAction -CategoryKey 'Quarantine' -DeployAction { $btnQuar.PerformClick() } }
Add-RecursiveClickHandler -Control $cardPreset -Handler { Invoke-ShadowCardAction -CategoryKey 'Preset' -DeployAction { $btnPreset.PerformClick() } }
Add-RecursiveClickHandler -Control $cardDeployAll -Handler { Invoke-ShadowDeployAllCustomPolicies }
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

$btnExportHtml.Add_Click({
    Set-ShadowModuleStatus -Status 'Running' -Detail 'Generating Shadow Deploy DFO365 report...'
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

$form.TopMost = $false
$form.Add_Shown({
    $form.Activate()
    Set-ShadowModuleStatus -Status 'Ready' -Detail 'Shadow Deploy DFO365 ready.'
    Set-ShadowSessionIdentity

    [void](Load-ConfigFile -Path $Script:ZeroTrustConfigPath -ConfigLabel $lblConfig)
    $lblConfig.Text = $lblConfig.Text -replace '^Profile: Zero Trust \| Config: ', ''
                $lblConfig.Text = $lblConfig.Text -replace '^Config: ', ''
    Refresh-ShadowPolicyCatalog

    if ($Script:Config) { $lblQuickConfig.Text = 'Loaded'; $lblQuickConfig.ForeColor = [System.Drawing.Color]::FromArgb(102,220,95) }
    Add-Log "Shadow Deploy DFO365 initialized."
    if ($logoPath) {
        Add-Log "Logo loaded: $logoPath"
    } else {
        Add-Log "Logo not found. Expected file name: shadowdeployo365.png under repo-root assets folder or script folder."
    }
})

[void]$form.ShowDialog()
