
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
# Shadow Suite UI Retrofit
# Target: ShadowDeploy-DefenderOffice365-SuiteUI.ps1
# Logo: shadowdeployo365.png
# Backend deployment/config/report functions above are preserved.

$form = New-Object System.Windows.Forms.Form
$form.Text = "ShadowDeploy Defender for Office 365 - Suite UI"
$form.Size = New-Object System.Drawing.Size(1220,900)
$form.MinimumSize = New-Object System.Drawing.Size(1220,900)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(13,16,23)
$form.ForeColor = [System.Drawing.Color]::White
$form.FormBorderStyle = 'Sizable'

$ShadowBg      = [System.Drawing.Color]::FromArgb(13,16,23)
$ShadowPanel   = [System.Drawing.Color]::FromArgb(22,27,34)
$ShadowBorder  = [System.Drawing.Color]::FromArgb(54,63,78)
$ShadowText    = [System.Drawing.Color]::FromArgb(235,239,245)
$ShadowMuted   = [System.Drawing.Color]::FromArgb(160,170,185)
$ShadowPurple  = [System.Drawing.Color]::FromArgb(124,77,255)
$ShadowBlue    = [System.Drawing.Color]::FromArgb(66,165,245)
$ShadowGreen   = [System.Drawing.Color]::FromArgb(67,160,71)
$ShadowOrange  = [System.Drawing.Color]::FromArgb(255,152,0)
$ShadowRed     = [System.Drawing.Color]::FromArgb(239,83,80)
$ShadowButton  = [System.Drawing.Color]::FromArgb(36,42,54)

$fontTitle  = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$fontSub    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$fontHeader = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontText   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$fontSmall  = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)

function New-ShadowCard {
  param([string]$Title,[int]$X,[int]$Y,[int]$Width,[int]$Height,[System.Drawing.Color]$AccentColor=$ShadowPurple)
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($X,$Y)
  $panel.Size = New-Object System.Drawing.Size($Width,$Height)
  $panel.BackColor = $ShadowPanel
  $panel.BorderStyle = 'FixedSingle'

  $accent = New-Object System.Windows.Forms.Panel
  $accent.BackColor = $AccentColor
  $accent.Location = New-Object System.Drawing.Point(0,0)
  $accent.Size = New-Object System.Drawing.Size(5,$Height)
  $panel.Controls.Add($accent)

  if ($Title) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Title
    $label.Font = $fontHeader
    $label.ForeColor = $ShadowText
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16,10)
    $panel.Controls.Add($label)

    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = $ShadowBorder
    $line.Location = New-Object System.Drawing.Point(16,36)
    $line.Size = New-Object System.Drawing.Size(($Width - 32),1)
    $panel.Controls.Add($line)
  }
  return $panel
}

function New-ShadowButton {
  param([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=36,[System.Drawing.Color]$Color=$ShadowButton)
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $Text
  $btn.Location = New-Object System.Drawing.Point($X,$Y)
  $btn.Size = New-Object System.Drawing.Size($Width,$Height)
  $btn.BackColor = $Color
  $btn.ForeColor = $ShadowText
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.BorderColor = $ShadowBorder
  $btn.FlatAppearance.BorderSize = 1
  $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(48,55,70)
  $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(38,44,58)
  $btn.Font = $fontText
  $btn.UseVisualStyleBackColor = $false
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $btn
}

function New-ShadowLabel {
  param([string]$Text,[int]$X,[int]$Y,[int]$Width=220,[int]$Height=20,[System.Drawing.Font]$Font=$null,[System.Drawing.Color]$Color=$null)
  if (-not $Font) { $Font = $fontText }
  if (-not $Color) { $Color = $ShadowMuted }
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X,$Y)
  $label.Size = New-Object System.Drawing.Size($Width,$Height)
  $label.Font = $Font
  $label.ForeColor = $Color
  return $label
}

