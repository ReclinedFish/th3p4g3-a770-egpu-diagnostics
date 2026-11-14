#Requires -Version 7.0
# Synthetic topology tests: no native calls, device changes, processes, or personal IDs.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\eGPU-Hotplug.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$functions = @('Test-KnownGpuBranch', 'Test-KnownUsbBranch', 'Get-AutomaticConfiguration', 'Update-DeviceSelection',
    'Get-UsbMouseTreeSnapshot', 'Assert-UsbMouseAccessory', 'Assert-DockAccessories', 'Show-Status')
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
    $script:usbFacts = @{}
    $script:stateOverrides = @{}
    $script:propertyReadHook = $null
    $script:childReadHook = $null
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
function Get-ChildInstanceIds([uint32]$Node) {
    if ($script:childReadHook) { & $script:childReadHook $script:byNode[[int]$Node] }
    $script:children[$script:byNode[[int]$Node]]
}
function Get-DeviceState([string]$InstanceId) {
    if ($script:stateOverrides.ContainsKey($InstanceId)) { return $script:stateOverrides[$InstanceId] }
    $present = $script:nodes.ContainsKey($InstanceId)
    [pscustomobject]@{ Present = $present; Started = $present; Problem = 0; Node = $script:nodes[$InstanceId] }
}
function Add-UsbNode([string]$Parent, [string]$Id, [string]$ClassGuid, [string]$Service, [string[]]$HardwareIds, [string[]]$CompatibleIds) {
    $number = $script:nodes.Count + 1
    $script:nodes[$Id] = $number
    $script:byNode[$number] = $Id
    $script:children[$Id] = @()
    $script:usbFacts[$Id] = [pscustomobject]@{
        Node=$number; ClassGuid=$ClassGuid; Service=$Service; HardwareIds=$HardwareIds; CompatibleIds=$CompatibleIds
    }
    Add-Edge $Parent $Id
    return $Id
}
function Get-UsbDeviceFacts([string]$InstanceId) {
    if ($script:propertyReadHook) { & $script:propertyReadHook $InstanceId }
    $state = Get-DeviceState $InstanceId
    if (!$state.Present -or !$state.Started -or $state.Problem -ne 0 -or !$script:usbFacts.ContainsKey($InstanceId)) {
        throw 'Synthetic unreadable or unready USB device.'
    }
    return $script:usbFacts[$InstanceId]
}
function Add-MouseReceiver([switch]$Composite) {
    $root = 'USB\VID_1234&PID_5678\TEST_MOUSE'
    $transport = $root
    if ($Composite) {
        $null = Add-UsbNode $testIds.Hub $root '36fc9e60-c465-11cf-8056-444553540000' 'usbccgp' @('USB\VID_1234&PID_5678') @('USB\COMPOSITE')
        $transport = 'USB\VID_1234&PID_5678&MI_00\TEST_MOUSE_INTERFACE'
        $null = Add-UsbNode $root $transport '745a17a0-74d3-11d0-b6fe-00a0c90f57da' 'HidUsb' @('USB\VID_1234&PID_5678&MI_00') @('USB\Class_03')
    } else {
        $null = Add-UsbNode $testIds.Hub $root '745a17a0-74d3-11d0-b6fe-00a0c90f57da' 'HidUsb' @('USB\VID_1234&PID_5678') @('USB\Class_03')
    }
    $mouse = 'HID\VID_1234&PID_5678&COL01\TEST_MOUSE_COLLECTION'
    $null = Add-UsbNode $transport $mouse '4d36e96f-e325-11ce-bfc1-08002be10318' 'mouhid' @('HID_DEVICE_SYSTEM_MOUSE','HID_DEVICE_UP:0001_U:0002','HID_DEVICE') @()
    if ($Composite) {
        $extra = 'USB\VID_1234&PID_5678&MI_01\TEST_EXTRA_INTERFACE'
        $null = Add-UsbNode $root $extra '745a17a0-74d3-11d0-b6fe-00a0c90f57da' 'HidUsb' @('USB\VID_1234&PID_5678&MI_01') @('USB\Class_03')
        $null = Add-UsbNode $extra 'HID\VID_1234&PID_5678&COL02\TEST_KEYBOARD' '4d36e96b-e325-11ce-bfc1-08002be10318' 'kbdhid' @('HID_DEVICE_SYSTEM_KEYBOARD','HID_DEVICE') @()
        $null = Add-UsbNode $extra 'HID\VID_1234&PID_5678&COL03\TEST_CONSUMER' '745a17a0-74d3-11d0-b6fe-00a0c90f57da' '' @('HID_DEVICE_SYSTEM_CONSUMER','HID_DEVICE_UP:000C_U:0001','HID_DEVICE') @()
        $null = Add-UsbNode $extra 'HID\VID_1234&PID_5678&COL04\TEST_VENDOR_HID' '745a17a0-74d3-11d0-b6fe-00a0c90f57da' '' @('HID_DEVICE_UP:FF00_U:0001','HID_DEVICE') @()
    }
    return @{Root=$root; Transport=$transport; Mouse=$mouse}
}
function Add-HidSoftwareLeaf([string]$Parent) {
    return Add-UsbNode $Parent 'SWD\DRIVERENUM\TEST_HID_SOFTWARE' '5c4c3332-344d-483c-8739-259e934c9cc8' '' @('SWC\VID_1234&PID_0001') @('SWC\Generic','SWD\GenericRaw','SWD\Generic')
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
Test-Case 'unreadable USB receiver blocks eject' {
    $null = Update-DeviceSelection
    $script:children[$testIds.Hub] += 'USB\VID_1234&PID_5678\TEST_RECEIVER'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'standard mouse HID automatically passes without any whitelist' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'composite mouse keyboard consumer and vendor HID receiver automatically passes' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'legacy whitelist cannot authorize an unreadable device' {
    $null = Update-DeviceSelection
    $receiver = 'USB\VID_1234&PID_5678\TEST_RECEIVER'
    $script:children[$testIds.Hub] += $receiver
    $script:allowedUsbIds = @($receiver)
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'mouse receiver permits its strict same-vendor service-free SoftwareComponent leaf' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'software component with a function service is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:usbFacts[$leaf].Service = 'VendorService'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component with a storage child is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $null = Add-UsbNode $leaf 'SCSI\DISK&VEN_TEST\TEST_SOFTWARE_DISK' '4d36e967-e325-11ce-bfc1-08002be10318' 'disk' @('GenDisk') @()
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component with a storage setup class is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:usbFacts[$leaf].ClassGuid = '4d36e967-e325-11ce-bfc1-08002be10318'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component with a different vendor is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:usbFacts[$leaf].HardwareIds = @('SWC\VID_9999&PID_0001')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component with an extra unknown hardware ID is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:usbFacts[$leaf].HardwareIds += 'SWC\UNKNOWN'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component with an extra compatible ID is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:usbFacts[$leaf].CompatibleIds += 'SWD\UNKNOWN'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'software component must be under a standard HID transport' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Root
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'arbitrary software enumerator does not receive SoftwareComponent exception' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-UsbNode $receiver.Transport 'SWD\WPDBUSENUM\TEST_OTHER_SOFTWARE' '5c4c3332-344d-483c-8739-259e934c9cc8' '' @('SWC\VID_1234&PID_0001') @('SWC\Generic','SWD\GenericRaw','SWD\Generic')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'stopped software component is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $leaf = Add-HidSoftwareLeaf $receiver.Transport
    $script:stateOverrides[$leaf] = [pscustomobject]@{ Present=$true; Started=$false; Problem=22; Node=$nodes[$leaf] }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'keyboard-only HID device lacks a mouse and is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].ClassGuid = '4d36e96b-e325-11ce-bfc1-08002be10318'
    $script:usbFacts[$receiver.Mouse].Service = 'kbdhid'
    $script:usbFacts[$receiver.Mouse].HardwareIds = @('HID_DEVICE_SYSTEM_KEYBOARD','HID_DEVICE')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'mouse marker in CompatibleIds alone is insufficient' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].HardwareIds = @('HID_DEVICE')
    $script:usbFacts[$receiver.Mouse].CompatibleIds = @('HID_DEVICE_SYSTEM_MOUSE')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'standard pointer collection with mouse system ID is supported' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].HardwareIds = @('HID_DEVICE_SYSTEM_MOUSE','HID_DEVICE_UP:0001_U:0001','HID_DEVICE')
    Assert-DockAccessories $nodes[$dockId]
}
Test-Case 'USBSTOR disk remains blocked even with an exact legacy whitelist entry' {
    $null = Update-DeviceSelection
    $disk = Add-UsbNode $testIds.Hub 'USB\VID_1234&PID_5678\TEST_DISK' '36fc9e60-c465-11cf-8056-444553540000' 'USBSTOR' @('USB\VID_1234&PID_5678') @('USB\Class_08&SubClass_06&Prot_50','USB\Class_08')
    $script:allowedUsbIds = @($disk)
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'UASP disk remains blocked even with an exact legacy whitelist entry' {
    $null = Update-DeviceSelection
    $disk = Add-UsbNode $testIds.Hub 'USB\VID_1234&PID_5678\TEST_UASP' '4d36e97b-e325-11ce-bfc1-08002be10318' 'UASPStor' @('USB\VID_1234&PID_5678') @('USB\Class_08&SubClass_06&Prot_62','USB\Class_08')
    $script:allowedUsbIds = @($disk)
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'composite mouse plus storage interface is blocked despite whitelist' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $null = Add-UsbNode $receiver.Root 'USB\VID_1234&PID_5678&MI_02\TEST_STORAGE' '36fc9e60-c465-11cf-8056-444553540000' 'USBSTOR' @('USB\VID_1234&PID_5678&MI_02') @('USB\Class_08')
    $script:allowedUsbIds = @($receiver.Root)
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'extra WinUSB interface on a mouse receiver is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $null = Add-UsbNode $receiver.Root 'USB\VID_1234&PID_5678&MI_02\TEST_WINUSB' '745a17a0-74d3-11d0-b6fe-00a0c90f57da' 'WinUSB' @('USB\VID_1234&PID_5678&MI_02') @('USB\Class_FF')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'unexpected disk child under a nominal HID collection is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $null = Add-UsbNode $receiver.Mouse 'SCSI\DISK&VEN_TEST\TEST_DISK' '4d36e967-e325-11ce-bfc1-08002be10318' 'disk' @('GenDisk') @()
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'storage class marker cannot hide behind HID service and mouse IDs' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].ClassGuid = '71a27cdd-812a-11d0-bec7-08002be2092f'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'storage USB class marker on a nominal HID interface is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Root].CompatibleIds += 'USB\Class_08&SubClass_06&Prot_50'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'extra USB hub with a mouse child is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Root].ClassGuid = '36fc9e60-c465-11cf-8056-444553540000'
    $script:usbFacts[$receiver.Root].Service = 'USBHUB3'
    $script:usbFacts[$receiver.Root].CompatibleIds = @('USB\Class_09')
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'HID interface with no enumerated collection is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:children[$receiver.Root] = @()
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'unknown HID custom driver is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].Service = 'VendorMouse'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'disabled receiver collection is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:stateOverrides[$receiver.Mouse] = [pscustomobject]@{ Present=$true; Started=$false; Problem=22; Node=$nodes[$receiver.Mouse] }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'USB child disappears during property inspection' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:propertyReadHook = { param($id) if ($id -eq $receiver.Mouse) { $script:stateOverrides[$id] = [pscustomobject]@{Present=$false; Started=$false; Problem=$null; Node=$null} } }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'USB parent mismatch blocks stale subtree selection' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:parents[$receiver.Mouse] = $testIds.Root
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'duplicate USB child cannot pass tree verification' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:children[$receiver.Root] += $receiver.Mouse
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'USB device node replacement during inspection is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:usbFacts[$receiver.Mouse].Node = 65000
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'changed HID properties across snapshots are blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:mouseReads = 0
    $script:propertyReadHook = { param($id) if ($id -eq $receiver.Mouse) { $script:mouseReads++; if ($script:mouseReads -eq 2) { $script:usbFacts[$id].HardwareIds += 'HID\TEST_CHANGED' } } }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'new storage sibling arriving between subtree snapshots is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver -Composite
    $script:rootReads = 0
    $script:propertyReadHook = { param($id) if ($id -eq $receiver.Root) { $script:rootReads++; if ($script:rootReads -eq 2) {
        $null = Add-UsbNode $receiver.Root 'USB\VID_1234&PID_5678&MI_02\TEST_LATE_STORAGE' '36fc9e60-c465-11cf-8056-444553540000' 'USBSTOR' @('USB\VID_1234&PID_5678&MI_02') @('USB\Class_08')
    } } }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '无法完整核对'
}
Test-Case 'new root-hub child arriving after receiver inspection is blocked' {
    $null = Update-DeviceSelection
    $receiver = Add-MouseReceiver
    $script:hubReads = 0
    $script:childReadHook = { param($id) if ($id -eq $testIds.Hub) { $script:hubReads++; if ($script:hubReads -eq 2) { $script:children[$id] += 'USB\VID_1234&PID_9999\TEST_LATE_DEVICE' } } }
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '设备发生变化'
}
Test-Case 'occupied downstream Thunderbolt port blocks eject' {
    $null = Update-DeviceSelection
    $script:children[$testIds.Spare] += 'PCI\VEN_1234&DEV_5678\TEST_STORAGE'
    Assert-Throws { Assert-DockAccessories $nodes[$dockId] } '其他外接设备'
}
Write-Host "All $passed synthetic discovery and accessory checks passed."
