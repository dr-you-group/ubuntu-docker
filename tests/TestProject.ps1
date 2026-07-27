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
    'Test-IPv4HostCidr',
    'Test-IPv4CidrsOverlap',
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
Assert-True ($ComposeTemplate.Contains('network_mode: service:wireguard')) 'proxy shares WireGuard namespace'
Assert-True ($ComposeTemplate.Contains('/dev/net/tun:/dev/net/tun')) 'TUN device mapping'

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