function Set-ModuleStatus {
  param([string]$Status,[string]$Detail='')
  if ($script:LblModuleStatus) {
    $script:LblModuleStatus.Text = "Status: $Status"
    switch ($Status) {
      'Ready'        { $script:LblModuleStatus.ForeColor = $ShadowBlue }
      'Running'      { $script:LblModuleStatus.ForeColor = $ShadowOrange }
      'Completed'    { $script:LblModuleStatus.ForeColor = $ShadowGreen }
      'Warning'      { $script:LblModuleStatus.ForeColor = $ShadowOrange }
      'Failed'       { $script:LblModuleStatus.ForeColor = $ShadowRed }
      'Needs Review' { $script:LblModuleStatus.ForeColor = $ShadowOrange }
      default        { $script:LblModuleStatus.ForeColor = $ShadowMuted }
    }
  }
  if ($script:LblModuleDetail -and $Detail) { $script:LblModuleDetail.Text = $Detail }
}

# Header / Logo
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(20,16)
$headerPanel.Size = New-Object System.Drawing.Size(760,120)
$headerPanel.BackColor = $ShadowPanel
$headerPanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($headerPanel)

$logoPathCandidates = @(
  (Join-Path $Script:ScriptDirectory 'shadowdeployo365.png'),
  (Join-Path (Split-Path -Parent $Script:ScriptDirectory) 'shadowdeployo365.png'),
  (Join-Path (Join-Path (Split-Path -Parent $Script:ScriptDirectory) 'assets') 'shadowdeployo365.png')
)
$logoPath = $logoPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($logoPath) {
  try {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Image = [System.Drawing.Image]::FromFile($logoPath)
    $logoBox.SizeMode = 'Zoom'
    $logoBox.Location = New-Object System.Drawing.Point(16,14)
    $logoBox.Size = New-Object System.Drawing.Size(96,92)
    $headerPanel.Controls.Add($logoBox)
  } catch {}
} else {
  $logoFallback = New-Object System.Windows.Forms.Label
  $logoFallback.Text = "SD"
  $logoFallback.Font = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
  $logoFallback.ForeColor = $ShadowPurple
  $logoFallback.TextAlign = 'MiddleCenter'
  $logoFallback.Location = New-Object System.Drawing.Point(16,18)
  $logoFallback.Size = New-Object System.Drawing.Size(86,82)
  $logoFallback.BorderStyle = 'FixedSingle'
  $headerPanel.Controls.Add($logoFallback)
}

$headerPanel.Controls.Add((New-ShadowLabel -Text "ShadowDeploy Defender for Office 365" -X 128 -Y 18 -Width 580 -Height 32 -Font $fontTitle -Color $ShadowText))
$headerPanel.Controls.Add((New-ShadowLabel -Text "Shadow Suite deployment shell for Microsoft Defender for Office 365 Zero Trust baselines" -X 130 -Y 55 -Width 590 -Height 22 -Font $fontSub -Color $ShadowMuted))
$headerPanel.Controls.Add((New-ShadowLabel -Text "Suite UI Retrofit | Existing deployment logic preserved | Config-driven deployment" -X 130 -Y 80 -Width 590 -Height 22 -Font $fontSmall -Color $ShadowBlue))

# Module / Session Summary
$summaryPanel = New-ShadowCard -Title "MODULE / SESSION SUMMARY" -X 800 -Y 16 -Width 380 -Height 180 -AccentColor $ShadowBlue
$form.Controls.Add($summaryPanel)
$script:LblModuleStatus = New-ShadowLabel -Text "Status: Ready" -X 18 -Y 48 -Width 330 -Height 22 -Font $fontHeader -Color $ShadowBlue
$script:LblModuleDetail = New-ShadowLabel -Text "Waiting for operator action." -X 18 -Y 74 -Width 330 -Height 22 -Font $fontText -Color $ShadowMuted
$lblConnection = New-ShadowLabel -Text "Session: Not Connected" -X 18 -Y 102 -Width 345 -Height 24 -Font $fontText -Color $ShadowMuted
$lblConfig = New-ShadowLabel -Text "Config: Not Loaded" -X 18 -Y 128 -Width 345 -Height 24 -Font $fontText -Color $ShadowMuted
$lblMode = New-ShadowLabel -Text "Service Mode: Disabled" -X 18 -Y 152 -Width 345 -Height 22 -Font $fontText -Color $ShadowMuted
$summaryPanel.Controls.AddRange(@($script:LblModuleStatus,$script:LblModuleDetail,$lblConnection,$lblConfig,$lblMode))

