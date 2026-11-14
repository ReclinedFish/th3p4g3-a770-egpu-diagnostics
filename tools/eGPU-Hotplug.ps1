#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Menu', 'Status', 'Eject', 'WaitForConnect')]
    [string]$Action = 'Menu',

    [ValidateRange(10, 120)]
    [int]$TimeoutSeconds = 30,

    [switch]$ForceCloseApps,

    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'eGPU-Hotplug.local.json')
)

$ErrorActionPreference = 'Stop'

# A local configuration is an explicit override. Without it, discover the live tree.
$manualConfig = $null
$hasLocalConfig = Test-Path -LiteralPath $ConfigPath -PathType Leaf
if (!$hasLocalConfig -and $PSBoundParameters.ContainsKey('ConfigPath')) {
    throw '指定的本机配置不存在。请检查 -ConfigPath；省略此参数可自动识别在线设备。'
}
if ($hasLocalConfig) {
    try {
        $manualConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw '本机配置无法读取，或不是有效的 JSON。请参照 eGPU-Hotplug.example.json。'
    }
    if ($manualConfig -isnot [System.Collections.IDictionary]) {
        throw '本机配置必须是 JSON 对象。'
    }
    $patterns = [ordered]@{
        DockInstanceId           = '^PCI\\VEN_8086&DEV_15EF(?:&[A-Z0-9_]+)*\\[A-Z0-9&_.-]+$'
        GpuInstanceId            = '^PCI\\VEN_8086&DEV_56A0(?:&[A-Z0-9_]+)*\\[A-Z0-9&_.-]+$'
        UsbHubInstanceId         = '^USB\\ROOT_HUB30\\[A-Z0-9&_.-]+$'
        DownstreamPortInstanceId = '^PCI\\VEN_8086&DEV_15EF(?:&[A-Z0-9_]+)*\\[A-Z0-9&_.-]+$'
    }
    foreach ($key in $patterns.Keys) {
        if ($manualConfig[$key] -isnot [string] -or $manualConfig[$key] -notmatch $patterns[$key]) {
            throw "本机配置的 $key 必须填入设备管理器中的完整实例路径。"
        }
    }
    if ($manualConfig.DockInstanceId -eq $manualConfig.DownstreamPortInstanceId) {
        throw '显卡坞上游桥与下游扩展端口必须是两个设备实例。'
    }
}
$dockId = $null
$arcId = $null
$hubId = $null
$extraPortId = $null
$allowedUsbIds = @()
if ($manualConfig -and $manualConfig.Contains('AllowedUsbInstanceIds')) {
    if ($manualConfig.AllowedUsbInstanceIds -isnot [array]) {
        throw 'AllowedUsbInstanceIds 必须为 JSON 字符串数组。'
    }
    foreach ($id in $manualConfig.AllowedUsbInstanceIds) {
        if ($id -isnot [string] -or $id -notmatch '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}(?:&[A-Z0-9_]+)*\\[A-Z0-9&_.-]+$') {
            throw 'AllowedUsbInstanceIds 中的每项必须是 USB 设备的完整实例路径。'
        }
    }
    # Retained for configuration compatibility only. An old whitelist cannot bypass
    # the HID-only check (in particular, cannot allow a disk or composite storage).
    $allowedUsbIds = $manualConfig.AllowedUsbInstanceIds
}
$noSuchDevNode = 0x0D
$startedFlag = 0x08
$removableFlag = 0x4000
$heldForEject = 47

