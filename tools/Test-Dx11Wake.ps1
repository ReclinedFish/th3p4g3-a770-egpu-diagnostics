#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'eGPU-Hotplug.local.json'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'captures'),
    [ValidateRange(1, 300)] [int]$BaselineSeconds = 300,
    [ValidateRange(1, 120)] [int]$RetestSeconds = 30,
    [ValidateRange(1, 300)] [int]$IdleSeconds = 120,
    [ValidateRange(1, 10)] [int]$RetestCount = 3
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'Dx11ArcBatched\bin\Release\net10.0\Dx11ArcBatched.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw 'Build Dx11ArcBatched in Release mode with the .NET 10 SDK before running this script.'
}
$hotplugOptions = @{ Action = 'Status' }
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $hotplugOptions.ConfigPath = $ConfigPath }
. (Join-Path $PSScriptRoot 'eGPU-Hotplug.ps1') @hotplugOptions
if (!$arcId) { throw 'Connect the Arc A770 and let Windows enumerate the dock before running this test.' }
$start=[DateTimeOffset]::Now
$folder=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('A770-DX11-Wake-' + $start.ToString('yyyyMMdd-HHmmss-fff'))
$watchDuration = $BaselineSeconds + $RetestCount * ($IdleSeconds + $RetestSeconds + 55) + $IdleSeconds + 90
$watch = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList (
    '-NoLogo -NoProfile -File "{0}" -DurationSeconds {1} -LookbackMinutes 0 -OutputDirectory "{2}"' -f
    (Join-Path $PSScriptRoot 'Watch-EgpuLink.ps1'), $watchDuration, $folder
) -PassThru -WindowStyle Hidden
$results = [Collections.Generic.List[bool]]::new()
$watchStopped = $false
try {
    for($attempt=0; !(Test-Path -LiteralPath (Join-Path $folder 'timeline.tsv')); $attempt++){
        if($watch.HasExited -or $attempt -ge 40){throw 'Event watcher failed to start.'}
        Start-Sleep -Milliseconds 250
    }
    $runs=Join-Path $folder 'run.tsv'
    "CAPTURE $folder"
    function Write-RunNote([string]$Line) {
        Add-Content -LiteralPath $runs -Value $Line -Encoding utf8
        Write-Output $Line
    }
    function Get-ArcPowerState {
        try {
            $state=(Get-PnpDeviceProperty -InstanceId $arcId -KeyName 'DEVPKEY_Device_PowerData' -ErrorAction Stop).Data
            if($state.Length -ge 8) {
                $value=[BitConverter]::ToUInt32([byte[]]$state,4)
                if($value -in 1,2,3,4){ return "D$($value - 1)" }
            }
        } catch {}
        return 'Unknown'
    }
    function Assert-NoMiner {
        $app=Get-Process -Name 'Kryptex*','kryptex_*' -ErrorAction SilentlyContinue
        if ($app) { throw 'Close Kryptex before running the DX11 test.' }
    }
    function Wait-Idle([int]$Seconds,[string]$Label) {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $last=''
        Write-RunNote "IDLE_START $([DateTimeOffset]::Now.ToString('o')) $Label seconds=$Seconds"
        do {
            Assert-NoMiner
            $state=Get-ArcPowerState
            if($state -ne $last){
                Write-RunNote "IDLE_STATE $([DateTimeOffset]::Now.ToString('o')) $Label Power=$state"
                $last=$state
            }
            $remaining=$Seconds-$clock.Elapsed.TotalSeconds
            if($remaining -le 0){break}
            Start-Sleep -Milliseconds ([int]([Math]::Min(4000,$remaining*1000)))
        } while($true)
        Write-RunNote "IDLE_END $([DateTimeOffset]::Now.ToString('o')) $Label Power=$last"
    }
    function Invoke-Dx11([string]$Label,[int]$Seconds) {
        Assert-NoMiner
        $arc=Get-DeviceState $arcId
        $dock=Get-DeviceState $dockId
        if(!$arc.Started -or $arc.Problem -ne 0 -or !$dock.Started -or !$dock.Present -or !(Test-UnderDock $arc.Node $dock.Node)){
            Write-RunNote "SKIP $([DateTimeOffset]::Now.ToString('o')) $Label A770Present=$($arc.Present) Started=$($arc.Started) Problem=$($arc.Problem)"
            $results.Add($false)
            return
        }
        # The benchmark selects by PCI ID from DXGI rather than by instance path.
        $activeA770s = @(Get-PnpDevice -PresentOnly -Class Display | Where-Object {
            $_.Status -eq 'OK' -and $_.InstanceId -match '^PCI\\VEN_8086&DEV_56A0(?:&|\\)'
        })
        if ($activeA770s.Count -ne 1 -or $activeA770s[0].InstanceId -ne $arcId) {
            throw 'Leave only the configured Arc A770 online before running the benchmark.'
        }
        $power=Get-ArcPowerState
        $out=Join-Path $folder "$Label.stdout.txt"
        $err=Join-Path $folder "$Label.stderr.txt"
        $launched=[DateTimeOffset]::Now
        $p=Start-Process -FilePath $exe -ArgumentList '--match','A770','--api','d3d11','--seconds',"$Seconds" -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        Write-RunNote "BEGIN $($launched.ToString('o')) $Label Seconds=$Seconds PrePower=$power PID=$($p.Id)"
        $timedOut=!$p.WaitForExit(($Seconds+35)*1000)
        if($timedOut){ $p.Kill(); $p.WaitForExit() }
        $finish=[DateTimeOffset]::Now
        $pass=Get-Content -LiteralPath $out | Select-String 'PASS native D3D11.*A770.*readback_values=4' | Select-Object -Last 1 -ExpandProperty Line
        $failure=Get-Content -LiteralPath $err | Select-Object -First 1
        Write-RunNote "END $($finish.ToString('o')) $Label Exit=$($p.ExitCode) Timeout=$timedOut Pass=$([bool]$pass) $pass $failure"
        $results.Add(!$timedOut -and $p.ExitCode -eq 0 -and [bool]$pass)
        $p.Dispose()
    }
    Write-RunNote "START $($start.ToString('o')) ExeSHA256=$((Get-FileHash -LiteralPath $exe).Hash)"
    Invoke-Dx11 '01-baseline' $BaselineSeconds
    for ($index = 1; $index -le $RetestCount; $index++) {
        $label = '{0:00}-after-idle' -f ($index + 1)
        Wait-Idle $IdleSeconds $label
        Invoke-Dx11 $label $RetestSeconds
    }
    Wait-Idle $IdleSeconds 'post-run'
    Assert-NoMiner
    Write-RunNote "COMPLETE $([DateTimeOffset]::Now.ToString('o'))"
} finally {
    if(Test-Path -LiteralPath $folder){
        New-Item -ItemType File -Path (Join-Path $folder 'stop.request') -Force | Out-Null
    }
    $watchStopped = $watch.WaitForExit(10000) -and $watch.ExitCode -eq 0
    if (!$watch.HasExited) {
        $watch.Kill()
        $watch.WaitForExit()
    }
    $watch.Dispose()
}