# Workflow
$workflowPanel = New-ShadowCard -Title "MAIN WORKFLOW" -X 20 -Y 150 -Width 760 -Height 108 -AccentColor $ShadowPurple
$form.Controls.Add($workflowPanel)
$btnConnect     = New-ShadowButton -Text "Connect Graph / EXO" -X 18 -Y 50 -Width 135 -Color $ShadowBlue
$btnLoadConfig  = New-ShadowButton -Text "Load Configuration" -X 163 -Y 50 -Width 135 -Color $ShadowPurple
$btnBackup      = New-ShadowButton -Text "Backup Existing Policies" -X 308 -Y 50 -Width 160 -Color $ShadowOrange
$btnQuickBuild  = New-ShadowButton -Text "Deploy Policies" -X 478 -Y 50 -Width 125 -Color $ShadowGreen
$btnRuleMode    = New-ShadowButton -Text "Enable Services" -X 613 -Y 50 -Width 125 -Color $ShadowButton
$workflowPanel.Controls.AddRange(@($btnConnect,$btnLoadConfig,$btnBackup,$btnQuickBuild,$btnRuleMode))

# Deployment Areas
$deployPanel = New-ShadowCard -Title "DEPLOYMENT AREAS" -X 20 -Y 276 -Width 760 -Height 250 -AccentColor $ShadowGreen
$form.Controls.Add($deployPanel)
$btnAPh     = New-ShadowButton -Text "Anti-Phishing" -X 18 -Y 50 -Width 170 -Color $ShadowPurple
$btnSA      = New-ShadowButton -Text "Safe Attachments" -X 204 -Y 50 -Width 170 -Color $ShadowBlue
$btnSL      = New-ShadowButton -Text "Safe Links" -X 390 -Y 50 -Width 170 -Color $ShadowBlue
$btnASp     = New-ShadowButton -Text "Anti-Spam" -X 576 -Y 50 -Width 150 -Color $ShadowOrange
$btnAMw     = New-ShadowButton -Text "Anti-Malware" -X 18 -Y 98 -Width 170 -Color $ShadowRed
$btnQuar    = New-ShadowButton -Text "Quarantine" -X 204 -Y 98 -Width 170 -Color $ShadowButton
$btnPreset  = New-ShadowButton -Text "Preset Security Policies" -X 390 -Y 98 -Width 170 -Color $ShadowButton
$btnSLUrls  = New-ShadowButton -Text "Safe Links URL Lists" -X 576 -Y 98 -Width 150 -Color $ShadowButton
$deployPanel.Controls.AddRange(@($btnAPh,$btnSA,$btnSL,$btnASp,$btnAMw,$btnQuar,$btnPreset,$btnSLUrls))
$deployPanel.Controls.Add((New-ShadowLabel -Text "Quarantine and Preset Security Policies are advisory cards in this retrofit; no new backend deployment logic was added." -X 18 -Y 154 -Width 710 -Height 38 -Font $fontSmall -Color $ShadowMuted))

# Reporting
$reportPanel = New-ShadowCard -Title "REPORTING / EXPORT" -X 20 -Y 544 -Width 760 -Height 120 -AccentColor $ShadowOrange
$form.Controls.Add($reportPanel)
$btnExportHtml = New-ShadowButton -Text "Export Report" -X 18 -Y 52 -Width 150 -Color $ShadowOrange
$btnExportJson = New-ShadowButton -Text "Export JSON" -X 184 -Y 52 -Width 150 -Color $ShadowBlue
$btnOpenReports = New-ShadowButton -Text "Open Reports" -X 350 -Y 52 -Width 120 -Color $ShadowButton
$btnOpenLogs = New-ShadowButton -Text "Open Logs" -X 486 -Y 52 -Width 110 -Color $ShadowButton
$btnOpenConfig = New-ShadowButton -Text "Open Config" -X 612 -Y 52 -Width 110 -Color $ShadowButton
$reportPanel.Controls.AddRange(@($btnExportHtml,$btnExportJson,$btnOpenReports,$btnOpenLogs,$btnOpenConfig))

