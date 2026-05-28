
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:RequiredModuleName = 'ExchangeOnlineManagement'
$Script:Config = $null
$Script:LoadedConfigPath = $null
$Script:EnableRulesOnDeploy = $false

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
$form = New-Object System.Windows.Forms.Form
$form.Text = "DFO365 Deployment Tool - V1.1"
$form.Size = New-Object System.Drawing.Size(1000,930)
$form.MinimumSize = New-Object System.Drawing.Size(1000,930)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(24,28,34)
$form.ForeColor = [System.Drawing.Color]::White
$form.FormBorderStyle = 'Sizable'

$fontTitle  = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$fontHeader = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontText   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

$colorCardBg   = [System.Drawing.Color]::FromArgb(31,36,43)
$colorButtonBg = [System.Drawing.Color]::FromArgb(34,39,46)
$colorBorder   = [System.Drawing.Color]::FromArgb(68,74,83)
$colorAccent   = [System.Drawing.Color]::FromArgb(98,114,164)
$colorText     = [System.Drawing.Color]::FromArgb(240,240,240)
$colorMuted    = [System.Drawing.Color]::FromArgb(188,188,188)

function New-SectionPanel {
  param(
    [string]$Title,
    [int]$PanelX,
    [int]$PanelY,
    [int]$PanelWidth,
    [int]$PanelHeight
  )

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($PanelX,$PanelY)
  $panel.Size = New-Object System.Drawing.Size($PanelWidth,$PanelHeight)
  $panel.BackColor = $colorCardBg
  $panel.BorderStyle = 'FixedSingle'

  if ($Title) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Title
    $label.Font = $fontHeader
    $label.ForeColor = $colorMuted
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(14,10)
    $panel.Controls.Add($label)

    $lineWidth = [Math]::Max(40, [int]$PanelWidth - 30)
    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = $colorBorder
    $line.Size = New-Object System.Drawing.Size($lineWidth, 1)
    $line.Location = New-Object System.Drawing.Point(14,34)
    $panel.Controls.Add($line)
  }

  return $panel
}

function New-StyledButton {
  param(
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height = 40,
    [bool]$Accent = $false
  )

  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $Text
  $btn.Location = New-Object System.Drawing.Point($X,$Y)
  $btn.Size = New-Object System.Drawing.Size($Width,$Height)
  $btn.BackColor = $colorButtonBg
  $btn.ForeColor = $colorText
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.BorderSize = 1
  $btn.FlatAppearance.BorderColor = $(if ($Accent) { $colorAccent } else { $colorBorder })
  $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(42,48,57)
  $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(48,54,63)
  $btn.Font = $fontText
  $btn.UseVisualStyleBackColor = $false
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $btn
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "DFO365 Deployment Tool - V1.1"
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = $colorText
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20,16)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Zero Trust baseline deployment, validation, and configuration"
$subtitleLabel.Font = $fontText
$subtitleLabel.ForeColor = $colorMuted
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(22,46)
$form.Controls.Add($subtitleLabel)

$btnConnect = New-StyledButton -Text "Connect to Exchange Online" -X 20 -Y 84 -Width 455
$btnDisconnect = New-StyledButton -Text "Disconnect Session" -X 505 -Y 84 -Width 455
$form.Controls.AddRange(@($btnConnect,$btnDisconnect))

$btnLoadConfig = New-StyledButton -Text "Load Custom JSON Config" -X 20 -Y 134 -Width 300
$btnValidate = New-StyledButton -Text "Validate Current Configuration" -X 340 -Y 134 -Width 300
$btnTestMode = New-StyledButton -Text "Test Mode Preview" -X 660 -Y 134 -Width 300
$form.Controls.AddRange(@($btnLoadConfig,$btnValidate,$btnTestMode))

$btnRuleMode = New-StyledButton -Text "Rule Mode: Disabled After Deploy" -X 20 -Y 184 -Width 220 -Height 42
$btnRuleMode.BackColor = [System.Drawing.Color]::FromArgb(52,58,66)
$form.Controls.Add($btnRuleMode)

$btnQuickBuild = New-StyledButton -Text "Deploy Zero Trust Baseline" -X 250 -Y 184 -Width 710 -Height 42 -Accent $true
$form.Controls.Add($btnQuickBuild)

$deployPanel = New-SectionPanel -Title "INDIVIDUAL POLICY DEPLOYMENTS" -PanelX 20 -PanelY 248 -PanelWidth 940 -PanelHeight 196
$form.Controls.Add($deployPanel)

