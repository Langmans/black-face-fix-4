# Probe the DX10 file-record layout of BA2 v1 vs v7/v8 by checking whether the
# fields at a candidate header size look sane:
#   chunkHeaderSize must be 24, width/height powers of two, format a known DXGI id.

param([string[]] $Path)

$known = @(0,2,10,11,24,28,29,31,41,49,54,56,61,65,71,72,74,75,77,78,80,81,83,84,87,88,91,95,96,98,99)

function Test-Layout {
    param([string] $File, [int] $HeaderSize)

    $fs = [System.IO.File]::OpenRead($File)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $null = $br.ReadBytes(4)
        $version = $br.ReadUInt32()
        $type    = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        $num     = $br.ReadUInt32()
        $nto     = $br.ReadUInt64()

        $fs.Position = $HeaderSize

        $null   = $br.ReadUInt32()                                          # nameHash
        $ext    = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4)).Trim([char]0)
        $null   = $br.ReadUInt32()                                          # dirHash
        $unk    = $br.ReadByte()
        $chunks = $br.ReadByte()
        $chs    = $br.ReadUInt16()
        $h      = $br.ReadUInt16()
        $w      = $br.ReadUInt16()
        $mips   = $br.ReadByte()
        $fmt    = $br.ReadByte()
        $cube   = $br.ReadByte()
        $tile   = $br.ReadByte()

        $sane = ($chs -eq 24) -and ($w -gt 0) -and ($h -gt 0) -and
                (($w -band ($w - 1)) -eq 0) -and (($h -band ($h - 1)) -eq 0) -and
                ($known -contains [int]$fmt) -and ($chunks -ge 1) -and ($chunks -le 16)

        return [pscustomobject]@{
            File = Split-Path $File -Leaf; Version = $version; Type = $type; Files = $num
            Header = $HeaderSize; Ext = $ext; Chunks = $chunks; ChunkHdr = $chs
            WxH = "${w}x${h}"; Mips = $mips; Fmt = $fmt; Sane = $sane
        }
    }
    finally { $fs.Dispose() }
}

foreach ($p in $Path) {
    foreach ($hs in @(24, 28, 32, 36)) {
        $r = Test-Layout -File $p -HeaderSize $hs
        if ($r.Type -ne 'DX10') { break }
        '{0,-42} v{1} hdr={2,-3} ext={3,-5} chunks={4,-3} chunkHdr={5,-5} {6,-12} mips={7,-3} fmt={8,-4} sane={9}' -f `
            $r.File, $r.Version, $r.Header, $r.Ext, $r.Chunks, $r.ChunkHdr, $r.WxH, $r.Mips, $r.Fmt, $r.Sane
    }
    ''
}
