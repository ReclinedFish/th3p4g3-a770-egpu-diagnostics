#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.2.0',
    [string]$OutputDirectory,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $repositoryRoot) 'release-artifacts'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$archiveName = "th3p4g3-a770-tools-v$Version.zip"
$archivePath = Join-Path $outputRoot $archiveName
$checksumPath = "$archivePath.sha256"

# Explicit paths only: never recursively copy a workspace or user's configuration.
# Keep the quickstart both at the ZIP root and at its source-tree path.
$files = [ordered]@{
    'README.md' = 'tools/README.md'
    'assets/hotplug-console.png' = 'assets/hotplug-console.png'
    'assets/receiver-in-dock-usb-a.png' = 'assets/receiver-in-dock-usb-a.png'
    'assets/receiver-in-dock-usb-a.prompt.md' = 'assets/receiver-in-dock-usb-a.prompt.md'
    "docs/release-v$Version.md" = "docs/release-v$Version.md"
    'tools/Build-Release.ps1' = 'tools/Build-Release.ps1'
    'tools/Dx11ArcBatched/Dx11ArcBatched.csproj' = 'tools/Dx11ArcBatched/Dx11ArcBatched.csproj'
    'tools/Dx11ArcBatched/Program.cs' = 'tools/Dx11ArcBatched/Program.cs'
    'tools/LICENSE' = 'tools/LICENSE'
    'tools/README.md' = 'tools/README.md'
    'tools/Test-Dx11Wake.ps1' = 'tools/Test-Dx11Wake.ps1'
    'tools/Watch-EgpuLink.ps1' = 'tools/Watch-EgpuLink.ps1'
    'tools/eGPU-Hotplug.cmd' = 'tools/eGPU-Hotplug.cmd'
    'tools/eGPU-Hotplug.example.json' = 'tools/eGPU-Hotplug.example.json'
    'tools/eGPU-Hotplug.ps1' = 'tools/eGPU-Hotplug.ps1'
}

foreach ($source in $files.Values) {
    $item = Get-Item -LiteralPath (Join-Path $repositoryRoot $source) -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Release input must be a regular file: $source"
    }
}
if (!$Force -and ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $checksumPath))) {
    throw 'Release artifacts already exist. Select another output directory or use -Force to rebuild.'
}

[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$stream = [IO.File]::Open($archivePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        # Fixed order, timestamps, and attributes exclude host metadata. With the
        # same input bytes and .NET runtime, rebuilding produces the same ZIP.
        foreach ($destination in $files.Keys) {
            $entry = $zip.CreateEntry($destination, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $inputStream = [IO.File]::OpenRead((Join-Path $repositoryRoot $files[$destination]))
            try {
                $entryStream = $entry.Open()
                try { $inputStream.CopyTo($entryStream) } finally { $entryStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }

$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumPath, "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Archive = $archivePath
    Checksum = $checksumPath
    SHA256 = $hash
    Files = $files.Count
}