if (-not ('EgpuHotplug.ConfigManager' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;

namespace EgpuHotplug
{
    public enum PnpVeto
    {
        Unknown, LegacyDevice, PendingClose, WindowsApp, WindowsService,
        OutstandingOpen, Device, Driver, IllegalDeviceRequest, InsufficientPower,
        NonDisableable, LegacyDriver, InsufficientRights, AlreadyRemoved
    }

    public static class ConfigManager
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct DevicePropertyKey
        {
            public System.Guid FormatId;
            public uint PropertyId;
        }

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint CM_Get_DevNode_PropertyW(uint device, ref DevicePropertyKey key,
            out uint type, [Out] byte[] buffer, ref uint length, uint flags);

        private static byte[] ReadProperty(uint device, uint property, uint expectedType, bool allowMissing)
        {
            var key = new DevicePropertyKey {
                FormatId = new System.Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), PropertyId = property
            };
            for (int attempt = 0; attempt < 3; attempt++)
            {
                uint size = 0, type;
                uint result = CM_Get_DevNode_PropertyW(device, ref key, out type, null, ref size, 0);
                if (result == 0x25 && allowMissing) return new byte[0]; // CR_NO_SUCH_VALUE
                if (result != 0x1A || size == 0 || size > 65536 || type != expectedType)
                    throw new System.InvalidOperationException("Cannot read a required USB device property.");
                byte[] buffer = new byte[size];
                result = CM_Get_DevNode_PropertyW(device, ref key, out type, buffer, ref size, 0);
                if (result == 0x1A) continue; // CR_BUFFER_SMALL: device properties changed
                if (result != 0 || type != expectedType || size == 0 || size > buffer.Length)
                    throw new System.InvalidOperationException(string.Format(
                        "USB property {0} changed during inspection (result 0x{1:X}, type 0x{2:X}, size {3}/{4}).",
                        property, result, type, size, buffer.Length));
                // ConfigMgr can return fewer bytes than its size query, notably
                // four requested bytes but two returned for an empty MULTI_SZ.
                if (size < buffer.Length) System.Array.Resize(ref buffer, (int)size);
                return buffer;
            }
            throw new System.InvalidOperationException("USB device properties did not stabilize.");
        }

        public static string ReadClassGuid(uint device)
        {
            var value = ReadProperty(device, 10, 0x0D, false); // DEVPKEY_Device_ClassGuid, GUID
            if (value.Length != 16) throw new System.InvalidOperationException("Invalid USB class GUID.");
            return new System.Guid(value).ToString("D");
        }

        public static string[] ReadDeviceStrings(uint device, uint property, bool list, bool allowMissing)
        {
            var value = ReadProperty(device, property, list ? 0x2012u : 0x12u, allowMissing);
            if (value.Length == 0) return new string[0];
            if (list && value.Length == 2 && value[0] == 0 && value[1] == 0) return new string[0];
            if (value.Length % 2 != 0 || value.Length < (list ? 4 : 2) ||
                value[value.Length - 1] != 0 || value[value.Length - 2] != 0 ||
                (list && (value[value.Length - 3] != 0 || value[value.Length - 4] != 0)))
                throw new System.InvalidOperationException("Invalid USB property string.");
            var result = Encoding.Unicode.GetString(value).Split(new char[] { '\0' }, System.StringSplitOptions.RemoveEmptyEntries);
            if (!list && result.Length > 1) throw new System.InvalidOperationException("Invalid USB service property.");
            return result;
        }

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Get_Device_ID_List_SizeW(out uint length, string filter, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Get_Device_ID_ListW(string filter, [Out] char[] buffer, uint length, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Locate_DevNodeW(out uint device, string instanceId, uint flags);

        [DllImport("cfgmgr32.dll", ExactSpelling = true)]
        public static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint device, uint flags);

        [DllImport("cfgmgr32.dll", ExactSpelling = true)]
        public static extern uint CM_Get_Parent(out uint parent, uint device, uint flags);

        [DllImport("cfgmgr32.dll", ExactSpelling = true)]
        public static extern uint CM_Get_Child(out uint child, uint device, uint flags);

        [DllImport("cfgmgr32.dll", ExactSpelling = true)]
        public static extern uint CM_Get_Sibling(out uint sibling, uint device, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Get_Device_IDW(uint device, StringBuilder instanceId, uint length, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Request_Device_EjectW(uint device, out PnpVeto veto, StringBuilder name, uint length, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Get_Device_Interface_List_SizeW(out uint length, ref System.Guid classId, string instanceId, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint CM_Get_Device_Interface_ListW(ref System.Guid classId, string instanceId, [Out] char[] names, uint length, uint flags);
    }

    public static class GraphicsAdapter
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct OpenAdapter
        {
            [MarshalAs(UnmanagedType.LPWStr)]
            public string DevicePath;
            public uint Handle;
            public uint LuidLow;
            public int LuidHigh;
        }

        [DllImport("gdi32.dll", ExactSpelling = true)]
        public static extern int D3DKMTOpenAdapterFromDeviceName(ref OpenAdapter adapter);

        [DllImport("gdi32.dll", ExactSpelling = true)]
        public static extern int D3DKMTCloseAdapter(ref uint handle);
    }
}
'@
}

function Get-DeviceState([string]$InstanceId) {
    [uint32]$node = 0
    [uint32]$status = 0
    [uint32]$problem = 0
    $result = [EgpuHotplug.ConfigManager]::CM_Locate_DevNodeW([ref]$node, $InstanceId, 0)
    if ($result -eq 0) {
        $result = [EgpuHotplug.ConfigManager]::CM_Get_DevNode_Status([ref]$status, [ref]$problem, $node, 0)
    }
    if ($result -eq $noSuchDevNode) {
        return [pscustomobject]@{ Present = $false; Node = $null; Started = $false; Removable = $false; Problem = $null }
    }
    if ($result -ne 0) { throw ('无法读取设备状态，ConfigMgr 返回 0x{0:X}。请等设备稳定后重试。' -f $result) }

    return [pscustomobject]@{
        Present = $true
        Node = $node
        Started = ($status -band $startedFlag) -ne 0
        Removable = ($status -band $removableFlag) -ne 0
        Problem = $problem
    }
}

function Test-UnderDock([uint32]$Node, [uint32]$DockNode) {
    for ($depth = 0; $depth -lt 32; $depth++) {
        [uint32]$parent = 0
        $result = [EgpuHotplug.ConfigManager]::CM_Get_Parent([ref]$parent, $Node, 0)
        if ($result -ne 0) { return $false }
        if ($parent -eq $DockNode) { return $true }
        $Node = $parent
    }
    return $false
}

function Get-ChildInstanceIds([uint32]$Node) {
    [uint32]$child = 0
    $result = [EgpuHotplug.ConfigManager]::CM_Get_Child([ref]$child, $Node, 0)
    while ($result -eq 0) {
        $name = [Text.StringBuilder]::new(512)
        $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_IDW($child, $name, $name.Capacity, 0)
        if ($result -ne 0) { throw '无法识别坞上的外接设备，请等设备稳定后重试。' }
        $name.ToString()
        [uint32]$sibling = 0
        $result = [EgpuHotplug.ConfigManager]::CM_Get_Sibling([ref]$sibling, $child, 0)
        $child = $sibling
    }
    if ($result -ne $noSuchDevNode) { throw '无法检查坞上的外接设备，请等设备稳定后重试。' }
}

function Get-PresentA770InstanceIds {
    # CM_GETIDLIST_FILTER_ENUMERATOR | CM_GETIDLIST_FILTER_PRESENT, without WMI polling.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        [uint32]$length = 0
        $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_ID_List_SizeW([ref]$length, 'PCI', 0x101)
        if ($result -ne 0) { throw '无法枚举在线 PCI 设备，请等 Windows 完成设备识别后重试。' }
        $buffer = [char[]]::new([Math]::Max(2, $length))
        $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_ID_ListW('PCI', $buffer, $buffer.Length, 0x101)
        if ($result -eq 0) {
            return @(($buffer -join '') -split "`0" | Where-Object {
                $_ -match '^PCI\\VEN_8086&DEV_56A0(?:&|\\)'
            } | Sort-Object -Unique)
        }
        if ($result -ne 0x1A) { break } # CR_BUFFER_SMALL: retry if enumeration changed.
    }
    throw 'PCI 设备列表在识别期间发生变化，请等设备稳定后重试。'
}

function Get-ParentInstanceId([string]$InstanceId) {
    $state = Get-DeviceState $InstanceId
    if (!$state.Present) { throw '设备在自动识别期间离线，请等设备稳定后重试。' }
    [uint32]$parent = 0
    $result = [EgpuHotplug.ConfigManager]::CM_Get_Parent([ref]$parent, $state.Node, 0)
    if ($result -eq $noSuchDevNode) { return $null }
    if ($result -ne 0) { throw '无法读取设备的上游连接，请等设备稳定后重试。' }
    $name = [Text.StringBuilder]::new(512)
    $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_IDW($parent, $name, $name.Capacity, 0)
    if ($result -ne 0) { throw '无法识别设备的上游连接，请等设备稳定后重试。' }
    return $name.ToString()
}

function Get-ImmediateInstanceIds([string]$InstanceId) {
    $state = Get-DeviceState $InstanceId
    if (!$state.Present) { throw '设备在自动识别期间离线，请等设备稳定后重试。' }
    return @(Get-ChildInstanceIds $state.Node)
}

function Test-KnownGpuBranch([string]$BranchId, [string]$ExpectedGpuId) {
    # A770's onboard PCIe switch: 4FA0 -> two 4FA4 ports -> GPU 56A0 / audio 4F90.
    # Do not accept an arbitrary bridge or a sibling device on the cable being removed.
    $switches = @(Get-ImmediateInstanceIds $BranchId)
    if ($switches.Count -ne 1 -or $switches[0] -notmatch '^PCI\\VEN_8086&DEV_4FA0(?:&|\\)') { return $false }
    $ports = @(Get-ImmediateInstanceIds $switches[0])
    if ($ports.Count -ne 2 -or @($ports | Where-Object {
        $_ -notmatch '^PCI\\VEN_8086&DEV_4FA4(?:&|\\)'
    }).Count) { return $false }
    $endpoints = @()
    foreach ($port in $ports) {
        $devices = @(Get-ImmediateInstanceIds $port)
        if ($devices.Count -ne 1) { return $false }
        $endpoints += $devices[0]
    }
    $audio = @($endpoints | Where-Object { $_ -match '^PCI\\VEN_8086&DEV_4F90(?:&|\\)' })
    return $endpoints.Count -eq 2 -and $ExpectedGpuId -in $endpoints -and $audio.Count -eq 1
}

function Test-KnownUsbBranch([string]$BranchId, [string]$ExpectedHubId) {
    $controllers = @(Get-ImmediateInstanceIds $BranchId)
    if ($controllers.Count -ne 1 -or $controllers[0] -notmatch '^PCI\\VEN_8086&DEV_15F0(?:&|\\)') { return $false }
    $hubs = @(Get-ImmediateInstanceIds $controllers[0])
    return $hubs.Count -eq 1 -and $hubs[0] -eq $ExpectedHubId -and $ExpectedHubId -match '^USB\\ROOT_HUB30\\'
}

function Get-AutomaticConfiguration {
    $gpus = @(Get-PresentA770InstanceIds)
    if ($gpus.Count -eq 0) { return $null }
    if ($gpus.Count -ne 1) {
        throw '检测到多张在线 A770，无法自动选择。请用本机配置指定目标显卡坞。'
    }
    $chain = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current = $gpus[0]
    for ($depth = 0; $current -and $depth -lt 32; $depth++) {
        if (!$chain.Add($current)) { throw '检测到不完整的设备父子关系，无法自动选择显卡坞。' }
        $current = Get-ParentInstanceId $current
    }
    if ($current) { throw '设备层级超过自动识别范围，请使用本机配置。' }
    $dockMatches = [Collections.Generic.List[object]]::new()
    foreach ($ancestor in $chain) {
        if ($ancestor -notmatch '^PCI\\VEN_8086&DEV_15EF(?:&|\\)') { continue }
        $branches = @(Get-ImmediateInstanceIds $ancestor)
        # Known TH3P4G3 topology: three Intel 15EF branches, GPU / USB / spare TB port.
        if ($branches.Count -ne 3 -or @($branches | Where-Object {
            $_ -notmatch '^PCI\\VEN_8086&DEV_15EF(?:&|\\)'
        }).Count) { continue }
        $gpuBranches = @($branches | Where-Object { $chain.Contains($_) })
        if ($gpuBranches.Count -ne 1 -or !(Test-KnownGpuBranch $gpuBranches[0] $gpus[0])) { continue }
        $usbMatches = @()
        foreach ($branch in $branches | Where-Object { $_ -ne $gpuBranches[0] }) {
            $controllers = @(Get-ImmediateInstanceIds $branch)
            if ($controllers.Count -ne 1 -or $controllers[0] -notmatch '^PCI\\VEN_8086&DEV_15F0(?:&|\\)') { continue }
            $hubs = @(Get-ImmediateInstanceIds $controllers[0])
            if ($hubs.Count -ne 1 -or $hubs[0] -notmatch '^USB\\ROOT_HUB30\\') { continue }
            $usbMatches += [pscustomobject]@{ Branch = $branch; Hub = $hubs[0] }
        }
        if ($usbMatches.Count -ne 1) { continue }
        $spare = @($branches | Where-Object { $_ -ne $gpuBranches[0] -and $_ -ne $usbMatches[0].Branch })
        if ($spare.Count -ne 1) { continue }
        $dockMatches.Add(@{
            DockInstanceId = $ancestor
            GpuInstanceId = $gpus[0]
            UsbHubInstanceId = $usbMatches[0].Hub
            DownstreamPortInstanceId = $spare[0]
        })
    }
    if ($dockMatches.Count -ne 1) {
        throw '找到 A770，但无法唯一核对 TH3P4G3 的 GPU、USB 和下游端口拓扑。请等设备稳定后重试，或使用本机配置。'
    }
    return $dockMatches[0]
}

function Update-DeviceSelection {
    $selection = $manualConfig
    if (!$selection) { $selection = Get-AutomaticConfiguration }
    if (!$selection) { return $false }
    $script:dockId = $selection.DockInstanceId
    $script:arcId = $selection.GpuInstanceId
    $script:hubId = $selection.UsbHubInstanceId
    $script:extraPortId = $selection.DownstreamPortInstanceId
    return $true
}

function Get-UsbDeviceFacts([string]$InstanceId) {
    $state = Get-DeviceState $InstanceId
    if (!$state.Present -or !$state.Started -or $state.Problem -ne 0) {
        throw 'USB 设备尚未就绪。'
    }
    # Use nonlocalized properties, never a friendly-name / vendor-name heuristic.
    # HIDClass puts HID_DEVICE_SYSTEM_MOUSE in HardwareIds, not CompatibleIds.
    [pscustomobject]@{
        Node = $state.Node
        ClassGuid = [EgpuHotplug.ConfigManager]::ReadClassGuid($state.Node)
        Service = ([EgpuHotplug.ConfigManager]::ReadDeviceStrings($state.Node, 6, $false, $true) -join '')
        HardwareIds = @([EgpuHotplug.ConfigManager]::ReadDeviceStrings($state.Node, 3, $true, $false))
        CompatibleIds = @([EgpuHotplug.ConfigManager]::ReadDeviceStrings($state.Node, 4, $true, $true))
    }
}

function Get-UsbMouseTreeSnapshot([string]$RootId, [string]$ExpectedParentId) {
    $usbClass = '36fc9e60-c465-11cf-8056-444553540000'
    $hidClass = '745a17a0-74d3-11d0-b6fe-00a0c90f57da'
    $mouseClass = '4d36e96f-e325-11ce-bfc1-08002be10318'
    $keyboardClass = '4d36e96b-e325-11ce-bfc1-08002be10318'
    $softwareClass = '5c4c3332-344d-483c-8739-259e934c9cc8'
    $vendorMatch = [regex]::Match($RootId, '(?i)^USB\\VID_([0-9A-F]{4})&PID_[0-9A-F]{4}(?:&[^\\]+)?\\')
    if (!$vendorMatch.Success) { throw '无法识别 USB 鼠标设备根节点。' }
    $softwareIdPattern = '^SWC\\VID_' + $vendorMatch.Groups[1].Value + '&PID_[0-9A-F]{4}(?:&[A-Z0-9_]+)*$'
    $storageClasses = @('4d36e967-e325-11ce-bfc1-08002be10318', # DiskDrive
        '4d36e97b-e325-11ce-bfc1-08002be10318', # SCSIAdapter (including UASP)
        '71a27cdd-812a-11d0-bec7-08002be2092f', # Volume
        '4d36e965-e325-11ce-bfc1-08002be10318', # CDROM
        '53f5630d-b6bf-11d0-94f2-00a0c91efb8b') # Volume interface, defensive
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@{ Id = $RootId; Parent = $ExpectedParentId; ParentKind = 'RootHub'; Depth = 0 })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $records = [Collections.Generic.List[string]]::new()
    $hasMouse = $false
    while ($queue.Count) {
        $entry = $queue.Dequeue()
        if ($entry.Depth -gt 8 -or $seen.Count -ge 64 -or !$seen.Add($entry.Id)) {
            throw 'USB 子设备关系重复或超出可核对范围。'
        }
        if ((Get-ParentInstanceId $entry.Id) -ne $entry.Parent) { throw 'USB 连接关系已变化。' }
        $facts = Get-UsbDeviceFacts $entry.Id
        $children = @(Get-ChildInstanceIds $facts.Node | Sort-Object)
        $ids = @($facts.HardwareIds) + @($facts.CompatibleIds)
        if (!$facts.HardwareIds.Count -or
            $entry.Id -match '^(USBSTOR|SCSI|STORAGE)\\' -or
            $facts.Service -match '^(USBSTOR|UASPStor|disk|partmgr|volmgr|volsnap|cdrom|spaceport|stor.*)$' -or
            $facts.ClassGuid -in $storageClasses -or
            @($ids | Where-Object { $_ -match '^(USBSTOR|SCSI|STORAGE)\\|^USB\\(?:.*&)?Class_08(?:&|$)' }).Count) {
            throw 'USB 设备含存储功能，或缺少必需的识别信息。'
        }
        $kind = $null
        if ($entry.Id -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}(?:&[^\\]+)?\\') {
            if ($entry.ParentKind -eq 'RootHub' -and $facts.ClassGuid -eq $usbClass -and
                $facts.Service -eq 'usbccgp' -and 'USB\COMPOSITE' -in $facts.CompatibleIds -and $children.Count) {
                $kind = 'Composite'
            } elseif ($entry.ParentKind -in @('RootHub', 'Composite') -and $facts.ClassGuid -eq $hidClass -and
                $facts.Service -eq 'HidUsb' -and 'USB\Class_03' -in $facts.CompatibleIds -and $children.Count) {
                $kind = 'HidTransport'
            }
        } elseif ($entry.Id -match '^HID\\' -and $entry.ParentKind -eq 'HidTransport' -and !$children.Count -and
            'HID_DEVICE' -in $facts.HardwareIds) {
            if ($facts.ClassGuid -eq $mouseClass -and $facts.Service -eq 'mouhid' -and
                'HID_DEVICE_SYSTEM_MOUSE' -in $facts.HardwareIds) {
                $kind = 'MouseCollection'
                $hasMouse = $true
            } elseif ($facts.ClassGuid -eq $keyboardClass -and $facts.Service -eq 'kbdhid' -and
                'HID_DEVICE_SYSTEM_KEYBOARD' -in $facts.HardwareIds) {
                $kind = 'KeyboardCollection'
            } elseif ($facts.ClassGuid -eq $hidClass -and !$facts.Service -and
                @($facts.HardwareIds | Where-Object { $_ -match '^HID_DEVICE_UP:[0-9A-F]{4}_U:[0-9A-F]{4}$' }).Count) {
                # Standard HID consumer/vendor collections have no function service.
                # Custom drivers, unknown interfaces and hubs fail closed.
                $kind = 'HidCollection'
            }
        } elseif ($entry.Id -match '^SWD\\DRIVERENUM\\' -and $entry.ParentKind -eq 'HidTransport' -and
            $facts.ClassGuid -eq $softwareClass -and !$facts.Service -and !$children.Count -and
            !@($facts.HardwareIds | Where-Object { $_ -notmatch $softwareIdPattern }).Count -and
            $facts.CompatibleIds.Count -eq 3 -and 'SWC\Generic' -in $facts.CompatibleIds -and
            'SWD\GenericRaw' -in $facts.CompatibleIds -and 'SWD\Generic' -in $facts.CompatibleIds) {
            # Windows AddComponent creates virtual children to install associated
            # software. Permit only a healthy same-vendor leaf with no associated
            # function-driver service under a verified HidUsb interface; this does
            # not assert that its package has no Win32 services. Never exempt siblings.
            $kind = 'HidSoftwareLeaf'
        }
        if (!$kind) { throw 'USB 设备包含集线器、非标准驱动或尚未核对的功能。' }
        $after = Get-DeviceState $entry.Id
        if (!$after.Present -or !$after.Started -or $after.Problem -ne 0 -or $after.Node -ne $facts.Node) {
            throw 'USB 设备在核对时发生变化。'
        }
        $records.Add((@($entry.Id, $entry.Parent, $facts.Node, $kind, $facts.ClassGuid, $facts.Service,
            ($facts.HardwareIds -join ';'), ($facts.CompatibleIds -join ';'), ($children -join ';')) -join '|'))
        foreach ($child in $children) {
            $queue.Enqueue(@{ Id = $child; Parent = $entry.Id; ParentKind = $kind; Depth = $entry.Depth + 1 })
        }
    }
    if (!$hasMouse) { throw 'USB HID 设备没有可核对的标准鼠标功能。' }
    # Snapshot remains in memory and must never be printed or written to a public log.
    return ($records | Sort-Object) -join "`n"
}

