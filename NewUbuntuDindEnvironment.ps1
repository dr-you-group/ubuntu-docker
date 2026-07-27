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
    [ValidateSet('Cloudflare', 'WireGuard')]
    [string]$RemoteAccessProvider,
    [string]$WireGuardHubEndpoint,
    [string]$WireGuardHubPublicKey,
    [string]$WireGuardAddress,
    [int]$WireGuardMtu = 1380,
    [int]$WireGuardKeepalive = 25,
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
    [switch]$RotateSshKey,
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

function Read-RequiredValue {
    param([Parameter(Mandatory)] [string]$Prompt)

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Warning '값을 반드시 입력하십시오.'
    }
}

function Read-IntegerInRange {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [int]$Default,
        [Parameter(Mandatory)] [int]$Minimum,
        [Parameter(Mandatory)] [int]$Maximum
    )

    while ($true) {
        $raw = Read-WithDefault -Prompt $Prompt -Default ([string]$Default)
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) {
            return $parsed
        }
        Write-Warning "$Minimum 이상 $Maximum 이하의 정수를 입력하십시오."
    }
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

function Get-IPv4CidrInfo {
    param([Parameter(Mandatory)] [string]$Value)

    if ($Value -notmatch '^(?<Address>(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3})/(?<Prefix>[0-9]|[12][0-9]|3[0-2])$') {
        return $null
    }

    $address = $null
    if (-not [Net.IPAddress]::TryParse($Matches['Address'], [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $null
    }

    $prefixLength = [int]$Matches['Prefix']
    $addressValue = [uint64]0
    foreach ($octet in $address.GetAddressBytes()) {
        $addressValue = ($addressValue * 256) + [uint64]$octet
    }
    $blockSize = [uint64][Math]::Pow(2, 32 - $prefixLength)
    $networkValue = $addressValue - ($addressValue % $blockSize)
    $broadcastValue = $networkValue + $blockSize - 1
    $networkAddress = '{0}.{1}.{2}.{3}' -f `
        (($networkValue -shr 24) -band 255),
        (($networkValue -shr 16) -band 255),
        (($networkValue -shr 8) -band 255),
        ($networkValue -band 255)

    return [pscustomobject]@{
        Address = $address.IPAddressToString
        PrefixLength = $prefixLength
        AddressValue = $addressValue
        NetworkValue = $networkValue
        BroadcastValue = $broadcastValue
        NetworkCidr = "$networkAddress/$prefixLength"
    }
}

function Test-IPv4HostCidr {
    param([string]$Value)

    $cidr = Get-IPv4CidrInfo -Value $Value
    if ($null -eq $cidr) {
        return $false
    }

    if ($cidr.PrefixLength -lt 8 -or $cidr.PrefixLength -gt 29) {
        return $false
    }

    $octets = @($cidr.Address.Split('.') | ForEach-Object { [int]$_ })
    if ($octets[0] -eq 0 -or $octets[0] -eq 127 -or $octets[0] -ge 224 -or
        ($octets[0] -eq 169 -and $octets[1] -eq 254)) {
        return $false
    }
    if ($cidr.PrefixLength -le 30 -and
        ($cidr.AddressValue -eq $cidr.NetworkValue -or $cidr.AddressValue -eq $cidr.BroadcastValue)) {
        return $false
    }
    return $true
}

function Test-IPv4CidrsOverlap {
    param(
        [Parameter(Mandatory)] [string]$First,
        [Parameter(Mandatory)] [string]$Second
    )

    $firstCidr = Get-IPv4CidrInfo -Value $First
    $secondCidr = Get-IPv4CidrInfo -Value $Second
    if ($null -eq $firstCidr -or $null -eq $secondCidr) {
        throw 'CIDR overlap validation received an invalid IPv4 CIDR.'
    }
    return $firstCidr.NetworkValue -le $secondCidr.BroadcastValue -and
        $secondCidr.NetworkValue -le $firstCidr.BroadcastValue
}

function Test-WireGuardEndpoint {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $endpointHost = $null
    $endpointPort = 0
    if ($Value -match '^(?<Host>[^:\[\]\s]+):(?<Port>[0-9]{1,5})$') {
        $endpointHost = $Matches['Host']
        $endpointPort = [int]$Matches['Port']
        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse($endpointHost, [ref]$parsedAddress)) {
            if ($parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                return $false
            }
        }
        elseif ($endpointHost -match '^[0-9.]+$' -or
            $endpointHost.Length -gt 253 -or
            $endpointHost -notmatch '^(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.?$') {
            return $false
        }
    }
    else {
        return $false
    }

    return $endpointPort -ge 1 -and $endpointPort -le 65535
}

function Test-WireGuardPublicKey {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9+/]{43}=$') {
        return $false
    }
    try {
        $decoded = [Convert]::FromBase64String($Value)
        if ($decoded.Length -ne 32) {
            return $false
        }
        foreach ($byte in $decoded) {
            if ($byte -ne 0) {
                return $true
            }
        }
        return $false
    }
    catch {
        return $false
    }
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

function Read-EnvironmentManifest {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "Environment manifest is not valid JSON: $Path"
    }
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()] [object]$Object,
        [Parameter(Mandatory)] [string]$Name,
        [AllowNull()] [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-IPv4Address {
    param([Parameter(Mandatory)] [uint64]$Value)

    if ($Value -gt [uint64]::MaxValue -or $Value -gt 4294967295) {
        throw "IPv4 integer is outside the supported range: $Value"
    }
    return '{0}.{1}.{2}.{3}' -f `
        (($Value -shr 24) -band 255),
        (($Value -shr 16) -band 255),
        (($Value -shr 8) -band 255),
        ($Value -band 255)
}

function Test-IPv4CidrContains {
    param(
        [Parameter(Mandatory)] [string]$Container,
        [Parameter(Mandatory)] [string]$Candidate
    )

    $containerCidr = Get-IPv4CidrInfo -Value $Container
    $candidateCidr = Get-IPv4CidrInfo -Value $Candidate
    if ($null -eq $containerCidr -or $null -eq $candidateCidr) {
        return $false
    }
    return $containerCidr.NetworkValue -le $candidateCidr.NetworkValue -and
        $containerCidr.BroadcastValue -ge $candidateCidr.BroadcastValue
}

function Test-PrivateIPv4Cidr {
    param([Parameter(Mandatory)] [string]$Value)

    $cidr = Get-IPv4CidrInfo -Value $Value
    if ($null -eq $cidr -or $cidr.NetworkCidr -ne $Value) {
        return $false
    }
    foreach ($privateRange in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) {
        if (Test-IPv4CidrContains -Container $privateRange -Candidate $Value) {
            return $true
        }
    }
    return $false
}

function Get-CloudflareAddressOwners {
    param(
        [Parameter(Mandatory)] [string]$RootPath,
        [Parameter(Mandatory)] [string]$ExcludedEnvironmentName
    )

    $owners = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($directory.Name -eq $ExcludedEnvironmentName -or $directory.Name.StartsWith('.')) {
            continue
        }

        $manifest = Read-EnvironmentManifest -Path (Join-Path $directory.FullName '.environment.json')
        $environmentValues = Read-EnvironmentFile -Path (Join-Path $directory.FullName '.env')
        $provider = [string](Get-ObjectPropertyValue -Object $manifest -Name 'remoteAccessProvider' -Default '')
        if ([string]::IsNullOrWhiteSpace($provider) -and $environmentValues.ContainsKey('REMOTE_ACCESS_PROVIDER')) {
            $provider = $environmentValues['REMOTE_ACCESS_PROVIDER']
        }
        if ($provider -ine 'cloudflare') {
            continue
        }

        $subnet = [string](Get-ObjectPropertyValue -Object $manifest -Name 'cloudflareDockerSubnet' -Default '')
        $privateIp = [string](Get-ObjectPropertyValue -Object $manifest -Name 'cloudflarePrivateIp' -Default '')
        if ([string]::IsNullOrWhiteSpace($subnet) -and $environmentValues.ContainsKey('CLOUDFLARE_PRIVATE_SUBNET')) {
            $subnet = $environmentValues['CLOUDFLARE_PRIVATE_SUBNET']
        }
        if ([string]::IsNullOrWhiteSpace($privateIp) -and $environmentValues.ContainsKey('CLOUDFLARE_PRIVATE_IP')) {
            $privateIp = $environmentValues['CLOUDFLARE_PRIVATE_IP']
        }
        $subnetInfo = Get-IPv4CidrInfo -Value $subnet
        if ($null -ne $subnetInfo -and $subnetInfo.PrefixLength -eq 29) {
            $owners += [pscustomobject]@{
                EnvironmentName = $directory.Name
                Subnet = $subnetInfo.NetworkCidr
                PrivateIp = $privateIp
            }
        }
    }
    return @($owners)
}

function Get-DockerNetworkCidrs {
    param([string[]]$ExcludedNames = @())

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $networkIds = @(& docker network ls -q 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'Docker networks could not be listed.'
        }
        $cidrs = @()
        foreach ($networkId in $networkIds) {
            if ([string]::IsNullOrWhiteSpace([string]$networkId)) {
                continue
            }
            $networkJson = [string](& docker network inspect --format '{{json .}}' ([string]$networkId).Trim() 2>$null)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkJson)) {
                continue
            }
            try {
                $network = $networkJson | ConvertFrom-Json
            }
            catch {
                continue
            }
            if ($ExcludedNames -contains [string]$network.Name) {
                continue
            }
            foreach ($configuration in @($network.IPAM.Config)) {
                if ($null -eq $configuration) {
                    continue
                }
                $subnet = [string](Get-ObjectPropertyValue -Object $configuration -Name 'Subnet' -Default '')
                if ($null -ne (Get-IPv4CidrInfo -Value $subnet)) {
                    $cidrs += $subnet
                }
            }
        }
        return @($cidrs | Sort-Object -Unique)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-HostRouteCidrs {
    $cidrs = @()
    try {
        foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)) {
            $destination = [string]$route.DestinationPrefix
            $cidr = Get-IPv4CidrInfo -Value $destination
            if ($null -ne $cidr -and $cidr.PrefixLength -gt 0) {
                $cidrs += $cidr.NetworkCidr
            }
        }
    }
    catch {
        Write-Verbose "Host IPv4 route inspection failed: $($_.Exception.Message)"
    }
    return @($cidrs | Sort-Object -Unique)
}

function Get-CloudflarePrivateAllocation {
    param(
        [Parameter(Mandatory)] [string]$PoolCidr,
        [string[]]$ReservedCidrs = @(),
        [string]$PreferredSubnet,
        [string]$PreferredPrivateIp
    )

    $pool = Get-IPv4CidrInfo -Value $PoolCidr
    if ($null -eq $pool -or $pool.PrefixLength -gt 29) {
        throw "Cloudflare private pool must contain at least one /29: $PoolCidr"
    }

    $candidateSubnets = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredSubnet)) {
        $preferred = Get-IPv4CidrInfo -Value $PreferredSubnet
        if ($null -eq $preferred -or $preferred.PrefixLength -ne 29 -or
            $preferred.NetworkCidr -ne $PreferredSubnet -or
            -not (Test-IPv4CidrContains -Container $PoolCidr -Candidate $PreferredSubnet)) {
            throw "Existing Cloudflare Docker subnet is not a /29 inside $PoolCidr`: $PreferredSubnet"
        }
        $candidateSubnets = @($PreferredSubnet)
    }
    $networkValue = $pool.NetworkValue
    while ($true) {
        $candidateSubnet = if ($null -ne $candidateSubnets) {
            $candidateSubnets[0]
        }
        else {
            "$(ConvertTo-IPv4Address -Value $networkValue)/29"
        }
        $overlaps = $false
        foreach ($reservedCidr in @($ReservedCidrs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ($null -ne (Get-IPv4CidrInfo -Value $reservedCidr) -and
                (Test-IPv4CidrsOverlap -First $candidateSubnet -Second $reservedCidr)) {
                $overlaps = $true
                break
            }
        }
        if ($overlaps) {
            if ($null -ne $candidateSubnets) { break }
            $networkValue += [uint64]8
            if ($networkValue -gt $pool.BroadcastValue) { break }
            continue
        }

        $candidateInfo = Get-IPv4CidrInfo -Value $candidateSubnet
        $expectedPrivateIp = ConvertTo-IPv4Address -Value ($candidateInfo.NetworkValue + 2)
        $privateIp = if ([string]::IsNullOrWhiteSpace($PreferredPrivateIp)) { $expectedPrivateIp } else { $PreferredPrivateIp }
        $privateHost = Get-IPv4CidrInfo -Value "$privateIp/32"
        if ($null -eq $privateHost -or
            $privateIp -ne $expectedPrivateIp) {
            throw "Cloudflare private IP must be host +2 in $candidateSubnet`: $privateIp"
        }
        return [pscustomobject]@{
            DockerSubnet = $candidateSubnet
            PrivateIp = $privateIp
            PrivateCidr = "$privateIp/32"
        }
    }

    throw "No non-overlapping /29 remains in the Cloudflare private pool: $PoolCidr"
}

function Get-CloudflareNumericErrorCodes {
    param([AllowNull()] [object]$Envelope)

    $codes = [Collections.Generic.List[string]]::new()
    foreach ($apiError in @(Get-ObjectPropertyValue -Object $Envelope -Name 'errors' -Default @())) {
        $candidate = Get-ObjectPropertyValue -Object $apiError -Name 'code' -Default $null
        $parsed = [long]0
        if ($null -ne $candidate -and
            [long]::TryParse([string]$candidate, [ref]$parsed) -and
            $parsed -ge 0) {
            $codes.Add([string]$parsed)
        }
    }
    return @($codes | Sort-Object -Unique)
}