$capture = Get-Content -LiteralPath (Join-Path $folder 'capture.txt')
$watchIssues = @($capture | Where-Object { $_ -match '^(SKIP|WARN|GAP|RESET) ' })
if (!$watchStopped -or $watchIssues.Count -or !($capture -match '^END ')) {
    Write-Warning 'The event capture has gaps or unavailable channels. See capture.txt.'
}
$events = @(Get-Content -LiteralPath (Join-Path $folder 'events.jsonl') | ConvertFrom-Json)
$thunderbolt = @($events | Where-Object { $_.kind -eq 'Thunderbolt' -and $_.eventId -eq 9003 })
$pnp = @($events | Where-Object { $_.kind -eq 'Pnp' -and $_.eventId -eq 1010 -and $_.device -match '^8086:' })
$dumps = @($events | Where-Object { $_.kind -eq 'Dump' -and $_.eventId -eq 1002 })
$reports = @($events | Where-Object { $_.kind -eq 'LiveKernelEvent' -and $_.code -eq '141' })
Write-RunNote "EVENTS ThunderboltDisconnectCandidates=$($thunderbolt.Count) PnpSurpriseRemovalCandidates=$($pnp.Count) WatchdogDump=$($dumps.Count) WER141Rows=$($reports.Count)"
if ($reports.Count) {
    Write-Host 'Use the dump filename and report ID in the event logs to identify repeat reports.'
}
Write-Host 'Capture files contain local Windows event logs and device identifiers. Review before sharing.'
if ($false -in $results) { throw 'One or more DX11 runs failed or were skipped. See run.tsv.' }
