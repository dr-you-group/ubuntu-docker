#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$GeneratorPath = Join-Path $RepoRoot 'NewUbuntuDindEnvironment.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-False {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )
    if ($Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] [string]$Message
    )
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter(Mandatory)] [string]$Message
    )
    $Threw = $false
    try {
        & $Action
    }
    catch {
        $Threw = $true
    }
    if (-not $Threw) {
        throw "Assertion failed: expected an exception for $Message"
    }
}

$PowerShellFiles = @($GeneratorPath)
$PowerShellFiles += @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'templates') -Recurse -File |
    Where-Object { $_.Name -like '*.ps1' -or $_.Name -like '*.ps1.template' } |
    Select-Object -ExpandProperty FullName)
$PowerShellFiles += @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -File -Filter '*.ps1' |
    Select-Object -ExpandProperty FullName)

foreach ($Path in $PowerShellFiles) {
    $Tokens = $null
    $ParseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    if ($ParseErrors.Count -gt 0) {
        $Details = ($ParseErrors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "PowerShell parse failed for $Path`n$Details"
    }
}

$GeneratorTokens = $null
$GeneratorErrors = $null
$GeneratorAst = [Management.Automation.Language.Parser]::ParseFile(
    $GeneratorPath,
    [ref]$GeneratorTokens,
    [ref]$GeneratorErrors
)
Assert-Equal 0 $GeneratorErrors.Count 'Generator parser errors'

$FunctionNames = @(
    'Test-IPv4Address',
    'Get-NetworkCidr',
    'Get-IPv4CidrInfo',
    'ConvertTo-IPv4Address',
    'Test-IPv4HostCidr',
    'Test-IPv4CidrsOverlap',
    'Test-IPv4CidrContains',
    'Test-PrivateIPv4Cidr',
    'Get-ObjectPropertyValue',
    'Get-CloudflareAddressOwners',
    'Get-DockerNetworkCidrs',
    'Get-HostRouteCidrs',
    'Get-CloudflarePrivateAllocation',
    'Get-CloudflareNumericErrorCodes',
    'New-CloudflareApiException',
    'Invoke-CloudflareApi',
    'Get-CloudflarePagedResults',
    'Test-CloudflareResourceId',
    'Resolve-CloudflareCreation',
    'Write-CloudflareTransactionJournal',
    'New-CloudflareTunnelResource',
    'New-CloudflareRouteResource',
    'Remove-CloudflareProvisioningResources',
    'Invoke-CloudflareTransactionRecovery',
    'Test-WireGuardEndpoint',
    'Test-WireGuardPublicKey',
    'Test-MemoryValue',
    'Expand-TemplateFile',
    'Assert-DockerComposeVersion',
    'Assert-DockerEngineVersion'
)

$FunctionAsts = @($GeneratorAst.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
foreach ($Name in $FunctionNames) {
    $FunctionAst = $FunctionAsts | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $FunctionAst) {
        throw "Required generator function is missing: $Name"
    }
    . ([scriptblock]::Create($FunctionAst.Extent.Text))
}

Assert-True (Test-IPv4Address '10.19.10.241') 'normal IPv4 address'
Assert-False (Test-IPv4Address '0.0.0.0') 'unspecified IPv4 address'
Assert-False (Test-IPv4Address '999.19.10.241') 'invalid IPv4 address'
Assert-Equal '10.19.10.0/24' (Get-NetworkCidr -Address '10.19.10.241' -PrefixLength 24) 'network CIDR'

$Cidr = Get-IPv4CidrInfo -Value '10.253.77.10/24'
Assert-True ($null -ne $Cidr) 'valid strict CIDR'
Assert-Equal '10.253.77.0/24' $Cidr.NetworkCidr 'CIDR network canonicalization'
Assert-True (Test-IPv4HostCidr '10.253.77.10/24') 'usable WireGuard address'
Assert-False (Test-IPv4HostCidr '10.253.77.0/24') 'network address rejection'
Assert-False (Test-IPv4HostCidr '10.253.77.255/24') 'broadcast rejection'
Assert-False (Test-IPv4HostCidr '10.253.77.10/30') 'prefix restriction'
Assert-False ($null -ne (Get-IPv4CidrInfo -Value '010.253.77.10/24')) 'leading-zero CIDR rejection'
Assert-True (Test-IPv4CidrsOverlap -First '10.0.0.0/24' -Second '10.0.0.128/25') 'overlap detection'
Assert-False (Test-IPv4CidrsOverlap -First '10.0.0.0/24' -Second '10.0.1.0/24') 'separate CIDRs'
Assert-True (Test-PrivateIPv4Cidr '10.210.0.0/24') 'RFC1918 Cloudflare pool'
Assert-False (Test-PrivateIPv4Cidr '203.0.113.0/24') 'public Cloudflare pool rejection'
Assert-False (Test-PrivateIPv4Cidr '10.210.0.1/24') 'non-canonical Cloudflare pool rejection'
$CloudflareAllocation = Get-CloudflarePrivateAllocation `
    -PoolCidr '10.210.0.0/24' `
    -ReservedCidrs @('10.210.0.0/29', '10.210.0.16/29')
Assert-Equal '10.210.0.8/29' $CloudflareAllocation.DockerSubnet 'first unused Cloudflare /29'
Assert-Equal '10.210.0.10' $CloudflareAllocation.PrivateIp 'Cloudflare desktop uses subnet host +2'
Assert-Equal '10.210.0.10/32' $CloudflareAllocation.PrivateCidr 'Cloudflare advertised host route'
Assert-True (
    Test-CloudflareResourceId '11111111-2222-4333-8444-555555555555'
) 'Cloudflare Tunnel UUID'
Assert-False (Test-CloudflareResourceId 'not-a-cloudflare-id') 'malformed Cloudflare resource ID'

Assert-True (Test-WireGuardEndpoint '192.0.2.1:51820') 'IPv4 WireGuard endpoint'
Assert-True (Test-WireGuardEndpoint 'wg.example.com:51820') 'DNS WireGuard endpoint'
Assert-False (Test-WireGuardEndpoint '[2001:db8::1]:51820') 'IPv6 endpoint rejection'
Assert-False (Test-WireGuardEndpoint '999.0.2.1:51820') 'invalid IPv4 endpoint rejection'
Assert-False (Test-WireGuardEndpoint 'wg.example.com:0') 'port zero rejection'

$ValidPublicKey = 'eym0tv2TMkozjekoJ6d25eVR2zl+gYgZswk/2EtzIhU='
Assert-True (Test-WireGuardPublicKey $ValidPublicKey) 'valid WireGuard public key'
Assert-False (Test-WireGuardPublicKey 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=') 'all-zero key rejection'
Assert-False (Test-WireGuardPublicKey 'not-a-key') 'malformed key rejection'

Assert-True (Test-MemoryValue '4096m') 'memory in MiB'
Assert-True (Test-MemoryValue '4G') 'memory in GiB'
Assert-False (Test-MemoryValue '4096') 'unitless memory rejection'
Assert-False (Test-MemoryValue '-1') 'special unlimited value is handled outside memory parser'

$script:MockDockerOutput = ''
$script:MockDockerExitCode = 0
function docker {
    $global:LASTEXITCODE = $script:MockDockerExitCode
    if (-not [string]::IsNullOrEmpty($script:MockDockerOutput)) {
        $script:MockDockerOutput
    }
}

$script:MockDockerOutput = '28.0.0'
Assert-DockerEngineVersion
$script:MockDockerOutput = 'v29.1.3+desktop.1'
Assert-DockerEngineVersion
$script:MockDockerOutput = '27.5.1'
Assert-Throws { Assert-DockerEngineVersion } 'Docker Engine 27 rejection'
$script:MockDockerOutput = '2.33.1'
Assert-DockerComposeVersion
$script:MockDockerOutput = 'v2.40.0-desktop.1'
Assert-DockerComposeVersion
$script:MockDockerOutput = '2.33.0'
Assert-Throws { Assert-DockerComposeVersion } 'Docker Compose 2.33.0 rejection'
Remove-Item Function:\docker

$script:CloudflareRequest = $null
$script:MockManagementToken = 'CI_DUMMY_MANAGEMENT_TOKEN_0123456789'
function Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$ErrorAction,
        [bool]$UseBasicParsing,
        [int]$TimeoutSec,
        [string]$ContentType,
        [string]$Body
    )
    $script:CloudflareRequest = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = $ErrorAction
        UseBasicParsing = $UseBasicParsing
        TimeoutSec = $TimeoutSec
        ContentType = $ContentType
        Body = $Body
    }
    return [pscustomobject]@{ success = $true; result = [pscustomobject]@{ id = 'mock-id' } }
}