function Assert-UsbMouseAccessory([string]$RootId, [string]$ExpectedParentId) {
    try {
        $first = Get-UsbMouseTreeSnapshot $RootId $ExpectedParentId
        $second = Get-UsbMouseTreeSnapshot $RootId $ExpectedParentId
        if ($first -cne $second) { throw 'USB 设备属性或子设备在核对时发生变化。' }
    } catch {
        # Do not expose unique device suffixes through native exceptions.
        throw '显卡坞 USB 上存在存储设备、非鼠标 HID 设备或无法完整核对的设备。请先单独安全移除并拔下这些设备，再重试；白名单不能跳过此检查。'
    }
}

function Assert-DockAccessories([uint32]$DockNode, [switch]$Report) {
    $hub = Get-DeviceState $hubId
    $port = Get-DeviceState $extraPortId
    if (!$hub.Started -or $hub.Problem -ne 0 -or !$port.Present -or
        !(Test-UnderDock $hub.Node $DockNode) -or !(Test-UnderDock $port.Node $DockNode)) {
        throw '无法核对这台坞的 USB 和下游端口，先保持雷电线连接。'
    }
    # This TH3P4G3 topology has three immediate branches: GPU, USB, and the spare port.
    $branches = @(Get-ChildInstanceIds $DockNode)
    if ($branches.Count -ne 3 -or $extraPortId -notin $branches) {
        throw '显卡坞的 PCIe 分支与预期不符，先保持雷电线连接。'
    }
    $arc = Get-DeviceState $arcId
    $gpuBranches = @($branches | Where-Object {
        $branchState = Get-DeviceState $_
        $branchState.Present -and $arc.Present -and (Test-UnderDock $arc.Node $branchState.Node)
    })
    $usbBranches = @($branches | Where-Object { $_ -ne $extraPortId -and $_ -notin $gpuBranches })
    if ($gpuBranches.Count -ne 1 -or $usbBranches.Count -ne 1 -or
        !(Test-KnownGpuBranch $gpuBranches[0] $arcId) -or !(Test-KnownUsbBranch $usbBranches[0] $hubId)) {
        throw '显卡坞的 GPU 或 USB 分支含有未核对的设备，先保持雷电线连接。'
    }
    $usbAccessories = @(Get-ChildInstanceIds $hub.Node | Sort-Object)
    foreach ($accessory in $usbAccessories) { Assert-UsbMouseAccessory $accessory $hubId }
    $otherThunderbolt = @(Get-ChildInstanceIds $port.Node)
    if ($otherThunderbolt.Count) {
        throw '显卡坞还有其他外接设备。请先单独安全移除并拔下这些设备，再重试。'
    }
    # A new direct child arriving during inspection must also be checked.
    if (($usbAccessories -join '|') -cne ((@(Get-ChildInstanceIds $hub.Node | Sort-Object)) -join '|')) {
        throw '核对期间显卡坞 USB 设备发生变化，请保持雷电线连接并重试。'
    }
    if ($Report -and $usbAccessories.Count) {
        Write-Host ("已自动核对并允许 {0} 个鼠标/HID 接收器及符合规则的软件组件。拔线后坞上鼠标将暂时不可用。" -f $usbAccessories.Count)
    }
}

