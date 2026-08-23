# Ba2.ps1 - reading Bethesda BA2 archives.
#
# Why this exists: plenty of face mods ship their textures inside a BA2, and the
# V3 script only ever looked at loose files. A mod with a 512 specular in an
# archive stayed broken and the user got no warning at all.
#
# Archives are NEVER repacked. For DX10 archives the width, height and DXGI format
# sit in the file table itself, so a mismatch can be reported without unpacking a
# single byte. When a texture actually needs fixing it is extracted, converted and
# written as a LOOSE file into the output mod - loose files win over archives in
# Fallout 4, so the original mod stays untouched.
#
# Format (BTDX version 1):
#   header      : "BTDX", uint32 version, "GNRL"|"DX10", uint32 numFiles,
#                 uint64 nameTableOffset
#   GNRL record : nameHash, char[4] ext, dirHash, flags, uint64 offset,
#                 uint32 packed, uint32 unpacked, uint32 align       (36 bytes)
#   DX10 record : nameHash, char[4] ext, dirHash, uint8 unk, uint8 numChunks,
#                 uint16 chunkHdrSize, uint16 height, uint16 width, uint8 numMips,
#                 uint8 format, uint8 isCubemap, uint8 tileMode      (24 bytes)
#                 followed by numChunks * (uint64 offset, uint32 packed,
#                 uint32 unpacked, uint16 startMip, uint16 endMip, uint32 align)
#   name table  : per file uint16 length + ASCII path

$script:BffDxgiFormatNames = @{
    0  = 'UNKNOWN';            2  = 'R32G32B32A32_FLOAT'; 10 = 'R16G16B16A16_FLOAT'
    11 = 'R16G16B16A16_UNORM'; 24 = 'R10G10B10A2_UNORM';  28 = 'R8G8B8A8_UNORM'
    29 = 'R8G8B8A8_UNORM_SRGB'; 31 = 'R8G8B8A8_SNORM';    41 = 'R32_FLOAT'
    49 = 'R8G8_UNORM';         54 = 'R16_FLOAT';          56 = 'R16_UNORM'
    61 = 'R8_UNORM';           65 = 'A8_UNORM'
    71 = 'BC1_UNORM';          72 = 'BC1_UNORM_SRGB'
    74 = 'BC2_UNORM';          75 = 'BC2_UNORM_SRGB'
    77 = 'BC3_UNORM';          78 = 'BC3_UNORM_SRGB'
    80 = 'BC4_UNORM';          81 = 'BC4_SNORM'
    83 = 'BC5_UNORM';          84 = 'BC5_SNORM'
    87 = 'B8G8R8A8_UNORM';     88 = 'B8G8R8X8_UNORM'
    91 = 'B8G8R8A8_UNORM_SRGB'
    95 = 'BC6H_UF16';          96 = 'BC6H_SF16'
    98 = 'BC7_UNORM';          99 = 'BC7_UNORM_SRGB'
}

function ConvertFrom-BffDxgiFormat {
    param([int] $Value)
    if ($script:BffDxgiFormatNames.ContainsKey($Value)) { return $script:BffDxgiFormatNames[$Value] }
    return ('DXGI_{0}' -f $Value)
}

function ConvertTo-BffDxgiValue {
    param([string] $Name)
    foreach ($pair in $script:BffDxgiFormatNames.GetEnumerator()) {
        if ($pair.Value -eq $Name) { return [int] $pair.Key }
    }
    return 0
}

