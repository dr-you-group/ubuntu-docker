#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$AccountName,
    [Security.SecureString]$Password,
    [string]$HostAddress,
    [int]$SshPort = 0,
    [int]$RdpPort = 0,
    [string]$RemoteSubnet,
    [double]$DesktopCpus = 0,
    [string]$DesktopMemory,
    [double]$DindCpus = 0,
    [string]$DindMemory,
    [string]$DockerVersion,
    [switch]$EnableGpu,
    [switch]$DisableGpu,
    [string]$CudaImage = 'nvidia/cuda:12.2.2-base-ubuntu22.04',
    [string]$NvidiaContainerToolkitVersion = '1.19.1-1',
    [string]$RootPath,
    [switch]$Replace,
    [switch]$MigrateLegacyHome,
    [switch]$AllowDockerVersionChange,
    [switch]$UseBuildKit,
    [switch]$GenerateOnly,
    [switch]$SkipFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-WithDefault {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function ConvertFrom-SecureValue {
    param([Parameter(Mandatory)] [Security.SecureString]$Value)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-ConfirmedPassword {
    while ($true) {
        $first = Read-Host '로그인 비밀번호' -AsSecureString
        $second = Read-Host '로그인 비밀번호 확인' -AsSecureString
        $firstText = ConvertFrom-SecureValue $first
        $secondText = ConvertFrom-SecureValue $second
        try {
            if ($firstText.Length -eq 0) {
                Write-Warning '빈 비밀번호는 사용할 수 없습니다.'
                continue
            }
            if ($firstText -ne $secondText) {
                Write-Warning '비밀번호가 일치하지 않습니다.'
                continue
            }
            return $first
        }
        finally {
            $firstText = $null
            $secondText = $null
        }
    }
}

function Test-IPv4Address {
    param([string]$Value)
    $parsed = $null
    return [Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
        $Value -ne '0.0.0.0'
}

function Get-NetworkCidr {
    param(
        [Parameter(Mandatory)] [string]$Address,
        [Parameter(Mandatory)] [ValidateRange(1, 32)] [int]$PrefixLength
    )

    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    $network = New-Object byte[] 4
    for ($index = 0; $index -lt 4; $index++) {
        $remaining = $PrefixLength - ($index * 8)
        if ($remaining -ge 8) {
            $mask = 255
        }
        elseif ($remaining -le 0) {
            $mask = 0
        }
        else {
            $mask = 256 - [Math]::Pow(2, 8 - $remaining)
        }
        $network[$index] = $bytes[$index] -band [int]$mask
    }
    return "$(New-Object Net.IPAddress -ArgumentList (, $network))/$PrefixLength"
}

function Get-DefaultLanConfiguration {
    try {
        $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
            Sort-Object RouteMetric, InterfaceMetric
        foreach ($route in $routes) {
            $address = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex |
                Where-Object {
                    $_.IPAddress -notlike '127.*' -and
                    $_.IPAddress -notlike '169.254.*'
                } |
                Select-Object -First 1
            if ($null -ne $address) {
                return [pscustomobject]@{
                    Address = $address.IPAddress
                    Subnet = Get-NetworkCidr -Address $address.IPAddress -PrefixLength $address.PrefixLength
                }
            }
        }
    }
    catch {
        Write-Verbose "LAN 자동 감지 실패: $($_.Exception.Message)"
    }

    try {
        $candidates = foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }
            $properties = $adapter.GetIPProperties()
            $hasGateway = $null -ne ($properties.GatewayAddresses |
                Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
                Select-Object -First 1)
            foreach ($unicast in $properties.UnicastAddresses) {
                $candidateAddress = $unicast.Address.IPAddressToString
                if ($unicast.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    $candidateAddress -notlike '127.*' -and $candidateAddress -notlike '169.254.*') {
                    [pscustomobject]@{
                        Address = $candidateAddress
                        PrefixLength = $unicast.PrefixLength
                        HasGateway = $hasGateway
                    }
                }
            }
        }
        $candidate = $candidates | Sort-Object @{ Expression = 'HasGateway'; Descending = $true } | Select-Object -First 1
        if ($null -ne $candidate) {
            return [pscustomobject]@{
                Address = $candidate.Address
                Subnet = Get-NetworkCidr -Address $candidate.Address -PrefixLength $candidate.PrefixLength
            }
        }
    }
    catch {
        Write-Verbose ".NET LAN 자동 감지 실패: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Address = '10.19.10.241'
        Subnet = '10.19.0.0/16'
    }
}

function Test-Cidr {
    param([string]$Value)
    if ($Value -notmatch '^([^/]+)/([0-9]|[12][0-9]|3[0-2])$') {
        return $false
    }
    if (-not (Test-IPv4Address $Matches[1])) {
        return $false
    }
    return [int]$Matches[2] -ge 8
}

function Get-ActiveTcpPorts {
    return [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port |
        Sort-Object -Unique
}

function Get-FreeTcpPort {
    param(
        [Parameter(Mandatory)] [int]$Start,
        [int[]]$AllowedExisting = @()
    )

    $used = @(Get-ActiveTcpPorts)
    for ($candidate = $Start; $candidate -le 65535; $candidate++) {
        if ($candidate -eq 3389) {
            continue
        }
        if ($used -notcontains $candidate -or $AllowedExisting -contains $candidate) {
            return $candidate
        }
    }
    throw "사용 가능한 TCP 포트를 찾지 못했습니다: $Start-65535"
}

function Get-EnvironmentPublishedPorts {
    param([Parameter(Mandatory)] [string]$Name)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
    $containerIds = @()
    foreach ($projectName in @($Name, "ubuntu-dind-$Name")) {
        $ids = @(& docker ps -aq --filter "label=com.docker.compose.project=$projectName" 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $containerIds += $ids
        }
    }

    $legacyName = (& docker inspect --format '{{.Name}}' $Name 2>$null)
    $legacyId = (& docker inspect --format '{{.Id}}' $Name 2>$null)
    if ($LASTEXITCODE -eq 0 -and ([string]$legacyName).Trim() -eq "/$Name" -and
        -not [string]::IsNullOrWhiteSpace([string]$legacyId)) {
        $containerIds += ([string]$legacyId).Trim()
    }

    $ports = @()
    foreach ($containerId in @($containerIds | Where-Object { $_ } | Sort-Object -Unique)) {
        $json = (& docker inspect --format '{{json .HostConfig.PortBindings}}' $containerId 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$json)) {
            continue
        }
        $bindings = [string]$json | ConvertFrom-Json
        foreach ($bindingProperty in $bindings.PSObject.Properties) {
            foreach ($binding in @($bindingProperty.Value)) {
                if ($null -ne $binding -and $binding.HostPort -match '^[0-9]+$') {
                    $ports += [int]$binding.HostPort
                }
            }
        }
    }
    return @($ports | Sort-Object -Unique)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-ComposeDeclaredHostPorts {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $ports = foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\s*-\s*["'']?(?:(?:[0-9]{1,3}\.){3}[0-9]{1,3}:)?(?<HostPort>[0-9]{1,5}):[0-9]{1,5}(?:/(?:tcp|udp))?["'']?\s*$') {
            [int]$Matches['HostPort']
        }
    }
    return @($ports | Sort-Object -Unique)
}