function Get-AdapterLuid([string]$InstanceId) {
    # D3DKMTOpenAdapterFromDeviceName uses GUID_DISPLAY_DEVICE_ARRIVAL.
    $interfaceClass = [guid]'1ca05180-a699-450a-9a0c-de4fbe3ddd89'
    [uint32]$length = 0
    $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_Interface_List_SizeW(
        [ref]$length, [ref]$interfaceClass, $InstanceId, 0
    )
    if ($result -ne 0 -or $length -le 1) {
        throw ('无法定位 A770 的显示接口（0x{0:X}）。' -f $result)
    }
    $buffer = [char[]]::new($length)
    $result = [EgpuHotplug.ConfigManager]::CM_Get_Device_Interface_ListW(
        [ref]$interfaceClass, $InstanceId, $buffer, $length, 0
    )
    $paths = @(($buffer -join '') -split "`0" | Where-Object { $_ })
    if ($result -ne 0 -or $paths.Count -ne 1) {
        throw ('无法唯一识别 A770 的显示接口（0x{0:X}）。' -f $result)
    }

    $adapter = [EgpuHotplug.GraphicsAdapter+OpenAdapter]::new()
    $adapter.DevicePath = $paths[0]
    $result = [EgpuHotplug.GraphicsAdapter]::D3DKMTOpenAdapterFromDeviceName([ref]$adapter)
    if ($result -ne 0) { throw ('无法读取 A770 的显卡标识（0x{0:X8}）。' -f $result) }
    $handle = $adapter.Handle
    $result = [EgpuHotplug.GraphicsAdapter]::D3DKMTCloseAdapter([ref]$handle)
    if ($result -ne 0) { throw ('无法释放 A770 的查询句柄（0x{0:X8}）。' -f $result) }
    return ('0x{0:x8}_0x{1:x8}' -f $adapter.LuidHigh, $adapter.LuidLow)
}