# Execution Results
$resultsPanel = New-ShadowCard -Title "EXECUTION RESULTS" -X 800 -Y 214 -Width 380 -Height 312 -AccentColor $ShadowPurple
$form.Controls.Add($resultsPanel)
$script:PolicyIndicatorLabels = @{}
function New-ResultIndicator {
  param([string]$Name,[int]$Y)
  $nameLabel = New-ShadowLabel -Text $Name -X 18 -Y $Y -Width 185 -Height 20 -Font $fontText -Color $ShadowMuted
  $valueLabel = New-ShadowLabel -Text "Unknown" -X 220 -Y $Y -Width 130 -Height 20 -Font $fontText -Color $ShadowOrange
  $resultsPanel.Controls.AddRange(@($nameLabel,$valueLabel))
  return $valueLabel
}
$script:PolicyIndicatorLabels['Anti-Phish']       = New-ResultIndicator -Name 'Anti-Phishing' -Y 52
$script:PolicyIndicatorLabels['Safe Attachments'] = New-ResultIndicator -Name 'Safe Attachments' -Y 82
$script:PolicyIndicatorLabels['Safe Links']       = New-ResultIndicator -Name 'Safe Links' -Y 112
$script:PolicyIndicatorLabels['Inbound Spam']     = New-ResultIndicator -Name 'Inbound Anti-Spam' -Y 142
$script:PolicyIndicatorLabels['Outbound Spam']    = New-ResultIndicator -Name 'Outbound Anti-Spam' -Y 172
$script:PolicyIndicatorLabels['Anti-Malware']     = New-ResultIndicator -Name 'Anti-Malware' -Y 202
$resultsPanel.Controls.Add((New-ShadowLabel -Text "Ready = deployed/disabled | Enabled = active | Missing = not found | Policy Only = rule missing" -X 18 -Y 246 -Width 335 -Height 42 -Font $fontSmall -Color $ShadowMuted))

# Operational Log
$logPanel = New-ShadowCard -Title "STATUS / OPERATIONAL LOG" -X 20 -Y 682 -Width 1160 -Height 160 -AccentColor $ShadowBlue
$form.Controls.Add($logPanel)
$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.ReadOnly = $true
$statusBox.Size = New-Object System.Drawing.Size(1126,102)
$statusBox.Location = New-Object System.Drawing.Point(18,44)
$statusBox.BackColor = [System.Drawing.Color]::FromArgb(8,10,14)
$statusBox.ForeColor = $ShadowText
$statusBox.BorderStyle = 'FixedSingle'
$statusBox.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
$logPanel.Controls.Add($statusBox)

function Log($msg) {
  $timestamp = Get-Date -Format 'HH:mm:ss'
  $statusBox.AppendText("[$timestamp] $msg`r`n")
  $statusBox.SelectionStart = $statusBox.Text.Length
  $statusBox.ScrollToCaret()
}

# Modal dialogs retained for Safe Links URL workflow
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
  $dialog.BackColor = $ShadowPanel
  $dialog.ForeColor = $ShadowText

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Size = New-Object System.Drawing.Size(490,35)
  $label.Location = New-Object System.Drawing.Point(18,16)
  $label.ForeColor = $ShadowText
  $label.Font = $fontText
  $dialog.Controls.Add($label)

  $textbox = New-Object System.Windows.Forms.TextBox
  $textbox.Size = New-Object System.Drawing.Size(490,25)
  $textbox.Location = New-Object System.Drawing.Point(18,58)
  $textbox.Text = $DefaultText
  $textbox.BackColor = [System.Drawing.Color]::FromArgb(8,10,14)
  $textbox.ForeColor = $ShadowText
  $textbox.BorderStyle = 'FixedSingle'
  $dialog.Controls.Add($textbox)

  $btnOk = New-ShadowButton -Text "OK" -X 322 -Y 102 -Width 90 -Height 32 -Color $ShadowGreen
  $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dialog.Controls.Add($btnOk)
  $btnCancel = New-ShadowButton -Text "Cancel" -X 418 -Y 102 -Width 90 -Height 32 -Color $ShadowButton
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