$null = Invoke-CloudflareApi `
    -Method POST `
    -Path '/accounts/0123456789abcdef0123456789abcdef/cfd_tunnel' `
    -ApiToken $script:MockManagementToken `
    -Body @{ name = 'dockervm-ci'; config_src = 'cloudflare' }
Assert-True (
    $script:CloudflareRequest.Uri -eq
    'https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/cfd_tunnel'
) 'Cloudflare API account-scoped URI'
Assert-True ($script:CloudflareRequest.Method -eq 'POST') 'Cloudflare API POST method'
Assert-True (
    $script:CloudflareRequest.Headers.Authorization -eq "Bearer $($script:MockManagementToken)"
) 'Cloudflare API token is confined to the Authorization header'
Assert-Equal 'application/json' $script:CloudflareRequest.Headers.Accept 'Cloudflare API Accept header'
Assert-Equal 90 $script:CloudflareRequest.TimeoutSec 'Cloudflare API finite timeout'
$CloudflareBody = $script:CloudflareRequest.Body | ConvertFrom-Json
Assert-True ($CloudflareBody.name -eq 'dockervm-ci') 'Cloudflare Tunnel request name'
Assert-True ($CloudflareBody.config_src -eq 'cloudflare') 'Cloudflare Tunnel config source'

function New-MockCloudflareHttpError {
    param(
        [Parameter(Mandatory)] [int]$StatusCode,
        [Parameter(Mandatory)] [int]$ErrorCode
    )

    $Exception = [InvalidOperationException]::new("hostile response text $($script:MockManagementToken)")
    Add-Member `
        -InputObject $Exception `
        -MemberType NoteProperty `
        -Name Response `
        -Value ([pscustomobject]@{ StatusCode = $StatusCode })
    $Record = [Management.Automation.ErrorRecord]::new(
        $Exception,
        'MockCloudflareHttpError',
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
    $Record.ErrorDetails = [Management.Automation.ErrorDetails]::new(
        ('{{"success":false,"errors":[{{"code":{0},"message":"hostile {1}"}}]}}' -f
            $ErrorCode,
            $script:MockManagementToken)
    )
    return $Record
}

$script:CloudflareMockMode = ''
$script:CloudflareCalls = [Collections.Generic.List[string]]::new()
$script:CloudflareSleepCalls = [Collections.Generic.List[int]]::new()
$script:MockTunnelId = '11111111-2222-4333-8444-555555555555'
$script:MockRouteId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
function Start-Sleep {
    param([int]$Seconds)
    $script:CloudflareSleepCalls.Add($Seconds)
}
function Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$ErrorAction,
        [bool]$UseBasicParsing,
        [int]$TimeoutSec,
        [string]$ContentType,
        [string]$Body
    )

    $script:CloudflareCalls.Add("$Method $Uri")
    if ($Method -eq 'POST') {
        switch ($script:CloudflareMockMode) {
            'tunnel-403' { throw (New-MockCloudflareHttpError -StatusCode 403 -ErrorCode 10000) }
            'tunnel-503-match' { throw (New-MockCloudflareHttpError -StatusCode 503 -ErrorCode 1001) }
            'route-503-match' { throw (New-MockCloudflareHttpError -StatusCode 503 -ErrorCode 1002) }
            'transport-zero' { throw "hostile transport detail $($script:MockManagementToken)" }
            'invalid-id-match' {
                return [pscustomobject]@{
                    success = $true
                    result = [pscustomobject]@{ id = 'invalid-id' }
                }
            }
            'success-false' {
                return [pscustomobject]@{
                    success = $false
                    errors = @([pscustomobject]@{
                        code = 7003
                        message = "hostile response $($script:MockManagementToken)"
                    })
                }
            }
        }
    }
    if ($script:CloudflareMockMode -eq 'malformed-success') {
        return [pscustomobject]@{ success = 'true'; result = @() }
    }
    if ($script:CloudflareMockMode -eq 'pagination') {
        $Page = if ($Uri -match '[?&]page=(\d+)') { [int]$Matches[1] } else { 1 }
        return [pscustomobject]@{
            success = $true
            result = @([pscustomobject]@{ page = $Page })
            result_info = [pscustomobject]@{
                page = $Page
                per_page = 1
                count = 1
                total_count = 2
            }
        }
    }
    if ($script:CloudflareMockMode -eq 'pagination-guard') {
        return [pscustomobject]@{
            success = $true
            result = @([pscustomobject]@{ page = 1 })
            result_info = [pscustomobject]@{ per_page = 1; count = 1; total_count = 10001 }
        }
    }
    if ($Uri -like '*/cfd_tunnel?*') {
        $TunnelResults = @(if ($script:CloudflareMockMode -in @(
                'tunnel-503-match',
                'invalid-id-match'
            )) {
            [pscustomobject]@{ id = $script:MockTunnelId; name = 'dockervm-ci' }
        }
        else { })
        return [pscustomobject]@{
            success = $true
            result = $TunnelResults
            result_info = [pscustomobject]@{ page = 1; per_page = 1000; count = $TunnelResults.Count; total_count = $TunnelResults.Count }
        }
    }
    if ($Uri -like '*/teamnet/routes?*') {
        $RouteResults = @(if ($script:CloudflareMockMode -eq 'route-503-match') {
            [pscustomobject]@{
                id = $script:MockRouteId
                network = '10.210.0.2/32'
                tunnelId = $script:MockTunnelId
            }
        }
        else { })
        return [pscustomobject]@{
            success = $true
            result = $RouteResults
            result_info = [pscustomobject]@{ page = 1; per_page = 1000; count = $RouteResults.Count; total_count = $RouteResults.Count }
        }
    }
    return [pscustomobject]@{ success = $true; result = @() }
}

