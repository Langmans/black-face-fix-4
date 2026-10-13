# TestBa2.ps1 - writes small BA2 archives and DDS files for the tests.
#
# Dot-source it. Archives are written byte for byte in the layout Ba2.ps1 reads
# (see the comment at the top of that file): a 24-byte header, the file records,
# the payload, then the name table. Version and type are free, so the reader can
# be fed v1, v7 and v8 as well as versions and types it has to refuse.
#
# Compression is real zlib - a 0x78 0x9C header, a deflate stream and the adler32
# trailer - because that is what the reader has to take apart.

function ConvertTo-TestZlib {
    param([byte[]] $Data)
    $ms = New-Object System.IO.MemoryStream
    $ms.WriteByte(0x78); $ms.WriteByte(0x9C)
    $deflate = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $deflate.Write($Data, 0, $Data.Length)
    $deflate.Dispose()

    $a = 1; $b = 0
    foreach ($byte in $Data) { $a = ($a + $byte) % 65521; $b = ($b + $a) % 65521 }
    # In long: shifted into the top bit, an int goes negative and [uint32] refuses it.
    $adler = [uint32] (([long] $b -shl 16) -bor $a)
    foreach ($shift in 24, 16, 8, 0) { $ms.WriteByte([byte] (($adler -shr $shift) -band 0xFF)) }

    $bytes = $ms.ToArray()
    $ms.Dispose()
    return , $bytes
}

function New-TestDds {
    <#
    .SYNOPSIS
    A DDS file: the 128-byte header, the DX10 extension when -Dxgi is given, then
    -PayloadSize bytes of pattern.
    #>
    param(
        [int] $Width = 64, [int] $Height = $Width, [int] $Mips = 1,
        [string] $FourCC = 'DX10', [int] $Dxgi = 0, [int] $PayloadSize = 16
    )
    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter($ms)
    $w.Write([System.Text.Encoding]::ASCII.GetBytes('DDS '))
    $w.Write([uint32] 124); $w.Write([uint32] 0xA1007)
    $w.Write([uint32] $Height); $w.Write([uint32] $Width)
    $w.Write([uint32] 0); $w.Write([uint32] 1); $w.Write([uint32] $Mips)
    for ($i = 0; $i -lt 11; $i++) { $w.Write([uint32] 0) }
    $w.Write([uint32] 32); $w.Write([uint32] 0x4)
    $w.Write([System.Text.Encoding]::ASCII.GetBytes($FourCC.PadRight(4).Substring(0, 4)))
    for ($i = 0; $i -lt 5; $i++) { $w.Write([uint32] 0) }
    for ($i = 0; $i -lt 5; $i++) { $w.Write([uint32] 0) }      # caps .. reserved2
    if ($Dxgi) {
        $w.Write([uint32] $Dxgi); $w.Write([uint32] 3); $w.Write([uint32] 0); $w.Write([uint32] 1); $w.Write([uint32] 0)
    }
    for ($i = 0; $i -lt $PayloadSize; $i++) { $w.Write([byte] ($i % 251)) }
    $w.Flush()
    $bytes = $ms.ToArray()
    $w.Dispose(); $ms.Dispose()
    return , $bytes
}

function New-TestEntry {
    <#
    .SYNOPSIS
    One file for New-TestBa2. A GNRL entry is -Data, a whole file. A DX10 entry
    is -Chunk, one byte array per chunk of raw pixel data, plus its size and format.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [byte[]] $Data,
        [object[]] $Chunk,
        [int] $Width = 64, [int] $Height = $Width, [int] $Mips = 1, [int] $Dxgi = 71,
        [switch] $Compress
    )
    [pscustomobject]@{
        Path = $Path; Data = $Data; Chunk = $Chunk; Width = $Width; Height = $Height
        Mips = $Mips; Dxgi = $Dxgi; Compress = [bool] $Compress
    }
}