# Folders / dialogs
$Script:RepoRoot = Split-Path -Parent $Script:ScriptDirectory
$Script:ReportsDirectory = Join-Path $Script:RepoRoot 'reports'
$Script:LogsDirectory = Join-Path $Script:RepoRoot 'logs'
foreach ($dir in @($Script:ReportsDirectory,$Script:LogsDirectory,$Script:ConfigDirectory)) {
  if (-not (Test-Path $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
}
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$saveHtmlDialog = New-Object System.Windows.Forms.SaveFileDialog
$saveHtmlDialog.Filter = 'HTML Files (*.html)|*.html'
$saveHtmlDialog.Title = 'Save ShadowDeploy Defender for Office 365 Report'
$saveHtmlDialog.FileName = ('ShadowDeploy-O365-Report-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Export-ShadowSuiteHtmlReport {
  param([Parameter(Mandatory)][string]$Path)
  Export-PoliciesHtml -Path $Path
  try {
    $html = Get-Content -Path $Path -Raw -Encoding UTF8
    $html = $html -replace 'DFO365 Deployment Tool - HTML Report','ShadowDeploy Defender for Office 365 - Deployment Report'
    $html = $html -replace 'DFO365 HTML Report','ShadowDeploy Defender for Office 365 Report'
    $html = $html -replace 'background:#1b1f26','background:#0d1017'
    $html = $html -replace 'background:#20252d','background:#161b22'
    $html = $html -replace '<h1>ShadowDeploy Defender for Office 365 - Deployment Report</h1>',
      '<h1>ShadowDeploy Defender for Office 365 - Deployment Report</h1><div class="meta">Shadow Suite branded report | Executive summary, deployment summary, policy inventory, success/failure status, and recommendations.</div><div class="card"><h2>Executive Summary</h2><p>This report summarizes Defender for Office 365 policy and rule inventory collected by ShadowDeploy Defender for Office 365.</p></div><div class="card"><h2>Recommendations</h2><ul><li>Review status before enabling enforcement in production.</li><li>Validate Safe Links, Safe Attachments, anti-phishing, anti-spam, and anti-malware behavior using controlled test scenarios.</li><li>Export JSON before and after changes for evidence and rollback support.</li></ul></div>'
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.Encoding]::UTF8)
  } catch { Log "[WARN] Report generated, but Shadow Suite branding update failed: $($_.Exception.Message)" }
}

# Events
$btnConnect.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Connecting to Microsoft cloud services...'
    if (Test-ExchangeOnlineConnection) {
      Update-ConnectionLabel -Label $lblConnection
      $lblConnection.Text = $lblConnection.Text -replace '^Status:', 'Session:'
      Set-ModuleStatus -Status 'Ready' -Detail 'Session already connected.'
      return
    }
    if (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log}) {
      $lblConnection.Text = $lblConnection.Text -replace '^Status:', 'Session:'
      Set-ModuleStatus -Status 'Ready' -Detail 'Exchange Online session connected.'
    }
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Connection failed.'; Log "[ERR] Connect failed: $($_.Exception.Message)" }
})

$btnLoadConfig.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Loading configuration...'
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "JSON Files (*.json)|*.json"
    $ofd.InitialDirectory = $Script:ConfigDirectory
    if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
      if (Load-ConfigFile -Path $ofd.FileName -ConfigLabel $lblConfig) {
        $lblConfig.Text = $lblConfig.Text -replace '^Profile: Zero Trust \| ', ''
        Set-ModuleStatus -Status 'Ready' -Detail 'Configuration loaded.'
      }
    }
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Configuration failed.'; Log "[ERR] Config load failed: $($_.Exception.Message)" }
})

$btnBackup.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Backing up policies...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    $backupPath = Join-Path $Script:ReportsDirectory ("Backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Export-PoliciesJson -Path $backupPath
    Log "[OK] Backup exported to $backupPath"
    Set-ModuleStatus -Status 'Completed' -Detail 'Backup complete.'
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Backup failed.'; Log "[ERR] Backup failed: $($_.Exception.Message)" }
})