$script:CloudflareMockMode = 'tunnel-403'
$script:CloudflareCalls.Clear()
$Cloudflare403 = $null
try {
    $null = New-CloudflareTunnelResource `
        -AccountId '0123456789abcdef0123456789abcdef' `
        -ApiToken $script:MockManagementToken `
        -Name 'dockervm-ci'
}
catch { $Cloudflare403 = $_.Exception }
Assert-True ($null -ne $Cloudflare403) 'Cloudflare HTTP 403 is raised'
Assert-Equal 403 $Cloudflare403.Data['CloudflareHttpStatus'] 'Cloudflare HTTP 403 status data'
Assert-Equal '10000' $Cloudflare403.Data['CloudflareErrorCodes'] 'Cloudflare numeric error-code data'
Assert-False ([bool]$Cloudflare403.Data['CloudflarePostOutcomeAmbiguous']) 'Cloudflare HTTP 403 is deterministic'
Assert-True ($Cloudflare403.Message.Contains('Write permissions')) 'Cloudflare HTTP 403 permission hint'
Assert-False ($Cloudflare403.Message.Contains($script:MockManagementToken)) 'Cloudflare HTTP 403 omits the management token'
Assert-False ($Cloudflare403.Message.Contains('hostile')) 'Cloudflare HTTP 403 omits API response messages'
Assert-Equal 1 $script:CloudflareCalls.Count 'Cloudflare HTTP 403 is not reconciled'

$script:CloudflareMockMode = 'tunnel-503-match'
$script:CloudflareCalls.Clear()
$ReconciledTunnelId = New-CloudflareTunnelResource `
    -AccountId '0123456789abcdef0123456789abcdef' `
    -ApiToken $script:MockManagementToken `
    -Name 'dockervm-ci'
Assert-Equal $script:MockTunnelId $ReconciledTunnelId 'Cloudflare HTTP 503 tunnel reconciliation'
Assert-Equal 2 $script:CloudflareCalls.Count 'Cloudflare HTTP 503 uses one read-only reconciliation'

$script:CloudflareMockMode = 'invalid-id-match'
$script:CloudflareCalls.Clear()
$ReconciledInvalidId = New-CloudflareTunnelResource `
    -AccountId '0123456789abcdef0123456789abcdef' `
    -ApiToken $script:MockManagementToken `
    -Name 'dockervm-ci'
Assert-Equal $script:MockTunnelId $ReconciledInvalidId 'Cloudflare invalid 2xx ID reconciliation'
Assert-Equal 2 $script:CloudflareCalls.Count 'Cloudflare invalid 2xx ID performs a read-only reconciliation'

$script:CloudflareMockMode = 'route-503-match'
$script:CloudflareCalls.Clear()
$ReconciledRouteId = New-CloudflareRouteResource `
    -AccountId '0123456789abcdef0123456789abcdef' `
    -ApiToken $script:MockManagementToken `
    -TunnelId $script:MockTunnelId `
    -Network '10.210.0.2/32' `
    -Comment 'unit test'
Assert-Equal $script:MockRouteId $ReconciledRouteId 'Cloudflare HTTP 503 route reconciliation'
Assert-Equal 2 $script:CloudflareCalls.Count 'Cloudflare route reconciliation uses only one GET after POST'

$script:CloudflareMockMode = 'transport-zero'
$script:CloudflareCalls.Clear()
$script:CloudflareSleepCalls.Clear()
$UnknownTunnel = $null
try {
    $null = New-CloudflareTunnelResource `
        -AccountId '0123456789abcdef0123456789abcdef' `
        -ApiToken $script:MockManagementToken `
        -Name 'dockervm-ci'
}
catch { $UnknownTunnel = $_.Exception }
Assert-True ($null -ne $UnknownTunnel) 'Cloudflare unresolved transport error is raised'
Assert-Equal 'tunnel' $UnknownTunnel.Data['CloudflareMutationOutcomeUnknown'] 'Cloudflare unknown tunnel marker'
Assert-Equal 'zero-matches' $UnknownTunnel.Data['CloudflareReconciliationState'] 'Cloudflare zero-match reconciliation state'
Assert-Equal 4 $script:CloudflareCalls.Count 'Cloudflare transport failure gets three bounded reconciliation reads'
Assert-Equal 2 $script:CloudflareSleepCalls.Count 'Cloudflare reconciliation backoff is bounded'
$ExceptionChainText = ''
$ChainException = $UnknownTunnel
while ($null -ne $ChainException) {
    $ExceptionChainText += $ChainException.Message
    $ChainException = $ChainException.InnerException
}
Assert-False ($ExceptionChainText.Contains($script:MockManagementToken)) 'management token is absent from the full exception chain'
Assert-False ($ExceptionChainText.Contains('hostile')) 'Cloudflare response messages are absent from the full exception chain'

$script:CloudflareMockMode = 'success-false'
$script:CloudflareCalls.Clear()
$RejectedEnvelope = $null
try {
    $null = New-CloudflareTunnelResource `
        -AccountId '0123456789abcdef0123456789abcdef' `
        -ApiToken $script:MockManagementToken `
        -Name 'dockervm-ci'
}
catch { $RejectedEnvelope = $_.Exception }
Assert-Equal '7003' $RejectedEnvelope.Data['CloudflareErrorCodes'] 'Cloudflare success-false numeric error code'
Assert-False ([bool]$RejectedEnvelope.Data['CloudflarePostOutcomeAmbiguous']) 'Cloudflare success-false is deterministic'
Assert-Equal 1 $script:CloudflareCalls.Count 'Cloudflare success-false is not reconciled'
Assert-False ($RejectedEnvelope.Message.Contains($script:MockManagementToken)) 'Cloudflare success-false message is sanitized'

$script:CloudflareMockMode = 'malformed-success'
$MalformedResponse = $null
try {
    $null = Invoke-CloudflareApi `
        -Method GET `
        -Path '/accounts/0123456789abcdef0123456789abcdef/teamnet/routes' `
        -ApiToken $script:MockManagementToken
}
catch { $MalformedResponse = $_.Exception }
Assert-True ($null -ne $MalformedResponse) 'Cloudflare non-boolean success is rejected'
Assert-False ([bool]$MalformedResponse.Data['CloudflarePostOutcomeAmbiguous']) 'malformed GET is not a mutation ambiguity'

$script:CloudflareMockMode = 'pagination'
$script:CloudflareCalls.Clear()
$PagedResults = @(Get-CloudflarePagedResults `
    -ResourcePath '/accounts/0123456789abcdef0123456789abcdef/teamnet/routes' `
    -ApiToken $script:MockManagementToken)
Assert-Equal 2 $PagedResults.Count 'Cloudflare total_count pagination result count'
Assert-Equal 2 $script:CloudflareCalls.Count 'Cloudflare total_count pagination request count'

$script:CloudflareMockMode = 'pagination-guard'
$script:CloudflareCalls.Clear()
Assert-Throws {
    $null = Get-CloudflarePagedResults `
        -ResourcePath '/accounts/0123456789abcdef0123456789abcdef/teamnet/routes' `
        -ApiToken $script:MockManagementToken
} 'Cloudflare pagination loop guard'
Assert-Equal 1 $script:CloudflareCalls.Count 'Cloudflare pagination guard stops before a second request'

Remove-Item Function:\Start-Sleep
Remove-Item Function:\Invoke-RestMethod
Remove-Item Function:\New-MockCloudflareHttpError
$script:CloudflareRequest = $null
$script:MockManagementToken = $null

$OriginalGetCloudflarePagedResults = ${function:Get-CloudflarePagedResults}
$OriginalRemoveCloudflareProvisioningResources = ${function:Remove-CloudflareProvisioningResources}
$script:RecoveryMode = 'zero'
$script:RecoveryDeleteCalls = 0
function Set-SecretAcl { param([string]$Path) }
function Read-EnvironmentManifest {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
function Get-CloudflarePagedResults {
    param([string]$ResourcePath, [string]$ApiToken)

    if ($script:RecoveryMode -eq 'read-failed') {
        throw 'synthetic read failure'
    }
    if ($ResourcePath -like '*/cfd_tunnel?*' -and $script:RecoveryMode -eq 'multiple') {
        return @(
            [pscustomobject]@{
                id = '11111111-2222-4333-8444-555555555555'
                name = 'dockervm-ci-recovery'
            },
            [pscustomobject]@{
                id = '66666666-7777-4888-8999-aaaaaaaaaaaa'
                name = 'dockervm-ci-recovery'
            }
        )
    }
    return @()
}
function Remove-CloudflareProvisioningResources {
    param([string]$AccountId, [string]$ApiToken, [string]$RouteId, [string]$TunnelId)
    $script:RecoveryDeleteCalls++
    return $true
}

$RecoveryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ubuntu-docker-cf-recovery-" + [Guid]::NewGuid().ToString('N'))
$RecoveryWorkspace = Join-Path $RecoveryRoot 'ci-recovery.pending'
$null = [IO.Directory]::CreateDirectory($RecoveryWorkspace)
$RecoveryJournal = Join-Path $RecoveryWorkspace '.cloudflare-provisioning-transaction.json'
try {
    Write-CloudflareTransactionJournal `
        -Path $RecoveryJournal `
        -EnvironmentName 'ci-recovery' `
        -AccountId '0123456789abcdef0123456789abcdef' `
        -TunnelName 'dockervm-ci-recovery' `
        -Network '10.210.0.2/32' `
        -MutationState 'tunnel-create-started'

    foreach ($RecoveryCase in @(
            [pscustomobject]@{ Mode = 'zero'; Expected = 'zero exact matches' },
            [pscustomobject]@{ Mode = 'multiple'; Expected = 'multiple matching tunnels' },
            [pscustomobject]@{ Mode = 'read-failed'; Expected = 'synthetic read failure' }
        )) {
        $script:RecoveryMode = $RecoveryCase.Mode
        $RecoveryFailure = $null
        try {
            Invoke-CloudflareTransactionRecovery `
                -StagingRoot $RecoveryRoot `
                -AccountId '0123456789abcdef0123456789abcdef' `
                -ApiToken 'CI_DUMMY_RECOVERY_TOKEN'
        }
        catch { $RecoveryFailure = $_.Exception }
        Assert-True ($null -ne $RecoveryFailure) "unknown journal $($RecoveryCase.Mode) blocks provisioning"
        Assert-True (
            $RecoveryFailure.Message.Contains($RecoveryCase.Expected)
        ) "unknown journal $($RecoveryCase.Mode) reports its safe blocking reason"
        Assert-True (Test-Path -LiteralPath $RecoveryJournal -PathType Leaf) "unknown journal $($RecoveryCase.Mode) is preserved"
        Assert-Equal 0 $script:RecoveryDeleteCalls "unknown journal $($RecoveryCase.Mode) performs no destructive recovery"
    }
}
finally {
    if (Test-Path -LiteralPath $RecoveryRoot) {
        [IO.Directory]::Delete($RecoveryRoot, $true)
    }
    Set-Item -LiteralPath Function:\Get-CloudflarePagedResults -Value $OriginalGetCloudflarePagedResults
    Set-Item -LiteralPath Function:\Remove-CloudflareProvisioningResources -Value $OriginalRemoveCloudflareProvisioningResources
    Remove-Item Function:\Read-EnvironmentManifest
    Remove-Item Function:\Set-SecretAcl
}