function New-TestBa2 {
    <#
    .SYNOPSIS
    Writes a BA2 holding the given entries, and returns its path.

    .PARAMETER NoNames
    Writes a name table offset of 0, as a broken archive might.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('GNRL', 'DX10')] [string] $Type = 'DX10',
        [uint32] $Version = 1,
        [object[]] $Entry = @(),
        [string] $Magic = 'BTDX',
        [string] $TypeTag = $Type,
        [switch] $NoNames
    )

    # Payload first, in memory, so the records can point at it.
    $tableSize = 0
    foreach ($e in $Entry) {
        $tableSize += if ($Type -eq 'GNRL') { 36 } else { 24 + 24 * @($e.Chunk).Count }
    }
    $dataStart = 24 + $tableSize

    $payload = New-Object System.IO.MemoryStream
    $placed  = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entry) {
        # A GNRL file is one piece, a DX10 texture one piece per chunk.
        $pieces = New-Object System.Collections.Generic.List[byte[]]
        if ($Type -eq 'GNRL') { $pieces.Add([byte[]] $e.Data) }
        else { foreach ($c in $e.Chunk) { $pieces.Add([byte[]] $c) } }

        $where = New-Object System.Collections.Generic.List[object]
        foreach ($raw in $pieces) {
            # Typed: an if that yields an array unrolls it into object[].
            [byte[]] $stored = if ($e.Compress) { ConvertTo-TestZlib $raw } else { $raw }
            $where.Add([pscustomobject]@{
                Offset = [uint64] ($dataStart + $payload.Length)
                Packed = [uint32] $(if ($e.Compress) { $stored.Length } else { 0 })
                Size   = [uint32] $raw.Length
            })
            $payload.Write($stored, 0, $stored.Length)
        }
        $placed.Add($where)
    }
    $namesAt = [uint64] ($dataStart + $payload.Length)

    $fs = [System.IO.File]::Create($Path)
    $w  = New-Object System.IO.BinaryWriter($fs)
    try {
        $w.Write([System.Text.Encoding]::ASCII.GetBytes($Magic))
        $w.Write([uint32] $Version)
        $w.Write([System.Text.Encoding]::ASCII.GetBytes($TypeTag))
        $w.Write([uint32] @($Entry).Count)
        $w.Write([uint64] $(if ($NoNames) { 0 } else { $namesAt }))

        for ($i = 0; $i -lt @($Entry).Count; $i++) {
            $e = $Entry[$i]; $parts = $placed[$i]
            $w.Write([uint32] 0x12345678)                                  # name hash
            $w.Write([System.Text.Encoding]::ASCII.GetBytes('dds' + [char] 0))
            # L: without it a hex literal with the top bit set is a negative int.
            $w.Write([uint32] 0x9ABCDEF0L)                                 # dir hash
            if ($Type -eq 'GNRL') {
                $w.Write([uint32] 0)                                       # flags
                $w.Write([uint64] $parts[0].Offset)
                $w.Write([uint32] $parts[0].Packed)
                $w.Write([uint32] $parts[0].Size)
                $w.Write([uint32] 0xBAADF00DL)
            }
            else {
                $w.Write([byte] 0)
                $w.Write([byte] $parts.Count)
                $w.Write([uint16] 24)
                $w.Write([uint16] $e.Height)
                $w.Write([uint16] $e.Width)
                $w.Write([byte] $e.Mips)
                $w.Write([byte] $e.Dxgi)
                $w.Write([byte] 0)                                         # cubemap
                $w.Write([byte] 8)                                         # tile mode
                $mip = 0
                foreach ($p in $parts) {
                    $w.Write([uint64] $p.Offset)
                    $w.Write([uint32] $p.Packed)
                    $w.Write([uint32] $p.Size)
                    $w.Write([uint16] $mip)
                    $w.Write([uint16] $mip)
                    $w.Write([uint32] 0xBAADF00DL)
                    $mip++
                }
            }
        }

        $w.Flush()
        $payload.WriteTo($fs)

        foreach ($e in $Entry) {
            $name = [System.Text.Encoding]::UTF8.GetBytes($e.Path)
            $w.Write([uint16] $name.Length)
            $w.Write($name)
        }
        $w.Flush()
    }
    finally { $w.Dispose(); $payload.Dispose() }
    return $Path
}