function New-CloudflareApiException {
    param(
        [Parameter(Mandatory)] [string]$Summary,
        [AllowNull()] [object]$HttpStatus = $null,
        [string[]]$ErrorCodes = @(),
        [bool]$PostOutcomeAmbiguous = $false
    )

    $statusSummary = if ($null -eq $HttpStatus) { 'unavailable' } else { [string]$HttpStatus }
    $codeSummary = if ($ErrorCodes.Count -gt 0) {
        ", error codes: $($ErrorCodes -join ',')"
    }
    else { '' }
    $message = "$Summary (HTTP $statusSummary$codeSummary)."
    $exception = [InvalidOperationException]::new($message)
    $exception.Data['CloudflareApiFailure'] = $true
    if ($null -ne $HttpStatus -and [string]$HttpStatus -match '^\d{3}$') {
        $exception.Data['CloudflareHttpStatus'] = [int]$HttpStatus
    }
    if ($ErrorCodes.Count -gt 0) {
        $exception.Data['CloudflareErrorCodes'] = $ErrorCodes -join ','
    }
    $exception.Data['CloudflarePostOutcomeAmbiguous'] = $PostOutcomeAmbiguous
    return $exception
}

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$ApiToken,
        [AllowNull()] [object]$Body = $null
    )

    $request = @{
        Uri = "https://api.cloudflare.com/client/v4$Path"
        Method = $Method
        Headers = @{
            Authorization = "Bearer $ApiToken"
            Accept = 'application/json'
        }
        ErrorAction = 'Stop'
        UseBasicParsing = $true
        TimeoutSec = 90
    }
    if ($null -ne $Body) {
        $request['ContentType'] = 'application/json'
        $request['Body'] = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    try {
        $response = Invoke-RestMethod @request
    }
    catch {
        $requestFailure = $_
        $statusCode = $null
        try {
            $responseProperty = $requestFailure.Exception.PSObject.Properties['Response']
            if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
                if ($null -ne $statusProperty) {
                    $candidateStatus = [int]$statusProperty.Value
                    if ($candidateStatus -ge 100 -and $candidateStatus -le 599) {
                        $statusCode = $candidateStatus
                    }
                }
            }
        }
        catch { }

        $errorEnvelope = $null
        $errorDetails = if ($null -eq $requestFailure.ErrorDetails) {
            ''
        }
        else { [string]$requestFailure.ErrorDetails.Message }
        if (-not [string]::IsNullOrWhiteSpace($errorDetails)) {
            try { $errorEnvelope = $errorDetails | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
        $errorCodes = @(Get-CloudflareNumericErrorCodes -Envelope $errorEnvelope)
        $ambiguousPost = $Method -eq 'POST' -and
            ($null -eq $statusCode -or $statusCode -ge 500)
        $failureSummary = "Cloudflare API request failed ($Method $Path)"
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            $failureSummary += '; verify the account scope and required Cloudflare One Write permissions'
        }
        throw (New-CloudflareApiException `
            -Summary $failureSummary `
            -HttpStatus $statusCode `
            -ErrorCodes $errorCodes `
            -PostOutcomeAmbiguous $ambiguousPost)
    }

    $successProperty = if ($null -eq $response) { $null } else { $response.PSObject.Properties['success'] }
    if ($null -eq $successProperty -or $successProperty.Value -isnot [bool]) {
        throw (New-CloudflareApiException `
            -Summary "Cloudflare API returned a malformed response for $Method $Path" `
            -HttpStatus '2xx' `
            -PostOutcomeAmbiguous ($Method -eq 'POST'))
    }
    if (-not $successProperty.Value) {
        $errorCodes = @(Get-CloudflareNumericErrorCodes -Envelope $response)
        throw (New-CloudflareApiException `
            -Summary "Cloudflare API rejected $Method $Path" `
            -HttpStatus '2xx' `
            -ErrorCodes $errorCodes `
            -PostOutcomeAmbiguous $false)
    }
    return $response
}

function Get-CloudflarePagedResults {
    param(
        [Parameter(Mandatory)] [string]$ResourcePath,
        [Parameter(Mandatory)] [string]$ApiToken
    )

    $results = @()
    $page = 1
    $maximumPages = 10000
    while ($true) {
        $separator = if ($ResourcePath.Contains('?')) { '&' } else { '?' }
        $response = Invoke-CloudflareApi -Method GET `
            -Path "$ResourcePath${separator}page=$page&per_page=1000" `
            -ApiToken $ApiToken
        $pageResults = @(Get-ObjectPropertyValue -Object $response -Name 'result' -Default @())
        $results += $pageResults
        $resultInfo = Get-ObjectPropertyValue -Object $response -Name 'result_info' -Default $null
        $totalPages = 0
        $totalPagesCandidate = [string](Get-ObjectPropertyValue -Object $resultInfo -Name 'total_pages' -Default '')
        $hasTotalPages = [int]::TryParse($totalPagesCandidate, [ref]$totalPages) -and $totalPages -ge 0
        if (-not $hasTotalPages) {
            $totalCount = [long]0
            $perPage = 0
            $hasTotalCount = [long]::TryParse(
                [string](Get-ObjectPropertyValue -Object $resultInfo -Name 'total_count' -Default ''),
                [ref]$totalCount
            ) -and $totalCount -ge 0
            $hasPerPage = [int]::TryParse(
                [string](Get-ObjectPropertyValue -Object $resultInfo -Name 'per_page' -Default ''),
                [ref]$perPage
            ) -and $perPage -gt 0
            if ($hasTotalCount -and $hasPerPage) {
                $totalPages = [int][Math]::Ceiling($totalCount / [double]$perPage)
                $hasTotalPages = $true
            }
        }
        if (-not $hasTotalPages) {
            # Older/malformed result_info objects cannot justify another read.
            # A short page is complete; a full page is rejected rather than
            # risking either truncation or an unbounded request loop.
            if ($pageResults.Count -ge 1000) {
                throw "Cloudflare API pagination metadata is incomplete for $ResourcePath."
            }
            break
        }
        if ($page -ge $totalPages) { break }
        if ($page -ge $maximumPages -or $totalPages -gt $maximumPages) {
            throw "Cloudflare API pagination exceeded the safe page limit for $ResourcePath."
        }
        $page++
    }
    return @($results)
}

function Test-CloudflareResourceId {
    param([string]$Value)

    $parsed = [Guid]::Empty
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        [Guid]::TryParseExact($Value, 'D', [ref]$parsed)
}

function Resolve-CloudflareCreation {
    param(
        [Parameter(Mandatory)] [ValidateSet('tunnel', 'route')] [string]$ResourceKind,
        [Parameter(Mandatory)] [string]$ResourcePath,
        [Parameter(Mandatory)] [string]$ApiToken,
        [string]$Name,
        [string]$Network,
        [string]$TunnelId,
        [ValidateRange(1, 10)] [int]$Attempts = 3
    )

    $state = 'not-read'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $resources = @(Get-CloudflarePagedResults `
                -ResourcePath $ResourcePath `
                -ApiToken $ApiToken)
            $matches = @(if ($ResourceKind -eq 'tunnel') {
                $resources | Where-Object {
                    [string](Get-ObjectPropertyValue -Object $_ -Name 'name' -Default '') -ceq $Name
                }
            }
            else {
                $resources | Where-Object {
                    $candidateTunnelId = [string](Get-ObjectPropertyValue -Object $_ -Name 'tunnel_id' -Default '')
                    if ([string]::IsNullOrWhiteSpace($candidateTunnelId)) {
                        $candidateTunnelId = [string](Get-ObjectPropertyValue -Object $_ -Name 'tunnelId' -Default '')
                    }
                    [string](Get-ObjectPropertyValue -Object $_ -Name 'network' -Default '') -eq $Network -and
                        $candidateTunnelId -eq $TunnelId
                }
            })
            if ($matches.Count -eq 1) {
                $resourceId = [string](Get-ObjectPropertyValue -Object $matches[0] -Name 'id' -Default '')
                if (Test-CloudflareResourceId -Value $resourceId) {
                    return [pscustomobject]@{
                        Resolved = $true
                        ResourceId = $resourceId
                        State = 'resolved'
                        Attempts = $attempt
                    }
                }
                $state = 'invalid-id'
            }
            elseif ($matches.Count -eq 0) {
                $state = 'zero-matches'
            }
            else {
                $state = 'multiple-matches'
            }
        }
        catch {
            $state = 'read-failed'
        }

        if ($attempt -lt $Attempts) {
            $delaySeconds = [int][Math]::Min(4, [Math]::Pow(2, $attempt - 1))
            Start-Sleep -Seconds $delaySeconds
        }
    }
    return [pscustomobject]@{
        Resolved = $false
        ResourceId = $null
        State = $state
        Attempts = $Attempts
    }
}

function Write-CloudflareTransactionJournal {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$EnvironmentName,
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$TunnelName,
        [Parameter(Mandatory)] [string]$Network,
        [string]$TunnelId,
        [string]$RouteId,
        [ValidateSet('tunnel-create-started', 'tunnel-created', 'route-create-started', 'route-created')]
        [string]$MutationState = 'tunnel-create-started'
    )

    $journal = [ordered]@{
        schemaVersion = 2
        environmentName = $EnvironmentName
        accountId = $AccountId
        tunnelName = $TunnelName
        network = $Network
        tunnelId = $TunnelId
        routeId = $RouteId
        mutationState = $MutationState
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText(
        $Path,
        ($journal | ConvertTo-Json -Depth 3),
        [Text.UTF8Encoding]::new($false)
    )
    Set-SecretAcl -Path $Path
}

function New-CloudflareTunnelResource {
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$ApiToken,
        [Parameter(Mandatory)] [string]$Name
    )

    $creationException = $null
    try {
        $response = Invoke-CloudflareApi -Method POST `
            -Path "/accounts/$AccountId/cfd_tunnel" `
            -ApiToken $ApiToken `
            -Body ([ordered]@{ name = $Name; config_src = 'cloudflare' })
    }
    catch {
        $isAmbiguous = $false
        if ($null -ne $_.Exception.Data -and
            $_.Exception.Data.Contains('CloudflarePostOutcomeAmbiguous')) {
            $isAmbiguous = [bool]$_.Exception.Data['CloudflarePostOutcomeAmbiguous']
        }
        if (-not $isAmbiguous) { throw }
        $creationException = $_.Exception
    }
    if ($null -eq $creationException) {
        $result = Get-ObjectPropertyValue -Object $response -Name 'result' -Default $null
        $tunnelId = [string](Get-ObjectPropertyValue -Object $result -Name 'id' -Default '')
        if (Test-CloudflareResourceId -Value $tunnelId) {
            return $tunnelId
        }
        $creationException = [InvalidOperationException]::new(
            'Cloudflare tunnel creation returned a success response without a valid resource ID.'
        )
    }

    $encodedName = [Uri]::EscapeDataString($Name)
    $reconciliation = Resolve-CloudflareCreation `
        -ResourceKind tunnel `
        -ResourcePath "/accounts/$AccountId/cfd_tunnel?is_deleted=false&name=$encodedName" `
        -ApiToken $ApiToken `
        -Name $Name
    if ($reconciliation.Resolved) {
        return [string]$reconciliation.ResourceId
    }

    $ambiguousFailure = [InvalidOperationException]::new(
        "Cloudflare tunnel creation outcome is unknown after $($reconciliation.Attempts) read-only reconciliation attempts ($($reconciliation.State)). Do not retry the POST manually; the protected transaction journal must be reconciled first.",
        $creationException
    )
    $ambiguousFailure.Data['CloudflareMutationOutcomeUnknown'] = 'tunnel'
    $ambiguousFailure.Data['CloudflareReconciliationState'] = $reconciliation.State
    foreach ($key in @('CloudflareHttpStatus', 'CloudflareErrorCodes')) {
        if ($null -ne $creationException.Data -and $creationException.Data.Contains($key)) {
            $ambiguousFailure.Data[$key] = $creationException.Data[$key]
        }
    }
    throw $ambiguousFailure
}

function New-CloudflareRouteResource {
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$ApiToken,
        [Parameter(Mandatory)] [string]$TunnelId,
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [string]$Comment
    )

    $creationException = $null
    try {
        $response = Invoke-CloudflareApi -Method POST `
            -Path "/accounts/$AccountId/teamnet/routes" `
            -ApiToken $ApiToken `
            -Body ([ordered]@{ network = $Network; tunnel_id = $TunnelId; comment = $Comment })
    }
    catch {
        $isAmbiguous = $false
        if ($null -ne $_.Exception.Data -and
            $_.Exception.Data.Contains('CloudflarePostOutcomeAmbiguous')) {
            $isAmbiguous = [bool]$_.Exception.Data['CloudflarePostOutcomeAmbiguous']
        }
        if (-not $isAmbiguous) { throw }
        $creationException = $_.Exception
    }
    if ($null -eq $creationException) {
        $result = Get-ObjectPropertyValue -Object $response -Name 'result' -Default $null
        $routeId = [string](Get-ObjectPropertyValue -Object $result -Name 'id' -Default '')
        if (Test-CloudflareResourceId -Value $routeId) {
            return $routeId
        }
        $creationException = [InvalidOperationException]::new(
            'Cloudflare route creation returned a success response without a valid resource ID.'
        )
    }

    $reconciliation = Resolve-CloudflareCreation `
        -ResourceKind route `
        -ResourcePath "/accounts/$AccountId/teamnet/routes" `
        -ApiToken $ApiToken `
        -Network $Network `
        -TunnelId $TunnelId
    if ($reconciliation.Resolved) {
        return [string]$reconciliation.ResourceId
    }

    $ambiguousFailure = [InvalidOperationException]::new(
        "Cloudflare route creation outcome is unknown after $($reconciliation.Attempts) read-only reconciliation attempts ($($reconciliation.State)). Do not retry the POST manually; the protected transaction journal must be reconciled first.",
        $creationException
    )
    $ambiguousFailure.Data['CloudflareMutationOutcomeUnknown'] = 'route'
    $ambiguousFailure.Data['CloudflareReconciliationState'] = $reconciliation.State
    foreach ($key in @('CloudflareHttpStatus', 'CloudflareErrorCodes')) {
        if ($null -ne $creationException.Data -and $creationException.Data.Contains($key)) {
            $ambiguousFailure.Data[$key] = $creationException.Data[$key]
        }
    }
    throw $ambiguousFailure
}

function Remove-CloudflareProvisioningResources {
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$ApiToken,
        [string]$RouteId,
        [string]$TunnelId
    )

    $routeRemoved = $true
    $tunnelRemoved = [string]::IsNullOrWhiteSpace($TunnelId)
    if (-not [string]::IsNullOrWhiteSpace($RouteId)) {
        try {
            $null = Invoke-CloudflareApi -Method DELETE `
                -Path "/accounts/$AccountId/teamnet/routes/$RouteId" `
                -ApiToken $ApiToken
        }
        catch {
            $routeRemoved = $false
            Write-Warning "Cloudflare route rollback failed for route ID $RouteId. The new tunnel is being retained to avoid an orphaned route."
        }
    }
    if ($routeRemoved -and -not [string]::IsNullOrWhiteSpace($TunnelId)) {
        try {
            $null = Invoke-CloudflareApi -Method DELETE `
                -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId" `
                -ApiToken $ApiToken
            $tunnelRemoved = $true
        }
        catch {
            Write-Warning "Cloudflare tunnel rollback failed for tunnel ID $TunnelId. Remove that tunnel manually after confirming it is unused."
        }
    }
    return $routeRemoved -and $tunnelRemoved
}