function Read-EnvironmentFile {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([^#=]+)=(.*)$') {
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$Matches[1].Trim()] = $value
        }
    }
    return $values
}

function Test-MemoryValue {
    param([string]$Value)
    return $Value -match '^[1-9][0-9]*(\.[0-9]+)?[mMgG]$'
}

function Convert-MemoryToBytes {
    param([Parameter(Mandatory)] [string]$Value)

    if (-not (Test-MemoryValue $Value)) {
        throw "Invalid memory value: $Value"
    }
    $null = $Value -match '^([0-9]+(?:\.[0-9]+)?)([mMgG])$'
    $amount = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $multiplier = if ($Matches[2].ToLowerInvariant() -eq 'g') { 1GB } else { 1MB }
    return [double]($amount * $multiplier)
}

function Get-DockerBackendResources {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& docker info --format '{{.NCPU}}|{{.MemTotal}}' 2>$null)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        return $null
    }
    $parts = ([string]$raw).Trim().Split('|')
    if ($parts.Count -ne 2) {
        return $null
    }
    $cpuCount = 0
    $memoryBytes = [long]0
    if (-not [int]::TryParse($parts[0], [ref]$cpuCount) -or
        -not [long]::TryParse($parts[1], [ref]$memoryBytes)) {
        return $null
    }
    return [pscustomobject]@{
        Cpus = $cpuCount
        MemoryBytes = $memoryBytes
    }
}

function Test-DockerVolume {
    param([Parameter(Mandatory)] [string]$Name)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker volume inspect $Name *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Test-DockerImage {
    param([Parameter(Mandatory)] [string]$Name)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker image inspect $Name *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-DockerGpuProbe {
    $nvidiaCommand = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($null -eq $nvidiaCommand) {
        $nvidiaCommand = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    }
    if ($null -eq $nvidiaCommand) {
        return [pscustomobject]@{
            HostReady = $false
            DockerReady = $false
            GpuNames = @()
            Message = 'Windows NVIDIA driver (nvidia-smi) was not found.'
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gpuNames = @(& $nvidiaCommand.Source --query-gpu=name --format=csv,noheader 2>$null)
        $hostExitCode = $LASTEXITCODE
        if ($hostExitCode -ne 0 -or $gpuNames.Count -eq 0) {
            return [pscustomobject]@{
                HostReady = $false
                DockerReady = $false
                GpuNames = @()
                Message = 'nvidia-smi could not query a host GPU.'
            }
        }

        $dockerProbe = @(& docker run --rm --gpus all ubuntu:26.04 nvidia-smi -L 2>$null)
        $dockerExitCode = $LASTEXITCODE
        return [pscustomobject]@{
            HostReady = $true
            DockerReady = $dockerExitCode -eq 0 -and $dockerProbe.Count -gt 0
            GpuNames = @($gpuNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            Message = if ($dockerExitCode -eq 0) {
                'NVIDIA GPU access through Docker is ready.'
            }
            else {
                'Docker could not access the NVIDIA GPU. Update the Windows NVIDIA driver and use the Docker Desktop WSL2 backend.'
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Read-CpuValue {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [double]$Default
    )

    while ($true) {
        $raw = Read-WithDefault -Prompt $Prompt -Default $Default.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
        $parsed = 0.0
        if ([double]::TryParse(
            $raw,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        ) -and ($parsed -eq -1 -or $parsed -ge 0.25)) {
            return $parsed
        }
        Write-Warning 'CPU는 -1(무제한) 또는 0.25 이상의 숫자로 입력하십시오.'
    }
}

function Read-MemoryValue {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Default
    )

    while ($true) {
        $value = Read-WithDefault -Prompt $Prompt -Default $Default
        if ($value -eq '-1') {
            return $value
        }
        if (Test-MemoryValue $value) {
            return $value.ToLowerInvariant()
        }
        Write-Warning '메모리는 -1(무제한), 4096m 또는 4g 형식으로 입력하십시오.'
    }
}

function Set-SecretAcl {
    param([Parameter(Mandatory)] [string]$Path)

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        "*${currentSid}:(F)",
        '*S-1-5-18:(F)',
        '*S-1-5-32-544:(F)'
    )
    & icacls.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "비밀번호 파일 ACL 설정에 실패했습니다: $Path"
    }
}

function Expand-TemplateFile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [hashtable]$Tokens
    )

    $content = [IO.File]::ReadAllText($Source)
    foreach ($token in $Tokens.GetEnumerator()) {
        $content = $content.Replace("__$($token.Key)__", [string]$token.Value)
    }
    $writeBom = [IO.Path]::GetExtension($Destination) -ieq '.ps1'
    [IO.File]::WriteAllText($Destination, $content, [Text.UTF8Encoding]::new($writeBom))
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$FailureMessage
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @Arguments
        $dockerExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($dockerExitCode -ne 0) {
        throw $FailureMessage
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$FailureMessage
    )

    Push-Location $ProjectPath
    try {
        $composeArguments = @('compose')
        if (Test-Path -LiteralPath (Join-Path $ProjectPath '.env') -PathType Leaf) {
            $composeArguments += @('--env-file', '.env')
        }
        Invoke-Docker -Arguments ($composeArguments + $Arguments) -FailureMessage $FailureMessage
    }
    finally {
        Pop-Location
    }
}

function Test-ComposeCommand {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $ProjectPath
    try {
        & docker compose --env-file .env @Arguments
        return $LASTEXITCODE -eq 0
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Wait-EnvironmentHealthy {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [int]$TimeoutSeconds = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Push-Location $ProjectPath
        try {
            $desktopId = [string](& docker compose --env-file .env ps -q desktop)
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to inspect the desktop service.'
            }
            $dockerId = [string](& docker compose --env-file .env ps -q docker)
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to inspect the DinD service.'
            }
            $desktopId = $desktopId.Trim()
            $dockerId = $dockerId.Trim()
            if ($desktopId -and $dockerId) {
                $desktopState = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $desktopId).Trim()
                $dockerState = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $dockerId).Trim()
                if ($desktopState -eq 'healthy' -and $dockerState -eq 'healthy') {
                    return
                }
                if ($desktopState -eq 'unhealthy' -or $dockerState -eq 'unhealthy') {
                    throw "컨테이너가 unhealthy 상태입니다: desktop=$desktopState, docker=$dockerState"
                }
            }
        }
        finally {
            Pop-Location
        }
        Start-Sleep -Seconds 3
    }
    throw "환경이 제한 시간 안에 healthy가 되지 않았습니다: $ProjectPath"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI를 찾을 수 없습니다. Docker Desktop을 먼저 설치하고 실행하십시오.'
}

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    throw '루트 경로를 확인할 수 없습니다. -RootPath로 경로를 지정하십시오.'
}