$TempDirectory = Join-Path ([IO.Path]::GetTempPath()) ("ubuntu-docker-ci-" + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($TempDirectory)
try {
    $Source = Join-Path $TempDirectory 'source.txt'
    $Destination = Join-Path $TempDirectory 'destination.txt'
    [IO.File]::WriteAllText($Source, '__FIRST__ __SECOND__', [Text.UTF8Encoding]::new($false))
    Expand-TemplateFile -Source $Source -Destination $Destination -Tokens @{
        FIRST = '__SECOND__'
        SECOND = 'rendered'
    }
    Assert-Equal '__SECOND__ rendered' ([IO.File]::ReadAllText($Destination)) 'single-pass template rendering'
    Assert-Throws {
        Expand-TemplateFile -Source $Source -Destination $Destination -Tokens @{ FIRST = 'only-one' }
    } 'unknown template token rejection'
}
finally {
    [IO.Directory]::Delete($TempDirectory, $true)
}

$SshConfig = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\ssh-container.conf'))
foreach ($RequiredLine in @(
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        'AuthenticationMethods publickey',
        'PermitRootLogin no'
    )) {
    Assert-True ($SshConfig -match "(?m)^$([regex]::Escape($RequiredLine))$") "SSH setting $RequiredLine"
}
Assert-False ($SshConfig.Contains('PasswordAuthentication yes')) 'password SSH authentication remains disabled'

$DesktopEntrypoint = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\docker_entrypoint.sh'))
Assert-True (
    $DesktopEntrypoint -match '(?m)^\s*chmod 0777 "\$\{account_home\}" /workspace\r?$'
) 'Windows bind roots are explicitly made writable'
Assert-True (
    $DesktopEntrypoint.Contains('runuser -u "${account_name}" -- test -w "${writable_path}"')
) 'desktop entrypoint fails fast when bind storage is not writable'
Assert-True (
    $DesktopEntrypoint.Contains('    "${account_home}/.docker" \')
) 'desktop Docker configuration directory is explicitly user-owned'
$HomeInitializationIndex = $DesktopEntrypoint.IndexOf(
    '    cp -a --update=none /etc/skel/. "${account_home}/"',
    [StringComparison]::Ordinal
)
$HomePermissionIndex = $DesktopEntrypoint.IndexOf(
    '    chown "${account_uid}:${account_gid}" "${account_home}" /workspace',
    [StringComparison]::Ordinal
)
$WritableCheckIndex = $DesktopEntrypoint.IndexOf(
    'for writable_path in "${account_home}" "${account_home}/.docker" /workspace; do',
    [StringComparison]::Ordinal
)
Assert-True (
    $HomeInitializationIndex -ge 0 -and
    $HomePermissionIndex -gt $HomeInitializationIndex -and
    $WritableCheckIndex -gt $HomePermissionIndex
) 'desktop home permissions are restored after skeleton initialization and before writability checks'

$XrdpStartWindowManager = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\xrdp_startwm.sh'))
Assert-True (
    $XrdpStartWindowManager.Contains('export LANG="${LANG:-en_US.UTF-8}"')
) 'XRDP session has a UTF-8 locale fallback'

$XrdpKoreanKeyboardSetup = [IO.File]::ReadAllText(
    (Join-Path $RepoRoot 'templates\ubuntu-dind\configure_xrdp_korean_keyboard.sh')
)
foreach ($RequiredSetting in @(
        's/^Key109=.*/Key109=65332:0/',
        's/^Key113=.*/Key113=65329:0/',
        'rdp_layout_kr_hangul=0xe0010412',
        'rdp_layout_kr_hangul=kr',
        'keyboard_type=8',
        'keyboard_subtype=1',
        'model=pc105',
        'variant=kr106',
        'options=korean:ralt_hangul,korean:rctrl_hanja',
        'rdp_layouts=rdp_layouts_kr_hangul',
        'layouts_map=layouts_map_kr_hangul'
    )) {
    Assert-True ($XrdpKoreanKeyboardSetup.Contains($RequiredSetting)) "XRDP Korean setting $RequiredSetting"
}

$DesktopDockerfile = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\Dockerfile'))
Assert-True (
    $DesktopDockerfile.Contains(
        'COPY configure_xrdp_korean_keyboard.sh /usr/local/sbin/configure_xrdp_korean_keyboard.sh'
    )
) 'desktop copies the XRDP Korean keyboard setup'
Assert-True (
    $DesktopDockerfile.Contains('    && /usr/local/sbin/configure_xrdp_korean_keyboard.sh')
) 'desktop applies the XRDP Korean keyboard setup'
Assert-True ($DesktopDockerfile.Contains('        fonts-noto-color-emoji \')) 'desktop installs emoji glyphs'
Assert-True ($DesktopDockerfile.Contains('        fonts-powerline \')) 'desktop installs Powerline glyphs'
Assert-True ($DesktopDockerfile.Contains('    && update-locale LANG=en_US.UTF-8 \')) 'desktop persists the UTF-8 locale for PAM sessions'
Assert-True ($DesktopDockerfile.Contains("    && grep -Fqx 'LANG=en_US.UTF-8' /etc/default/locale \")) 'desktop verifies the PAM locale file'
Assert-True ($DesktopDockerfile.Contains(':charset=1F680')) 'desktop verifies emoji glyph coverage'
Assert-True ($DesktopDockerfile.Contains(':charset=E0A0')) 'desktop verifies Powerline glyph coverage'

$ComposeTemplate = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\compose.yaml.template'))
Assert-True ($ComposeTemplate.Contains('"${HOST_ADDRESS}:${RDP_PORT}:3389"')) 'LAN RDP port mapping'
Assert-False ($ComposeTemplate.Contains('"${HOST_ADDRESS}:3389:3389"')) 'reserved host RDP port is not published'
foreach ($TemplateToken in @(
        '__DESKTOP_REMOTE_NETWORKS__',
        '__REMOTE_ACCESS_SERVICES__',
        '__REMOTE_ACCESS_SECRETS__',
        '__REMOTE_ACCESS_VOLUMES__',
        '__REMOTE_ACCESS_NETWORKS__'
    )) {
    Assert-True ($ComposeTemplate.Contains($TemplateToken)) "provider template slot $TemplateToken"
}

$CloudflareFragment = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\compose.cloudflare.services.template'))
Assert-True (
    $CloudflareFragment -match '(?m)^    image: cloudflare/cloudflared:[^\s@]+@sha256:[0-9a-f]{64}\r?$'
) 'cloudflared image is pinned by tag and SHA-256 digest'
Assert-True ($CloudflareFragment -match '(?m)^      - --token-file\r?$') 'cloudflared uses --token-file'
Assert-True (
    $CloudflareFragment -match '(?m)^      - /run/secrets/cloudflared_token\r?$'
) 'cloudflared token-file path'
Assert-True ($CloudflareFragment -match '(?m)^    cap_drop:\r?$') 'cloudflared cap_drop'
Assert-True ($CloudflareFragment -match '(?m)^      - ALL\r?$') 'cloudflared drops all capabilities'
Assert-True ($CloudflareFragment -match '(?m)^    read_only: true\r?$') 'cloudflared read-only root filesystem'
foreach ($ForbiddenValue in @('/dev/net/tun', 'NET_ADMIN', 'privileged:', 'CLOUDFLARE_API_TOKEN')) {
    Assert-False (
        $CloudflareFragment.IndexOf($ForbiddenValue, [StringComparison]::OrdinalIgnoreCase) -ge 0
    ) "Cloudflare runtime excludes $ForbiddenValue"
}
Assert-True ($CloudflareFragment.Contains('cloudflared_token')) 'tunnel-specific Cloudflare runtime secret'

$WireGuardFragment = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\ubuntu-dind\compose.wireguard.services.template'))
Assert-True ($WireGuardFragment.Contains('network_mode: service:wireguard')) 'proxy shares WireGuard namespace'
Assert-True ($WireGuardFragment.Contains('/dev/net/tun:/dev/net/tun')) 'WireGuard TUN device mapping'
$WireGuardMatch = [regex]::Match(
    $WireGuardFragment,
    '(?ms)^  wireguard:\r?\n(?<Body>.*?)(?=^  remote_proxy:)'
)
Assert-True $WireGuardMatch.Success 'WireGuard service block'
Assert-False ($WireGuardMatch.Value.Contains('privileged: true')) 'WireGuard service is not privileged'
Assert-True ($WireGuardMatch.Value.Contains('- NET_ADMIN')) 'WireGuard NET_ADMIN capability'
$ProxyMatch = [regex]::Match($WireGuardFragment, '(?ms)^  remote_proxy:\r?\n(?<Body>.*)$')
Assert-True $ProxyMatch.Success 'WireGuard remote proxy block'
Assert-True ($ProxyMatch.Value.Contains('- NET_BIND_SERVICE')) 'remote proxy bind capability'
Assert-False ($ProxyMatch.Value.Contains('/var/lib/wireguard')) 'remote proxy excludes WireGuard state'

$RootIgnore = [IO.File]::ReadAllText((Join-Path $RepoRoot '.gitignore'))
Assert-True ($RootIgnore -match '(?m)^!/.github/$') '.github ignore exception'
Assert-True ($RootIgnore -match '(?m)^!/tests/$') 'tests ignore exception'

$TrackedPaths = @(& git -C $RepoRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed'
}
foreach ($TrackedPath in $TrackedPaths) {
    Assert-False (
        $TrackedPath -match '(?i)(^|/)(secrets|wireguard)/.+\.(key|pem)$|\.(pem|key|p12|pfx|rdp)$'
    ) "sensitive generated path is tracked: $TrackedPath"
}

Write-Host 'Windows static and unit tests passed.'