function Read-BffBa2Index {
    <#
    .SYNOPSIS
    Reads a BA2's file table. Only the table and the name table are read, never the
    payload, so this is fast even on multi-gigabyte archives.

    .PARAMETER PathFilter
    Optional regex applied to the internal path. Entries that do not match are
    dropped before any objects are built.

    .OUTPUTS
    [pscustomobject] with Type, ArchivePath and Entries (BffArchiveEntry[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $PathFilter
    )

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                                [System.IO.FileAccess]::Read,
                                                [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.BinaryReader($stream)

        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'BTDX') {
            return [pscustomobject]@{ ArchivePath = $Path; Type = ''; Version = 0; Entries = @(); Error = "not a BA2 archive (magic '$magic')" }
        }

        $version  = $reader.ReadUInt32()
        $type     = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        $numFiles = [int] $reader.ReadUInt32()
        $nameOff  = $reader.ReadUInt64()

        if ($type -ne 'GNRL' -and $type -ne 'DX10') {
            return [pscustomobject]@{ ArchivePath = $Path; Type = $type; Version = $version; Entries = @(); Error = "unsupported archive type '$type'" }
        }
        # Version 1 is the original Fallout 4 archive; 7 and 8 are the next-gen
        # update. Probing the record fields at candidate header sizes of 24/28/32/36
        # across v1, v7 and v8 archives shows all three parse cleanly at 24 and
        # produce nonsense at every other offset, so the layout is identical and
        # only the version number changed. Skipping v7/v8 would have made 42 of the
        # 100 mod archives on this machine unreadable.
        #
        # Versions 2 and 3 (Fallout 76, Starfield) genuinely differ and are rejected
        # rather than misreported.
        if ($version -notin @(1, 7, 8)) {
            return [pscustomobject]@{ ArchivePath = $Path; Type = $type; Version = $version; Entries = @(); Error = "unsupported BA2 version $version" }
        }

        # --- file records -------------------------------------------------------
        $records = New-Object object[] $numFiles

        for ($i = 0; $i -lt $numFiles; $i++) {
            if ($type -eq 'GNRL') {
                [void] $reader.ReadUInt32()                       # nameHash
                [void] $reader.ReadBytes(4)                       # extension
                [void] $reader.ReadUInt32()                       # dirHash
                [void] $reader.ReadUInt32()                       # flags
                $offset   = $reader.ReadUInt64()
                $packed   = [int] $reader.ReadUInt32()
                $unpacked = [int] $reader.ReadUInt32()
                [void] $reader.ReadUInt32()                       # 0xBAADF00D

                $records[$i] = @{
                    Offset = $offset; PackedSize = $packed; UnpackedSize = $unpacked
                }
            }
            else {
                [void] $reader.ReadUInt32()                       # nameHash
                [void] $reader.ReadBytes(4)                       # extension
                [void] $reader.ReadUInt32()                       # dirHash
                [void] $reader.ReadByte()                         # unknown
                $numChunks = [int] $reader.ReadByte()
                [void] $reader.ReadUInt16()                       # chunk header size
                $height    = [int] $reader.ReadUInt16()
                $width     = [int] $reader.ReadUInt16()
                $numMips   = [int] $reader.ReadByte()
                $format    = [int] $reader.ReadByte()
                $isCube    = [int] $reader.ReadByte()
                [void] $reader.ReadByte()                         # tile mode

                $chunks = New-Object object[] $numChunks
                for ($c = 0; $c -lt $numChunks; $c++) {
                    $chunks[$c] = @{
                        Offset       = $reader.ReadUInt64()
                        PackedSize   = [int] $reader.ReadUInt32()
                        UnpackedSize = [int] $reader.ReadUInt32()
                        StartMip     = [int] $reader.ReadUInt16()
                        EndMip       = [int] $reader.ReadUInt16()
                    }
                    [void] $reader.ReadUInt32()                   # 0xBAADF00D
                }

                $records[$i] = @{
                    Width = $width; Height = $height; MipLevels = $numMips
                    Format = $format; IsCubemap = $isCube; Chunks = $chunks
                }
            }
        }

        # --- name table ---------------------------------------------------------
        $names = New-Object string[] $numFiles
        if ($nameOff -gt 0 -and $nameOff -lt [uint64] $stream.Length) {
            $stream.Position = [long] $nameOff
            for ($i = 0; $i -lt $numFiles; $i++) {
                if ($stream.Position -ge $stream.Length) { break }
                $len      = [int] $reader.ReadUInt16()
                $names[$i] = [System.Text.Encoding]::UTF8.GetString($reader.ReadBytes($len))
            }
        }

        # --- build entries ------------------------------------------------------
        $entries = New-Object System.Collections.Generic.List[BffArchiveEntry]

        for ($i = 0; $i -lt $numFiles; $i++) {
            $name = $names[$i]
            if (-not $name) { continue }
            if ($PathFilter -and $name -notmatch $PathFilter) { continue }

            $rec = $records[$i]
            $e   = [BffArchiveEntry]::new()
            $e.ArchivePath  = $Path
            $e.InternalPath = $name

            if ($type -eq 'DX10') {
                $e.Width       = $rec.Width
                $e.Height      = $rec.Height
                $e.MipLevels   = $rec.MipLevels
                $e.Format      = ConvertFrom-BffDxgiFormat $rec.Format
                $e.NumChunks   = $rec.Chunks.Count
                $e.Chunks      = $rec.Chunks
                $e.HasMetadata = $true
            }
            else {
                $e.Offset       = [long] $rec.Offset
                $e.PackedSize   = $rec.PackedSize
                $e.UnpackedSize = $rec.UnpackedSize
                $e.HasMetadata  = $false   # needs the DDS header read to know the size
            }

            $entries.Add($e)
        }

        return [pscustomobject]@{
            ArchivePath = $Path
            Type        = $type
            Version     = [int] $version
            FileCount   = $numFiles
            Entries     = $entries
            Error       = ''
        }
    }
    catch {
        return [pscustomobject]@{ ArchivePath = $Path; Type = ''; Version = 0; Entries = @(); Error = $_.Exception.Message }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Expand-BffZlibBlock {
    <#
    .SYNOPSIS
    Inflates a zlib stream. .NET Framework has no ZLibStream, so the 2-byte zlib
    header is skipped and raw DeflateStream is used.
    #>
    param(
        [Parameter(Mandatory)] [byte[]] $Data,
        [int] $ExpectedSize
    )

    # Next-gen archives may compress chunks with LZ4 instead of zlib. A zlib stream
    # starts with a CMF byte of 0x78 for the window sizes Bethesda uses; anything
    # else would silently inflate to garbage, so refuse it instead.
    if ($Data.Length -lt 2 -or $Data[0] -ne 0x78) {
        throw 'chunk is not zlib compressed (next-gen LZ4 archives are not supported for extraction)'
    }

    $input = New-Object System.IO.MemoryStream(, $Data)
    try {
        [void] $input.Seek(2, [System.IO.SeekOrigin]::Begin)   # skip CMF + FLG
        $deflate = New-Object System.IO.Compression.DeflateStream($input, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $output = New-Object System.IO.MemoryStream
            try {
                $deflate.CopyTo($output)
                return $output.ToArray()
            }
            finally { $output.Dispose() }
        }
        finally { $deflate.Dispose() }
    }
    finally { $input.Dispose() }
}

function Read-BffBa2GnrlHeader {
    <#
    .SYNOPSIS
    Fills Width/Height/Format on a GNRL entry by reading just the DDS header out of
    the payload. GNRL archives store whole .dds files, so the first 148 bytes are
    enough; only the first chunk is inflated when the entry is compressed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffArchiveEntry] $Entry)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Entry.ArchivePath, [System.IO.FileMode]::Open,
                                                             [System.IO.FileAccess]::Read,
                                                             [System.IO.FileShare]::ReadWrite)
        $stream.Position = $Entry.Offset

        if ($Entry.PackedSize -gt 0) {
            $buffer = New-Object byte[] $Entry.PackedSize
            [void] $stream.Read($buffer, 0, $buffer.Length)
            $bytes = Expand-BffZlibBlock -Data $buffer
        }
        else {
            $take   = [Math]::Min(148, $Entry.UnpackedSize)
            $bytes  = New-Object byte[] $take
            [void] $stream.Read($bytes, 0, $take)
        }

        if ($bytes.Length -lt 128) { return $false }
        if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'DDS ') { return $false }

        $Entry.Height    = [BitConverter]::ToInt32($bytes, 12)
        $Entry.Width     = [BitConverter]::ToInt32($bytes, 16)
        $Entry.MipLevels = [BitConverter]::ToInt32($bytes, 28)

        $pfFlags = [BitConverter]::ToUInt32($bytes, 80)
        $fourCc  = [System.Text.Encoding]::ASCII.GetString($bytes, 84, 4)

        if (($pfFlags -band 0x4) -and $fourCc -eq 'DX10' -and $bytes.Length -ge 148) {
            $Entry.Format = ConvertFrom-BffDxgiFormat ([BitConverter]::ToInt32($bytes, 128))
        }
        else {
            switch ($fourCc) {
                'DXT1' { $Entry.Format = 'BC1_UNORM' }
                'DXT3' { $Entry.Format = 'BC2_UNORM' }
                'DXT5' { $Entry.Format = 'BC3_UNORM' }
                'ATI1' { $Entry.Format = 'BC4_UNORM' }
                'BC4U' { $Entry.Format = 'BC4_UNORM' }
                'ATI2' { $Entry.Format = 'BC5_UNORM' }
                'BC5U' { $Entry.Format = 'BC5_UNORM' }
                default { $Entry.Format = "FOURCC_$fourCc" }
            }
        }

        $Entry.HasMetadata = $true
        return $true
    }
    catch {
        Write-Verbose "Could not read DDS header for '$($Entry.InternalPath)': $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function New-BffDdsHeader {
    <#
    .SYNOPSIS
    Builds a DDS + DX10 header for a texture extracted from a DX10 archive, which
    stores raw pixel data with no header of its own.
    #>
    param(
        [Parameter(Mandatory)] [int] $Width,
        [Parameter(Mandatory)] [int] $Height,
        [Parameter(Mandatory)] [int] $MipLevels,
        [Parameter(Mandatory)] [int] $DxgiFormat,
        [int] $ArraySize = 1,
        [bool] $IsCubemap = $false
    )

    $blockSize = switch ($DxgiFormat) {
        { $_ -in 70, 71, 72, 73, 79, 80, 81 } { 8; break }   # BC1 / BC4 families
        default                               { 16 }         # BC2/3/5/6/7
    }
    $linearSize = [Math]::Max(1, [Math]::Floor(($Width + 3) / 4)) *
                  [Math]::Max(1, [Math]::Floor(($Height + 3) / 4)) * $blockSize

    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter($ms)
    try {
        $w.Write([System.Text.Encoding]::ASCII.GetBytes('DDS '))

        $w.Write([uint32] 124)        # header size
        # CAPS | HEIGHT | WIDTH | PIXELFORMAT | MIPMAPCOUNT | LINEARSIZE
        $w.Write([uint32] 0xA1007)
        $w.Write([uint32] $Height)
        $w.Write([uint32] $Width)
        $w.Write([uint32] $linearSize)
        $w.Write([uint32] 1)          # depth
        $w.Write([uint32] $MipLevels)
        for ($i = 0; $i -lt 11; $i++) { $w.Write([uint32] 0) }   # reserved1

        # DDS_PIXELFORMAT: FOURCC 'DX10'
        $w.Write([uint32] 32)
        $w.Write([uint32] 0x4)
        $w.Write([System.Text.Encoding]::ASCII.GetBytes('DX10'))
        for ($i = 0; $i -lt 5; $i++) { $w.Write([uint32] 0) }

        $caps = 0x1000                                        # TEXTURE
        if ($MipLevels -gt 1) { $caps = $caps -bor 0x400008 }  # MIPMAP | COMPLEX
        if ($IsCubemap)       { $caps = $caps -bor 0x8 }
        $w.Write([uint32] $caps)
        $w.Write([uint32] $(if ($IsCubemap) { 0xFE00 } else { 0 }))   # caps2
        $w.Write([uint32] 0)
        $w.Write([uint32] 0)
        $w.Write([uint32] 0)

        # DDS_HEADER_DXT10
        $w.Write([uint32] $DxgiFormat)
        $w.Write([uint32] 3)                                   # TEXTURE2D
        $w.Write([uint32] $(if ($IsCubemap) { 0x4 } else { 0 }))
        $w.Write([uint32] $ArraySize)
        $w.Write([uint32] 0)                                   # miscFlags2

        $w.Flush()
        return $ms.ToArray()
    }
    finally { $w.Dispose(); $ms.Dispose() }
}

