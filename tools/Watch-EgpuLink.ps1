[CmdletBinding(DefaultParameterSetName = 'Watch')]
param(
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0, 86400)] [int] $DurationSeconds = 300,

    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0, 1440)] [int] $LookbackMinutes = 30,

    [string] $OutputDirectory,

    [Parameter(Mandatory, ParameterSetName = 'Mark')]
    [ValidateNotNullOrEmpty()] [string] $Mark
)

$ErrorActionPreference = 'Stop'
$started = [DateTimeOffset]::Now
if (-not $OutputDirectory) {
    if ($PSCmdlet.ParameterSetName -eq 'Mark') { throw 'Specify -OutputDirectory for the active capture.' }
    $OutputDirectory = Join-Path $PSScriptRoot ('captures\' + $started.ToString('yyyyMMdd-HHmmss'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$markerPath = Join-Path $OutputDirectory 'markers.jsonl'

if ($PSCmdlet.ParameterSetName -eq 'Mark') {
    if (-not (Test-Path -LiteralPath (Join-Path $OutputDirectory 'capture.txt'))) {
        throw "Capture directory not found: $OutputDirectory"
    }
    $marker = [ordered]@{ timeLocal = $started.ToString('o'); timeUtc = $started.UtcDateTime.ToString('o'); note = $Mark }
    Add-Content -LiteralPath $markerPath -Encoding utf8 -Value ($marker | ConvertTo-Json -Compress)
    Write-Output "MARK $($marker.timeLocal) $Mark"
    return
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$meta = Join-Path $OutputDirectory 'capture.txt'
$raw = Join-Path $OutputDirectory 'events.jsonl'
$tsv = Join-Path $OutputDirectory 'timeline.tsv'
$stopPath = Join-Path $OutputDirectory 'stop.request'
if ((Test-Path -LiteralPath $meta) -or (Test-Path -LiteralPath $raw) -or (Test-Path -LiteralPath $tsv)) {
    throw "Capture files already exist: $OutputDirectory"
}

function Write-CaptureNote([string] $Line) {
    Add-Content -LiteralPath $meta -Encoding utf8 -Value $Line
    Write-Output $Line
}

function Read-Events([string] $Log, [string] $XPath, [int] $Limit = 0, [switch] $Oldest) {
    $argsForRead = @{ LogName = $Log; FilterXPath = $XPath; ErrorAction = 'Stop' }
    if ($Limit) { $argsForRead.MaxEvents = $Limit }
    if ($Oldest) { $argsForRead.Oldest = $true }
    try { Get-WinEvent @argsForRead }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
    }
}

function Read-CaptureEvent($Source, $Event) {
    $xmlText = $Event.ToXml()
    $xml = [xml]$xmlText
    $data = [ordered]@{}
    $fieldIndex = 0
    foreach ($node in $xml.Event.EventData.Data) {
        $fieldIndex++
        $key = if ($node.Name) { [string]$node.Name } else { "field$fieldIndex" }
        if ($data.Contains($key)) { $key = "${key}_$fieldIndex" }
        $data[$key] = [string]$node.'#text'
    }
    try { $message = [string]$Event.Message } catch { $message = '' }
    $hay = "$message $xmlText"
    $device = ''
    $kind = $Source.Kind
    if ($kind -in 'Pnp','Config','PCI') {
        $match = [regex]::Match($hay, '(?i)(?:VEN_8086&DEV_|0x8086\.0x)(1133|1134|15EF|15F0|4FA0|4FA4|4F90|56A0)|VID_2516&PID_01B5')
        if ($match.Success) {
            $device = if ($match.Groups[1].Success) { '8086:' + $match.Groups[1].Value.ToUpperInvariant() } else { '2516:01B5' }
        } elseif ($kind -eq 'PCI' -and $data.VendorId -in '32902','0x8086') {
            $numeric = 0
            if ([int]::TryParse($data.DeviceId, [ref]$numeric)) { $device = '8086:{0:X4}' -f $numeric }
            if ($device -notmatch '^8086:(1133|1134|15EF|15F0|4FA0|4FA4|4F90|56A0)$') { return }
        } else { return }
        if ($kind -eq 'PCI' -and $Event.Id -eq 12 -and $message -notmatch '(?i)surprise remov|not present|not physically present|failed power up|意外删除|总线上报告为缺少') { return }
    } elseif ($kind -eq 'WER') {
        if ($data.EventName -eq 'LiveKernelEvent' -and $data.P1 -in '117','141','142','1a8','1b0','1b8') { $kind = 'LiveKernelEvent' }
        elseif ($data.EventName -eq 'D3DDeviceErrorDxDmp') { $kind = 'D3D' }
        else { return }
    } elseif ($kind -eq 'Dump' -and $hay -notmatch '(?i)WATCHDOG|DXGKRNL') { return }
    elseif ($kind -eq 'System') {
        $kind = switch -Regex ($Event.ProviderName) {
            '^nhi$' { 'Thunderbolt'; break }
            'USB4' { 'USB4'; break }
            'WHEA' { 'WHEA'; break }
            'Power' { 'Power'; break }
            default { 'Display' }
        }
    }

    $time = [DateTimeOffset]$Event.TimeCreated
    return [pscustomobject][ordered]@{
        timeLocal = $time.ToString('o')
        timeUtc = $time.UtcDateTime.ToString('o')
        readUtc = [DateTime]::UtcNow.ToString('o')
        kind = $kind
        channel = $Event.LogName
        provider = $Event.ProviderName
        eventId = $Event.Id
        recordId = $Event.RecordId
        device = $device
        code = $data.P1
        reportId = $data.ReportId
        message = $message
        data = $data
        eventXml = $xmlText
    }
}

$sources = @(
    @{ Kind = 'System'; Log = 'System'; Filter = "(Provider[@Name='nhi'] and (EventID=9001 or EventID=9002 or EventID=9003 or EventID=9007 or EventID=9008)) or Provider[@Name='Display'] or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='Microsoft-Windows-USB-USB4DeviceRouter-EventLogs'] or Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42 or EventID=107 or EventID=506 or EventID=507))" },
    @{ Kind = 'Pnp'; Log = 'Microsoft-Windows-Kernel-PnP/Device Management'; Filter = 'EventID=1010 or EventID=1011 or EventID=1020' },
    @{ Kind = 'Config'; Log = 'Microsoft-Windows-Kernel-PnP/Configuration'; Filter = 'EventID=400 or EventID=410 or EventID=411 or EventID=420' },
    @{ Kind = 'PCI'; Log = 'Microsoft-Windows-PCI/Operational'; Filter = 'EventID=12 or EventID=41 or EventID=42 or EventID=80 or EventID=82 or EventID=83 or EventID=90 or EventID=101 or EventID=102' },
    @{ Kind = 'Dump'; Log = 'Microsoft-Windows-WerKernel/Operational'; Filter = 'EventID=1001 or EventID=1002' },
    @{ Kind = 'WER'; Log = 'Application'; Filter = "Provider[@Name='Windows Error Reporting'] and EventID=1001" }
)

$lookback = $started.AddMinutes(-$LookbackMinutes)
$sinceUtc = $lookback.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
$duration = if ($DurationSeconds -eq 0) { 'until stopped' } else { "$DurationSeconds s" }
Write-CaptureNote "START $($started.ToString('o')) | lookback=$LookbackMinutes min | duration=$duration | pid=$PID"
Write-CaptureNote "DIR $OutputDirectory"
$active = @(
    foreach ($source in $sources) {
        try {
            $settings = Get-WinEvent -ListLog $source.Log
            if (-not $settings.IsEnabled) { Write-CaptureNote "SKIP disabled $($source.Log)" | Out-Host; continue }
            $source.Cursor = 0L
            $source.Initial = $true
            $oldest = Read-Events $source.Log '*' -Limit 1 -Oldest
            if ($oldest -and [DateTimeOffset]$oldest.TimeCreated -gt $lookback) {
                Write-CaptureNote "HISTORY $($source.Log) oldest retained $($oldest.TimeCreated.ToString('o'))" | Out-Host
            }
            $source
        } catch { Write-CaptureNote "SKIP $($source.Log) $($_.Exception.Message)" | Out-Host }
    }
)

$rawWriter = [IO.StreamWriter]::new($raw, $false, [Text.UTF8Encoding]::new($false))
$timelineWriter = [IO.StreamWriter]::new($tsv, $false, [Text.UTF8Encoding]::new($true))
$rawWriter.AutoFlush = $true
$timelineWriter.AutoFlush = $true
$timelineWriter.WriteLine("TimeLocal`tKind`tEventId`tRecordId`tDevice`tCode`tReportId`tMessage")
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$count = 0
$nextHeartbeat = 30
try {
    do {
        $batch = foreach ($source in $active) {
            try {
                $head = Read-Events $source.Log '*' -Limit 1
                if (-not $head) { continue }
                $top = [long]$head.RecordId
                if ($top -eq $source.Cursor) { continue }
                if ($top -lt $source.Cursor) {
                    Write-CaptureNote "RESET $($source.Log) $($source.Cursor) -> $top" | Out-Host
                    $source.Cursor = 0L
                }
                if (-not $source.Initial -and $source.Cursor) {
                    $oldest = Read-Events $source.Log '*' -Limit 1 -Oldest
                    if ($oldest -and [long]$oldest.RecordId -gt ($source.Cursor + 1)) {
                        Write-CaptureNote "GAP $($source.Log) records $($source.Cursor + 1)..$([long]$oldest.RecordId - 1) rotated before read" | Out-Host
                    }
                }
                $scope = if ($source.Initial) { "TimeCreated[@SystemTime >= '$sinceUtc'] and " } else { '' }
                $xpath = "*[System[$scope(EventRecordID > $($source.Cursor) and EventRecordID <= $top) and ($($source.Filter))]]"
                $events = @(Read-Events $source.Log $xpath)
                foreach ($event in $events) { Read-CaptureEvent $source $event }
                $source.Cursor = $top
                $source.Initial = $false
            } catch { Write-CaptureNote "WARN $($source.Log) $($_.Exception.Message)" | Out-Host }
        }
        foreach ($row in ($batch | Sort-Object timeUtc,channel,recordId)) {
            $rawWriter.WriteLine(($row | ConvertTo-Json -Depth 6 -Compress))
            $fields = @($row.timeLocal,$row.kind,$row.eventId,$row.recordId,$row.device,$row.code,$row.reportId,$row.message)
            $timelineWriter.WriteLine((($fields | ForEach-Object { ([string]$_ -replace '[\t\r\n]+',' ').Trim() }) -join "`t"))
            $count++
        }
        if ($elapsed.Elapsed.TotalSeconds -ge $nextHeartbeat) {
            Write-CaptureNote "CHECK $([DateTimeOffset]::Now.ToString('o')) events=$count"
            $nextHeartbeat = $elapsed.Elapsed.TotalSeconds + 30
        }
        if ((Test-Path -LiteralPath $stopPath) -or ($DurationSeconds -gt 0 -and $elapsed.Elapsed.TotalSeconds -ge $DurationSeconds)) {
            break
        }
        Start-Sleep -Milliseconds 1000
    } while ($true)
} finally {
    $rawWriter.Dispose()
    $timelineWriter.Dispose()
    Write-CaptureNote "END $([DateTimeOffset]::Now.ToString('o')) events=$count"
}