function Invoke-CloudflareTransactionRecovery {
    param(
        [Parameter(Mandatory)] [string]$StagingRoot,
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$ApiToken
    )

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        return
    }
    $stagingRootFull = [IO.Path]::GetFullPath($StagingRoot).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    foreach ($directory in @(Get-ChildItem -LiteralPath $StagingRoot -Directory -Force -ErrorAction Stop)) {
        $directoryFull = [IO.Path]::GetFullPath($directory.FullName).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if (-not $directoryFull.StartsWith($stagingRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cloudflare transaction journal path escaped the staging root: $($directory.FullName)"
        }
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing Cloudflare recovery through a reparse point: $($directory.FullName)"
        }
        $journalPath = Join-Path $directory.FullName '.cloudflare-provisioning-transaction.json'
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            continue
        }

        $journal = Read-EnvironmentManifest -Path $journalPath
        $journalSchema = [int](Get-ObjectPropertyValue -Object $journal -Name 'schemaVersion' -Default 0)
        $journalEnvironment = [string](Get-ObjectPropertyValue -Object $journal -Name 'environmentName' -Default '')
        $journalAccount = [string](Get-ObjectPropertyValue -Object $journal -Name 'accountId' -Default '')
        $journalTunnelName = [string](Get-ObjectPropertyValue -Object $journal -Name 'tunnelName' -Default '')
        $journalNetwork = [string](Get-ObjectPropertyValue -Object $journal -Name 'network' -Default '')
        $journalTunnelId = [string](Get-ObjectPropertyValue -Object $journal -Name 'tunnelId' -Default '')
        $journalRouteId = [string](Get-ObjectPropertyValue -Object $journal -Name 'routeId' -Default '')
        $journalMutationState = [string](Get-ObjectPropertyValue -Object $journal -Name 'mutationState' -Default '')
        if ($journalSchema -eq 1) {
            # Schema 1 did not record whether the next POST had started. Treat
            # every missing ID conservatively as an unknown mutation outcome.
            $journalMutationState = if ([string]::IsNullOrWhiteSpace($journalTunnelId)) {
                'tunnel-create-started'
            }
            elseif ([string]::IsNullOrWhiteSpace($journalRouteId)) {
                'route-create-started'
            }
            else { 'route-created' }
        }
        $validMutationShape =
            ($journalMutationState -eq 'tunnel-create-started' -and
             [string]::IsNullOrWhiteSpace($journalTunnelId) -and
             [string]::IsNullOrWhiteSpace($journalRouteId)) -or
            ($journalMutationState -eq 'tunnel-created' -and
             -not [string]::IsNullOrWhiteSpace($journalTunnelId) -and
             [string]::IsNullOrWhiteSpace($journalRouteId)) -or
            ($journalMutationState -eq 'route-create-started' -and
             -not [string]::IsNullOrWhiteSpace($journalTunnelId) -and
             [string]::IsNullOrWhiteSpace($journalRouteId)) -or
            ($journalMutationState -eq 'route-created' -and
             -not [string]::IsNullOrWhiteSpace($journalTunnelId) -and
             -not [string]::IsNullOrWhiteSpace($journalRouteId))
        if (($journalSchema -ne 1 -and $journalSchema -ne 2) -or
            $journalEnvironment -notmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$' -or
            $journalTunnelName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$' -or
            $null -eq (Get-IPv4CidrInfo -Value $journalNetwork) -or
            -not $validMutationShape -or
            (-not [string]::IsNullOrWhiteSpace($journalTunnelId) -and
             -not (Test-CloudflareResourceId -Value $journalTunnelId)) -or
            (-not [string]::IsNullOrWhiteSpace($journalRouteId) -and
             -not (Test-CloudflareResourceId -Value $journalRouteId))) {
            throw "Invalid Cloudflare transaction journal; inspect it without deleting Cloudflare resources: $journalPath"
        }
        if ($journalAccount -ne $AccountId) {
            throw "Cloudflare transaction journal belongs to account $journalAccount, not the configured account. Recover it with the matching account configuration: $journalPath"
        }

        $knownTunnels = @(Get-CloudflarePagedResults `
            -ResourcePath "/accounts/$AccountId/cfd_tunnel?is_deleted=false" `
            -ApiToken $ApiToken)
        $knownRoutes = @(Get-CloudflarePagedResults `
            -ResourcePath "/accounts/$AccountId/teamnet/routes" `
            -ApiToken $ApiToken)
        $ownedTunnel = @(if ([string]::IsNullOrWhiteSpace($journalTunnelId)) {
            $knownTunnels | Where-Object {
                [string](Get-ObjectPropertyValue -Object $_ -Name 'name' -Default '') -ceq $journalTunnelName
            }
        }
        else {
            $knownTunnels | Where-Object {
                [string](Get-ObjectPropertyValue -Object $_ -Name 'id' -Default '') -eq $journalTunnelId
            }
        })
        if ($ownedTunnel.Count -gt 1) {
            throw "Cloudflare transaction recovery found multiple matching tunnels; the unknown journal was preserved and no resource was deleted: $journalPath"
        }
        if ($ownedTunnel.Count -eq 1 -and [string]::IsNullOrWhiteSpace($journalTunnelId)) {
            $discoveredTunnelId = [string](Get-ObjectPropertyValue -Object $ownedTunnel[0] -Name 'id' -Default '')
            if (-not (Test-CloudflareResourceId -Value $discoveredTunnelId)) {
                throw "Cloudflare transaction recovery found an invalid tunnel ID: $journalPath"
            }
            $journalTunnelId = $discoveredTunnelId
        }
        $ownedRoute = @(if ([string]::IsNullOrWhiteSpace($journalRouteId)) {
            if ([string]::IsNullOrWhiteSpace($journalTunnelId)) {
            }
            else {
                $knownRoutes | Where-Object {
                    $candidateTunnelId = [string](Get-ObjectPropertyValue -Object $_ -Name 'tunnel_id' -Default '')
                    if ([string]::IsNullOrWhiteSpace($candidateTunnelId)) {
                        $candidateTunnelId = [string](Get-ObjectPropertyValue -Object $_ -Name 'tunnelId' -Default '')
                    }
                    [string](Get-ObjectPropertyValue -Object $_ -Name 'network' -Default '') -eq $journalNetwork -and
                        $candidateTunnelId -eq $journalTunnelId
                }
            }
        }
        else {
            $knownRoutes | Where-Object {
                [string](Get-ObjectPropertyValue -Object $_ -Name 'id' -Default '') -eq $journalRouteId
            }
        })
        if ($ownedRoute.Count -gt 1) {
            throw "Cloudflare transaction recovery found multiple matching routes; the unknown journal was preserved and no resource was deleted: $journalPath"
        }
        if ($ownedTunnel.Count -eq 1 -and
            [string](Get-ObjectPropertyValue -Object $ownedTunnel[0] -Name 'name' -Default '') -cne $journalTunnelName) {
            throw "Cloudflare transaction tunnel ownership check failed: $journalPath"
        }
        if ($ownedRoute.Count -eq 1) {
            $ownedRouteTunnelId = [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'tunnel_id' -Default '')
            if ([string]::IsNullOrWhiteSpace($ownedRouteTunnelId)) {
                $ownedRouteTunnelId = [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'tunnelId' -Default '')
            }
            if ($ownedRouteTunnelId -ne $journalTunnelId) {
                throw "Cloudflare transaction route ownership check failed: $journalPath"
            }
        }
        if ($ownedRoute.Count -eq 1 -and
            [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'network' -Default '') -ne $journalNetwork) {
            throw "Cloudflare transaction route network check failed: $journalPath"
        }
        if ($ownedRoute.Count -eq 1 -and
            -not (Test-CloudflareResourceId -Value ([string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'id' -Default '')))) {
            throw "Cloudflare transaction recovery found an invalid route ID: $journalPath"
        }
        if ($ownedRoute.Count -eq 1 -and $ownedTunnel.Count -ne 1) {
            throw "Cloudflare transaction route exists without its recorded tunnel: $journalPath"
        }

        if ($journalMutationState -eq 'tunnel-create-started') {
            if ($ownedTunnel.Count -eq 0) {
                throw "Cloudflare tunnel creation is still unverified (zero exact matches). The unknown journal was preserved and no new POST or destructive recovery was attempted: $journalPath"
            }
            if ($ownedRoute.Count -ne 0) {
                throw "Cloudflare recovery found an unexpected route for an unjournaled tunnel result. The journal was preserved and nothing was deleted: $journalPath"
            }
            # The exact, preflight-unique name now resolves to one valid ID.
            # Journal that proof before any delete so another interruption is safe.
            $journalMutationState = 'tunnel-created'
            Write-CloudflareTransactionJournal `
                -Path $journalPath `
                -EnvironmentName $journalEnvironment `
                -AccountId $journalAccount `
                -TunnelName $journalTunnelName `
                -Network $journalNetwork `
                -TunnelId $journalTunnelId `
                -MutationState $journalMutationState
        }
        elseif ($journalMutationState -eq 'route-create-started') {
            if ($ownedTunnel.Count -ne 1) {
                throw "Cloudflare route creation cannot be reconciled because its recorded tunnel is not verifiable. The journal was preserved and nothing was deleted: $journalPath"
            }
            if ($ownedRoute.Count -eq 0) {
                throw "Cloudflare route creation is still unverified (zero exact matches). The unknown journal was preserved and no new POST or destructive recovery was attempted: $journalPath"
            }
            $journalRouteId = [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'id' -Default '')
            $journalMutationState = 'route-created'
            Write-CloudflareTransactionJournal `
                -Path $journalPath `
                -EnvironmentName $journalEnvironment `
                -AccountId $journalAccount `
                -TunnelName $journalTunnelName `
                -Network $journalNetwork `
                -TunnelId $journalTunnelId `
                -RouteId $journalRouteId `
                -MutationState $journalMutationState
        }

        $routeToRemove = if ($ownedRoute.Count -eq 1) {
            [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'id' -Default '')
        }
        else { $null }
        $tunnelToRemove = if ($ownedTunnel.Count -eq 1) { $journalTunnelId } else { $null }
        $recovered = Remove-CloudflareProvisioningResources `
            -AccountId $AccountId `
            -ApiToken $ApiToken `
            -RouteId $routeToRemove `
            -TunnelId $tunnelToRemove
        if (-not $recovered) {
            throw "Cloudflare transaction recovery did not finish. Keep this journal and retry after restoring API access: $journalPath"
        }
        Remove-Item -LiteralPath $journalPath -Force
        Write-Warning "Recovered an interrupted Cloudflare provisioning transaction for environment '$journalEnvironment'."
        # The directory was resolved inside .staging and verified not to be a
        # reparse point above; it contains only an interrupted generator output.
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
    }
}

function Get-WireGuardAddressOwners {
    param(
        [Parameter(Mandatory)] [string]$RootPath,
        [Parameter(Mandatory)] [string]$ExcludedEnvironmentName
    )

    $owners = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($directory.Name -eq $ExcludedEnvironmentName) {
            continue
        }
        $environmentFile = Join-Path $directory.FullName '.env'
        if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
            continue
        }
        $environmentValues = Read-EnvironmentFile -Path $environmentFile
        if (-not $environmentValues.ContainsKey('WIREGUARD_ADDRESS')) {
            continue
        }
        $cidr = Get-IPv4CidrInfo -Value $environmentValues['WIREGUARD_ADDRESS']
        if ($null -ne $cidr) {
            $owners += [pscustomobject]@{
                EnvironmentName = $directory.Name
                Address = $cidr.Address
                EnvironmentFile = $environmentFile
            }
        }
    }
    return @($owners)
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
    $permission = if (Test-Path -LiteralPath $Path -PathType Container) { '(OI)(CI)(F)' } else { '(F)' }
    $arguments = @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        "*${currentSid}:$permission",
        "*S-1-5-18:$permission",
        "*S-1-5-32-544:$permission"
    )
    & icacls.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "보안 파일 또는 디렉터리 ACL 설정에 실패했습니다: $Path"
    }
}

function New-SshPemKeyPair {
    param(
        [Parameter(Mandatory)] [string]$PrivateKeyPath,
        [Parameter(Mandatory)] [string]$Comment
    )

    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw 'ssh-keygen.exe를 찾을 수 없습니다. Windows OpenSSH Client를 설치하십시오.'
    }
    if ((Test-Path -LiteralPath $PrivateKeyPath) -or (Test-Path -LiteralPath "$PrivateKeyPath.pub")) {
        throw "SSH 키 생성 대상이 이미 존재합니다: $PrivateKeyPath"
    }

    # Windows PowerShell 5.1 drops a native empty-string argument. A literal
    # pair of quotes is required so ssh-keygen receives an empty passphrase.
    & $sshKeygen.Source -q -t rsa -b 4096 -m PEM -N '""' -C $Comment -f $PrivateKeyPath
    $keygenExitCode = $LASTEXITCODE
    if ($keygenExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath "$PrivateKeyPath.pub" -PathType Leaf)) {
        throw "RSA PEM SSH 키 생성에 실패했습니다(종료 코드 $keygenExitCode)."
    }
}

function Write-SshCanonicalPublicKey {
    param(
        [Parameter(Mandatory)] [string]$PrivateKeyPath,
        [Parameter(Mandatory)] [string]$PublicKeyPath,
        [Parameter(Mandatory)] [string]$Comment
    )

    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw 'ssh-keygen.exe를 찾을 수 없습니다. Windows OpenSSH Client를 설치하십시오.'
    }
    $derivedLines = @(& $sshKeygen.Source -y -P '""' -f $PrivateKeyPath 2>$null |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $deriveExitCode = $LASTEXITCODE
    if ($deriveExitCode -ne 0 -or $derivedLines.Count -ne 1) {
        throw 'SSH private key에서 단일 public key를 생성하지 못했습니다.'
    }
    $derivedParts = ([string]$derivedLines[0]).Trim() -split '\s+'
    if ($derivedParts.Count -ne 2 -or $derivedParts[0] -ne 'ssh-rsa') {
        throw 'SSH private key에서 올바른 RSA public key를 생성하지 못했습니다.'
    }

    $canonicalPublicKey = "ssh-rsa $($derivedParts[1]) $Comment"
    [IO.File]::WriteAllText(
        $PublicKeyPath,
        "$canonicalPublicKey`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-SshKeyPairMetadata {
    param(
        [Parameter(Mandatory)] [string]$PrivateKeyPath,
        [Parameter(Mandatory)] [string]$PublicKeyPath
    )

    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        throw 'SSH private/public key pair is incomplete.'
    }
    $privateHeader = Get-Content -LiteralPath $PrivateKeyPath -Encoding ASCII -TotalCount 1
    if ([string]$privateHeader -ne '-----BEGIN RSA PRIVATE KEY-----') {
        throw 'SSH private key is not an RSA PEM key.'
    }

    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw 'ssh-keygen.exe를 찾을 수 없습니다. Windows OpenSSH Client를 설치하십시오.'
    }
    $derivedPublic = @(& $sshKeygen.Source -y -P '""' -f $PrivateKeyPath 2>$null |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $deriveExitCode = $LASTEXITCODE
    if ($deriveExitCode -ne 0 -or $derivedPublic.Count -ne 1) {
        throw 'SSH private key validation failed.'
    }

    $publicLines = @(Get-Content -LiteralPath $PublicKeyPath -Encoding ASCII |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($publicLines.Count -ne 1) {
        throw 'SSH public key file must contain exactly one non-empty line.'
    }
    $publicLine = $publicLines[0]
    $derivedParts = ([string]$derivedPublic[0]).Trim() -split '\s+'
    $publicParts = ([string]$publicLine).Trim() -split '\s+'
    if ($derivedParts.Count -lt 2 -or $publicParts.Count -lt 2 -or
        $derivedParts[0] -ne 'ssh-rsa' -or $publicParts[0] -ne 'ssh-rsa' -or
        $derivedParts[1] -ne $publicParts[1]) {
        throw 'SSH public key does not match the RSA private key.'
    }

    $fingerprintOutput = @(& $sshKeygen.Source -l -E sha256 -f $PublicKeyPath 2>$null)
    $fingerprintExitCode = $LASTEXITCODE
    $fingerprint = if ($fingerprintOutput.Count -gt 0) { ([string]$fingerprintOutput[0]).Trim() } else { '' }
    if ($fingerprintExitCode -ne 0 -or $fingerprint -notmatch '^4096\s+SHA256:[A-Za-z0-9+/]+') {
        throw 'SSH key must be a valid 4096-bit RSA key.'
    }

    return [pscustomobject]@{
        PublicKey = "ssh-rsa $($publicParts[1])"
        Fingerprint = $fingerprint
    }
}

function Expand-TemplateFile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [hashtable]$Tokens
    )

    $content = [IO.File]::ReadAllText($Source)
    $tokenPattern = '__([A-Z][A-Z0-9_]*)__'
    $tokenEvaluator = [Text.RegularExpressions.MatchEvaluator] {
        param([Text.RegularExpressions.Match]$Match)

        $key = $Match.Groups[1].Value
        if (-not $Tokens.ContainsKey($key)) {
            throw "템플릿 토큰 값이 없습니다: __${key}__ ($Source)"
        }
        return [string]$Tokens[$key]
    }
    $content = [Text.RegularExpressions.Regex]::Replace($content, $tokenPattern, $tokenEvaluator)
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