$btnAPh = New-StyledButton -Text "Deploy Anti-Phish" -X 16 -Y 50 -Width 445 -Height 40
$btnSL = New-StyledButton -Text "Deploy Safe Links" -X 476 -Y 50 -Width 445 -Height 40
$btnASp = New-StyledButton -Text "Deploy Anti-Spam" -X 16 -Y 98 -Width 445 -Height 40
$btnSA = New-StyledButton -Text "Deploy Safe Attachments" -X 476 -Y 98 -Width 445 -Height 40
$btnAMw = New-StyledButton -Text "Deploy Anti-Malware" -X 16 -Y 146 -Width 445 -Height 40
$btnSLUrls = New-StyledButton -Text "Manage Safe Links URL Lists" -X 476 -Y 146 -Width 445 -Height 40
$deployPanel.Controls.AddRange(@($btnAPh,$btnSL,$btnASp,$btnSA,$btnAMw,$btnSLUrls))

$reportPanel = New-SectionPanel -Title "REPORTING & EXPORTS" -PanelX 20 -PanelY 456 -PanelWidth 940 -PanelHeight 100
$form.Controls.Add($reportPanel)

$btnExportJson = New-StyledButton -Text "Export JSON" -X 16 -Y 48 -Width 445 -Height 40
$btnExportHtml = New-StyledButton -Text "Export HTML Report" -X 476 -Y 48 -Width 445 -Height 40
$reportPanel.Controls.AddRange(@($btnExportJson,$btnExportHtml))

$statusPanel = New-SectionPanel -Title "CURRENT STATUS" -PanelX 20 -PanelY 568 -PanelWidth 940 -PanelHeight 190
$form.Controls.Add($statusPanel)

$lblConnection = New-Object System.Windows.Forms.Label
$lblConnection.Text = "Status: Not Connected"
$lblConnection.Font = $fontHeader
$lblConnection.ForeColor = $colorText
$lblConnection.AutoSize = $true
$lblConnection.Location = New-Object System.Drawing.Point(16,46)
$statusPanel.Controls.Add($lblConnection)

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = "Profile: Zero Trust | Config: Not Loaded"
$lblConfig.Font = $fontText
$lblConfig.ForeColor = $colorMuted
$lblConfig.AutoSize = $true
$lblConfig.Location = New-Object System.Drawing.Point(16,72)
$statusPanel.Controls.Add($lblConfig)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = "Mode: Policies deploy or update; rules remain disabled"
$lblMode.Font = $fontText
$lblMode.ForeColor = $colorMuted
$lblMode.AutoSize = $true
$lblMode.Location = New-Object System.Drawing.Point(16,92)
$statusPanel.Controls.Add($lblMode)

$indicatorTitle = New-Object System.Windows.Forms.Label
$indicatorTitle.Text = "Policy Status Indicators:"
$indicatorTitle.Font = $fontHeader
$indicatorTitle.ForeColor = $colorText
$indicatorTitle.AutoSize = $true
$indicatorTitle.Location = New-Object System.Drawing.Point(16,120)
$statusPanel.Controls.Add($indicatorTitle)

$script:PolicyIndicatorLabels = @{}

function New-IndicatorLabel {
  param(
    [string]$Name,
    [int]$PosX,
    [int]$PosY
  )

  $nameLabel = New-Object System.Windows.Forms.Label
  $nameLabel.Text = $Name
  $nameLabel.Font = $fontText
  $nameLabel.ForeColor = $colorMuted
  $nameLabel.AutoSize = $true
  $nameLabel.Location = New-Object System.Drawing.Point($PosX, $PosY)
  $statusPanel.Controls.Add($nameLabel)

  $warnColor = [System.Drawing.Color]::FromArgb(255,193,7)

  $valueLabel = New-Object System.Windows.Forms.Label
  $valueLabel.Text = "Unknown"
  $valueLabel.Font = $fontText
  $valueLabel.ForeColor = $warnColor
  $valueLabel.AutoSize = $true
  $valueLabel.Location = New-Object System.Drawing.Point(($PosX + 120), $PosY)
  $statusPanel.Controls.Add($valueLabel)

  return $valueLabel
}