try {
    $rootFullPath = [IO.Path]::GetFullPath($RootPath)
}
catch {
    throw "루트 경로 형식이 올바르지 않습니다: '$RootPath'. $($_.Exception.Message)"
}

$rootPathRoot = [IO.Path]::GetPathRoot($rootFullPath)
if ($rootFullPath.Length -gt $rootPathRoot.Length) {
    $rootFullPath = $rootFullPath.TrimEnd([char[]]@('\', '/'))
}
$templatePath = Join-Path $PSScriptRoot 'templates\ubuntu-dind'
if (-not (Test-Path -LiteralPath $templatePath -PathType Container)) {
    throw "템플릿 폴더가 없습니다: $templatePath"
}

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $EnvironmentName = (Read-Host '가상환경 이름').Trim().ToLowerInvariant()
}
else {
    $EnvironmentName = $EnvironmentName.Trim().ToLowerInvariant()
}
if ($EnvironmentName.Length -gt 32 -or $EnvironmentName -notmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$') {
    throw '가상환경 이름은 영문 소문자로 시작하고, 영문 소문자와 숫자 조각을 단일 하이픈으로만 구분해야 합니다.'
}

$environmentNamePascalCase = (($EnvironmentName -split '-') | ForEach-Object {
    $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
}) -join ''
$firewallScriptName = "Configure${environmentNamePascalCase}Firewall.ps1"
$gpuTestScriptName = 'TestGpu.ps1'

$targetPath = Join-Path $rootFullPath $EnvironmentName
$targetExists = Test-Path -LiteralPath $targetPath
$oldEnvironment = Read-EnvironmentFile (Join-Path $targetPath '.env')

if ([string]::IsNullOrWhiteSpace($AccountName)) {
    $defaultAccountName = if ($oldEnvironment.ContainsKey('ACCOUNT_NAME')) {
        $oldEnvironment['ACCOUNT_NAME']
    }
    else {
        $EnvironmentName
    }
    $AccountName = (Read-WithDefault -Prompt 'Linux 계정 이름' -Default $defaultAccountName).ToLowerInvariant()
}
else {
    $AccountName = $AccountName.Trim().ToLowerInvariant()
}
if ($AccountName -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
    throw '계정 이름 형식이 올바르지 않습니다.'
}
if (@(
        'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp',
        'proxy', 'www-data', 'backup', 'operator', 'list', 'irc', '_apt', 'nobody', 'ubuntu',
        'systemd-network', 'systemd-journal', 'messagebus', 'sshd', '_ssh', 'xrdp', 'adm',
        'tty', 'disk', 'dialout', 'fax', 'voice', 'cdrom', 'floppy', 'tape', 'sudo', 'audio',
        'dip', 'src', 'shadow', 'utmp', 'video', 'sasl', 'plugdev', 'staff', 'users', 'nogroup',
        'ssl-cert', 'input', 'sgx', 'clock', 'kvm', 'render'
    ) -contains $AccountName) {
    throw "예약된 Ubuntu 사용자/그룹 이름은 사용할 수 없습니다: $AccountName"
}

$allowedExistingPorts = @()
if ($oldEnvironment.ContainsKey('SSH_PORT')) {
    $allowedExistingPorts += [int]$oldEnvironment['SSH_PORT']
}
if ($oldEnvironment.ContainsKey('RDP_PORT')) {
    $allowedExistingPorts += [int]$oldEnvironment['RDP_PORT']
}
if ($targetExists) {
    $allowedExistingPorts += @(Get-EnvironmentPublishedPorts -Name $EnvironmentName)
    $allowedExistingPorts += @(Get-ComposeDeclaredHostPorts -Path (Join-Path $targetPath 'compose.yaml'))
}
$allowedExistingPorts = @($allowedExistingPorts | Sort-Object -Unique)

if ([string]::IsNullOrWhiteSpace($DockerVersion)) {
    $defaultDockerVersion = if ($oldEnvironment.ContainsKey('DOCKER_VERSION')) {
        $oldEnvironment['DOCKER_VERSION']
    }
    else {
        '29.6.2'
    }
    $DockerVersion = Read-WithDefault -Prompt 'Docker/DinD version' -Default $defaultDockerVersion
}
$DockerVersion = $DockerVersion.Trim()
if ($DockerVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Docker version must use the x.y.z format: $DockerVersion"
}
if ($oldEnvironment.ContainsKey('DOCKER_VERSION') -and
    $oldEnvironment['DOCKER_VERSION'] -ne $DockerVersion -and
    -not $AllowDockerVersionChange) {
    throw "Changing Docker from $($oldEnvironment['DOCKER_VERSION']) to $DockerVersion can modify the persistent DinD volume. Back it up, then rerun with -AllowDockerVersionChange."
}

if ($EnableGpu -and $DisableGpu) {
    throw '-EnableGpu와 -DisableGpu는 동시에 사용할 수 없습니다.'
}
if (-not $PSBoundParameters.ContainsKey('CudaImage') -and $oldEnvironment.ContainsKey('CUDA_IMAGE')) {
    $CudaImage = $oldEnvironment['CUDA_IMAGE']
}
if (-not $PSBoundParameters.ContainsKey('NvidiaContainerToolkitVersion') -and
    $oldEnvironment.ContainsKey('NVIDIA_CONTAINER_TOOLKIT_VERSION')) {
    $NvidiaContainerToolkitVersion = $oldEnvironment['NVIDIA_CONTAINER_TOOLKIT_VERSION']
}
if ($CudaImage -notmatch '^[A-Za-z0-9][A-Za-z0-9._/:@-]+$') {
    throw "CUDA image reference is invalid: $CudaImage"
}
if ($NvidiaContainerToolkitVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$') {
    throw "NVIDIA Container Toolkit version is invalid: $NvidiaContainerToolkitVersion"
}

$gpuProbe = $null
$gpuEnabled = $false
if (-not $DisableGpu) {
    $gpuProbe = Get-DockerGpuProbe
}
if ($EnableGpu) {
    $gpuEnabled = $true
}
elseif ($DisableGpu) {
    $gpuEnabled = $false
}
else {
    $oldGpuEnabled = $oldEnvironment.ContainsKey('GPU_ENABLED') -and $oldEnvironment['GPU_ENABLED'] -eq '1'
    $defaultGpuAnswer = if ($oldGpuEnabled -or ($null -ne $gpuProbe -and $gpuProbe.DockerReady)) { 'Y' } else { 'N' }
    $gpuAnswer = Read-WithDefault -Prompt 'NVIDIA GPU/CUDA를 사용할까요? (Y/N)' -Default $defaultGpuAnswer
    $gpuEnabled = $gpuAnswer -match '^[Yy]'
}
if ($gpuEnabled -and ($null -eq $gpuProbe -or -not $gpuProbe.DockerReady)) {
    $gpuMessage = if ($null -ne $gpuProbe) { $gpuProbe.Message } else { 'NVIDIA GPU probe was not run.' }
    throw "GPU mode cannot be enabled: $gpuMessage"
}
$gpuEnabledValue = if ($gpuEnabled) { '1' } else { '0' }
$gpuDescription = if ($gpuEnabled) {
    "Enabled: $($gpuProbe.GpuNames -join ', ')"
}
else {
    'Disabled (CPU-only)'
}

$lanDefaults = Get-DefaultLanConfiguration
if ([string]::IsNullOrWhiteSpace($HostAddress)) {
    $HostAddress = Read-WithDefault -Prompt '호스트 LAN IPv4 주소' -Default $lanDefaults.Address
}
if (-not (Test-IPv4Address $HostAddress)) {
    throw "유효하지 않은 IPv4 주소입니다: $HostAddress"
}
$hostOctets = @($HostAddress.Split('.') | ForEach-Object { [int]$_ })
if ($hostOctets[0] -eq 127 -or
    ($hostOctets[0] -eq 169 -and $hostOctets[1] -eq 254) -or
    $hostOctets[0] -ge 224) {
    throw "LAN 접속용으로 사용할 수 없는 호스트 주소입니다: $HostAddress"
}

try {
    $assignedAddress = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object {
            $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            $_.Address.IPAddressToString -eq $HostAddress
        } |
        Select-Object -First 1
    if ($null -eq $assignedAddress) {
        throw "호스트에 할당되지 않은 주소입니다: $HostAddress"
    }
}
catch {
    throw "호스트 LAN 주소를 확인할 수 없습니다: $HostAddress ($($_.Exception.Message))"
}

if ([string]::IsNullOrWhiteSpace($RemoteSubnet)) {
    $defaultSubnet = if ($HostAddress -eq $lanDefaults.Address) { $lanDefaults.Subnet } else { '10.19.0.0/16' }
    $RemoteSubnet = Read-WithDefault -Prompt '접속을 허용할 원격 CIDR' -Default $defaultSubnet
}
if (-not (Test-Cidr $RemoteSubnet)) {
    throw "유효하지 않거나 지나치게 넓은 CIDR입니다: $RemoteSubnet"
}

if ($SshPort -eq 0) {
    $defaultSshPort = Get-FreeTcpPort -Start 2222 -AllowedExisting $allowedExistingPorts
    $SshPort = [int](Read-WithDefault -Prompt '호스트 SSH 포트' -Default ([string]$defaultSshPort))
}
if ($RdpPort -eq 0) {
    $defaultRdpPort = Get-FreeTcpPort -Start 3390 -AllowedExisting $allowedExistingPorts
    $RdpPort = [int](Read-WithDefault -Prompt '호스트 RDP 포트 (3389 사용 금지)' -Default ([string]$defaultRdpPort))
}
if ($SshPort -lt 1 -or $SshPort -gt 65535 -or $RdpPort -lt 3390 -or $RdpPort -gt 65535) {
    throw '포트 범위가 올바르지 않습니다. RDP 포트는 반드시 3390 이상이어야 합니다.'
}
if ($SshPort -eq 3389 -or $RdpPort -eq 3389) {
    throw '호스트 포트 3389는 온프레미스 서버 RDP용으로 예약되어 있어 사용할 수 없습니다.'
}
if ($SshPort -eq $RdpPort) {
    throw 'SSH 포트와 RDP 포트는 서로 달라야 합니다.'
}

$activePorts = @(Get-ActiveTcpPorts)
foreach ($port in @($SshPort, $RdpPort)) {
    if ($activePorts -contains $port -and $allowedExistingPorts -notcontains $port) {
        throw "이미 사용 중인 호스트 포트입니다: $port"
    }
}

$dockerBackend = Get-DockerBackendResources
$logicalCpus = if ($null -ne $dockerBackend -and $dockerBackend.Cpus -gt 0) {
    $dockerBackend.Cpus
}
else {
    [Math]::Max(1, [Environment]::ProcessorCount)
}
if ($DesktopCpus -eq 0) {
    $DesktopCpus = Read-CpuValue -Prompt 'Ubuntu 데스크톱 CPU 코어 (-1 = 무제한)' -Default ([Math]::Min(2, $logicalCpus))
}
if ([string]::IsNullOrWhiteSpace($DesktopMemory)) {
    $DesktopMemory = Read-MemoryValue -Prompt 'Ubuntu 데스크톱 RAM (-1 = 무제한)' -Default '4g'
}
if ($DindCpus -eq 0) {
    $DindCpus = Read-CpuValue -Prompt 'DinD 엔진 및 내부 컨테이너 CPU 코어 (-1 = 무제한)' -Default ([Math]::Min(4, $logicalCpus))
}
if ([string]::IsNullOrWhiteSpace($DindMemory)) {
    $DindMemory = Read-MemoryValue -Prompt 'DinD 엔진 및 내부 컨테이너 RAM (-1 = 무제한)' -Default '8g'
}
if ([double]::IsNaN($DesktopCpus) -or [double]::IsInfinity($DesktopCpus) -or
    [double]::IsNaN($DindCpus) -or [double]::IsInfinity($DindCpus) -or
    ($DesktopCpus -ne -1 -and $DesktopCpus -lt 0.25) -or
    ($DindCpus -ne -1 -and $DindCpus -lt 0.25)) {
    throw 'CPU 값은 -1(무제한) 또는 0.25 이상이어야 합니다.'
}
$DesktopMemory = $DesktopMemory.Trim().ToLowerInvariant()
$DindMemory = $DindMemory.Trim().ToLowerInvariant()
if (($DesktopMemory -ne '-1' -and -not (Test-MemoryValue $DesktopMemory)) -or
    ($DindMemory -ne '-1' -and -not (Test-MemoryValue $DindMemory))) {
    throw '메모리는 -1(무제한), 4096m 또는 4g 형식이어야 합니다.'
}

$desktopCpuUnlimited = $DesktopCpus -eq -1
$desktopMemoryUnlimited = $DesktopMemory -eq '-1'
$dindCpuUnlimited = $DindCpus -eq -1
$dindMemoryUnlimited = $DindMemory -eq '-1'

$desktopMemoryBytes = if ($desktopMemoryUnlimited) { $null } else { Convert-MemoryToBytes $DesktopMemory }
$dindMemoryBytes = if ($dindMemoryUnlimited) { $null } else { Convert-MemoryToBytes $DindMemory }
if ((-not $desktopMemoryUnlimited -and $desktopMemoryBytes -lt 512MB) -or
    (-not $dindMemoryUnlimited -and $dindMemoryBytes -lt 512MB)) {
    throw 'Each service requires at least 512m of memory.'
}
if ($null -ne $dockerBackend) {
    if ((-not $desktopCpuUnlimited -and $DesktopCpus -gt $dockerBackend.Cpus) -or
        (-not $dindCpuUnlimited -and $DindCpus -gt $dockerBackend.Cpus)) {
        Write-Warning "A service CPU limit exceeds the Docker backend capacity ($($dockerBackend.Cpus) CPUs)."
    }
    if ((-not $desktopMemoryUnlimited -and $desktopMemoryBytes -gt $dockerBackend.MemoryBytes) -or
        (-not $dindMemoryUnlimited -and $dindMemoryBytes -gt $dockerBackend.MemoryBytes)) {
        Write-Warning "A service memory limit exceeds the Docker backend capacity ($([Math]::Round($dockerBackend.MemoryBytes / 1GB, 2)) GiB)."
    }
    if (-not $desktopMemoryUnlimited -and -not $dindMemoryUnlimited -and
        ($desktopMemoryBytes + $dindMemoryBytes) -gt $dockerBackend.MemoryBytes) {
        Write-Warning 'The combined desktop and DinD memory limits exceed the Docker backend memory. This is allowed, but both services cannot reach their limits simultaneously.'
    }
}

if ($null -eq $Password) {
    $Password = Read-ConfirmedPassword
}
$passwordText = ConvertFrom-SecureValue $Password
try {
    if ([string]::IsNullOrEmpty($passwordText) -or $passwordText.IndexOfAny([char[]]"`r`n`0") -ge 0) {
        throw '비밀번호는 비어 있을 수 없으며 CR, LF, NUL 문자를 포함할 수 없습니다.'
    }
}
finally {
    $passwordText = $null
}

if ($targetExists -and -not $Replace) {
    $confirmation = Read-Host "기존 환경을 교체하려면 정확히 'REPLACE $EnvironmentName'을 입력하십시오"
    if ($confirmation -cne "REPLACE $EnvironmentName") {
        throw '기존 환경 교체가 취소되었습니다.'
    }
    $Replace = $true
}

$storagePath = Join-Path (Join-Path $rootFullPath 'mount') $EnvironmentName
$homeStoragePath = Join-Path $storagePath 'home'
$workspaceStoragePath = Join-Path $storagePath 'workspace'
$backupRoot = Join-Path $rootFullPath '.backup'
$stagingRoot = Join-Path $rootFullPath '.staging'
$stagingPath = Join-Path $stagingRoot "$EnvironmentName.$([Guid]::NewGuid().ToString('N'))"
$storageExistedBefore = Test-Path -LiteralPath $storagePath

$mutex = [Threading.Mutex]::new($false, 'Local\UbuntuDindEnvironmentGenerator')
if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(10))) {
    throw '다른 환경 생성 작업이 실행 중입니다.'
}

