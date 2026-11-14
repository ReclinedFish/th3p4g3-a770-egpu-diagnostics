#Requires -Version 7.0
# Synthetic topology tests: no native calls, device changes, processes, or personal IDs.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\eGPU-Hotplug.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$functions = @('Test-KnownGpuBranch', 'Test-KnownUsbBranch', 'Get-AutomaticConfiguration', 'Update-DeviceSelection', 'Assert-DockAccessories', 'Show-Status')
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false) | Where-Object Name -In $functions) {
    Invoke-Expression $definition.Extent.Text
}

function Reset-Topology([string]$Suffix = 'A') {
    $script:testIds = @{
        Root = 'ROOT\SYNTHETIC\ROOT'
        Dock = "PCI\VEN_8086&DEV_15EF\TEST_DOCK_$Suffix"
        GpuBranch = "PCI\VEN_8086&DEV_15EF\TEST_GPU_BRANCH_$Suffix"
        UsbBranch = "PCI\VEN_8086&DEV_15EF\TEST_USB_BRANCH_$Suffix"
        Spare = "PCI\VEN_8086&DEV_15EF\TEST_SPARE_$Suffix"
        Switch = "PCI\VEN_8086&DEV_4FA0\TEST_SWITCH_$Suffix"
        GraphicsPort = "PCI\VEN_8086&DEV_4FA4\TEST_GRAPHICS_PORT_$Suffix"
        AudioPort = "PCI\VEN_8086&DEV_4FA4\TEST_AUDIO_PORT_$Suffix"
        Audio = "PCI\VEN_8086&DEV_4F90\TEST_AUDIO_$Suffix"
        Controller = "PCI\VEN_8086&DEV_15F0\TEST_USB_CONTROLLER_$Suffix"
        Hub = "USB\ROOT_HUB30\TEST_HUB_$Suffix"
        Gpu = "PCI\VEN_8086&DEV_56A0\TEST_GPU_$Suffix"
    }
    $script:children = @{}
    $script:parents = @{}
    $script:nodes = @{}
    $script:byNode = @{}
    $nodeNumber = 1
    foreach ($id in $testIds.Values) {
        $script:children[$id] = @()
        $script:nodes[$id] = $nodeNumber
        $script:byNode[$nodeNumber] = $id
        $nodeNumber++
    }
    Add-Edge $testIds.Root $testIds.Dock
    Add-Edge $testIds.Dock $testIds.GpuBranch
    Add-Edge $testIds.Dock $testIds.UsbBranch
    Add-Edge $testIds.Dock $testIds.Spare
    Add-Edge $testIds.GpuBranch $testIds.Switch
    Add-Edge $testIds.Switch $testIds.GraphicsPort
    Add-Edge $testIds.Switch $testIds.AudioPort
    Add-Edge $testIds.GraphicsPort $testIds.Gpu
    Add-Edge $testIds.AudioPort $testIds.Audio
    Add-Edge $testIds.UsbBranch $testIds.Controller
    Add-Edge $testIds.Controller $testIds.Hub
    $script:testGpus = @($testIds.Gpu)
    $script:manualConfig = $null
    $script:allowedUsbIds = @()
    $script:arcId = $null
    $script:dockId = $null
    $script:hubId = $null
    $script:extraPortId = $null
    $script:heldForEject = 47
}
function Add-Edge([string]$Parent, [string]$Child) {
    $script:parents[$Child] = $Parent
    $script:children[$Parent] = @($script:children[$Parent]) + @($Child)
}
function Get-PresentA770InstanceIds { $script:testGpus }
function Get-ParentInstanceId([string]$InstanceId) { $script:parents[$InstanceId] }
function Get-ImmediateInstanceIds([string]$InstanceId) { $script:children[$InstanceId] }
function Get-ChildInstanceIds([uint32]$Node) { $script:children[$script:byNode[[int]$Node]] }
function Get-DeviceState([string]$InstanceId) {
    $present = $script:nodes.ContainsKey($InstanceId)
    [pscustomobject]@{ Present = $present; Started = $present; Problem = 0; Node = $script:nodes[$InstanceId] }
}
function Test-UnderDock([uint32]$Node, [uint32]$DockNode) {
    $id = $script:byNode[[int]$Node]
    for ($i = 0; $i -lt 32 -and $id; $i++) {
        $id = $script:parents[$id]
        if ($id -and $id -eq $script:byNode[[int]$DockNode]) { return $true }
    }
    return $false
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Operation, [string]$Pattern) {
    try { & $Operation } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw 'Expected fail-closed rejection, but operation succeeded.'
}
$passed = 0
function Test-Case([string]$Name, [scriptblock]$Operation) {
    Reset-Topology
    & $Operation
    $script:passed++
    Write-Host "PASS $Name"
}
Test-Case 'unique supported topology selects only its GPU, dock, hub and spare port' {
    $result = Get-AutomaticConfiguration
    Assert-True ($result.GpuInstanceId -eq $testIds.Gpu -and $result.DockInstanceId -eq $testIds.Dock -and
        $result.UsbHubInstanceId -eq $testIds.Hub -and $result.DownstreamPortInstanceId -eq $testIds.Spare) 'Wrong topology selection.'
}
Test-Case 'no connected A770 leaves discovery empty and status usable' {
    $script:testGpus = @()
    Assert-True ($null -eq (Get-AutomaticConfiguration)) 'Offline discovery must be empty.'
    Show-Status
}
Test-Case 'multiple A770 adapters are rejected' {
    $script:testGpus += 'PCI\VEN_8086&DEV_56A0\TEST_SECOND_GPU'
    Assert-Throws { Get-AutomaticConfiguration } '多张'
}
Test-Case 'internal GPU without supported dock is rejected' {
    $script:parents[$testIds.Gpu] = $testIds.Root
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'unknown fourth PCIe branch is rejected' {
    $script:children[$testIds.Dock] += 'PCI\VEN_1234&DEV_1234\TEST_EXTRA'
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'unrelated GPU-branch sibling blocks discovery and eject guard' {
    $null = Update-DeviceSelection
    $script:children[$testIds.GpuBranch] += 'PCI\VEN_1234&DEV_5678\TEST_NVME'
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '未核对的设备'
}
Test-Case 'GPU behind an unknown additional bridge is rejected' {
    $bridge = 'PCI\VEN_1234&DEV_1234\TEST_EXTERNAL_BRIDGE'
    $script:parents[$testIds.Switch] = $bridge
    $script:parents[$bridge] = $testIds.GpuBranch
    $script:children[$testIds.GpuBranch] = @($bridge)
    $script:children[$bridge] = @($testIds.Switch)
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'unexpected device on the GPU internal audio port is rejected' {
    $script:children[$testIds.AudioPort] += 'PCI\VEN_1234&DEV_5678\TEST_NVME'
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'USB root hub missing during enumeration is rejected' {
    $script:children[$testIds.Controller] = @()
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'ambiguous identical USB branches are rejected' {
    $script:children[$testIds.Spare] = @($testIds.Controller)
    Assert-Throws { Get-AutomaticConfiguration } '无法唯一核对'
}
Test-Case 'parent cycle is rejected' {
    $script:parents[$testIds.Root] = $testIds.Dock
    Assert-Throws { Get-AutomaticConfiguration } '父子关系'
}
Test-Case 'reconnection replaces the selected instance paths' {
    Assert-True (Update-DeviceSelection) 'Initial selection missing.'
    $oldGpu = $script:arcId
    Reset-Topology 'B'
    $script:arcId = $oldGpu
    Assert-True (Update-DeviceSelection) 'Reconnected selection missing.'
    Assert-True ($script:arcId -eq $testIds.Gpu -and $script:arcId -ne $oldGpu) 'Stale GPU path retained.'
}
Test-Case 'manual configuration takes priority over auto discovery' {
    $script:testGpus = @()
    $script:manualConfig = @{ DockInstanceId='manual-dock'; GpuInstanceId='manual-gpu'; UsbHubInstanceId='manual-hub'; DownstreamPortInstanceId='manual-port' }
    Assert-True (Update-DeviceSelection) 'Manual selection missing.'
    Assert-True ($script:arcId -eq 'manual-gpu') 'Manual configuration was ignored.'
}
Test-Case 'empty accessory branches pass existing eject guard' {
    $null = Update-DeviceSelection
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'unapproved USB receiver blocks eject' {
    $null = Update-DeviceSelection
    $script:children[$testIds.Hub] += 'USB\VID_1234&PID_5678\TEST_RECEIVER'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '其他外接设备'
}
Test-Case 'explicitly allowed USB receiver passes existing accessory policy' {
    $null = Update-DeviceSelection
    $receiver = 'USB\VID_1234&PID_5678\TEST_RECEIVER'
    $script:children[$testIds.Hub] += $receiver
    $script:allowedUsbIds = @($receiver)
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'occupied downstream Thunderbolt port blocks eject' {
    $null = Update-DeviceSelection
    $script:children[$testIds.Spare] += 'PCI\VEN_1234&DEV_5678\TEST_STORAGE'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '其他外接设备'
}
Write-Host "All $passed synthetic discovery and accessory checks passed."