function Export-WireGuardOutputs {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string]$PublicKeyDestination,
        [Parameter(Mandatory)] [string]$HubPeerDestination,
        [Parameter(Mandatory)] [string]$ExpectedWireGuardIp,
        [Parameter(Mandatory)] [string]$EnvironmentName
    )

    $outputDirectory = Split-Path -Parent $PublicKeyDestination
    if ($outputDirectory -ne (Split-Path -Parent $HubPeerDestination)) {
        throw 'WireGuard output files must share one directory.'
    }
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $outputDirectoryItem = Get-Item -LiteralPath $outputDirectory -Force
    if (($outputDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "WireGuard output directory must not be a reparse point: $outputDirectory"
    }
    Set-SecretAcl -Path $outputDirectory

    $temporaryDirectory = Join-Path $outputDirectory ".$([Guid]::NewGuid().ToString('N')).export"
    try {
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        $temporaryDirectoryItem = Get-Item -LiteralPath $temporaryDirectory -Force
        if (($temporaryDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "WireGuard temporary output directory must not be a reparse point: $temporaryDirectory"
        }
        Set-SecretAcl -Path $temporaryDirectory
        $temporaryPublicKey = Join-Path $temporaryDirectory 'public.key'
        $temporaryHubPeer = Join-Path $temporaryDirectory 'hub_peer.conf'
        $publicKeyBackup = Join-Path $temporaryDirectory 'previous-public.key'
        $hubPeerBackup = Join-Path $temporaryDirectory 'previous-hub_peer.conf'

        Invoke-Compose -ProjectPath $ProjectPath `
            -Arguments @('cp', 'wireguard:/var/lib/wireguard/public.key', $temporaryPublicKey) `
            -FailureMessage 'WireGuard public key를 host로 복사하지 못했습니다.' | Out-Host

        if (-not (Test-Path -LiteralPath $temporaryPublicKey -PathType Leaf)) {
            throw 'WireGuard sidecar public-key copy is incomplete.'
        }
        $publicKeyLines = @([IO.File]::ReadAllLines($temporaryPublicKey) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($publicKeyLines.Count -ne 1) {
            throw 'WireGuard public key output must contain exactly one non-empty line.'
        }
        $publicKey = $publicKeyLines[0].Trim()
        if (-not (Test-WireGuardPublicKey $publicKey)) {
            throw 'WireGuard sidecar generated an invalid public key.'
        }

        $hubPeerContent = @"
# Add this peer to the public WireGuard Hub, then reload the Hub configuration.
[Peer]
# DockerVM environment: $EnvironmentName
PublicKey = $publicKey
AllowedIPs = $ExpectedWireGuardIp/32
"@
        [IO.File]::WriteAllText(
            $temporaryHubPeer,
            "$hubPeerContent`n",
            [Text.UTF8Encoding]::new($false)
        )

        $hubPeerContent = [IO.File]::ReadAllText($temporaryHubPeer)
        $escapedPublicKey = [regex]::Escape($publicKey)
        $escapedAllowedIp = [regex]::Escape("$ExpectedWireGuardIp/32")
        if ($hubPeerContent -match '(?m)^\s*PrivateKey\s*=' -or
            $hubPeerContent -notmatch '(?m)^\[Peer\]\s*$' -or
            $hubPeerContent -notmatch "(?m)^PublicKey\s*=\s*$escapedPublicKey\s*$" -or
            $hubPeerContent -notmatch "(?m)^AllowedIPs\s*=\s*$escapedAllowedIp\s*$") {
            throw 'WireGuard Hub peer output does not match the generated public key/address.'
        }

        if (Test-Path -LiteralPath $PublicKeyDestination -PathType Container) {
            throw "WireGuard public key destination is a directory: $PublicKeyDestination"
        }
        if (Test-Path -LiteralPath $HubPeerDestination -PathType Container) {
            throw "WireGuard Hub peer destination is a directory: $HubPeerDestination"
        }
        if (Test-Path -LiteralPath $PublicKeyDestination -PathType Leaf) {
            [IO.File]::Replace($temporaryPublicKey, $PublicKeyDestination, $publicKeyBackup)
        }
        else {
            [IO.File]::Move($temporaryPublicKey, $PublicKeyDestination)
        }
        if (Test-Path -LiteralPath $HubPeerDestination -PathType Leaf) {
            [IO.File]::Replace($temporaryHubPeer, $HubPeerDestination, $hubPeerBackup)
        }
        else {
            [IO.File]::Move($temporaryHubPeer, $HubPeerDestination)
        }
        Set-SecretAcl -Path $PublicKeyDestination
        Set-SecretAcl -Path $HubPeerDestination

        $exportedPublicKey = ([IO.File]::ReadAllText($PublicKeyDestination)).Trim()
        $exportedHubPeer = [IO.File]::ReadAllText($HubPeerDestination)
        if ($exportedPublicKey -ne $publicKey -or
            $exportedHubPeer -match '(?m)^\s*PrivateKey\s*=' -or
            $exportedHubPeer -notmatch '(?m)^\[Peer\]\s*$' -or
            $exportedHubPeer -notmatch "(?m)^PublicKey\s*=\s*$escapedPublicKey\s*$" -or
            $exportedHubPeer -notmatch "(?m)^AllowedIPs\s*=\s*$escapedAllowedIp\s*$") {
            throw 'WireGuard host output verification failed after the atomic move.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            $expectedParent = [IO.Path]::GetFullPath($outputDirectory).TrimEnd('\')
            $actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $temporaryDirectory)).TrimEnd('\')
            if ($actualParent -ne $expectedParent) {
                throw "Refusing to remove an unexpected WireGuard temporary directory: $temporaryDirectory"
            }
            $temporaryItem = Get-Item -LiteralPath $temporaryDirectory -Force
            if (($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Remove-Item -LiteralPath $temporaryDirectory -Force
            }
            else {
                Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
            }
        }
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

function Assert-DockerComposeVersion {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $versionOutput = @()
    $composeExitCode = -1
    try {
        $versionOutput = @(& docker compose version --short 2>$null)
        $composeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $versionText = if ($versionOutput.Count -gt 0) { ([string]$versionOutput[0]).Trim() } else { '' }
    if ($composeExitCode -ne 0 -or
        $versionText -notmatch '^v?(?<Major>[0-9]+)\.(?<Minor>[0-9]+)\.(?<Patch>[0-9]+)(?:[-+].*)?$') {
        throw "Docker Compose version을 확인할 수 없습니다. Compose 2.33.1 이상이 필요합니다. 감지값: '$versionText'"
    }
    $major = [int]$Matches['Major']
    $minor = [int]$Matches['Minor']
    $patch = [int]$Matches['Patch']
    $supported = $major -gt 2 -or
        ($major -eq 2 -and ($minor -gt 33 -or ($minor -eq 33 -and $patch -ge 1)))
    if (-not $supported) {
        throw "Docker Compose $versionText 은 지원되지 않습니다. gw_priority를 지원하는 Compose 2.33.1 이상으로 업그레이드하십시오."
    }
}

function Assert-DockerEngineVersion {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $versionOutput = @()
    $engineExitCode = -1
    try {
        $versionOutput = @(& docker version --format '{{.Server.Version}}' 2>$null)
        $engineExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $versionText = if ($versionOutput.Count -gt 0) { ([string]$versionOutput[0]).Trim() } else { '' }
    if ($engineExitCode -ne 0 -or
        $versionText -notmatch '^v?(?<Major>[0-9]+)\.(?<Minor>[0-9]+)\.(?<Patch>[0-9]+)(?:[-+].*)?$') {
        throw "Docker Engine server version을 확인할 수 없습니다. Engine 28.0.0 이상이 필요합니다. 감지값: '$versionText'"
    }
    $major = [int]$Matches['Major']
    $minor = [int]$Matches['Minor']
    $patch = [int]$Matches['Patch']
    $supported = $major -gt 28 -or
        ($major -eq 28 -and ($minor -gt 0 -or ($minor -eq 0 -and $patch -ge 0)))
    if (-not $supported) {
        throw "Docker Engine $versionText 은 지원되지 않습니다. gw_priority를 지원하는 Engine 28.0.0 이상으로 업그레이드하십시오."
    }
}

function Write-EnvironmentServiceLogs {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string[]]$ServiceNames
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $ProjectPath
    try {
        & docker compose --env-file .env logs --no-color --tail 100 @ServiceNames
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Wait-EnvironmentHealthy {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string[]]$ServiceNames,
        [int]$TimeoutSeconds = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Push-Location $ProjectPath
        try {
            $containerIds = @{}
            foreach ($serviceName in $serviceNames) {
                $containerId = [string](& docker compose --env-file .env ps -q $serviceName)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to inspect the $serviceName service."
                }
                $containerIds[$serviceName] = $containerId.Trim()
            }

            if (@($containerIds.Values | Where-Object { $_ }).Count -eq $serviceNames.Count) {
                $serviceStates = [ordered]@{}
                foreach ($serviceName in $serviceNames) {
                    $serviceStates[$serviceName] = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerIds[$serviceName]).Trim()
                }
                if (@($serviceStates.Values | Where-Object { $_ -ne 'healthy' }).Count -eq 0) {
                    return
                }
                if (@($serviceStates.Values | Where-Object { $_ -eq 'unhealthy' }).Count -gt 0) {
                    $stateSummary = ($ServiceNames | ForEach-Object { "$_=$($serviceStates[$_])" }) -join ', '
                    Write-EnvironmentServiceLogs -ProjectPath $ProjectPath -ServiceNames $ServiceNames
                    throw "컨테이너가 unhealthy 상태입니다: $stateSummary"
                }
            }
        }
        finally {
            Pop-Location
        }
        Start-Sleep -Seconds 3
    }
    Write-EnvironmentServiceLogs -ProjectPath $ProjectPath -ServiceNames $ServiceNames
    throw "환경이 제한 시간 안에 healthy가 되지 않았습니다: $ProjectPath"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI를 찾을 수 없습니다. Docker Desktop 또는 Docker Engine 28.0.0 이상을 설치하고 실행하십시오.'
}
Assert-DockerEngineVersion
Assert-DockerComposeVersion

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
$oldManifest = Read-EnvironmentManifest -Path (Join-Path $targetPath '.environment.json')
$oldSchemaVersion = [int](Get-ObjectPropertyValue -Object $oldManifest -Name 'schemaVersion' -Default 0)
$oldRemoteAccessProvider = [string](Get-ObjectPropertyValue `
    -Object $oldManifest `
    -Name 'remoteAccessProvider' `
    -Default '')
if ([string]::IsNullOrWhiteSpace($oldRemoteAccessProvider) -and
    $oldEnvironment.ContainsKey('REMOTE_ACCESS_PROVIDER')) {
    $oldRemoteAccessProvider = $oldEnvironment['REMOTE_ACCESS_PROVIDER']
}
if ($targetExists) {
    if ([string]::IsNullOrWhiteSpace($oldRemoteAccessProvider)) {
        # Schema 1-3 environments predate provider selection and are WireGuard environments.
        $oldRemoteAccessProvider = 'wireguard'
    }
    $oldRemoteAccessProvider = $oldRemoteAccessProvider.Trim().ToLowerInvariant()
    if ($oldRemoteAccessProvider -notin @('cloudflare', 'wireguard')) {
        throw "Existing environment has an unsupported remote-access provider: $oldRemoteAccessProvider"
    }
    if ($PSBoundParameters.ContainsKey('RemoteAccessProvider') -and
        $RemoteAccessProvider.Trim().ToLowerInvariant() -ne $oldRemoteAccessProvider) {
        throw "Automatic remote-access migration is disabled. Existing schema $oldSchemaVersion environment must remain $oldRemoteAccessProvider."
    }
    $RemoteAccessProvider = $oldRemoteAccessProvider
}
elseif ([string]::IsNullOrWhiteSpace($RemoteAccessProvider)) {
    $RemoteAccessProvider = 'cloudflare'
}
else {
    $RemoteAccessProvider = $RemoteAccessProvider.Trim().ToLowerInvariant()
}

$WireGuardIp = $null
$WireGuardNetwork = $null
$cloudflareApiToken = $null
$cloudflareAccountId = $null
$cloudflareTeamName = $null
$cloudflarePrivatePool = $null
$cloudflarePrivateIp = $null
$cloudflarePrivateCidr = $null
$cloudflareDockerSubnet = $null
$cloudflareTunnelName = $null
$cloudflareTunnelId = $null
$cloudflareRouteId = $null
$cloudflareProvisioningStatus = $null
$cloudflareTunnelTokenFile = 'secrets/cloudflared_tunnel_token'
$cloudflareKnownRoutes = @()
$cloudflareKnownTunnels = @()

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

$wireGuardAddressOwners = @()
if ($RemoteAccessProvider -eq 'wireguard') {
if ([string]::IsNullOrWhiteSpace($WireGuardHubEndpoint)) {
    if ($oldEnvironment.ContainsKey('WIREGUARD_HUB_ENDPOINT') -and
        -not [string]::IsNullOrWhiteSpace($oldEnvironment['WIREGUARD_HUB_ENDPOINT'])) {
        $WireGuardHubEndpoint = Read-WithDefault -Prompt 'WireGuard Hub endpoint (IPv4-or-hostname:port)' `
            -Default $oldEnvironment['WIREGUARD_HUB_ENDPOINT']
    }
    else {
        $WireGuardHubEndpoint = Read-RequiredValue -Prompt 'WireGuard Hub endpoint (IPv4-or-hostname:port)'
    }
}
$WireGuardHubEndpoint = $WireGuardHubEndpoint.Trim()
if (-not (Test-WireGuardEndpoint $WireGuardHubEndpoint)) {
    throw "WireGuard Hub endpoint는 IPv4-or-hostname:port 형식이어야 합니다: $WireGuardHubEndpoint"
}

if ([string]::IsNullOrWhiteSpace($WireGuardHubPublicKey)) {
    if ($oldEnvironment.ContainsKey('WIREGUARD_HUB_PUBLIC_KEY') -and
        -not [string]::IsNullOrWhiteSpace($oldEnvironment['WIREGUARD_HUB_PUBLIC_KEY'])) {
        $WireGuardHubPublicKey = Read-WithDefault -Prompt 'WireGuard Hub public key' `
            -Default $oldEnvironment['WIREGUARD_HUB_PUBLIC_KEY']
    }
    else {
        $WireGuardHubPublicKey = Read-RequiredValue -Prompt 'WireGuard Hub public key'
    }
}
$WireGuardHubPublicKey = $WireGuardHubPublicKey.Trim()
if (-not (Test-WireGuardPublicKey $WireGuardHubPublicKey)) {
    throw 'WireGuard Hub public key는 Base64로 인코딩된 32바이트 키여야 합니다.'
}

$wireGuardAddressOwners = @(Get-WireGuardAddressOwners `
    -RootPath $rootFullPath `
    -ExcludedEnvironmentName $EnvironmentName)
if ([string]::IsNullOrWhiteSpace($WireGuardAddress)) {
    if ($oldEnvironment.ContainsKey('WIREGUARD_ADDRESS')) {
        $defaultWireGuardAddress = $oldEnvironment['WIREGUARD_ADDRESS']
    }
    else {
        $defaultWireGuardAddress = $null
        $usedWireGuardIps = @($wireGuardAddressOwners | ForEach-Object { $_.Address })
        for ($hostOctet = 10; $hostOctet -le 254; $hostOctet++) {
            $candidateIp = "10.200.0.$hostOctet"
            if ($usedWireGuardIps -notcontains $candidateIp) {
                $defaultWireGuardAddress = "$candidateIp/24"
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($defaultWireGuardAddress)) {
            throw '10.200.0.10/24~10.200.0.254/24 범위에 사용 가능한 WireGuard 주소가 없습니다.'
        }
    }
    $WireGuardAddress = Read-WithDefault -Prompt 'WireGuard IPv4 host CIDR' -Default $defaultWireGuardAddress
}
$WireGuardAddress = $WireGuardAddress.Trim()
if (-not (Test-IPv4HostCidr $WireGuardAddress)) {
    throw "WireGuard address는 prefix /8~/29 범위의 유효한 IPv4 host CIDR이어야 합니다: $WireGuardAddress"
}
$wireGuardCidr = Get-IPv4CidrInfo -Value $WireGuardAddress
$WireGuardAddress = "$($wireGuardCidr.Address)/$($wireGuardCidr.PrefixLength)"
$WireGuardIp = $wireGuardCidr.Address
$WireGuardNetwork = $wireGuardCidr.NetworkCidr
$duplicateWireGuardOwners = @($wireGuardAddressOwners | Where-Object { $_.Address -eq $WireGuardIp })
if ($duplicateWireGuardOwners.Count -gt 0) {
    $duplicateNames = ($duplicateWireGuardOwners | ForEach-Object { $_.EnvironmentName }) -join ', '
    throw "WireGuard IP $WireGuardIp 는 다른 환경에서 이미 사용 중입니다: $duplicateNames"
}
if (Test-IPv4CidrsOverlap -First $WireGuardNetwork -Second $RemoteSubnet) {
    throw "WireGuard network와 LAN 허용 대역이 겹칩니다: $WireGuardNetwork, $RemoteSubnet"
}

if (-not $PSBoundParameters.ContainsKey('WireGuardMtu')) {
    $defaultWireGuardMtu = 1380
    if ($oldEnvironment.ContainsKey('WIREGUARD_MTU')) {
        if (-not [int]::TryParse($oldEnvironment['WIREGUARD_MTU'], [ref]$defaultWireGuardMtu)) {
            throw "기존 WIREGUARD_MTU 값이 올바르지 않습니다: $($oldEnvironment['WIREGUARD_MTU'])"
        }
    }
    $WireGuardMtu = Read-IntegerInRange -Prompt 'WireGuard MTU' -Default $defaultWireGuardMtu -Minimum 1280 -Maximum 1420
}
if ($WireGuardMtu -lt 1280 -or $WireGuardMtu -gt 1420) {
    throw 'WireGuard MTU는 1280 이상 1420 이하여야 합니다.'
}

if (-not $PSBoundParameters.ContainsKey('WireGuardKeepalive')) {
    $defaultWireGuardKeepalive = 25
    if ($oldEnvironment.ContainsKey('WIREGUARD_KEEPALIVE')) {
        if (-not [int]::TryParse($oldEnvironment['WIREGUARD_KEEPALIVE'], [ref]$defaultWireGuardKeepalive)) {
            throw "기존 WIREGUARD_KEEPALIVE 값이 올바르지 않습니다: $($oldEnvironment['WIREGUARD_KEEPALIVE'])"
        }
    }
    $WireGuardKeepalive = Read-IntegerInRange -Prompt 'WireGuard persistent keepalive (seconds)' `
        -Default $defaultWireGuardKeepalive -Minimum 0 -Maximum 65535
}
if ($WireGuardKeepalive -lt 0 -or $WireGuardKeepalive -gt 65535) {
    throw 'WireGuard keepalive는 0 이상 65535 이하여야 합니다.'
}
}
else {
    if ($GenerateOnly) {
        throw 'GenerateOnly cannot provision a runnable Cloudflare tunnel. Use a normal run, or explicitly select WireGuard for generate-only output.'
    }
    $rootConfigurationPath = Join-Path $PSScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $rootConfigurationPath -PathType Leaf)) {
        throw "Cloudflare provisioning configuration is missing: $rootConfigurationPath"
    }
    $rootConfigurationItem = Get-Item -LiteralPath $rootConfigurationPath -Force
    if (($rootConfigurationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Cloudflare provisioning configuration must not be a reparse point: $rootConfigurationPath"
    }
    Set-SecretAcl -Path $rootConfigurationPath
    $rootEnvironment = Read-EnvironmentFile -Path $rootConfigurationPath
    foreach ($requiredKey in @(
            'CLOUDFLARE_API_TOKEN',
            'CLOUDFLARE_ACCOUNT_ID',
            'CLOUDFLARE_TEAM_NAME',
            'CLOUDFLARE_PRIVATE_CIDR'
        )) {
        if (-not $rootEnvironment.ContainsKey($requiredKey) -or
            [string]::IsNullOrWhiteSpace($rootEnvironment[$requiredKey])) {
            throw "Root .env is missing required Cloudflare setting: $requiredKey"
        }
    }

    $cloudflareApiToken = $rootEnvironment['CLOUDFLARE_API_TOKEN'].Trim()
    $cloudflareAccountId = $rootEnvironment['CLOUDFLARE_ACCOUNT_ID'].Trim().ToLowerInvariant()
    $cloudflareTeamName = $rootEnvironment['CLOUDFLARE_TEAM_NAME'].Trim().ToLowerInvariant()
    $cloudflarePrivatePool = $rootEnvironment['CLOUDFLARE_PRIVATE_CIDR'].Trim()
    if ($cloudflareApiToken.IndexOfAny([char[]]"`r`n`0") -ge 0) {
        throw 'CLOUDFLARE_API_TOKEN contains an invalid control character.'
    }
    if ($cloudflareAccountId -notmatch '^[A-Fa-f0-9]{32}$') {
        throw 'CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal account ID.'
    }
    if ($cloudflareTeamName.Length -gt 63 -or
        $cloudflareTeamName -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw 'CLOUDFLARE_TEAM_NAME must be the team slug without .cloudflareaccess.com.'
    }
    $privatePoolInfo = Get-IPv4CidrInfo -Value $cloudflarePrivatePool
    if ($null -eq $privatePoolInfo -or
        $privatePoolInfo.NetworkCidr -ne $cloudflarePrivatePool -or
        $privatePoolInfo.PrefixLength -gt 29 -or
        -not (Test-PrivateIPv4Cidr -Value $cloudflarePrivatePool)) {
        throw 'CLOUDFLARE_PRIVATE_CIDR must be a canonical RFC1918 IPv4 network containing at least one /29.'
    }

    $cloudflareTunnelName = [string](Get-ObjectPropertyValue `
        -Object $oldManifest `
        -Name 'cloudflareTunnelName' `
        -Default "dockervm-$EnvironmentName")
    $cloudflareTunnelId = [string](Get-ObjectPropertyValue `
        -Object $oldManifest `
        -Name 'cloudflareTunnelId' `
        -Default '')
    $cloudflareRouteId = [string](Get-ObjectPropertyValue `
        -Object $oldManifest `
        -Name 'cloudflareRouteId' `
        -Default '')
    if ($cloudflareTunnelName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$') {
        throw "Cloudflare tunnel name is invalid: $cloudflareTunnelName"
    }
    if ($targetExists -and
        ([string]::IsNullOrWhiteSpace($cloudflareTunnelId) -or
         [string]::IsNullOrWhiteSpace($cloudflareRouteId))) {
        throw 'Existing Cloudflare environment is missing its tunnel or route ID; automatic resource adoption is disabled.'
    }
    if ($targetExists -and
        (-not (Test-CloudflareResourceId -Value $cloudflareTunnelId) -or
         -not (Test-CloudflareResourceId -Value $cloudflareRouteId))) {
        throw 'Existing Cloudflare environment contains an invalid tunnel or route UUID.'
    }

    # These account-scoped reads validate the Developer Platform API token without
    # relying on /user/tokens/verify, which rejects account-owned tokens.
    $cloudflareKnownTunnels = @(Get-CloudflarePagedResults `
        -ResourcePath "/accounts/$cloudflareAccountId/cfd_tunnel?is_deleted=false" `
        -ApiToken $cloudflareApiToken)
    $cloudflareKnownRoutes = @(Get-CloudflarePagedResults `
        -ResourcePath "/accounts/$cloudflareAccountId/teamnet/routes" `
        -ApiToken $cloudflareApiToken)

    if ($targetExists) {
        $ownedTunnel = @($cloudflareKnownTunnels | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name 'id' -Default '') -eq $cloudflareTunnelId
        })
        if ($ownedTunnel.Count -ne 1 -or
            [string](Get-ObjectPropertyValue -Object $ownedTunnel[0] -Name 'name' -Default '') -cne $cloudflareTunnelName) {
            throw "Existing Cloudflare tunnel ownership could not be verified: $cloudflareTunnelId"
        }
        $ownedRoute = @($cloudflareKnownRoutes | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name 'id' -Default '') -eq $cloudflareRouteId
        })
        if ($ownedRoute.Count -ne 1 -or
            [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'tunnel_id' -Default '') -ne $cloudflareTunnelId) {
            throw "Existing Cloudflare route ownership could not be verified: $cloudflareRouteId"
        }
    }
    # New-environment name collisions are rechecked under the global lock after
    # interrupted-transaction recovery has had a chance to remove stale resources.

    $preferredSubnet = [string](Get-ObjectPropertyValue `
        -Object $oldManifest `
        -Name 'cloudflareDockerSubnet' `
        -Default '')
    $preferredPrivateIp = [string](Get-ObjectPropertyValue `
        -Object $oldManifest `
        -Name 'cloudflarePrivateIp' `
        -Default '')
    if ([string]::IsNullOrWhiteSpace($preferredSubnet) -and
        $oldEnvironment.ContainsKey('CLOUDFLARE_PRIVATE_SUBNET')) {
        $preferredSubnet = $oldEnvironment['CLOUDFLARE_PRIVATE_SUBNET']
    }
    if ([string]::IsNullOrWhiteSpace($preferredPrivateIp) -and
        $oldEnvironment.ContainsKey('CLOUDFLARE_PRIVATE_IP')) {
        $preferredPrivateIp = $oldEnvironment['CLOUDFLARE_PRIVATE_IP']
    }

    $cloudflareAddressOwners = @(Get-CloudflareAddressOwners `
        -RootPath $rootFullPath `
        -ExcludedEnvironmentName $EnvironmentName)
    $reservedCloudflareCidrs = @($cloudflareAddressOwners | ForEach-Object { $_.Subnet })
    $reservedCloudflareCidrs += @(Get-DockerNetworkCidrs -ExcludedNames @(
        "${EnvironmentName}_remote_access",
        "${EnvironmentName}_cloudflare_egress"
    ))
    $reservedCloudflareCidrs += @(Get-HostRouteCidrs)
    $reservedCloudflareCidrs += $RemoteSubnet
    foreach ($route in $cloudflareKnownRoutes) {
        $routeId = [string](Get-ObjectPropertyValue -Object $route -Name 'id' -Default '')
        if ($targetExists -and $routeId -eq $cloudflareRouteId) {
            continue
        }
        $routeNetwork = [string](Get-ObjectPropertyValue -Object $route -Name 'network' -Default '')
        if ($null -ne (Get-IPv4CidrInfo -Value $routeNetwork)) {
            $reservedCloudflareCidrs += $routeNetwork
        }
    }
    $cloudflareAllocation = Get-CloudflarePrivateAllocation `
        -PoolCidr $cloudflarePrivatePool `
        -ReservedCidrs @($reservedCloudflareCidrs | Sort-Object -Unique) `
        -PreferredSubnet $preferredSubnet `
        -PreferredPrivateIp $preferredPrivateIp
    $cloudflarePrivateIp = $cloudflareAllocation.PrivateIp
    $cloudflarePrivateCidr = $cloudflareAllocation.PrivateCidr
    $cloudflareDockerSubnet = $cloudflareAllocation.DockerSubnet
    if ($targetExists) {
        $ownedRouteNetwork = [string](Get-ObjectPropertyValue -Object $ownedRoute[0] -Name 'network' -Default '')
        if ($ownedRouteNetwork -ne $cloudflarePrivateCidr) {
            throw "Existing Cloudflare route does not match the environment address: $ownedRouteNetwork"
        }
    }
    $cloudflareProvisioningStatus = if ($targetExists) { 'verified' } else { 'pending' }
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
$sshPrivateKeyFileName = "${EnvironmentName}_ssh.pem"
$sshPublicKeyFileName = "${sshPrivateKeyFileName}.pub"
$targetSshPrivateKeyPath = Join-Path $targetPath $sshPrivateKeyFileName
$targetSshPublicKeyPath = Join-Path $targetPath $sshPublicKeyFileName
$wireGuardPublicKeyFileName = "${EnvironmentName}_wireguard_public.key"
$wireGuardHubPeerFileName = "${EnvironmentName}_hub_peer.conf"
$targetWireGuardDirectory = Join-Path $targetPath 'wireguard'
$targetWireGuardPublicKeyPath = Join-Path $targetWireGuardDirectory $wireGuardPublicKeyFileName
$targetWireGuardHubPeerPath = Join-Path $targetWireGuardDirectory $wireGuardHubPeerFileName
$backupRoot = Join-Path $rootFullPath '.backup'
$stagingRoot = Join-Path $rootFullPath '.staging'
$stagingPath = Join-Path $stagingRoot "$EnvironmentName.$([Guid]::NewGuid().ToString('N'))"
$storageExistedBefore = Test-Path -LiteralPath $storagePath

$mutex = $null
$mutexAcquired = $false
try {
    # A Global mutex serializes generators across Windows logon/RDP sessions.
    # Failing closed on an inaccessible object is safer than using a separate
    # session-local lock and racing environment names or WireGuard addresses.
    $mutex = [Threading.Mutex]::new($false, 'Global\DockerVMsUbuntuDindEnvironmentGenerator')
    try {
        $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    }
    catch [Threading.AbandonedMutexException] {
        # WaitOne grants ownership when reporting an abandoned mutex.
        $mutexAcquired = $true
    }
    if (-not $mutexAcquired) {
        throw [TimeoutException]::new('다른 환경 생성 작업이 실행 중입니다.')
    }
}
catch [UnauthorizedAccessException] {
    if ($null -ne $mutex) { $mutex.Dispose() }
    $mutex = $null
    throw '서버 전체 환경 생성 잠금에 접근할 수 없습니다. 동일한 관리자 계정 또는 관리자 권한으로 다시 실행하십시오.'
}
catch {
    if ($null -ne $mutex -and -not $mutexAcquired) { $mutex.Dispose() }
    $mutex = $null
    throw
}

$backupPath = $null
$failedPath = $null
$oldStopped = $false
$swapped = $false
$newStarted = $false
$migrationPath = $null
$completed = $false
$createdCloudflareTunnelId = $null
$createdCloudflareRouteId = $null
$cloudflareTransactionJournalPath = $null
$cloudflareRollbackSucceeded = $true

try {
    if ($RemoteAccessProvider -eq 'wireguard') {
    $wireGuardOwnersAfterLock = @(Get-WireGuardAddressOwners `
        -RootPath $rootFullPath `
        -ExcludedEnvironmentName $EnvironmentName)
    $duplicateAfterLock = @($wireGuardOwnersAfterLock | Where-Object { $_.Address -eq $WireGuardIp })
    if ($duplicateAfterLock.Count -gt 0) {
        $duplicateNames = ($duplicateAfterLock | ForEach-Object { $_.EnvironmentName }) -join ', '
        throw "WireGuard IP $WireGuardIp 가 대기 중 다른 환경에 할당되었습니다: $duplicateNames"
    }
    }
    else {
        Invoke-CloudflareTransactionRecovery `
            -StagingRoot $stagingRoot `
            -AccountId $cloudflareAccountId `
            -ApiToken $cloudflareApiToken
        if (-not $targetExists) {
            $tunnelsAfterRecovery = @(Get-CloudflarePagedResults `
                -ResourcePath "/accounts/$cloudflareAccountId/cfd_tunnel?is_deleted=false" `
                -ApiToken $cloudflareApiToken)
            $nameCollisionsAfterRecovery = @($tunnelsAfterRecovery | Where-Object {
                [string](Get-ObjectPropertyValue -Object $_ -Name 'name' -Default '') -ceq $cloudflareTunnelName
            })
            if ($nameCollisionsAfterRecovery.Count -gt 0) {
                throw "A Cloudflare tunnel named '$cloudflareTunnelName' already exists but is not owned by this environment."
            }
        }
        $cloudflareOwnersAfterLock = @(Get-CloudflareAddressOwners `
            -RootPath $rootFullPath `
            -ExcludedEnvironmentName $EnvironmentName)
        $duplicateCloudflareSubnet = @($cloudflareOwnersAfterLock | Where-Object {
            $_.Subnet -eq $cloudflareDockerSubnet
        })
        if ($duplicateCloudflareSubnet.Count -gt 0) {
            $duplicateNames = ($duplicateCloudflareSubnet | ForEach-Object { $_.EnvironmentName }) -join ', '
            throw "Cloudflare subnet $cloudflareDockerSubnet was assigned while this generator waited: $duplicateNames"
        }

        $routesAfterLock = @(Get-CloudflarePagedResults `
            -ResourcePath "/accounts/$cloudflareAccountId/teamnet/routes" `
            -ApiToken $cloudflareApiToken)
        foreach ($route in $routesAfterLock) {
            $routeId = [string](Get-ObjectPropertyValue -Object $route -Name 'id' -Default '')
            if ($targetExists -and $routeId -eq $cloudflareRouteId) {
                continue
            }
            $routeNetwork = [string](Get-ObjectPropertyValue -Object $route -Name 'network' -Default '')
            if ($null -ne (Get-IPv4CidrInfo -Value $routeNetwork) -and
                (Test-IPv4CidrsOverlap -First $cloudflareDockerSubnet -Second $routeNetwork)) {
                throw "Cloudflare route $routeNetwork overlaps the allocated Docker subnet $cloudflareDockerSubnet."
            }
        }
    }

    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    # Protect the project root itself so another local account with inherited
    # parent-directory rights cannot replace the PEM key or secret files.
    Set-SecretAcl -Path $stagingPath
    New-Item -ItemType Directory -Path $storagePath -Force | Out-Null
    Set-SecretAcl -Path $storagePath
    New-Item -ItemType Directory -Path $homeStoragePath -Force | Out-Null
    New-Item -ItemType Directory -Path $workspaceStoragePath -Force | Out-Null
    Set-SecretAcl -Path $homeStoragePath
    Set-SecretAcl -Path $workspaceStoragePath
    Copy-Item -Path (Join-Path $templatePath '*') -Destination $stagingPath -Recurse -Force

    $wireGuardDirectory = Join-Path $stagingPath 'wireguard'
    $secretDirectory = Join-Path $stagingPath 'secrets'
    New-Item -ItemType Directory -Path $wireGuardDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    Set-SecretAcl -Path $wireGuardDirectory
    Set-SecretAcl -Path $secretDirectory

    $stagingSshPrivateKeyPath = Join-Path $stagingPath $sshPrivateKeyFileName
    $stagingSshPublicKeyPath = Join-Path $stagingPath $sshPublicKeyFileName
    $existingPrivateKey = Test-Path -LiteralPath $targetSshPrivateKeyPath -PathType Leaf
    $existingPublicKey = Test-Path -LiteralPath $targetSshPublicKeyPath -PathType Leaf
    $reusedExistingPrivateKey = $false
    if ($targetExists -and -not $RotateSshKey -and $existingPrivateKey) {
        Copy-Item -LiteralPath $targetSshPrivateKeyPath -Destination $stagingSshPrivateKeyPath
        $reusedExistingPrivateKey = $true
    }
    elseif ($targetExists -and -not $RotateSshKey -and $existingPublicKey) {
        throw "기존 SSH public key만 있고 private key가 없습니다. private key를 복구하거나 -RotateSshKey로 교체하십시오: $targetPath"
    }
    else {
        New-SshPemKeyPair -PrivateKeyPath $stagingSshPrivateKeyPath -Comment "$AccountName@$EnvironmentName"
    }
    Set-SecretAcl -Path $stagingSshPrivateKeyPath
    Write-SshCanonicalPublicKey `
        -PrivateKeyPath $stagingSshPrivateKeyPath `
        -PublicKeyPath $stagingSshPublicKeyPath `
        -Comment "$AccountName@$EnvironmentName"
    Set-SecretAcl -Path $stagingSshPublicKeyPath
    try {
        $sshKeyMetadata = Get-SshKeyPairMetadata `
            -PrivateKeyPath $stagingSshPrivateKeyPath `
            -PublicKeyPath $stagingSshPublicKeyPath
    }
    catch {
        if ($reusedExistingPrivateKey) {
            throw "기존 SSH 키 검증에 실패했습니다. 키를 복구하거나 -RotateSshKey로 교체하십시오. $($_.Exception.Message)"
        }
        throw
    }
    $sshAuthorizedKeysPath = Join-Path $secretDirectory 'ssh_authorized_keys'
    [IO.File]::WriteAllText(
        $sshAuthorizedKeysPath,
        [IO.File]::ReadAllText($stagingSshPublicKeyPath),
        [Text.UTF8Encoding]::new($false)
    )
    Set-SecretAcl -Path $sshAuthorizedKeysPath

    if ($RemoteAccessProvider -eq 'cloudflare') {
        $cloudflaredTunnelTokenPath = Join-Path $secretDirectory 'cloudflared_tunnel_token'
        if (-not $targetExists) {
            $cloudflareTransactionJournalPath = Join-Path $stagingPath '.cloudflare-provisioning-transaction.json'
            Write-CloudflareTransactionJournal `
                -Path $cloudflareTransactionJournalPath `
                -EnvironmentName $EnvironmentName `
                -AccountId $cloudflareAccountId `
                -TunnelName $cloudflareTunnelName `
                -Network $cloudflarePrivateCidr `
                -MutationState 'tunnel-create-started'
            $cloudflareTunnelId = New-CloudflareTunnelResource `
                -AccountId $cloudflareAccountId `
                -ApiToken $cloudflareApiToken `
                -Name $cloudflareTunnelName
            $createdCloudflareTunnelId = $cloudflareTunnelId
            Write-CloudflareTransactionJournal `
                -Path $cloudflareTransactionJournalPath `
                -EnvironmentName $EnvironmentName `
                -AccountId $cloudflareAccountId `
                -TunnelName $cloudflareTunnelName `
                -Network $cloudflarePrivateCidr `
                -TunnelId $createdCloudflareTunnelId `
                -MutationState 'tunnel-created'
        }

            $tokenResponse = Invoke-CloudflareApi -Method GET `
                -Path "/accounts/$cloudflareAccountId/cfd_tunnel/$cloudflareTunnelId/token" `
                -ApiToken $cloudflareApiToken
            $cloudflaredRuntimeToken = [string](Get-ObjectPropertyValue `
                -Object $tokenResponse `
                -Name 'result' `
                -Default '')
            if ([string]::IsNullOrWhiteSpace($cloudflaredRuntimeToken) -or
                $cloudflaredRuntimeToken.IndexOfAny([char[]]"`r`n`0") -ge 0) {
                throw 'Cloudflare returned an invalid tunnel runtime token.'
            }

        if (-not $targetExists) {
                Write-CloudflareTransactionJournal `
                    -Path $cloudflareTransactionJournalPath `
                    -EnvironmentName $EnvironmentName `
                    -AccountId $cloudflareAccountId `
                    -TunnelName $cloudflareTunnelName `
                    -Network $cloudflarePrivateCidr `
                    -TunnelId $createdCloudflareTunnelId `
                    -MutationState 'route-create-started'
                $cloudflareRouteId = New-CloudflareRouteResource `
                    -AccountId $cloudflareAccountId `
                    -ApiToken $cloudflareApiToken `
                    -TunnelId $cloudflareTunnelId `
                    -Network $cloudflarePrivateCidr `
                    -Comment "DockerVM environment: $EnvironmentName"
                $createdCloudflareRouteId = $cloudflareRouteId
                Write-CloudflareTransactionJournal `
                    -Path $cloudflareTransactionJournalPath `
                    -EnvironmentName $EnvironmentName `
                    -AccountId $cloudflareAccountId `
                    -TunnelName $cloudflareTunnelName `
                    -Network $cloudflarePrivateCidr `
                    -TunnelId $createdCloudflareTunnelId `
                    -RouteId $createdCloudflareRouteId `
                    -MutationState 'route-created'
        }

        try {
            [IO.File]::WriteAllText(
                $cloudflaredTunnelTokenPath,
                $cloudflaredRuntimeToken,
                [Text.UTF8Encoding]::new($false)
            )
        }
        finally {
            $cloudflaredRuntimeToken = $null
        }
        $cloudflareProvisioningStatus = 'ready'
        Set-SecretAcl -Path $cloudflaredTunnelTokenPath
    }

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
        "REMOTE_ACCESS_PROVIDER=$RemoteAccessProvider"
    )
    if ($RemoteAccessProvider -eq 'wireguard') {
        $environmentLines += @(
            "WIREGUARD_ADDRESS=$WireGuardAddress",
            "WIREGUARD_NETWORK=$WireGuardNetwork",
            "WIREGUARD_HUB_ENDPOINT=$WireGuardHubEndpoint",
            "WIREGUARD_HUB_PUBLIC_KEY=$WireGuardHubPublicKey",
            "WIREGUARD_MTU=$WireGuardMtu",
            "WIREGUARD_KEEPALIVE=$WireGuardKeepalive"
        )
    }
    else {
        $environmentLines += @(
            "CLOUDFLARE_PRIVATE_IP=$cloudflarePrivateIp",
            "CLOUDFLARE_PRIVATE_CIDR=$cloudflarePrivateCidr",
            "CLOUDFLARE_PRIVATE_SUBNET=$cloudflareDockerSubnet"
        )
    }
    $environmentLines += @(
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

    $secretPath = Join-Path $secretDirectory 'login_password.txt'
    $passwordText = ConvertFrom-SecureValue $Password
    try {
        [IO.File]::WriteAllText($secretPath, $passwordText, [Text.UTF8Encoding]::new($false))
    }
    finally {
        $passwordText = $null
    }
    Set-SecretAcl -Path $secretPath

    $remoteServiceTemplateName = if ($RemoteAccessProvider -eq 'cloudflare') {
        'compose.cloudflare.services.template'
    }
    else {
        'compose.wireguard.services.template'
    }
    $remoteServiceTemplatePath = Join-Path $stagingPath $remoteServiceTemplateName
    if (-not (Test-Path -LiteralPath $remoteServiceTemplatePath -PathType Leaf)) {
        throw "Remote-access service template is missing: $remoteServiceTemplateName"
    }
    $remoteAccessServices = [IO.File]::ReadAllText($remoteServiceTemplatePath).TrimEnd([char[]]"`r`n")

    if ($RemoteAccessProvider -eq 'cloudflare') {
        $remoteAccessIp = $cloudflarePrivateIp
        $desktopRemoteNetworks = @'
      remote_access:
        ipv4_address: ${CLOUDFLARE_PRIVATE_IP}
'@.TrimEnd([char[]]"`r`n")
        $remoteAccessSecrets = @'
  cloudflared_token:
    file: ./secrets/cloudflared_tunnel_token
'@.TrimEnd([char[]]"`r`n")
        $remoteAccessVolumes = ''
        $remoteAccessNetworks = @'
  remote_access:
    name: ${ENVIRONMENT_NAME}_remote_access
    internal: true
    ipam:
      config:
        - subnet: ${CLOUDFLARE_PRIVATE_SUBNET}
  cloudflare_egress:
    name: ${ENVIRONMENT_NAME}_cloudflare_egress
'@.TrimEnd([char[]]"`r`n")
        $remoteAccessSummary = 'Cloudflare Zero Trust remote access'
        $remoteConnectionRows = @(
            '| Remote SSH | `{0}:22` | `ssh -o IdentitiesOnly=yes -i "{1}" {2}@{0}` |' -f $remoteAccessIp, $targetSshPrivateKeyPath, $AccountName
            '| Remote RDP | `{0}:3389` | `{1}` |' -f $remoteAccessIp, "${EnvironmentName}_remote.rdp"
        ) -join "`n"
        $tunnelIdDisplay = if ([string]::IsNullOrWhiteSpace($cloudflareTunnelId)) { 'pending (GenerateOnly)' } else { $cloudflareTunnelId }
        $routeIdDisplay = if ([string]::IsNullOrWhiteSpace($cloudflareRouteId)) { 'pending (GenerateOnly)' } else { $cloudflareRouteId }
        $remoteAccessInstructions = @'
## Connect through Cloudflare Zero Trust

1. Install Cloudflare One Client on the remote computer, enroll it in team **{{TEAM_NAME}}**, and enable WARP mode.
2. Ensure the Zero Trust Split Tunnel and Gateway policies route and allow **{{PRIVATE_CIDR}}** on TCP ports 22 and 3389 for the intended user/device.
3. Use the Remote SSH command or Remote RDP file above while WARP is connected.

- Private desktop route: `{{PRIVATE_CIDR}}`
- Tunnel ID: `{{TUNNEL_ID}}`
- Route ID: `{{ROUTE_ID}}`

Check the connector with:

```text
docker compose ps cloudflared
docker compose logs --no-color --tail 100 cloudflared
```

The account API token is never copied into this environment. The tunnel-specific runtime token in `secrets/cloudflared_tunnel_token` is sensitive and must not be committed or shared.
'@
        $remoteAccessInstructions = $remoteAccessInstructions.Replace('{{TEAM_NAME}}', $cloudflareTeamName).
            Replace('{{PRIVATE_CIDR}}', $cloudflarePrivateCidr).
            Replace('{{TUNNEL_ID}}', $tunnelIdDisplay).
            Replace('{{ROUTE_ID}}', $routeIdDisplay).TrimEnd([char[]]"`r`n")
        $remoteDataWarning = 'Do not run `docker compose down -v`; it deletes DinD data and SSH host keys. Keep the Cloudflare tunnel token private.'
    }
    else {
        $remoteAccessIp = $WireGuardIp
        $desktopRemoteNetworks = '      remote_access: {}'
        $remoteAccessSecrets = ''
        $remoteAccessVolumes = @'
  wireguard_state:
    name: ${ENVIRONMENT_NAME}_wireguard_state
'@.TrimEnd([char[]]"`r`n")
        $remoteAccessNetworks = @'
  remote_access:
    name: ${ENVIRONMENT_NAME}_remote_access
    internal: true
  wireguard_transport:
    name: ${ENVIRONMENT_NAME}_wireguard_transport
'@.TrimEnd([char[]]"`r`n")
        $remoteAccessSummary = 'WireGuard remote access'
        $remoteConnectionRows = @(
            '| Remote SSH | `{0}:22` | `ssh -o IdentitiesOnly=yes -i "{1}" {2}@{0}` |' -f $remoteAccessIp, $targetSshPrivateKeyPath, $AccountName
            '| Remote RDP | `{0}:3389` | `{1}` |' -f $remoteAccessIp, "${EnvironmentName}_remote.rdp"
        ) -join "`n"
        $remoteAccessInstructions = @'
## Register with the WireGuard Hub

- Environment address: `{{WIREGUARD_ADDRESS}}`
- VPN network: `{{WIREGUARD_NETWORK}}`
- Hub endpoint: `{{WIREGUARD_HUB_ENDPOINT}}`

After the first `docker compose up -d`, add `{{HUB_PEER_FILE}}` to the Hub and reload it. The Hub must forward authorized peers to `{{WIREGUARD_IP}}/32` on TCP ports 22 and 3389.

If the public files are missing, export them again:

```bash
docker compose cp wireguard:/var/lib/wireguard/public.key {{PUBLIC_KEY_FILE}}
docker compose cp wireguard:/var/lib/wireguard/hub_peer.conf {{HUB_PEER_FILE}}
```

Verify a nonzero handshake timestamp with `docker compose exec -T wireguard wg show wg0 latest-handshakes`, then test remote SSH and RDP.
'@
        $remoteAccessInstructions = $remoteAccessInstructions.Replace('{{WIREGUARD_ADDRESS}}', $WireGuardAddress).
            Replace('{{WIREGUARD_NETWORK}}', $WireGuardNetwork).
            Replace('{{WIREGUARD_HUB_ENDPOINT}}', $WireGuardHubEndpoint).
            Replace('{{WIREGUARD_IP}}', $WireGuardIp).
            Replace('{{PUBLIC_KEY_FILE}}', "wireguard/${EnvironmentName}_wireguard_public.key").
            Replace('{{HUB_PEER_FILE}}', "wireguard/${EnvironmentName}_hub_peer.conf").TrimEnd([char[]]"`r`n")
        $remoteDataWarning = 'Do not run `docker compose down -v`; it deletes DinD data, SSH host keys, and the WireGuard identity.'
    }

    $tokens = @{
        ENVIRONMENT_NAME = $EnvironmentName
        ACCOUNT_NAME = $AccountName
        HOST_ADDRESS = $HostAddress
        SSH_PORT = $SshPort
        RDP_PORT = $RdpPort
        REMOTE_SUBNET = $RemoteSubnet
        WIREGUARD_ADDRESS = $WireGuardAddress
        WIREGUARD_IP = $WireGuardIp
        WIREGUARD_NETWORK = $WireGuardNetwork
        WIREGUARD_HUB_ENDPOINT = $WireGuardHubEndpoint
        CLOUDFLARE_PRIVATE_IP = $cloudflarePrivateIp
        CLOUDFLARE_PRIVATE_CIDR = $cloudflarePrivateCidr
        CLOUDFLARE_PRIVATE_SUBNET = $cloudflareDockerSubnet
        DESKTOP_REMOTE_NETWORKS = $desktopRemoteNetworks
        REMOTE_ACCESS_SERVICES = $remoteAccessServices
        REMOTE_ACCESS_SECRETS = $remoteAccessSecrets
        REMOTE_ACCESS_VOLUMES = $remoteAccessVolumes
        REMOTE_ACCESS_NETWORKS = $remoteAccessNetworks
        REMOTE_ACCESS_SUMMARY = $remoteAccessSummary
        REMOTE_CONNECTION_ROWS = $remoteConnectionRows
        REMOTE_ACCESS_INSTRUCTIONS = $remoteAccessInstructions
        REMOTE_DATA_WARNING = $remoteDataWarning
        SSH_PRIVATE_KEY = $targetSshPrivateKeyPath
        SSH_PUBLIC_KEY = $targetSshPublicKeyPath
        SSH_FINGERPRINT = $sshKeyMetadata.Fingerprint
        LOCAL_RDP_FILE = "${EnvironmentName}_local.rdp"
        REMOTE_RDP_FILE = "${EnvironmentName}_remote.rdp"
        WIREGUARD_PUBLIC_KEY_FILE = "wireguard/${EnvironmentName}_wireguard_public.key"
        WIREGUARD_HUB_PEER_FILE = "wireguard/${EnvironmentName}_hub_peer.conf"
        WIREGUARD_STATE_VOLUME = "${EnvironmentName}_wireguard_state"
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
    $localRdpTokens = $tokens.Clone()
    $localRdpTokens['RDP_FULL_ADDRESS'] = "${HostAddress}:$RdpPort"
    $localRdpTemplate = @{
        Source = Join-Path $stagingPath 'environment_VM.rdp.template'
        Destination = Join-Path $stagingPath $tokens['LOCAL_RDP_FILE']
        Tokens = $localRdpTokens
    }
    Expand-TemplateFile @localRdpTemplate
    $remoteRdpTokens = $tokens.Clone()
    $remoteRdpTokens['RDP_FULL_ADDRESS'] = "${remoteAccessIp}:3389"
    $remoteRdpTemplate = @{
        Source = Join-Path $stagingPath 'environment_VM.rdp.template'
        Destination = Join-Path $stagingPath $tokens['REMOTE_RDP_FILE']
        Tokens = $remoteRdpTokens
    }
    Expand-TemplateFile @remoteRdpTemplate
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
    Remove-Item -LiteralPath (Join-Path $stagingPath 'compose.cloudflare.services.template')
    Remove-Item -LiteralPath (Join-Path $stagingPath 'compose.wireguard.services.template')

    $manifest = [ordered]@{
        schemaVersion = 4
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
        sshAuthentication = 'publickey-only'
        sshPrivateKeyPath = $targetSshPrivateKeyPath
        sshPublicKeyPath = $targetSshPublicKeyPath
        sshFingerprint = $sshKeyMetadata.Fingerprint
        localRdpFile = $tokens['LOCAL_RDP_FILE']
        remoteRdpFile = $tokens['REMOTE_RDP_FILE']
        remoteAccessProvider = $RemoteAccessProvider
        cloudflareAccountId = $cloudflareAccountId
        cloudflareTeamName = $cloudflareTeamName
        cloudflareTunnelName = $cloudflareTunnelName
        cloudflareTunnelId = $cloudflareTunnelId
        cloudflareRouteId = $cloudflareRouteId
        cloudflarePrivateIp = $cloudflarePrivateIp
        cloudflarePrivateCidr = $cloudflarePrivateCidr
        cloudflareDockerSubnet = $cloudflareDockerSubnet
        cloudflareTunnelTokenFile = if ($RemoteAccessProvider -eq 'cloudflare') { $cloudflareTunnelTokenFile } else { $null }
        cloudflareProvisioningStatus = $cloudflareProvisioningStatus
        wireGuardRequired = $RemoteAccessProvider -eq 'wireguard'
        wireGuardAddress = $WireGuardAddress
        wireGuardIp = $WireGuardIp
        wireGuardNetwork = $WireGuardNetwork
        wireGuardHubEndpoint = $WireGuardHubEndpoint
        wireGuardHubPublicKey = $WireGuardHubPublicKey
        wireGuardMtu = $WireGuardMtu
        wireGuardKeepalive = $WireGuardKeepalive
        wireGuardPublicKey = $null
        wireGuardPublicKeyPending = $RemoteAccessProvider -eq 'wireguard'
        wireGuardPublicKeyPath = if ($RemoteAccessProvider -eq 'wireguard') { $targetWireGuardPublicKeyPath } else { $null }
        wireGuardHubPeerPath = if ($RemoteAccessProvider -eq 'wireguard') { $targetWireGuardHubPeerPath } else { $null }
        wireGuardStateVolume = if ($RemoteAccessProvider -eq 'wireguard') { $tokens['WIREGUARD_STATE_VOLUME'] } else { $null }
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
        Write-Host "SSH private key: $targetSshPrivateKeyPath"
        Write-Host "WireGuard public key와 Hub peer 설정은 첫 'docker compose up -d' 후 다음 명령으로 내보내십시오:"
        Write-Host "  docker compose --env-file .env cp wireguard:/var/lib/wireguard/public.key `"wireguard/$wireGuardPublicKeyFileName`""
        Write-Host "  docker compose --env-file .env cp wireguard:/var/lib/wireguard/hub_peer.conf `"wireguard/$wireGuardHubPeerFileName`""
        return
    }

    if ($UseBuildKit) {
        $buildServices = @('build', 'desktop', 'docker')
        if ($RemoteAccessProvider -eq 'wireguard') { $buildServices += 'wireguard' }
        Invoke-Compose -ProjectPath $stagingPath -Arguments $buildServices -FailureMessage 'Ubuntu 데스크톱/DinD 원격접속 이미지 빌드에 실패했습니다.'
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
            if ($RemoteAccessProvider -eq 'wireguard') {
                Invoke-Docker -Arguments @(
                    'build', '--pull=false',
                    '--tag', "${EnvironmentName}-wireguard:${imageTag}",
                    '--file', (Join-Path $stagingPath 'Dockerfile.wireguard'),
                    $stagingPath
                ) -FailureMessage 'WireGuard sidecar 이미지 빌드에 실패했습니다.'
            }
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
    $healthServices = if ($RemoteAccessProvider -eq 'cloudflare') {
        @('desktop', 'docker', 'cloudflared')
    }
    else {
        @('desktop', 'docker', 'wireguard', 'remote_proxy')
    }
    Wait-EnvironmentHealthy -ProjectPath $targetPath -ServiceNames $healthServices

    if ($RemoteAccessProvider -eq 'wireguard') {
    Export-WireGuardOutputs `
        -ProjectPath $targetPath `
        -PublicKeyDestination $targetWireGuardPublicKeyPath `
        -HubPeerDestination $targetWireGuardHubPeerPath `
        -ExpectedWireGuardIp $WireGuardIp `
        -EnvironmentName $EnvironmentName
    if (-not (Test-Path -LiteralPath $targetWireGuardPublicKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $targetWireGuardHubPeerPath -PathType Leaf)) {
        throw "WireGuard public output이 생성되지 않았습니다: $targetWireGuardDirectory"
    }
    $wireGuardPublicKey = ([IO.File]::ReadAllText($targetWireGuardPublicKeyPath)).Trim()
    if (-not (Test-WireGuardPublicKey $wireGuardPublicKey)) {
        throw "WireGuard sidecar가 잘못된 public key를 생성했습니다: $targetWireGuardPublicKeyPath"
    }
    $manifest['wireGuardPublicKey'] = $wireGuardPublicKey
    $manifest['wireGuardPublicKeyPending'] = $false
    }
    [IO.File]::WriteAllText(
        (Join-Path $targetPath '.environment.json'),
        ($manifest | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )

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

    if (-not [string]::IsNullOrWhiteSpace($createdCloudflareTunnelId)) {
        $committedJournalPath = Join-Path $targetPath '.cloudflare-provisioning-transaction.json'
        if (Test-Path -LiteralPath $committedJournalPath -PathType Leaf) {
            Remove-Item -LiteralPath $committedJournalPath -Force
        }
    }

    Write-Host ''
    Write-Host "환경 생성 완료: $EnvironmentName"
    Write-Host "설정: $targetPath"
    Write-Host "영구 홈: $homeStoragePath"
    Write-Host "영구 작업공간: $workspaceStoragePath"
    Write-Host "Local SSH: ssh -o IdentitiesOnly=yes -i `"$targetSshPrivateKeyPath`" -p $SshPort $AccountName@$HostAddress"
    Write-Host "Remote SSH: ssh -o IdentitiesOnly=yes -i `"$targetSshPrivateKeyPath`" -p 22 $AccountName@$remoteAccessIp"
    Write-Host "Local RDP: $(Join-Path $targetPath $tokens['LOCAL_RDP_FILE'])"
    Write-Host "Remote RDP: $(Join-Path $targetPath $tokens['REMOTE_RDP_FILE'])"
    if ($RemoteAccessProvider -eq 'cloudflare') {
        Write-Host "Cloudflare Zero Trust team: $cloudflareTeamName"
        Write-Host "Cloudflare private route: $cloudflarePrivateCidr"
        Write-Host 'Connect the remote computer to the team with Cloudflare One Client (WARP) before SSH/RDP.'
    }
    else {
        Write-Host "WireGuard public key: $targetWireGuardPublicKeyPath"
        Write-Host "WireGuard Hub peer: $targetWireGuardHubPeerPath"
    }
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

    $cloudflareMutationOutcomeUnknown = $null
    if ($null -ne $failure.Exception.Data) {
        $cloudflareMutationOutcomeUnknown = $failure.Exception.Data['CloudflareMutationOutcomeUnknown']
    }
    if ($null -ne $cloudflareMutationOutcomeUnknown) {
        $cloudflareRollbackSucceeded = $false
        Write-Warning 'A Cloudflare create request has an unknown outcome. The protected journal will reconcile it on the next run; no destructive retry was attempted.'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($createdCloudflareTunnelId)) {
        $cloudflareRollbackSucceeded = Remove-CloudflareProvisioningResources `
            -AccountId $cloudflareAccountId `
            -ApiToken $cloudflareApiToken `
            -RouteId $createdCloudflareRouteId `
            -TunnelId $createdCloudflareTunnelId
        if ($cloudflareRollbackSucceeded) {
            foreach ($journalCandidate in @(
                    $cloudflareTransactionJournalPath,
                    $(if ($null -ne $failedPath) { Join-Path $failedPath '.cloudflare-provisioning-transaction.json' })
                )) {
                if (-not [string]::IsNullOrWhiteSpace([string]$journalCandidate) -and
                    (Test-Path -LiteralPath $journalCandidate -PathType Leaf)) {
                    Remove-Item -LiteralPath $journalCandidate -Force
                }
            }
        }
        else {
            Write-Warning 'Cloudflare rollback is incomplete. Keep the protected transaction journal for the next run.'
        }
    }
    if (-not $cloudflareRollbackSucceeded -and $null -ne $failedPath) {
        $failedJournalPath = Join-Path $failedPath '.cloudflare-provisioning-transaction.json'
        if (Test-Path -LiteralPath $failedJournalPath -PathType Leaf) {
            $recoveryDirectory = Join-Path $stagingRoot "$EnvironmentName.recovery.$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $recoveryDirectory -Force | Out-Null
            Set-SecretAcl -Path $recoveryDirectory
            $recoveryJournalPath = Join-Path $recoveryDirectory '.cloudflare-provisioning-transaction.json'
            Move-Item -LiteralPath $failedJournalPath -Destination $recoveryJournalPath
            Set-SecretAcl -Path $recoveryJournalPath
        }
    }

    throw $failure
}
finally {
    $cloudflareApiToken = $null
    $rootEnvironment = $null
    if ($null -ne $migrationPath -and (Test-Path -LiteralPath $migrationPath)) {
        Remove-Item -LiteralPath $migrationPath -Recurse -Force
    }
    if ($cloudflareRollbackSucceeded -and (Test-Path -LiteralPath $stagingPath)) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    if (-not $completed -and -not $storageExistedBefore -and (Test-Path -LiteralPath $storagePath)) {
        $storageFile = Get-ChildItem -LiteralPath $storagePath -File -Recurse -Force | Select-Object -First 1
        if ($null -eq $storageFile) {
            Remove-Item -LiteralPath $storagePath -Recurse -Force
        }
    }
    if ($null -ne $mutex -and $mutexAcquired) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
