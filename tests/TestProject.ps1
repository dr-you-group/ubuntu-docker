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
    'Invoke-CloudflareApi',
    'Get-CloudflarePagedResults',
    'Test-CloudflareResourceId',
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
        [string]$ContentType,
        [string]$Body
    )
    $script:CloudflareRequest = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = $ErrorAction
        UseBasicParsing = $UseBasicParsing
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
$CloudflareBody = $script:CloudflareRequest.Body | ConvertFrom-Json
Assert-True ($CloudflareBody.name -eq 'dockervm-ci') 'Cloudflare Tunnel request name'
Assert-True ($CloudflareBody.config_src -eq 'cloudflare') 'Cloudflare Tunnel config source'

function Invoke-RestMethod {
    throw "hostile transport detail $($script:MockManagementToken)"
}
$CloudflareError = ''
try {
    $null = Invoke-CloudflareApi `
        -Method GET `
        -Path '/accounts/0123456789abcdef0123456789abcdef/teamnet/routes' `
        -ApiToken $script:MockManagementToken
}
catch {
    $CloudflareError = $_.Exception.Message
}
Assert-True ($CloudflareError.Contains('Cloudflare API request failed')) 'Cloudflare API safe error'
Assert-False ($CloudflareError.Contains($script:MockManagementToken)) 'management token is redacted from API errors'
Remove-Item Function:\Invoke-RestMethod
$script:CloudflareRequest = $null
$script:MockManagementToken = $null

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