$btnRuleMode.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Applying service state...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    $Script:EnableRulesOnDeploy = -not $Script:EnableRulesOnDeploy
    $Names = Get-NamesMap
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    if ($Script:EnableRulesOnDeploy) {
      $btnRuleMode.Text = 'Disable Services'
      $btnRuleMode.BackColor = $ShadowRed
      $lblMode.Text = 'Service Mode: Enabled'
      $lblMode.ForeColor = $ShadowGreen
      Log '[OK] Services enabled.'
      Set-ModuleStatus -Status 'Completed' -Detail 'Services enabled.'
    } else {
      $btnRuleMode.Text = 'Enable Services'
      $btnRuleMode.BackColor = $ShadowButton
      $lblMode.Text = 'Service Mode: Disabled'
      $lblMode.ForeColor = $ShadowMuted
      Log '[OK] Services disabled.'
      Set-ModuleStatus -Status 'Completed' -Detail 'Services disabled.'
    }
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Service state failed.'; Log "[ERR] Enable Services failed: $($_.Exception.Message)" }
})

$btnQuickBuild.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Deploying Defender for Office 365 baseline...'
    Log '[INFO] Starting ShadowDeploy Defender for Office 365 baseline deployment...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    $Names = Get-NamesMap
    $AdminNotify = Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'
    foreach ($cmd in @('Get-SafeLinksPolicy','Get-SafeAttachmentPolicy','Get-AntiPhishPolicy','Get-HostedContentFilterPolicy','Get-HostedOutboundSpamFilterPolicy','Get-MalwareFilterPolicy')) {
      if (-not (Ensure-ExchangeCommandAvailable -CommandName $cmd -Logger ${function:Log})) { Set-ModuleStatus -Status 'Failed' -Detail "Missing cmdlet: $cmd"; return }
    }
    $dom = Get-AllAcceptedDomains
    Log "[INFO] Accepted domain scope: $($dom -join ', ')"
    Log '[INFO] Deploying Safe Links...'; Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy; Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom
    Log '[INFO] Deploying Safe Attachments...'; Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy; Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom
    Log '[INFO] Deploying Anti-Phishing...'; Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy; Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom
    Log '[INFO] Deploying Inbound Anti-Spam...'; Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy; Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom
    Log '[INFO] Deploying Outbound Anti-Spam...'; Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify; Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom
    Log '[INFO] Deploying Anti-Malware...'; Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify; Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom
    Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
    Log "[OK] ShadowDeploy Defender for Office 365 deployment complete."
    Set-ModuleStatus -Status 'Completed' -Detail 'Policy deployment completed.'
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Deployment failed.'; Log "[ERR] Deploy Policies error: $($_.Exception.Message)" }
})