$script:PolicyIndicatorLabels['Anti-Phish'] = New-IndicatorLabel -Name 'Anti-Phish' -PosX 16 -PosY 144
$script:PolicyIndicatorLabels['Safe Links'] = New-IndicatorLabel -Name 'Safe Links' -PosX 240 -PosY 144
$script:PolicyIndicatorLabels['Safe Attachments'] = New-IndicatorLabel -Name 'Safe Attachments' -PosX 464 -PosY 144
$script:PolicyIndicatorLabels['Inbound Spam'] = New-IndicatorLabel -Name 'Inbound Spam' -PosX 688 -PosY 144
$script:PolicyIndicatorLabels['Outbound Spam'] = New-IndicatorLabel -Name 'Outbound Spam' -PosX 16 -PosY 166
$script:PolicyIndicatorLabels['Anti-Malware'] = New-IndicatorLabel -Name 'Anti-Malware' -PosX 240 -PosY 166

$logPanel = New-SectionPanel -Title "ACTIVITY LOG" -PanelX 20 -PanelY 770 -PanelWidth 940 -PanelHeight 120
$form.Controls.Add($logPanel)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.ReadOnly = $true
$statusBox.Size = New-Object System.Drawing.Size(908,72)
$statusBox.Location = New-Object System.Drawing.Point(16,40)
$statusBox.BackColor = [System.Drawing.Color]::FromArgb(19,22,27)
$statusBox.ForeColor = $colorText
$statusBox.BorderStyle = 'FixedSingle'
$statusBox.Font = $fontText
$logPanel.Controls.Add($statusBox)

function Log($msg) { $statusBox.AppendText("$msg`r`n") }

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
  $dialog.BackColor = $colorCardBg
  $dialog.ForeColor = $colorText

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Size = New-Object System.Drawing.Size(490,35)
  $label.Location = New-Object System.Drawing.Point(18,16)
  $label.ForeColor = $colorText
  $label.Font = $fontText
  $dialog.Controls.Add($label)

  $textbox = New-Object System.Windows.Forms.TextBox
  $textbox.Size = New-Object System.Drawing.Size(490,25)
  $textbox.Location = New-Object System.Drawing.Point(18,58)
  $textbox.Text = $DefaultText
  $textbox.BackColor = [System.Drawing.Color]::FromArgb(19,22,27)
  $textbox.ForeColor = $colorText
  $textbox.BorderStyle = 'FixedSingle'
  $dialog.Controls.Add($textbox)

  $btnOk = New-StyledButton -Text "OK" -X 322 -Y 102 -Width 90 -Height 32
  $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dialog.Controls.Add($btnOk)

  $btnCancel = New-StyledButton -Text "Cancel" -X 418 -Y 102 -Width 90 -Height 32
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

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$saveHtmlDialog = New-Object System.Windows.Forms.SaveFileDialog
$saveHtmlDialog.Filter = 'HTML Files (*.html)|*.html'
$saveHtmlDialog.Title = 'Save HTML Report'
$saveHtmlDialog.FileName = ('DFO365_Report_{0}.html' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$btnRuleMode.Add_Click({
  $Script:EnableRulesOnDeploy = -not $Script:EnableRulesOnDeploy

  if ($Script:EnableRulesOnDeploy) {
    $btnRuleMode.Text = 'Rule Mode: Enabled After Deploy'
    $btnRuleMode.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(100,181,246)
    $btnRuleMode.BackColor = [System.Drawing.Color]::FromArgb(38,68,92)
    $lblMode.Text = 'Mode: Policies deploy or update; rules will be enabled after deploy'
    Log '[INFO] Rule mode set to: enable rules after deploy.'
  }
  else {
    $btnRuleMode.Text = 'Rule Mode: Disabled After Deploy'
    $btnRuleMode.FlatAppearance.BorderColor = $colorBorder
    $btnRuleMode.BackColor = [System.Drawing.Color]::FromArgb(52,58,66)
    $lblMode.Text = 'Mode: Policies deploy or update; rules remain disabled'
    Log '[INFO] Rule mode set to: keep rules disabled after deploy.'
  }
})

$btnConnect.Add_Click({
  if (Test-ExchangeOnlineConnection) {
    Update-ConnectionLabel -Label $lblConnection
    return
  }
  [void](Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})
})

$btnDisconnect.Add_Click({
  try {
    if (Test-ExchangeOnlineConnection) {
      Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop
    }
    Update-ConnectionLabel -Label $lblConnection
    Log "[OK] Disconnected."
  }
  catch {
    Log "[ERR] Disconnect failed: $($_.Exception.Message)"
  }
})

$btnLoadConfig.Add_Click({
  $ofd = New-Object System.Windows.Forms.OpenFileDialog
  $ofd.Filter = "JSON Files (*.json)|*.json"
  $ofd.InitialDirectory = $Script:ConfigDirectory
  if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    [void](Load-ConfigFile -Path $ofd.FileName -ConfigLabel $lblConfig)
  }
})

