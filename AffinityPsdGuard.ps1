param(
    [string]$AnalyzePath,
    [string]$JsonOut,
    [string]$SanitizePath,
    [string]$SanitizedPsd
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

function Read-UInt16BE {
    param([System.IO.BinaryReader]$Reader)
    $bytes = $Reader.ReadBytes(2)
    if ($bytes.Length -ne 2) { throw "Unexpected end of file." }
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt16($bytes, 0)
}

function Read-Int16BE {
    param([System.IO.BinaryReader]$Reader)
    $bytes = $Reader.ReadBytes(2)
    if ($bytes.Length -ne 2) { throw "Unexpected end of file." }
    [Array]::Reverse($bytes)
    return [BitConverter]::ToInt16($bytes, 0)
}

function Read-UInt32BE {
    param([System.IO.BinaryReader]$Reader)
    $bytes = $Reader.ReadBytes(4)
    if ($bytes.Length -ne 4) { throw "Unexpected end of file." }
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Read-Int32BE {
    param([System.IO.BinaryReader]$Reader)
    $bytes = $Reader.ReadBytes(4)
    if ($bytes.Length -ne 4) { throw "Unexpected end of file." }
    [Array]::Reverse($bytes)
    return [BitConverter]::ToInt32($bytes, 0)
}

function Read-UInt64BE {
    param([System.IO.BinaryReader]$Reader)
    $bytes = $Reader.ReadBytes(8)
    if ($bytes.Length -ne 8) { throw "Unexpected end of file." }
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt64($bytes, 0)
}

function Write-UInt16BE {
    param([System.IO.BinaryWriter]$Writer, [UInt16]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    $Writer.Write($bytes)
}

function Write-Int16BE {
    param([System.IO.BinaryWriter]$Writer, [Int16]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    $Writer.Write($bytes)
}

function Write-UInt32BE {
    param([System.IO.BinaryWriter]$Writer, [UInt32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    $Writer.Write($bytes)
}

function Write-Bytes {
    param([System.IO.BinaryWriter]$Writer, [byte[]]$Bytes)
    if ($Bytes.Length -gt 0) {
        $Writer.Write($Bytes, 0, $Bytes.Length)
    }
}

function Read-Ascii {
    param([System.IO.BinaryReader]$Reader, [int]$Length)
    $bytes = $Reader.ReadBytes($Length)
    if ($bytes.Length -ne $Length) { throw "Unexpected end of file." }
    return [Text.Encoding]::ASCII.GetString($bytes)
}

function Skip-Bytes {
    param([System.IO.BinaryReader]$Reader, [UInt64]$Length)
    if ($Length -le 0) { return }
    $stream = $Reader.BaseStream
    $target = $stream.Position + [int64]$Length
    if ($target -gt $stream.Length) { throw "Unexpected end of file." }
    $stream.Position = $target
}

function Get-Pad2 {
    param([UInt64]$Value)
    if (($Value % 2) -eq 0) { return $Value }
    return $Value + 1
}

function Get-Pad4 {
    param([UInt64]$Value)
    return ($Value + 3) -band (-bnot 3)
}

function Read-PascalString4 {
    param([System.IO.BinaryReader]$Reader)
    $start = $Reader.BaseStream.Position
    $length = $Reader.ReadByte()
    $bytes = $Reader.ReadBytes($length)
    $consumed = $Reader.BaseStream.Position - $start
    $padded = Get-Pad4 $consumed
    if ($padded -gt $consumed) { Skip-Bytes $Reader ($padded - $consumed) }
    return ([Text.Encoding]::GetEncoding("iso-8859-1").GetString($bytes)).TrimEnd([char]0)
}

function Read-UnicodeLayerName {
    param([byte[]]$Data)
    if ($Data.Length -lt 4) { return $null }
    $countBytes = $Data[0..3]
    [Array]::Reverse($countBytes)
    $charCount = [BitConverter]::ToUInt32($countBytes, 0)
    $byteLength = [Math]::Min([int]($charCount * 2), $Data.Length - 4)
    if ($byteLength -le 0) { return $null }
    $raw = New-Object byte[] $byteLength
    [Array]::Copy($Data, 4, $raw, 0, $byteLength)
    for ($i = 0; $i -lt $raw.Length; $i += 2) {
        $tmp = $raw[$i]
        $raw[$i] = $raw[$i + 1]
        $raw[$i + 1] = $tmp
    }
    return ([Text.Encoding]::Unicode.GetString($raw)).TrimEnd([char]0)
}

function Get-TagLabel {
    param([string]$Key)
    switch ($Key) {
        "TySh" { "text layer"; break }
        "TySh2" { "text layer"; break }
        "vmsk" { "vector mask"; break }
        "vsms" { "vector mask"; break }
        "lfx2" { "layer effects"; break }
        "lmfx" { "layer effects"; break }
        "PlLd" { "placed/smart object"; break }
        "SoLd" { "placed/smart object"; break }
        "SoLE" { "placed/smart object"; break }
        "lsct" { "section divider"; break }
        "luni" { "unicode layer name"; break }
        default { "unknown"; break }
    }
}

function Read-TaggedBlocks {
    param(
        [System.IO.BinaryReader]$Reader,
        [int64]$End,
        [bool]$IsPsb
    )
    $tags = New-Object System.Collections.Generic.List[object]
    while (($Reader.BaseStream.Position + 12) -le $End) {
        $signature = Read-Ascii $Reader 4
        $key = Read-Ascii $Reader 4
        $length = if ($IsPsb) { Read-UInt64BE $Reader } else { Read-UInt32BE $Reader }
        $offset = $Reader.BaseStream.Position
        $data = $Reader.ReadBytes([int]$length)
        $padded = Get-Pad2 $length
        if ($padded -gt $length) { Skip-Bytes $Reader ($padded - $length) }
        $tags.Add([pscustomobject]@{
            Signature = $signature
            Key = $key
            Label = Get-TagLabel $key
            Length = [uint64]$length
            Offset = [int64]$offset
            Data = $data
        })
    }
    if ($Reader.BaseStream.Position -lt $End) {
        Skip-Bytes $Reader ($End - $Reader.BaseStream.Position)
    }
    return $tags
}

function Read-PsdDocument {
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        $signature = Read-Ascii $reader 4
        if ($signature -ne "8BPS") { throw "Not a PSD/PSB file: missing 8BPS signature." }

        $version = Read-UInt16BE $reader
        if (($version -ne 1) -and ($version -ne 2)) { throw "Unsupported PSD version: $version" }
        $isPsb = $version -eq 2

        Skip-Bytes $reader 6
        $channels = Read-UInt16BE $reader
        $height = Read-UInt32BE $reader
        $width = Read-UInt32BE $reader
        $depth = Read-UInt16BE $reader
        $colorMode = Read-UInt16BE $reader

        Skip-Bytes $reader (Read-UInt32BE $reader)
        Skip-Bytes $reader (Read-UInt32BE $reader)

        $layerMaskLength = if ($isPsb) { Read-UInt64BE $reader } else { Read-UInt32BE $reader }
        $layerMaskEnd = $reader.BaseStream.Position + [int64]$layerMaskLength
        $layers = New-Object System.Collections.Generic.List[object]

        if ($layerMaskLength -gt 0) {
            $layerInfoLength = if ($isPsb) { Read-UInt64BE $reader } else { Read-UInt32BE $reader }
            $layerInfoEnd = $reader.BaseStream.Position + [int64]$layerInfoLength

            if ($layerInfoLength -gt 0) {
                $layerCountRaw = Read-Int16BE $reader
                $mergedAlpha = $layerCountRaw -lt 0
                $layerCount = [Math]::Abs($layerCountRaw)

                for ($index = 0; $index -lt $layerCount; $index++) {
                    $top = Read-Int32BE $reader
                    $left = Read-Int32BE $reader
                    $bottom = Read-Int32BE $reader
                    $right = Read-Int32BE $reader
                    $channelCount = Read-UInt16BE $reader
                    $channelInfo = New-Object System.Collections.Generic.List[object]

                    for ($c = 0; $c -lt $channelCount; $c++) {
                        $channelInfo.Add([pscustomobject]@{
                            Id = Read-Int16BE $reader
                            Length = if ($isPsb) { Read-UInt64BE $reader } else { Read-UInt32BE $reader }
                        })
                    }

                    $blendSignature = Read-Ascii $reader 4
                    $blendMode = Read-Ascii $reader 4
                    $opacity = $reader.ReadByte()
                    $clipping = $reader.ReadByte()
                    $flags = $reader.ReadByte()
                    Skip-Bytes $reader 1

                    $extraLength = Read-UInt32BE $reader
                    $extraEnd = $reader.BaseStream.Position + [int64]$extraLength

                    $maskLength = Read-UInt32BE $reader
                    $mask = $null
                    if ($maskLength -gt 0) {
                        $maskEnd = $reader.BaseStream.Position + [int64]$maskLength
                        if ($maskLength -ge 20) {
                            $mask = [pscustomobject]@{
                                Top = Read-Int32BE $reader
                                Left = Read-Int32BE $reader
                                Bottom = Read-Int32BE $reader
                                Right = Read-Int32BE $reader
                                DefaultColor = $reader.ReadByte()
                                Flags = $reader.ReadByte()
                            }
                        }
                        if ($reader.BaseStream.Position -lt $maskEnd) { Skip-Bytes $reader ($maskEnd - $reader.BaseStream.Position) }
                    }

                    Skip-Bytes $reader (Read-UInt32BE $reader)
                    $name = Read-PascalString4 $reader
                    $tags = Read-TaggedBlocks $reader $extraEnd $isPsb
                    $unicodeTag = $tags | Where-Object { $_.Key -eq "luni" } | Select-Object -First 1
                    if ($unicodeTag) {
                        $unicodeName = Read-UnicodeLayerName $unicodeTag.Data
                        if ($unicodeName) { $name = $unicodeName }
                    }
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = "(Layer $($index + 1))" }

                    $layers.Add([pscustomobject]@{
                        Index = $index
                        Name = $name
                        Bounds = [pscustomobject]@{
                            Top = $top
                            Left = $left
                            Bottom = $bottom
                            Right = $right
                            Width = $right - $left
                            Height = $bottom - $top
                        }
                        ChannelInfo = $channelInfo
                        BlendSignature = $blendSignature
                        BlendMode = $blendMode
                        Opacity = $opacity
                        Clipping = $clipping
                        Flags = $flags
                        Hidden = (($flags -band 2) -ne 0)
                        Mask = $mask
                        Tags = @($tags | ForEach-Object {
                            [pscustomobject]@{
                                Key = $_.Key
                                Label = $_.Label
                                Length = $_.Length
                                Offset = $_.Offset
                            }
                        })
                    })
                }

                foreach ($layer in $layers) {
                    foreach ($channel in $layer.ChannelInfo) {
                        Skip-Bytes $reader $channel.Length
                    }
                }

                if ($reader.BaseStream.Position -lt $layerInfoEnd) {
                    Skip-Bytes $reader ($layerInfoEnd - $reader.BaseStream.Position)
                }

                return [pscustomobject]@{
                    FileType = if ($isPsb) { "PSB" } else { "PSD" }
                    Header = [pscustomobject]@{
                        Width = $width
                        Height = $height
                        Channels = $channels
                        Depth = $depth
                        ColorMode = $colorMode
                        MergedAlpha = $mergedAlpha
                    }
                    Layers = $layers
                }
            }
        }

        $reader.BaseStream.Position = $layerMaskEnd
        return [pscustomobject]@{
            FileType = if ($isPsb) { "PSB" } else { "PSD" }
            Header = [pscustomobject]@{
                Width = $width
                Height = $height
                Channels = $channels
                Depth = $depth
                ColorMode = $colorMode
                MergedAlpha = $false
            }
            Layers = $layers
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-Finding {
    param([string]$Severity, $Layer, [string]$Message, $Detail)
    return [pscustomobject]@{
        Severity = $Severity
        Layer = if ($Layer) { [pscustomobject]@{ Index = $Layer.Index; Name = $Layer.Name } } else { $null }
        Message = $Message
        Detail = $Detail
    }
}

function Get-PsdFindings {
    param($Document)
    $findings = New-Object System.Collections.Generic.List[object]

    foreach ($layer in $Document.Layers) {
        $b = $layer.Bounds
        if (($b.Left -lt 0) -or ($b.Top -lt 0) -or ($b.Right -gt $Document.Header.Width) -or ($b.Bottom -gt $Document.Header.Height)) {
            $findings.Add((New-Finding "medium" $layer "Layer extends outside the canvas" $b))
        }
        if (($b.Width -lt 0) -or ($b.Height -lt 0)) {
            $findings.Add((New-Finding "high" $layer "Layer has invalid bounds" $b))
        }
        if ($layer.Mask) {
            $findings.Add((New-Finding "medium" $layer "Layer mask has independent bounds" $layer.Mask))
        }

        $keys = @($layer.Tags | ForEach-Object { $_.Key })
        if (($keys -contains "PlLd") -or ($keys -contains "SoLd") -or ($keys -contains "SoLE")) {
            $findings.Add((New-Finding "high" $layer "Placed/smart object layer may use Photoshop transform data" ($layer.Tags | Where-Object { $_.Label -eq "placed/smart object" })))
        }
        if (($keys -contains "vmsk") -or ($keys -contains "vsms")) {
            $findings.Add((New-Finding "high" $layer "Vector mask can shift or clip differently outside Photoshop" ($layer.Tags | Where-Object { $_.Label -eq "vector mask" })))
        }
        if (($keys -contains "lfx2") -or ($keys -contains "lmfx")) {
            $findings.Add((New-Finding "medium" $layer "Layer effects may render differently in Affinity" ($layer.Tags | Where-Object { $_.Label -eq "layer effects" })))
        }
        if (($keys -contains "TySh") -or ($keys -contains "TySh2")) {
            $findings.Add((New-Finding "medium" $layer "Text layer uses Photoshop text engine data" ($layer.Tags | Where-Object { $_.Label -eq "text layer" })))
        }
        if ($keys -contains "lsct") {
            $findings.Add((New-Finding "low" $layer "Group/section layer" ($layer.Tags | Where-Object { $_.Key -eq "lsct" })))
        }
    }

    return $findings
}

function Format-PsdReport {
    param([string]$Path, $Document, $Findings)

    $high = @($Findings | Where-Object { $_.Severity -eq "high" }).Count
    $medium = @($Findings | Where-Object { $_.Severity -eq "medium" }).Count
    $low = @($Findings | Where-Object { $_.Severity -eq "low" }).Count

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Affinity PSD Guard report: $(Split-Path $Path -Leaf)")
    $lines.Add("Type: $($Document.FileType)")
    $lines.Add("Canvas: $($Document.Header.Width) x $($Document.Header.Height), $($Document.Header.Depth)-bit, $($Document.Header.Channels) channels")
    $lines.Add("Layers: $($Document.Layers.Count)")
    $lines.Add("Findings: high=$high, medium=$medium, low=$low")
    $lines.Add("")

    if ($Findings.Count -eq 0) {
        $lines.Add("No common layer-offset risks found in the PSD layer metadata.")
    } else {
        foreach ($finding in $Findings) {
            $where = if ($finding.Layer) { "Layer $($finding.Layer.Index + 1) `"$($finding.Layer.Name)`"" } else { "Document" }
            $lines.Add("[$($finding.Severity)] ${where}: $($finding.Message)")
        }
    }

    $lines.Add("")
    $lines.Add("Layer bounds:")
    foreach ($layer in $Document.Layers) {
        $b = $layer.Bounds
        $lines.Add("- $($layer.Index + 1). $($layer.Name): left=$($b.Left), top=$($b.Top), right=$($b.Right), bottom=$($b.Bottom), blend=$($layer.BlendMode), hidden=$($layer.Hidden)")
    }

    return ($lines -join [Environment]::NewLine)
}

function Invoke-PsdAnalysis {
    param([string]$Path)
    $document = Read-PsdDocument $Path
    $findings = @(Get-PsdFindings $document)
    return [pscustomobject]@{
        Input = (Resolve-Path $Path).Path
        Document = $document
        Findings = $findings
        Text = Format-PsdReport $Path $document $findings
    }
}

function Copy-BytesFromReader {
    param([System.IO.BinaryReader]$Reader, [int64]$Length)
    if ($Length -lt 0) { throw "Invalid byte range length." }
    $bytes = $Reader.ReadBytes([int]$Length)
    if ($bytes.Length -ne $Length) { throw "Unexpected end of file." }
    return $bytes
}

function Sanitize-PsdSmartObjects {
    param(
        [string]$InputPath,
        [string]$OutputPath
    )

    if (-not (Test-Path $InputPath)) { throw "PSD file not found: $InputPath" }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $folder = Split-Path $InputPath -Parent
        $name = [IO.Path]::GetFileNameWithoutExtension($InputPath)
        $OutputPath = Join-Path $folder "$name.affinity-v3-safe.psd"
    }
    if ([IO.Path]::GetExtension($OutputPath).ToLowerInvariant() -ne ".psd") {
        $OutputPath = "$OutputPath.psd"
    }
    $OutputPath = Get-AvailableOutputPath $OutputPath

    $removeKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($key in @("PlLd", "SoLd", "SoLE")) { [void]$removeKeys.Add($key) }

    $input = [IO.File]::Open($InputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.BinaryReader]::new($input)
        $outStream = [IO.MemoryStream]::new()
        $writer = [IO.BinaryWriter]::new($outStream)

        $signature = Read-Ascii $reader 4
        if ($signature -ne "8BPS") { throw "Not a PSD file." }
        $version = Read-UInt16BE $reader
        if ($version -ne 1) { throw "Only standard PSD files are supported by the sanitizer. PSB is not supported yet." }

        Write-Bytes $writer ([Text.Encoding]::ASCII.GetBytes("8BPS"))
        Write-UInt16BE $writer ([UInt16]$version)
        Write-Bytes $writer (Copy-BytesFromReader $reader 20)

        $colorLength = Read-UInt32BE $reader
        Write-UInt32BE $writer $colorLength
        Write-Bytes $writer (Copy-BytesFromReader $reader $colorLength)

        $resourceLength = Read-UInt32BE $reader
        Write-UInt32BE $writer $resourceLength
        Write-Bytes $writer (Copy-BytesFromReader $reader $resourceLength)

        $layerMaskLength = Read-UInt32BE $reader
        if ($layerMaskLength -eq 0) {
            Write-UInt32BE $writer 0
            Write-Bytes $writer (Copy-BytesFromReader $reader ($reader.BaseStream.Length - $reader.BaseStream.Position))
            [IO.File]::WriteAllBytes($OutputPath, $outStream.ToArray())
            return [pscustomobject]@{ OutputPath = (Resolve-Path $OutputPath).Path; RemovedBlocks = 0; LayersChanged = 0 }
        }

        $layerMaskEnd = $reader.BaseStream.Position + [int64]$layerMaskLength
        $layerInfoLength = Read-UInt32BE $reader
        $layerInfoEnd = $reader.BaseStream.Position + [int64]$layerInfoLength

        $newLayerInfoStream = [IO.MemoryStream]::new()
        $liWriter = [IO.BinaryWriter]::new($newLayerInfoStream)
        $removedBlocks = 0
        $layersChanged = 0

        if ($layerInfoLength -gt 0) {
            $layerCountRaw = Read-Int16BE $reader
            Write-Int16BE $liWriter ([Int16]$layerCountRaw)
            $layerCount = [Math]::Abs($layerCountRaw)
            $channelLengthLists = New-Object System.Collections.Generic.List[object]

            for ($i = 0; $i -lt $layerCount; $i++) {
                Write-Bytes $liWriter (Copy-BytesFromReader $reader 16)
                $channelCount = Read-UInt16BE $reader
                Write-UInt16BE $liWriter $channelCount
                $lengths = New-Object System.Collections.Generic.List[UInt32]
                for ($c = 0; $c -lt $channelCount; $c++) {
                    $channelId = Read-Int16BE $reader
                    $channelLength = Read-UInt32BE $reader
                    Write-Int16BE $liWriter $channelId
                    Write-UInt32BE $liWriter $channelLength
                    $lengths.Add($channelLength)
                }
                $channelLengthLists.Add($lengths)

                Write-Bytes $liWriter (Copy-BytesFromReader $reader 12)
                $extraLength = Read-UInt32BE $reader
                $extraEnd = $reader.BaseStream.Position + [int64]$extraLength

                $extraStream = [IO.MemoryStream]::new()
                $extraWriter = [IO.BinaryWriter]::new($extraStream)
                $layerChanged = $false

                $maskLength = Read-UInt32BE $reader
                Write-UInt32BE $extraWriter $maskLength
                Write-Bytes $extraWriter (Copy-BytesFromReader $reader $maskLength)

                $blendLength = Read-UInt32BE $reader
                Write-UInt32BE $extraWriter $blendLength
                Write-Bytes $extraWriter (Copy-BytesFromReader $reader $blendLength)

                $nameStart = $reader.BaseStream.Position
                $nameLength = $reader.ReadByte()
                $reader.BaseStream.Position = $nameStart
                $nameBlockLength = Get-Pad4 (1 + $nameLength)
                Write-Bytes $extraWriter (Copy-BytesFromReader $reader $nameBlockLength)

                while (($reader.BaseStream.Position + 12) -le $extraEnd) {
                    $signatureBytes = Copy-BytesFromReader $reader 4
                    $keyBytes = Copy-BytesFromReader $reader 4
                    $key = [Text.Encoding]::ASCII.GetString($keyBytes)
                    $tagLength = Read-UInt32BE $reader
                    $tagData = Copy-BytesFromReader $reader $tagLength
                    $pad = (Get-Pad2 $tagLength) - $tagLength
                    $padBytes = if ($pad -gt 0) { Copy-BytesFromReader $reader $pad } else { [byte[]]@() }

                    if ($removeKeys.Contains($key)) {
                        $removedBlocks += 1
                        $layerChanged = $true
                    } else {
                        Write-Bytes $extraWriter $signatureBytes
                        Write-Bytes $extraWriter $keyBytes
                        Write-UInt32BE $extraWriter $tagLength
                        Write-Bytes $extraWriter $tagData
                        if ($padBytes.Length -gt 0) { Write-Bytes $extraWriter $padBytes }
                    }
                }

                if ($reader.BaseStream.Position -lt $extraEnd) {
                    Write-Bytes $extraWriter (Copy-BytesFromReader $reader ($extraEnd - $reader.BaseStream.Position))
                }

                if ($layerChanged) { $layersChanged += 1 }
                $newExtra = $extraStream.ToArray()
                Write-UInt32BE $liWriter ([UInt32]$newExtra.Length)
                Write-Bytes $liWriter $newExtra
            }

            foreach ($lengths in $channelLengthLists) {
                foreach ($length in $lengths) {
                    Write-Bytes $liWriter (Copy-BytesFromReader $reader $length)
                }
            }

            if ($reader.BaseStream.Position -lt $layerInfoEnd) {
                Write-Bytes $liWriter (Copy-BytesFromReader $reader ($layerInfoEnd - $reader.BaseStream.Position))
            }
        }

        $newLayerInfo = $newLayerInfoStream.ToArray()
        $remainingLayerMask = Copy-BytesFromReader $reader ($layerMaskEnd - $reader.BaseStream.Position)
        $newLayerMaskLength = 4 + $newLayerInfo.Length + $remainingLayerMask.Length

        Write-UInt32BE $writer ([UInt32]$newLayerMaskLength)
        Write-UInt32BE $writer ([UInt32]$newLayerInfo.Length)
        Write-Bytes $writer $newLayerInfo
        Write-Bytes $writer $remainingLayerMask
        Write-Bytes $writer (Copy-BytesFromReader $reader ($reader.BaseStream.Length - $reader.BaseStream.Position))

        [IO.File]::WriteAllBytes($OutputPath, $outStream.ToArray())
        return [pscustomobject]@{
            OutputPath = (Resolve-Path $OutputPath).Path
            RemovedBlocks = $removedBlocks
            LayersChanged = $layersChanged
        }
    }
    finally {
        $input.Dispose()
    }
}

function Find-FirstExistingPath {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($path)
        if (Test-Path $expanded) { return (Resolve-Path $expanded).Path }
    }
    return $null
}

function Find-AffinityV3 {
    return Find-FirstExistingPath @(
        "C:\Program Files\Affinity\Affinity\Affinity.exe",
        "%LOCALAPPDATA%\Microsoft\WindowsApps\Affinity.exe"
    )
}

function Get-DefaultSafePsdPath {
    param([string]$PsdPath)
    if ([string]::IsNullOrWhiteSpace($PsdPath)) { return "" }
    $folder = Split-Path $PsdPath -Parent
    $name = [IO.Path]::GetFileNameWithoutExtension($PsdPath)
    return Join-Path $folder "$name.affinity-v3-safe.psd"
}

function Get-AvailableOutputPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $Path }
    $folder = Split-Path $Path -Parent
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [IO.Path]::GetExtension($Path)
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $folder "$name-$stamp$extension"
}

if ($SanitizePath) {
    $result = Sanitize-PsdSmartObjects -InputPath $SanitizePath -OutputPath $SanitizedPsd
    "Created: $($result.OutputPath)"
    "Removed smart object blocks: $($result.RemovedBlocks)"
    "Layers changed: $($result.LayersChanged)"
    exit 0
}

if ($AnalyzePath) {
    $result = Invoke-PsdAnalysis $AnalyzePath
    $result.Text
    if ($JsonOut) {
        $json = $result | Select-Object Input, Document, Findings | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($JsonOut), $json, [Text.Encoding]::UTF8)
    }
    if (@($result.Findings | Where-Object { $_.Severity -eq "high" }).Count -gt 0) {
        exit 1
    }
    exit 0
}

$form = [Windows.Forms.Form]::new()
$form.Text = "Affinity PSD Guard"
$form.Size = [Drawing.Size]::new(980, 680)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = [Drawing.Size]::new(760, 500)
$form.AllowDrop = $true

$pathBox = [Windows.Forms.TextBox]::new()
$pathBox.Anchor = "Top,Left,Right"
$pathBox.Location = [Drawing.Point]::new(16, 18)
$pathBox.Size = [Drawing.Size]::new(580, 28)

$browseButton = [Windows.Forms.Button]::new()
$browseButton.Anchor = "Top,Right"
$browseButton.Text = "Open PSD"
$browseButton.Location = [Drawing.Point]::new(608, 16)
$browseButton.Size = [Drawing.Size]::new(110, 32)

$analyzeButton = [Windows.Forms.Button]::new()
$analyzeButton.Anchor = "Top,Right"
$analyzeButton.Text = "Analyze"
$analyzeButton.Location = [Drawing.Point]::new(728, 16)
$analyzeButton.Size = [Drawing.Size]::new(96, 32)

$convertButton = [Windows.Forms.Button]::new()
$convertButton.Anchor = "Top,Right"
$convertButton.Text = "Sanitize PSD"
$convertButton.Location = [Drawing.Point]::new(832, 16)
$convertButton.Size = [Drawing.Size]::new(112, 32)

$outputLabel = [Windows.Forms.Label]::new()
$outputLabel.Location = [Drawing.Point]::new(16, 58)
$outputLabel.Size = [Drawing.Size]::new(82, 22)
$outputLabel.Text = "Output"

$outputBox = [Windows.Forms.TextBox]::new()
$outputBox.Anchor = "Top,Left,Right"
$outputBox.Location = [Drawing.Point]::new(104, 54)
$outputBox.Size = [Drawing.Size]::new(840, 28)

$statusLabel = [Windows.Forms.Label]::new()
$statusLabel.Anchor = "Top,Left,Right"
$statusLabel.Location = [Drawing.Point]::new(16, 90)
$statusLabel.Size = [Drawing.Size]::new(928, 22)
$statusLabel.Text = "Select a PSD file. Use Sanitize PSD to remove smart object metadata for Affinity v3."

$reportBox = [Windows.Forms.TextBox]::new()
$reportBox.Anchor = "Top,Bottom,Left,Right"
$reportBox.Location = [Drawing.Point]::new(16, 120)
$reportBox.Size = [Drawing.Size]::new(928, 460)
$reportBox.Multiline = $true
$reportBox.ScrollBars = "Both"
$reportBox.WordWrap = $false
$reportBox.Font = [Drawing.Font]::new("Consolas", 10)

$saveJsonButton = [Windows.Forms.Button]::new()
$saveJsonButton.Anchor = "Bottom,Right"
$saveJsonButton.Text = "Save JSON"
$saveJsonButton.Location = [Drawing.Point]::new(820, 592)
$saveJsonButton.Size = [Drawing.Size]::new(124, 32)
$saveJsonButton.Enabled = $false

$currentResult = $null

$runAnalysis = {
    if (-not (Test-Path $pathBox.Text)) {
        [Windows.Forms.MessageBox]::Show("Please select a PSD/PSB file.", "Affinity PSD Guard", "OK", "Warning") | Out-Null
        return
    }

    try {
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = "Analyzing..."
        $script:currentResult = Invoke-PsdAnalysis $pathBox.Text
        $reportBox.Text = $script:currentResult.Text
        $high = @($script:currentResult.Findings | Where-Object { $_.Severity -eq "high" }).Count
        $statusLabel.Text = if ($high -gt 0) { "Found $high high-risk item(s). Rasterize or simplify those layers before opening in Affinity." } else { "Analysis complete." }
        $saveJsonButton.Enabled = $true
    }
    catch {
        $reportBox.Text = "Error: $($_.Exception.Message)"
        $statusLabel.Text = "Analysis failed."
        $saveJsonButton.Enabled = $false
    }
    finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

$browseButton.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = "Photoshop files (*.psd;*.psb)|*.psd;*.psb|All files (*.*)|*.*"
    $dialog.Title = "Select a PSD/PSB file"
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = $dialog.FileName
        $outputBox.Text = Get-DefaultSafePsdPath $dialog.FileName
        & $runAnalysis
    }
})

$analyzeButton.Add_Click($runAnalysis)

$convertButton.Add_Click({
    if (-not (Test-Path $pathBox.Text)) {
        [Windows.Forms.MessageBox]::Show("Please select a PSD/PSB file.", "Affinity PSD Guard", "OK", "Warning") | Out-Null
        return
    }
    try {
        if ([string]::IsNullOrWhiteSpace($outputBox.Text)) {
            $outputBox.Text = Get-DefaultSafePsdPath $pathBox.Text
        }
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = "Creating Affinity v3 safe PSD..."
        $result = Sanitize-PsdSmartObjects -InputPath $pathBox.Text -OutputPath $outputBox.Text
        $outputBox.Text = $result.OutputPath
        $statusLabel.Text = "Created safe PSD. Removed $($result.RemovedBlocks) smart object block(s) from $($result.LayersChanged) layer(s)."
        $v3 = Find-AffinityV3
        if ($v3 -and (Test-Path $v3)) {
            Start-Process -FilePath $v3 -ArgumentList "`"$($result.OutputPath)`"" | Out-Null
        }
    }
    catch {
        $statusLabel.Text = "PSD sanitize failed."
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Affinity PSD Guard", "OK", "Error") | Out-Null
    }
    finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
})

$saveJsonButton.Add_Click({
    if (-not $script:currentResult) { return }
    $dialog = [Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter = "JSON report (*.json)|*.json|All files (*.*)|*.*"
    $dialog.Title = "Save JSON report"
    $dialog.FileName = "$(Split-Path $script:currentResult.Input -Leaf).affinity-psd-report.json"
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $json = $script:currentResult | Select-Object Input, Document, Findings | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($dialog.FileName, $json, [Text.Encoding]::UTF8)
        $statusLabel.Text = "JSON saved: $($dialog.FileName)"
    }
})

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
})

$form.Add_DragDrop({
    $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($files.Count -gt 0) {
        $pathBox.Text = $files[0]
        $outputBox.Text = Get-DefaultSafePsdPath $files[0]
        & $runAnalysis
    }
})

$pathBox.Add_TextChanged({
    if ((Test-Path $pathBox.Text) -and [string]::IsNullOrWhiteSpace($outputBox.Text)) {
        $outputBox.Text = Get-DefaultSafePsdPath $pathBox.Text
    }
})

$form.Controls.AddRange(@($pathBox, $browseButton, $analyzeButton, $convertButton, $outputLabel, $outputBox, $statusLabel, $reportBox, $saveJsonButton))
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::Run($form)