$btnAPh.Add_Click({
  try { Set-ModuleStatus -Status 'Running' -Detail 'Deploying Anti-Phishing...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-AntiPhishPolicy' -Logger ${function:Log})) { return }; $Names=Get-NamesMap; $dom=Get-AllAcceptedDomains; Ensure-AntiPhishPolicy -Name $Names.AntiPhishPolicy; Ensure-AntiPhishRuleGlobal -RuleName $Names.AntiPhishRule -PolicyName $Names.AntiPhishPolicy -RecipientDomains $dom; Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy; Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels; Set-ModuleStatus -Status 'Completed' -Detail 'Anti-Phishing completed.'; Log '[OK] Anti-Phishing deployment complete.' } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Anti-Phishing failed.'; Log "[ERR] Anti-Phishing error: $($_.Exception.Message)" }
})
$btnSL.Add_Click({
  try { Set-ModuleStatus -Status 'Running' -Detail 'Deploying Safe Links...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { return }; $Names=Get-NamesMap; $dom=Get-AllAcceptedDomains; Ensure-SafeLinksPolicy -Name $Names.SafeLinksPolicy; Ensure-SafeLinksRuleGlobal -RuleName $Names.SafeLinksRule -PolicyName $Names.SafeLinksPolicy -RecipientDomains $dom; Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy; Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels; Set-ModuleStatus -Status 'Completed' -Detail 'Safe Links completed.'; Log '[OK] Safe Links deployment complete.' } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Safe Links failed.'; Log "[ERR] Safe Links error: $($_.Exception.Message)" }
})
$btnASp.Add_Click({
  try { Set-ModuleStatus -Status 'Running' -Detail 'Deploying Anti-Spam...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedContentFilterPolicy' -Logger ${function:Log})) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-HostedOutboundSpamFilterPolicy' -Logger ${function:Log})) { return }; $Names=Get-NamesMap; $AdminNotify=Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'; $dom=Get-AllAcceptedDomains; Ensure-AntiSpamInboundPolicy -Name $Names.AntiSpamInboundPolicy; Ensure-AntiSpamInboundRuleGlobal -RuleName $Names.AntiSpamInboundRule -PolicyName $Names.AntiSpamInboundPolicy -RecipientDomains $dom; Ensure-AntiSpamOutboundPolicy -Name $Names.AntiSpamOutboundPolicy -NotifyAddress $AdminNotify; Ensure-AntiSpamOutboundRuleGlobal -RuleName $Names.AntiSpamOutboundRule -PolicyName $Names.AntiSpamOutboundPolicy -SenderDomains $dom; Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy; Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels; Set-ModuleStatus -Status 'Completed' -Detail 'Anti-Spam completed.'; Log '[OK] Anti-Spam deployment complete.' } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Anti-Spam failed.'; Log "[ERR] Anti-Spam error: $($_.Exception.Message)" }
})
$btnSA.Add_Click({
  try { Set-ModuleStatus -Status 'Running' -Detail 'Deploying Safe Attachments...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeAttachmentPolicy' -Logger ${function:Log})) { return }; $Names=Get-NamesMap; $dom=Get-AllAcceptedDomains; Ensure-SafeAttachmentsPolicy -Name $Names.SafeAttachmentsPolicy; Ensure-SafeAttachmentsRuleGlobal -RuleName $Names.SafeAttachmentsRule -PolicyName $Names.SafeAttachmentsPolicy -RecipientDomains $dom; Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy; Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels; Set-ModuleStatus -Status 'Completed' -Detail 'Safe Attachments completed.'; Log '[OK] Safe Attachments deployment complete.' } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Safe Attachments failed.'; Log "[ERR] Safe Attachments error: $($_.Exception.Message)" }
})
$btnAMw.Add_Click({
  try { Set-ModuleStatus -Status 'Running' -Detail 'Deploying Anti-Malware...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }; if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-MalwareFilterPolicy' -Logger ${function:Log})) { return }; $Names=Get-NamesMap; $AdminNotify=Get-ConfigValue -SectionName 'General' -Key 'AdminNotify' -DefaultValue 'postmaster@yourdomain.com'; $dom=Get-AllAcceptedDomains; Ensure-AntiMalwarePolicy -Name $Names.AntiMalwarePolicy -AdminNotify $AdminNotify; Ensure-AntiMalwareRuleGlobal -RuleName $Names.AntiMalwareRule -PolicyName $Names.AntiMalwarePolicy -RecipientDomains $dom; Apply-DesiredRuleState -NamesMap $Names -EnableRules:$Script:EnableRulesOnDeploy; Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels; Set-ModuleStatus -Status 'Completed' -Detail 'Anti-Malware completed.'; Log '[OK] Anti-Malware deployment complete.' } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Anti-Malware failed.'; Log "[ERR] Anti-Malware error: $($_.Exception.Message)" }
})

$btnQuar.Add_Click({ Set-ModuleStatus -Status 'Needs Review' -Detail 'Quarantine workflow is advisory only.'; Log '[INFO] Quarantine card selected. No quarantine changes executed in this version.' })
$btnPreset.Add_Click({ Set-ModuleStatus -Status 'Needs Review' -Detail 'Preset Security Policies workflow is advisory only.'; Log '[INFO] Preset Security Policies card selected. No preset policy changes executed in this version.' })