$backupPath = $null
$oldStopped = $false
$swapped = $false
$newStarted = $false
$migrationPath = $null
$completed = $false

try {
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    New-Item -ItemType Directory -Path $homeStoragePath -Force | Out-Null
    New-Item -ItemType Directory -Path $workspaceStoragePath -Force | Out-Null
    Copy-Item -Path (Join-Path $templatePath '*') -Destination $stagingPath -Recurse -Force

    $desktopCpuText = $DesktopCpus.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $dindCpuText = $DindCpus.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $desktopCpuDisplay = if ($desktopCpuUnlimited) { 'unlimited (-1)' } else { $desktopCpuText }
    $desktopMemoryDisplay = if ($desktopMemoryUnlimited) { 'unlimited (-1)' } else { $DesktopMemory }
    $dindCpuDisplay = if ($dindCpuUnlimited) { 'unlimited (-1)' } else { $dindCpuText }
    $dindMemoryDisplay = if ($dindMemoryUnlimited) { 'unlimited (-1)' } else { $DindMemory }
    $desktopCpuLimitToken = if ($desktopCpuUnlimited) { '# CPU limit: unlimited (-1)' } else { 'cpus: "${DESKTOP_CPUS}"' }
    $desktopMemoryLimitToken = if ($desktopMemoryUnlimited) { '# Memory limit: unlimited (-1)' } else { 'mem_limit: ${DESKTOP_MEMORY}' }
    $dindCpuLimitToken = if ($dindCpuUnlimited) { '# CPU limit: unlimited (-1)' } else { 'cpus: "${DIND_CPUS}"' }
    $dindMemoryLimitToken = if ($dindMemoryUnlimited) { '# Memory limit: unlimited (-1)' } else { 'mem_limit: ${DIND_MEMORY}' }
    $storageComposePath = $storagePath.Replace('\', '/')
    $imageTag = "26.04-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

    $environmentLines = @(
        "ENVIRONMENT_NAME=$EnvironmentName",
        "ACCOUNT_NAME=$AccountName",
        'ACCOUNT_UID=1001',
        'ACCOUNT_GID=1001',
        'HOST_PLATFORM=windows',
        "HOST_ADDRESS=$HostAddress",
        "SSH_PORT=$SshPort",
        "RDP_PORT=$RdpPort",
        "REMOTE_SUBNET=$RemoteSubnet",
        '# A resource value of -1 means unlimited; the corresponding Compose limit is omitted.',
        "DESKTOP_CPUS=$desktopCpuText",
        "DESKTOP_MEMORY=$DesktopMemory",
        "DIND_CPUS=$dindCpuText",
        "DIND_MEMORY=$DindMemory",
        "DOCKER_VERSION=$DockerVersion",
        "GPU_ENABLED=$gpuEnabledValue",
        "NVIDIA_CONTAINER_TOOLKIT_VERSION=$NvidiaContainerToolkitVersion",
        "CUDA_IMAGE=$CudaImage",
        "IMAGE_TAG=$imageTag",
        'TZ=Asia/Seoul',
        "STORAGE_ROOT=`"$storageComposePath`""
    )
    [IO.File]::WriteAllLines(
        (Join-Path $stagingPath '.env'),
        $environmentLines,
        [Text.UTF8Encoding]::new($false)
    )

    $secretDirectory = Join-Path $stagingPath 'secrets'
    $secretPath = Join-Path $secretDirectory 'login_password.txt'
    New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    $passwordText = ConvertFrom-SecureValue $Password
    try {
        [IO.File]::WriteAllText($secretPath, $passwordText, [Text.UTF8Encoding]::new($false))
    }
    finally {
        $passwordText = $null
    }
    Set-SecretAcl -Path $secretPath

    $tokens = @{
        ENVIRONMENT_NAME = $EnvironmentName
        ACCOUNT_NAME = $AccountName
        HOST_ADDRESS = $HostAddress
        SSH_PORT = $SshPort
        RDP_PORT = $RdpPort
        REMOTE_SUBNET = $RemoteSubnet
        STORAGE_ROOT = $storagePath
        HOME_STORAGE = $homeStoragePath
        WORKSPACE_STORAGE = $workspaceStoragePath
        PROJECT_PATH = $targetPath
        PROJECT_PATH_POWERSHELL = "'$($targetPath.Replace("'", "''"))'"
        DESKTOP_CPUS = $desktopCpuDisplay
        DESKTOP_MEMORY = $desktopMemoryDisplay
        DIND_CPUS = $dindCpuDisplay
        DIND_MEMORY = $dindMemoryDisplay
        DESKTOP_CPU_LIMIT = $desktopCpuLimitToken
        DESKTOP_MEMORY_LIMIT = $desktopMemoryLimitToken
        DIND_CPU_LIMIT = $dindCpuLimitToken
        DIND_MEMORY_LIMIT = $dindMemoryLimitToken
        GPU_STATUS = $gpuDescription
        CUDA_IMAGE = $CudaImage
        HOST_PLATFORM = 'Windows'
        FIREWALL_COMMAND = "& '$(Join-Path $targetPath $firewallScriptName)'"
        GPU_TEST_COMMAND = "& '$(Join-Path $targetPath $gpuTestScriptName)'"
    }

    $composeTemplate = @{
        Source = Join-Path $stagingPath 'compose.yaml.template'
        Destination = Join-Path $stagingPath 'compose.yaml'
        Tokens = $tokens
    }
    Expand-TemplateFile @composeTemplate
    $readmeTemplate = @{
        Source = Join-Path $stagingPath 'README.md.template'
        Destination = Join-Path $stagingPath 'README.md'
        Tokens = $tokens
    }
    Expand-TemplateFile @readmeTemplate
    $firewallTemplate = @{
        Source = Join-Path $stagingPath 'ConfigureFirewall.ps1.template'
        Destination = Join-Path $stagingPath $firewallScriptName
        Tokens = $tokens
    }
    Expand-TemplateFile @firewallTemplate
    $rdpTemplate = @{
        Source = Join-Path $stagingPath 'environment_VM.rdp.template'
        Destination = Join-Path $stagingPath "${EnvironmentName}_VM.rdp"
        Tokens = $tokens
    }
    Expand-TemplateFile @rdpTemplate
    $gpuTestTemplate = @{
        Source = Join-Path $stagingPath 'TestGpu.ps1.template'
        Destination = Join-Path $stagingPath $gpuTestScriptName
        Tokens = $tokens
    }
    Expand-TemplateFile @gpuTestTemplate
    if ($gpuEnabled) {
        Copy-Item -LiteralPath (Join-Path $stagingPath 'compose.gpu.yaml.template') `
            -Destination (Join-Path $stagingPath 'compose.override.yaml')
    }
    Remove-Item -LiteralPath (Join-Path $stagingPath 'README.md.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'compose.yaml.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'ConfigureFirewall.ps1.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'configure_firewall.sh.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'environment_VM.rdp.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'compose.gpu.yaml.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'test_gpu.sh.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'TestGpu.ps1.template')

    $manifest = [ordered]@{
        schemaVersion = 1
        generator = 'NewUbuntuDindEnvironment.ps1'
        generatedAt = [DateTime]::UtcNow.ToString('o')
        environmentName = $EnvironmentName
        projectName = "ubuntu-dind-$EnvironmentName"
        accountName = $AccountName
        storagePath = $storagePath
        hostAddress = $HostAddress
        sshPort = $SshPort
        rdpPort = $RdpPort
        hostPort3389Reserved = $true
        desktopCpus = $DesktopCpus
        desktopCpusUnlimited = $desktopCpuUnlimited
        desktopMemory = $DesktopMemory
        desktopMemoryUnlimited = $desktopMemoryUnlimited
        dindCpus = $DindCpus
        dindCpusUnlimited = $dindCpuUnlimited
        dindMemory = $DindMemory
        dindMemoryUnlimited = $dindMemoryUnlimited
        dockerVersion = $DockerVersion
        hostOs = 'windows'
        gpuEnabled = $gpuEnabled
        gpuNames = if ($gpuEnabled) { @($gpuProbe.GpuNames) } else { @() }
        nestedGpuPolicy = 'best-effort-on-windows-wsl2'
        cudaImage = $CudaImage
        nvidiaContainerToolkitVersion = $NvidiaContainerToolkitVersion
        imageTag = $imageTag
        useBuildKit = [bool]$UseBuildKit
    }
    [IO.File]::WriteAllText(
        (Join-Path $stagingPath '.environment.json'),
        ($manifest | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )

    Invoke-Compose -ProjectPath $stagingPath -Arguments @('config', '--quiet') -FailureMessage '생성된 Compose 구성이 유효하지 않습니다.'

    if ($GenerateOnly) {
        if ($targetExists) {
            throw 'GenerateOnly는 기존 환경을 교체할 수 없습니다. 새 환경 이름으로 시험하십시오.'
        }
        Move-Item -LiteralPath $stagingPath -Destination $targetPath
        $completed = $true
        Write-Host "환경 설정 생성 완료: $targetPath"
        return
    }

    if ($UseBuildKit) {
        Invoke-Compose -ProjectPath $stagingPath -Arguments @('build', 'desktop', 'docker') -FailureMessage 'Ubuntu 데스크톱/DinD 이미지 빌드에 실패했습니다.'
    }
    else {
        # Docker Desktop's BuildKit resolves registry metadata even when the
        # Ubuntu base image is already local. The classic builder can work
        # entirely from the local cache when Docker Hub is unavailable.
        $previousBuildKit = $env:DOCKER_BUILDKIT
        try {
            $env:DOCKER_BUILDKIT = '0'
            Invoke-Docker -Arguments @(
                'build', '--pull=false',
                '--tag', "${EnvironmentName}-ubuntu-dind:${imageTag}",
                '--file', (Join-Path $stagingPath 'Dockerfile'),
                '--build-arg', "ENVIRONMENT_NAME=$EnvironmentName",
                '--build-arg', "ACCOUNT_NAME=$AccountName",
                '--build-arg', 'ACCOUNT_UID=1001',
                '--build-arg', 'ACCOUNT_GID=1001',
                '--build-arg', "DOCKER_VERSION=$DockerVersion",
                $stagingPath
            ) -FailureMessage 'Ubuntu 데스크톱 이미지 빌드에 실패했습니다.'
            Invoke-Docker -Arguments @(
                'build', '--pull=false',
                '--tag', "${EnvironmentName}-dind:${imageTag}",
                '--file', (Join-Path $stagingPath 'Dockerfile.dind'),
                '--build-arg', "DOCKER_VERSION=$DockerVersion",
                '--build-arg', "ENABLE_GPU=$gpuEnabledValue",
                '--build-arg', "NVIDIA_CONTAINER_TOOLKIT_VERSION=$NvidiaContainerToolkitVersion",
                $stagingPath
            ) -FailureMessage 'DinD 엔진 이미지 빌드에 실패했습니다.'
        }
        finally {
            if ($null -eq $previousBuildKit) {
                Remove-Item Env:DOCKER_BUILDKIT -ErrorAction SilentlyContinue
            }
            else {
                $env:DOCKER_BUILDKIT = $previousBuildKit
            }
        }
    }

    $legacyVolume = "${EnvironmentName}_home"
    $legacyVolumeExists = Test-DockerVolume -Name $legacyVolume
    $homeHasData = $null -ne (Get-ChildItem -LiteralPath $homeStoragePath -Force | Select-Object -First 1)
    $migrationMarker = Join-Path $homeStoragePath '.legacy-volume-migrated'
    $migrationAlreadyCompleted = Test-Path -LiteralPath $migrationMarker -PathType Leaf
    $shouldMigrate = $MigrateLegacyHome
    if ($MigrateLegacyHome -and $migrationAlreadyCompleted) {
        $shouldMigrate = $false
    }
    if ($legacyVolumeExists -and -not $homeHasData -and -not $MigrateLegacyHome) {
        $answer = Read-WithDefault -Prompt "기존 볼륨 $legacyVolume 데이터를 host mount로 이전할까요? (Y/N)" -Default 'Y'
        $shouldMigrate = $answer -match '^[Yy]'
    }

    if ($shouldMigrate) {
        if (-not $legacyVolumeExists) {
            throw "이전할 legacy 볼륨이 없습니다: $legacyVolume"
        }
        if ($homeHasData) {
            throw "대상 홈 폴더가 비어 있지 않아 자동 이전을 중단합니다: $homeStoragePath"
        }
        # Ensure the helper image is available before stopping the old environment.
        if (-not (Test-DockerImage -Name 'ubuntu:26.04')) {
            Invoke-Docker -Arguments @('pull', 'ubuntu:26.04') -FailureMessage '홈 마이그레이션용 Ubuntu 이미지를 가져오지 못했습니다.'
        }
    }

    if ($targetExists) {
        Invoke-Compose -ProjectPath $targetPath -Arguments @('down') -FailureMessage '기존 환경을 중지하지 못했습니다.'
        $oldStopped = $true
    }

    if ($shouldMigrate) {
        # NTFS bind mounts can reject directory rename after Linux ownership
        # metadata has been applied. Copy into the final empty home instead;
        # the legacy named volume remains the rollback source until verification.
        $migrationPath = $homeStoragePath
        Invoke-Docker -Arguments @(
            'run', '--rm',
            '--mount', "type=volume,src=$legacyVolume,dst=/source,readonly",
            '--mount', "type=bind,src=$migrationPath,dst=/destination",
            'ubuntu:26.04',
            'bash', '-c', 'set -o pipefail; tar -C /source -cf - . | tar -C /destination --no-overwrite-dir -xpf -; touch /destination/.legacy-volume-migrated; chown 1001:1001 /destination/.legacy-volume-migrated'
        ) -FailureMessage '기존 사용자 홈 데이터 이전에 실패했습니다.'
        $migrationPath = $null
    }

    if ($targetExists) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $backupRoot "$EnvironmentName.$timestamp"
        Move-Item -LiteralPath $targetPath -Destination $backupPath
    }

    Move-Item -LiteralPath $stagingPath -Destination $targetPath
    $swapped = $true

    Invoke-Compose -ProjectPath $targetPath -Arguments @('up', '-d') -FailureMessage '새 환경 시작에 실패했습니다.'
    $newStarted = $true
    Wait-EnvironmentHealthy -ProjectPath $targetPath

    if ($gpuEnabled) {
        Invoke-Compose -ProjectPath $targetPath `
            -Arguments @('exec', '-T', 'desktop', 'nvidia-smi', '-L') `
            -FailureMessage 'Ubuntu 데스크톱에서 NVIDIA GPU를 인식하지 못했습니다.'
        Invoke-Compose -ProjectPath $targetPath `
            -Arguments @('exec', '-T', 'docker', 'nvidia-smi', '-L') `
            -FailureMessage 'DinD 서비스에서 NVIDIA GPU를 인식하지 못했습니다.'
        $nestedGpuReady = Test-ComposeCommand -ProjectPath $targetPath `
            -Arguments @('exec', '-T', '-u', $AccountName, 'desktop', 'docker', 'run', '--rm', '--gpus', 'all', $CudaImage, 'nvidia-smi', '-L')
        if (-not $nestedGpuReady) {
            Write-Warning @"
데스크톱과 DinD 서비스는 GPU를 인식하지만 DinD 내부 컨테이너의 GPU 전달은 실패했습니다.
Docker Desktop WSL2의 중첩 GPU 전달은 공식 지원 범위가 아니므로 환경은 유지합니다.
CUDA 작업은 우선 데스크톱 컨테이너에서 실행하고, 중첩 CUDA가 필수라면 Ubuntu 호스트에서 Bash 생성기를 사용하십시오.
"@
        }
    }

    if (-not $SkipFirewall) {
        $firewallScript = Join-Path $targetPath $firewallScriptName
        $firewallProcess = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$firewallScript`""
        if ($firewallProcess.ExitCode -ne 0) {
            throw "방화벽 구성 스크립트가 종료 코드 $($firewallProcess.ExitCode)로 실패했습니다."
        }
    }

    Write-Host ''
    Write-Host "환경 생성 완료: $EnvironmentName"
    Write-Host "설정: $targetPath"
    Write-Host "영구 홈: $homeStoragePath"
    Write-Host "영구 작업공간: $workspaceStoragePath"
    Write-Host "SSH: ssh -p $SshPort $AccountName@$HostAddress"
    Write-Host "RDP: $(Join-Path $targetPath "${EnvironmentName}_VM.rdp")"
    Write-Host "자원: desktop=${desktopCpuDisplay} CPU/$desktopMemoryDisplay, DinD=${dindCpuDisplay} CPU/$dindMemoryDisplay"
    Write-Host "GPU: $gpuDescription"
    if ($null -ne $backupPath) {
        Write-Host "이전 설정 백업: $backupPath"
    }
    $completed = $true
}
catch {
    $failure = $_
    Write-Warning "환경 생성 실패: $($failure.Exception.Message)"

    if ($swapped) {
        try {
            if (Test-Path -LiteralPath $targetPath) {
                try {
                    Invoke-Compose -ProjectPath $targetPath -Arguments @('down') -FailureMessage '실패한 새 환경을 중지하지 못했습니다.'
                }
                catch {
                    Write-Warning $_.Exception.Message
                }
            }
            $failedRoot = Join-Path $rootFullPath '.failed'
            New-Item -ItemType Directory -Path $failedRoot -Force | Out-Null
            $failedPath = Join-Path $failedRoot "$EnvironmentName.$(Get-Date -Format 'yyyyMMdd-HHmmss').$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            if (Test-Path -LiteralPath $targetPath) {
                Move-Item -LiteralPath $targetPath -Destination $failedPath
            }
        }
        catch {
            Write-Warning "실패한 새 환경 정리 중 오류: $($_.Exception.Message)"
        }
    }

    if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
        try {
            if (Test-Path -LiteralPath $targetPath) {
                throw "롤백 대상 경로가 이미 존재합니다: $targetPath"
            }
            Move-Item -LiteralPath $backupPath -Destination $targetPath
            Invoke-Compose -ProjectPath $targetPath -Arguments @('up', '-d') -FailureMessage '기존 환경 롤백 시작에 실패했습니다.'
        }
        catch {
            Write-Warning "기존 환경 롤백 중 오류: $($_.Exception.Message)"
        }
    }
    elseif ($oldStopped -and $targetExists -and (Test-Path -LiteralPath $targetPath)) {
        try {
            Invoke-Compose -ProjectPath $targetPath -Arguments @('up', '-d') -FailureMessage '기존 환경 재시작에 실패했습니다.'
        }
        catch {
            Write-Warning "기존 환경 재시작 중 오류: $($_.Exception.Message)"
        }
    }

    throw $failure
}
finally {
    if ($null -ne $migrationPath -and (Test-Path -LiteralPath $migrationPath)) {
        Remove-Item -LiteralPath $migrationPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    if (-not $completed -and -not $storageExistedBefore -and (Test-Path -LiteralPath $storagePath)) {
        $storageFile = Get-ChildItem -LiteralPath $storagePath -File -Recurse -Force | Select-Object -First 1
        if ($null -eq $storageFile) {
            Remove-Item -LiteralPath $storagePath -Recurse -Force
        }
    }
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