function Expand-BffBa2Texture {
    <#
    .SYNOPSIS
    Extracts one texture from a BA2 to a .dds file on disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffArchiveEntry] $Entry,
        [Parameter(Mandatory)] [string] $Destination
    )

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void] (New-Item -ItemType Directory -Path $dir -Force)
    }

    $stream = [System.IO.File]::Open($Entry.ArchivePath, [System.IO.FileMode]::Open,
                                                         [System.IO.FileAccess]::Read,
                                                         [System.IO.FileShare]::ReadWrite)
    $out = $null
    try {
        $out = [System.IO.File]::Create($Destination)

        if ($Entry.Chunks) {
            # DX10: raw pixel data, header has to be rebuilt.
            $header = New-BffDdsHeader -Width $Entry.Width -Height $Entry.Height `
                                       -MipLevels $Entry.MipLevels `
                                       -DxgiFormat (ConvertTo-BffDxgiValue $Entry.Format)
            $out.Write($header, 0, $header.Length)

            foreach ($chunk in $Entry.Chunks) {
                $stream.Position = [long] $chunk.Offset
                if ($chunk.PackedSize -gt 0) {
                    $buffer = New-Object byte[] $chunk.PackedSize
                    [void] $stream.Read($buffer, 0, $buffer.Length)
                    $data = Expand-BffZlibBlock -Data $buffer -ExpectedSize $chunk.UnpackedSize
                }
                else {
                    $data = New-Object byte[] $chunk.UnpackedSize
                    [void] $stream.Read($data, 0, $data.Length)
                }
                $out.Write($data, 0, $data.Length)
            }
        }
        else {
            # GNRL: the payload already is a complete .dds file.
            $stream.Position = $Entry.Offset
            if ($Entry.PackedSize -gt 0) {
                $buffer = New-Object byte[] $Entry.PackedSize
                [void] $stream.Read($buffer, 0, $buffer.Length)
                $data = Expand-BffZlibBlock -Data $buffer -ExpectedSize $Entry.UnpackedSize
            }
            else {
                $data = New-Object byte[] $Entry.UnpackedSize
                [void] $stream.Read($data, 0, $data.Length)
            }
            $out.Write($data, 0, $data.Length)
        }

        return $Destination
    }
    finally {
        if ($out) { $out.Dispose() }
        $stream.Dispose()
    }
}