function Get-AdapterProcessIds([string]$Luid) {
    # Dedicated memory catches paused apps. Shared memory alone can be adapter discovery.
    try {
        # Read whole counter classes. WQL filters can time out in the GPU provider.
        $memory = Get-CimInstance -ClassName Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory `
            -OperationTimeoutSec 10 | Where-Object DedicatedUsage -GT 0
        $engines = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine `
            -OperationTimeoutSec 10 | Where-Object UtilizationPercentage -GT 0
    } catch {
        throw "无法查询 A770 的进程占用，请保持雷电线连接并重试。$($_.Exception.Message)"
    }
    $pattern = '^pid_(\d+)_luid_' + [regex]::Escape($Luid) + '_phys_\d+(?:_|$)'
    @($memory; $engines) | ForEach-Object {
        if ($_.Name -match $pattern) { [int]$Matches[1] }
    } | Sort-Object -Unique
}

function Get-RecordedParent($Process, $ProcessById) {
    $parent = $ProcessById[[int]$Process.ParentProcessId]
    if ($parent -and $parent.ProcessId -ne $Process.ProcessId -and
        $parent.SessionId -eq $Process.SessionId -and $parent.CreationDate -le $Process.CreationDate) {
        return $parent
    }
}

function Get-ArcApplications([string]$Luid) {
    $processById = @{}
    Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,SessionId,CreationDate,ExecutablePath,Name `
        -OperationTimeoutSec 5 | ForEach-Object { $processById[[int]$_.ProcessId] = $_ }
    $self = $processById[$PID]
    if (!$self -or !$self.SessionId) { throw '请从当前 Windows 桌面会话运行热拔插脚本。' }
    $protected = [Collections.Generic.HashSet[int]]::new()
    for ($caller = $self; $caller -and $protected.Add([int]$caller.ProcessId);
        $caller = Get-RecordedParent $caller $processById) {}

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $windows = $env:SystemRoot.TrimEnd('\') + '\'
    $kryptexDirectory = Join-Path $env:ProgramFiles 'Kryptex'
    $kryptexController = Join-Path $kryptexDirectory 'Kryptex.exe'
    $kryptexService = Join-Path $kryptexDirectory 'KryptexService.exe'
    $minerDirectory = (Join-Path $env:APPDATA 'Kryptex\miners') + '\'
    # Intel's own telemetry clients can allocate memory without running a workload.
    $intelDirectory = Join-Path $env:ProgramFiles 'Intel\Intel Graphics Software'
    $intelTelemetry = @(
        (Join-Path $intelDirectory 'IntelGraphicsSoftware.Overlay.exe')
        (Join-Path $intelDirectory 'IntelGraphicsSoftware.Service.Graphics.exe')
    )
    $targets = @{}
    foreach ($processId in Get-AdapterProcessIds $Luid) {
        $client = $processById[$processId]
        if (!$client -or !$client.ExecutablePath -or $client.SessionId -ne $self.SessionId -or
            $client.ExecutablePath.StartsWith($windows, [StringComparison]::OrdinalIgnoreCase) -or
            $client.ExecutablePath -in $intelTelemetry -or
            $protected.Contains($processId)) { continue }

        $target = $client
        $parent = Get-RecordedParent $target $processById
        while ($parent -and $parent.ExecutablePath -eq $target.ExecutablePath) {
            $target = $parent
            $parent = Get-RecordedParent $target $processById
        }

        # End this mining app's controller and worker supervisor before its miner can respawn.
        if ($client.ExecutablePath.StartsWith($minerDirectory, [StringComparison]::OrdinalIgnoreCase) -and
            $parent.ExecutablePath -eq $kryptexService) {
            $controller = Get-RecordedParent $parent $processById
            if ($controller.ExecutablePath -eq $kryptexController) {
                $targets[[int]$controller.ProcessId] = $controller
            }
            $targets[[int]$parent.ProcessId] = $parent
        }
        $targets[[int]$target.ProcessId] = $target
    }

    foreach ($target in $targets.Values | Sort-Object CreationDate,ProcessId) {
        if ($protected.Contains([int]$target.ProcessId)) { continue }
        $owner = Invoke-CimMethod -InputObject $target -MethodName GetOwnerSid -WhatIf:$false -Confirm:$false `
            -ErrorAction SilentlyContinue
        if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $sid) {
            $target | Add-Member -NotePropertyName ForceIfWindow -NotePropertyValue ($target.ExecutablePath -eq $kryptexController) -PassThru
        }
    }
}