$btnSLUrls.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Updating Safe Links URL list...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    if (-not (Ensure-ConfigLoaded -ConfigLabel $lblConfig)) { return }
    if (-not (Ensure-ExchangeCommandAvailable -CommandName 'Get-SafeLinksPolicy' -Logger ${function:Log})) { return }
    $Names = Get-NamesMap
    $policyName = $Names.SafeLinksPolicy
    $mode = Show-ModalMessageBox -Owner $form -Text "Choose YES=Block, NO=DoNotRewrite, Cancel=Disabled list" -Caption "Safe Links URL List" -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNoCancel) -Icon ([System.Windows.Forms.MessageBoxIcon]::Question)
    if ($mode -eq [System.Windows.Forms.DialogResult]::Cancel) { $target = 'DisabledUrls' } elseif ($mode -eq [System.Windows.Forms.DialogResult]::Yes) { $target = 'BlockedUrls' } else { $target = 'DoNotRewriteUrls' }
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
      Set-ModuleStatus -Status 'Completed' -Detail 'Safe Links URL list updated.'
    }
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'Safe Links URL update failed.'; Log "[ERR] Safe Links list update error: $($_.Exception.Message)" }
})

$btnExportJson.Add_Click({
  if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    try { Set-ModuleStatus -Status 'Running' -Detail 'Exporting JSON...'; if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }; Export-PoliciesJson -Path $folderDialog.SelectedPath; Log "[OK] Exported JSON to $($folderDialog.SelectedPath)"; Set-ModuleStatus -Status 'Completed' -Detail 'JSON export complete.' }
    catch { Set-ModuleStatus -Status 'Failed' -Detail 'JSON export failed.'; Log "[ERR] Export failed: $($_.Exception.Message)" }
  }
})
$btnExportHtml.Add_Click({
  try {
    Set-ModuleStatus -Status 'Running' -Detail 'Generating Shadow Suite report...'
    if (-not (Ensure-ExchangeOnlineAuthenticated -ConnectionLabel $lblConnection -Logger ${function:Log})) { return }
    $saveHtmlDialog.InitialDirectory = $Script:ReportsDirectory
    if ($saveHtmlDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { Set-ModuleStatus -Status 'Ready' -Detail 'Report export cancelled.'; return }
    Export-ShadowSuiteHtmlReport -Path $saveHtmlDialog.FileName
    Log "[OK] Exported Shadow Suite HTML report to $($saveHtmlDialog.FileName)"
    Set-ModuleStatus -Status 'Completed' -Detail 'HTML report generated.'
  } catch { Set-ModuleStatus -Status 'Failed' -Detail 'HTML report failed.'; Log "[ERR] HTML export failed: $($_.Exception.Message)" }
})
$btnOpenReports.Add_Click({ try { Start-Process $Script:ReportsDirectory } catch { Log "[WARN] Could not open reports folder: $($_.Exception.Message)" } })
$btnOpenLogs.Add_Click({ try { Start-Process $Script:LogsDirectory } catch { Log "[WARN] Could not open logs folder: $($_.Exception.Message)" } })
$btnOpenConfig.Add_Click({ try { Start-Process $Script:ConfigDirectory } catch { Log "[WARN] Could not open config folder: $($_.Exception.Message)" } })

$btnExit = New-ShadowButton -Text "Exit" -X 1070 -Y 850 -Width 110 -Height 30 -Color $ShadowRed
$form.Controls.Add($btnExit)
$btnExit.Add_Click({ $form.Close() })

$form.TopMost = $false
$form.Add_Shown({
  $form.Activate()
  Set-ModuleStatus -Status 'Ready' -Detail 'ShadowDeploy Office 365 module ready.'
  Update-ConnectionLabel -Label $lblConnection
  $lblConnection.Text = $lblConnection.Text -replace '^Status:', 'Session:'
  [void](Load-ConfigFile -Path $Script:ZeroTrustConfigPath -ConfigLabel $lblConfig)
  $lblConfig.Text = $lblConfig.Text -replace '^Profile: Zero Trust \| ', ''
  try {
    $Names = Get-NamesMap
    Update-PolicyIndicators -NamesMap $Names -IndicatorLabels $script:PolicyIndicatorLabels
  } catch {}
})
[void]$form.ShowDialog()