$btnTestMode.Add_Click({
  try {
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    $Names = Get-NamesMap
    Invoke-TestMode -NamesMap $Names -ConfigLabel $lblConfig -IndicatorLabels $script:PolicyIndicatorLabels
  } catch {
    Log "[ERR] Test mode failed: $($_.Exception.Message)"
  }
})

$btnValidate.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    $Names = Get-NamesMap
    Run-Validation -NamesMap $Names
  }
  catch {
    Log "[ERR] Validation error: $($_.Exception.Message)"
  }
})

$btnQuickBuild.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    $Names = Get-NamesMap
    $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'

    foreach ($cmd in @('Get-SafeLinksPolicy','Get-SafeAttachmentPolicy','Get-AntiPhishPolicy','Get-HostedContentFilterPolicy','Get-HostedOutboundSpamFilterPolicy','Get-MalwareFilterPolicy')) {
      if (-not (Ensure-ExchangeCommandAvailable -CommandName $cmd -Logger ${function:Log})) { return }
    }

    $dom = Get-AllAcceptedDomains
    Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy
    Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom
    Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy
    Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom
    Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy
    Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom
    Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy
    Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom
    Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify
    Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom
    Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify
    Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom
    Log "[OK] Zero Trust baseline deployment complete."
  }
  catch {
    Log "[ERR] Deploy Zero Trust Baseline error: $($_.Exception.Message)"
  }
})

$btnAPh.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-AntiPhishPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy
    Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Log "[OK] Anti-Phish deployment complete."
  }
  catch { Log "[ERR] Anti-Phish error: $($_.Exception.Message)" }
})

$btnSL.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy
    Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Log "[OK] Safe Links deployment complete."
  }
  catch { Log "[ERR] Safe Links error: $($_.Exception.Message)" }
})

$btnASp.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
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
    Log "[OK] Anti-Spam deployment complete."
  }
  catch { Log "[ERR] Anti-Spam error: $($_.Exception.Message)" }
})

$btnSA.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeAttachmentPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $dom = Get-AllAcceptedDomains
    Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy
    Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Log "[OK] Safe Attachments deployment complete."
  }
  catch { Log "[ERR] Safe Attachments error: $($_.Exception.Message)" }
})

$btnAMw.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-MalwareFilterPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
    $dom = Get-AllAcceptedDomains
    Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify
    Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Log "[OK] Anti-Malware deployment complete."
  }
  catch { Log "[ERR] Anti-Malware error: $($_.Exception.Message)" }
})

$btnSLUrls.Add_Click({
  try {
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
      Log ("[OK] {0} updated on '{1}'." -f $target, $policyName)
    }
  }
  catch {
    Log "[ERR] Safe Links list update error: $($_.Exception.Message)"
  }
})

$btnExportJson.Add_Click({
  if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    try {
      if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
      Export-PoliciesJson -Path $folderDialog.SelectedPath
      Log "[OK] Exported JSON to $($folderDialog.SelectedPath)"
    }
    catch {
      Log "[ERR] Export failed: $($_.Exception.Message)"
    }
  }
})

$btnExportHtml.Add_Click({
  try {
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if ($saveHtmlDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Export-PoliciesHtml -Path $saveHtmlDialog.FileName
    Log "[OK] Exported HTML report to $($saveHtmlDialog.FileName)"
  }
  catch {
    Log "[ERR] HTML export failed: $($_.Exception.Message)"
  }
})

$form.TopMost = $false
$form.Add_Shown({
  $form.Activate()
  if ($Script:EnableRulesOnDeploy) {
    $btnRuleMode.Text = 'Rule Mode: Enabled After Deploy'
    $btnRuleMode.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(100,181,246)
    $btnRuleMode.BackColor = [System.Drawing.Color]::FromArgb(38,68,92)
    $lblMode.Text = 'Mode: Policies deploy or update; rules will be enabled after deploy'
  }
  else {
    $btnRuleMode.Text = 'Rule Mode: Disabled After Deploy'
    $btnRuleMode.FlatAppearance.BorderColor = $colorBorder
    $btnRuleMode.BackColor = [System.Drawing.Color]::FromArgb(52,58,66)
    $lblMode.Text = 'Mode: Policies deploy or update; rules remain disabled'
  }
  Update-ConnectionLabel -Label $lblConnection
  [void](Load-ConfigFile -Path $Script:ZeroTrustConfigPath -ConfigLabel $lblConfig)
  try {
    $Names = Get-NamesMap
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
  } catch {}
})
[void]$form.ShowDialog()