function Get-SameProcess($Target) {
    $process = Get-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue
    if (!$process) { return }
    try {
        # Keep a handle to this process while closing it, even if its PID is later reused.
        $null = $process.SafeHandle
        # CIM reports six decimal places, whereas StartTime can include 100 ns ticks.
        if ($process.HasExited -or [Math]::Abs(
            ($process.StartTime.ToUniversalTime() - $Target.CreationDate.ToUniversalTime()).Ticks
        ) -ge 10) {
            $process.Dispose()
            return
        }
        return $process
    } catch {
        $process.Dispose()
        if (Get-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue) { throw }
    }
}

function Stop-ArcApplications($Targets) {
    $open = [Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $Targets) {
            $process = Get-SameProcess $target
            if ($process) {
                $app = [pscustomobject]@{
                    Process = $process
                    HasWindow = $false
                    ForceIfWindow = $target.ForceIfWindow
                }
                $open.Add($app)
                $app.HasWindow = $process.MainWindowHandle -ne [IntPtr]::Zero
            }
        }
        foreach ($app in $open) {
            if ($app.HasWindow -and !$app.Process.HasExited) {
                Write-Host ("正在关闭 {0}（PID {1}）……" -f $app.Process.ProcessName, $app.Process.Id)
                $null = $app.Process.CloseMainWindow()
            }
        }
        $grace = [Diagnostics.Stopwatch]::StartNew()
        foreach ($app in $open | Where-Object HasWindow) {
            $remaining = [Math]::Max(0, 5000 - $grace.ElapsedMilliseconds)
            $null = $app.Process.WaitForExit([int]$remaining)
        }
        $pending = @($open | Where-Object {
            $_.HasWindow -and !$_.Process.HasExited -and !$_.ForceIfWindow -and !$ForceCloseApps
        })
        foreach ($app in $open) {
            $process = $app.Process
            if ($process.HasExited -or $app -in $pending) { continue }
            try {
                Write-Host ("正在结束后台或未退出的进程 {0}（PID {1}）……" -f $process.ProcessName, $process.Id)
                $process.Kill()
            } catch {
                if (!$process.HasExited) { throw }
            }
            if (!$process.WaitForExit(2000)) { throw "进程 $($process.Id) 尚未退出。请保持雷电线连接。" }
        }
        $stillOpen = @($pending | Where-Object { !$_.Process.HasExited })
        if ($stillOpen.Count) {
            $names = ($stillOpen.Process.ProcessName | Sort-Object -Unique) -join '、'
            throw "这些应用还未退出：$names。请保存并关闭窗口后重试。"
        }
    } finally {
        foreach ($app in $open) { $app.Process.Dispose() }
    }
}

function Show-Status {
    $selected = Update-DeviceSelection
    if (!$selected -and !$arcId) {
        Write-Host '当前未检测到在线 A770，无法自动定位显卡坞。插回雷电线后选择 2。'
        return
    }
    if ($manualConfig) { Write-Host '设备选择：本机配置。' }
    elseif ($selected) { Write-Host '已自动识别 A770 和 TH3P4G3 设备路径（仅保留在本次运行内存中）。' }
    else { Write-Host '当前未检测到在线 A770；以下为本次运行上次识别到的设备状态。' }
    $dock = Get-DeviceState $dockId
    $arc = Get-DeviceState $arcId
    $hub = Get-DeviceState $hubId
    Write-Host ("显卡坞在线 {0}，坞上 USB 根集线器已启动 {1}" -f $dock.Present, $hub.Started)
    if (!$arc.Present) {
        Write-Host 'Windows 当前未枚举到已核对的 A770。'
    } elseif (!$dock.Present -or !(Test-UnderDock $arc.Node $dock.Node)) {
        Write-Host '找到 A770，但设备路径与已核对的显卡坞不同。'
    } elseif ($arc.Problem -eq $heldForEject -and !$arc.Started) {
        Write-Host 'A770 已处于等待弹出状态（代码 47）。可选 1 核对拔线条件。'
    } else {
        Write-Host ("A770 驱动已启动 {0}，设备问题代码 {1}" -f $arc.Started, $arc.Problem)
    }
}

function Invoke-ArcEject {
    if (!(Update-DeviceSelection)) {
        throw '当前未检测到在线 A770，无法确认安全弹出。请保持雷电线连接并重试。'
    }
    $dock = Get-DeviceState $dockId
    $arc = Get-DeviceState $arcId
    if (!$dock.Started -or $dock.Problem -ne 0 -or !$arc.Present -or
        !(Test-UnderDock $arc.Node $dock.Node)) {
        throw '当前设备路径与已核对的 A770 和 TH3P4G3 不符，先保持雷电线连接。'
    }
    Assert-DockAccessories $dock.Node -Report

    if ($arc.Problem -ne $heldForEject -or $arc.Started) {
        if (!$arc.Started -or $arc.Problem -ne 0 -or !$arc.Removable) {
            throw "A770 当前无法安全弹出（设备问题代码 $($arc.Problem)），先保持雷电线连接。"
        }
        $luid = Get-AdapterLuid $arcId
        $targets = @(Get-ArcApplications $luid)
        if ($targets.Count) {
            $applications = ($targets | ForEach-Object { "$($_.Name)（PID $($_.ProcessId)）" }) -join '、'
            Write-Host "检测到需要关闭的应用或进程：$applications"
        } else {
            Write-Host '未发现需要自动结束的 A770 应用。'
        }
        if (!$PSCmdlet.ShouldProcess('Intel Arc A770（已核对的 TH3P4G3 下游）', '关闭占用应用并请求 Windows 安全弹出')) {
            return
        }
        for ($attempt = 0; $targets.Count -and $attempt -lt 3; $attempt++) {
            if ((Get-AdapterLuid $arcId) -ne $luid) { throw 'A770 的连接已变化，请保持雷电线连接并重试。' }
            Stop-ArcApplications $targets
            Start-Sleep -Milliseconds 750
            $targets = @(Get-ArcApplications $luid)
        }
        if ($targets.Count) {
            $names = ($targets.Name | Sort-Object -Unique) -join '、'
            throw "A770 仍被这些进程占用：$names。请关闭应用后重试。"
        }
        $dock = Get-DeviceState $dockId
        $arc = Get-DeviceState $arcId
        if (!$dock.Started -or $dock.Problem -ne 0 -or !$arc.Started -or $arc.Problem -ne 0 -or
            !$arc.Removable -or !(Test-UnderDock $arc.Node $dock.Node) -or (Get-AdapterLuid $arcId) -ne $luid) {
            throw '准备弹出时设备路径或状态已变化，请保持雷电线连接并重试。'
        }
        Assert-DockAccessories $dock.Node
        $name = [Text.StringBuilder]::new(260)
        $veto = [EgpuHotplug.PnpVeto]::Unknown
        $result = [EgpuHotplug.ConfigManager]::CM_Request_Device_EjectW(
            $arc.Node, [ref]$veto, $name, $name.Capacity, 0
        )
        if ($result -ne 0) {
            throw ('Windows 未批准弹出（0x{0:X}，{1} {2}）。请保留雷电线，检查占用或权限后重试。' -f $result, $veto, $name)
        }
    }

    # 等待已知的代码 47，避免把链路意外消失当作弹出成功。
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $arc = Get-DeviceState $arcId
        $dock = Get-DeviceState $dockId
        if (!$arc.Present -or !$dock.Started -or $dock.Problem -ne 0 -or
            !(Test-UnderDock $arc.Node $dock.Node)) {
            throw '等待确认时设备路径发生变化，无法确认安全弹出。'
        }
        if ($arc.Problem -eq $heldForEject -and !$arc.Started) {
            Assert-DockAccessories $dock.Node
            Write-Host 'Windows 已安全弹出 A770（代码 47）。现在可以拔显卡坞的雷电线。' -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt 10)
    throw '未等到 A770 的安全弹出确认（代码 47），先保持雷电线连接。'
}

function Wait-ArcConnection {
    Write-Host "等待 Windows 启动显卡坞和 A770，最多 $TimeoutSeconds 秒……"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $readySince = $null
    $lastDiscoveryError = $null
    $previousSelection = $null
    do {
        $ready = $false
        try {
            $selected = Update-DeviceSelection
            if ($selected) {
                $selectionKey = "$dockId|$arcId|$hubId|$extraPortId"
                if ($selectionKey -ne $previousSelection) { $readySince = $null }
                $previousSelection = $selectionKey
                $dock = Get-DeviceState $dockId
                $arc = Get-DeviceState $arcId
                $hub = Get-DeviceState $hubId
                $ready = $dock.Started -and $dock.Problem -eq 0 -and $arc.Started -and $arc.Problem -eq 0 -and
                    $hub.Started -and $hub.Problem -eq 0 -and (Test-UnderDock $arc.Node $dock.Node) -and
                    (Test-UnderDock $hub.Node $dock.Node)
            }
            $lastDiscoveryError = $null
        } catch {
            # Hotplug can invalidate a devnode between locating it and reading its status.
            $ready = $false
            $lastDiscoveryError = $_.Exception.Message
        }
        if ($ready) {
            if ($null -eq $readySince) { $readySince = $timer.Elapsed.TotalSeconds }
            if ($timer.Elapsed.TotalSeconds - $readySince -ge 5) {
                Write-Host '显卡坞和 A770 已连续就绪 5 秒。Windows 已启动 A770 驱动，设备代码为 0。' -ForegroundColor Green
                return
            }
        } else {
            $readySince = $null
        }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($lastDiscoveryError) { Write-Host $lastDiscoveryError -ForegroundColor Yellow }
    else { Show-Status }
    throw '未确认 A770 连续就绪。'
}

if ($Action -ne 'Menu') {
    switch ($Action) {
        'Status' { Show-Status }
        'Eject' { Invoke-ArcEject }
        'WaitForConnect' { Wait-ArcConnection }
    }
    return
}

while ($true) {
    Write-Host ''
    Write-Host 'TH3P4G3 / Arc A770 热插拔'
    Write-Host '1  自动关闭占用 A770 的应用并安全弹出'
    Write-Host '2  插回后确认'
    Write-Host '3  查看状态'
    Write-Host 'Q  退出'
    try {
        switch (Read-Host '选择') {
            '1' { Invoke-ArcEject }
            '2' { Wait-ArcConnection }
            '3' { Show-Status }
            'Q' { return }
            default { Write-Host '请选择 1、2、3 或 Q。' }
        }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}
