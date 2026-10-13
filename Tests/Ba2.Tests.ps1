# Unit tests for Ba2.ps1 - reading BA2 archives, and getting a texture back out.
#
#   Invoke-Pester -Path .\Tests\Ba2.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Ba2.ps1'
#
# Pester 5. Every archive here is written by TestBa2.ps1, byte for byte, into
# TestDrive: GNRL and DX10, versions 1, 7 and 8, compressed and not, and broken
# in the ways the reader has to survive. What comes out is checked against what
# went in, and one extracted texture is handed to the real texdiag, so the DDS
# header the code builds is proven readable by the tool that reads it next.
#
# Verify-Ba2.ps1 is the other half: the same reader against the game's own
# archives, which only a machine with Fallout 4 can run.
#
# Type names are given as strings - New-Object BffArchiveEntry rather than
# [BffArchiveEntry]::new() - because a type literal in this file is resolved when
# the file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'TexInfo', 'Ba2') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }
    . (Join-Path $PSScriptRoot 'TestBa2.ps1')

    function New-TestPath {
        param([string] $Extension = '.ba2')
        Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8) + $Extension)
    }

    # A pattern that does not compress to nothing, so packed and unpacked differ
    # but both are real.
    function New-TestBytes {
        param([int] $Count, [int] $Seed = 1)
        $b = New-Object byte[] $Count
        for ($i = 0; $i -lt $Count; $i++) { $b[$i] = [byte] (($i * $Seed + ($i -shr 3)) % 256) }
        return , $b
    }

    function Set-TestBytes {
        param([string] $Path, [int] $At, [byte[]] $Bytes)
        $all = [System.IO.File]::ReadAllBytes($Path)
        [Array]::Copy($Bytes, 0, $all, $At, $Bytes.Length)
        [System.IO.File]::WriteAllBytes($Path, $all)
    }

    function Limit-TestFile {
        param([string] $Path, [int] $Length)
        $all = [System.IO.File]::ReadAllBytes($Path)
        [System.IO.File]::WriteAllBytes($Path, $all[0..($Length - 1)])
    }

    $face = 'textures\actors\character\basehumanmale\malehead_d.dds'
}

Describe 'the DXGI format names' {
    It 'names the formats face textures use' -TestCases @(
        @{ Value = 71; Name = 'BC1_UNORM' }, @{ Value = 77; Name = 'BC3_UNORM' }, @{ Value = 83; Name = 'BC5_UNORM' }
        @{ Value = 98; Name = 'BC7_UNORM' }, @{ Value = 80; Name = 'BC4_UNORM' }, @{ Value = 28; Name = 'R8G8B8A8_UNORM' }
    ) {
        ConvertFrom-BffDxgiFormat $Value | Should -Be $Name
        ConvertTo-BffDxgiValue $Name     | Should -Be $Value
    }

    It 'names a format it does not know by its number' {
        ConvertFrom-BffDxgiFormat 200 | Should -Be 'DXGI_200'
    }

    It 'gives 0, UNKNOWN, for a name it does not know' {
        ConvertTo-BffDxgiValue 'FOURCC_ABCD' | Should -Be 0
    }
}

Describe 'Read-BffBa2Index' {

    Context 'a DX10 archive' {
        It 'reads size, format, mips and chunks from the file table alone, in every version Fallout 4 writes' -TestCases @(
            @{ Version = 1 }, @{ Version = 7 }, @{ Version = 8 }
        ) {
            $path = New-TestBa2 -Path (New-TestPath) -Type DX10 -Version $Version -Entry @(
                (New-TestEntry $face -Chunk @((New-TestBytes 2048), (New-TestBytes 512)) -Width 64 -Height 32 -Mips 2 -Dxgi 77)
            )
            $idx = Read-BffBa2Index -Path $path
            $idx.Error     | Should -Be ''
            $idx.Type      | Should -Be 'DX10'
            $idx.Version   | Should -Be $Version
            $idx.FileCount | Should -Be 1
            $e = @($idx.Entries)[0]
            $e.ArchivePath  | Should -Be $path
            $e.InternalPath | Should -Be $face
            "$($e.Width)x$($e.Height) $($e.Format) $($e.MipLevels)" | Should -Be '64x32 BC3_UNORM 2'
            $e.NumChunks    | Should -Be 2
            $e.Chunks[1].UnpackedSize | Should -Be 512
            $e.Chunks[1].StartMip     | Should -Be 1
            $e.HasMetadata  | Should -BeTrue
        }
    }

    Context 'a GNRL archive' {
        It 'reads where each file is, and leaves its size to the DDS header' {
            $dds  = New-TestDds -Dxgi 98
            $path = New-TestBa2 -Path (New-TestPath) -Type GNRL -Entry @(
                (New-TestEntry $face -Data $dds), (New-TestEntry 'meshes\head.nif' -Data (New-TestBytes 300) -Compress)
            )
            $idx = Read-BffBa2Index -Path $path
            $idx.Type | Should -Be 'GNRL'
            $e = @($idx.Entries)
            $e.Count | Should -Be 2
            $e[0].Offset       | Should -BeGreaterThan 0
            $e[0].PackedSize   | Should -Be 0
            $e[0].UnpackedSize | Should -Be $dds.Length
            $e[0].HasMetadata  | Should -BeFalse
            $e[1].PackedSize   | Should -BeGreaterThan 0
            $e[1].UnpackedSize | Should -Be 300
        }
    }

    It 'keeps only the paths that match the filter' {
        $path = New-TestBa2 -Path (New-TestPath) -Entry @(
            (New-TestEntry $face -Chunk @(, (New-TestBytes 2048))),
            (New-TestEntry 'textures\armor\helmet_d.dds' -Chunk @(, (New-TestBytes 2048)))
        )
        @((Read-BffBa2Index -Path $path -PathFilter 'actors\\character\\').Entries | ForEach-Object InternalPath) | Should -Be @($face)
    }

    Context 'what it refuses' {
        It 'refuses a file that is not a BA2, and says what it found' {
            $path = New-TestBa2 -Path (New-TestPath) -Magic 'PK!!'
            $idx = Read-BffBa2Index -Path $path
            $idx.Error | Should -Be "not a BA2 archive (magic 'PK!!')"
            @($idx.Entries).Count | Should -Be 0
        }

        It 'refuses an archive type it does not know' {
            (Read-BffBa2Index -Path (New-TestBa2 -Path (New-TestPath) -TypeTag 'XBOX')).Error |
                Should -Be "unsupported archive type 'XBOX'"
        }

        It 'refuses the versions Fallout 76 and Starfield write' -TestCases @(@{ Version = 2 }, @{ Version = 3 }) {
            $idx = Read-BffBa2Index -Path (New-TestBa2 -Path (New-TestPath) -Version $Version)
            $idx.Error   | Should -Be "unsupported BA2 version $Version"
            $idx.Version | Should -Be $Version
        }

        It 'reports an archive cut short instead of failing' {
            $path = New-TestBa2 -Path (New-TestPath) -Entry @((New-TestEntry $face -Chunk @(, (New-TestBytes 2048))))
            Limit-TestFile $path 30
            (Read-BffBa2Index -Path $path).Error | Should -Not -BeNullOrEmpty
        }

        It 'reports a file that is not there instead of failing' {
            (Read-BffBa2Index -Path (Join-Path $TestDrive 'missing.ba2')).Error | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a damaged name table' {
        It 'lists nothing without a name table' {
            $path = New-TestBa2 -Path (New-TestPath) -NoNames -Entry @((New-TestEntry $face -Chunk @(, (New-TestBytes 2048))))
            $idx = Read-BffBa2Index -Path $path
            $idx.Error | Should -Be ''
            @($idx.Entries).Count | Should -Be 0
        }

        It 'lists nothing when the name table points past the end' {
            $path = New-TestBa2 -Path (New-TestPath) -Entry @((New-TestEntry $face -Chunk @(, (New-TestBytes 2048))))
            Set-TestBytes $path 16 ([BitConverter]::GetBytes([uint64] 99999999))
            @((Read-BffBa2Index -Path $path).Entries).Count | Should -Be 0
        }

        It 'lists the files it has names for when the table is cut short' {
            $path = New-TestBa2 -Path (New-TestPath) -Entry @(
                (New-TestEntry $face -Chunk @(, (New-TestBytes 2048))),
                (New-TestEntry 'textures\second.dds' -Chunk @(, (New-TestBytes 2048)))
            )
            Limit-TestFile $path ((Get-Item -LiteralPath $path).Length - ('textures\second.dds'.Length + 2))
            @((Read-BffBa2Index -Path $path).Entries | ForEach-Object InternalPath) | Should -Be @($face)
        }
    }
}

Describe 'Expand-BffZlibBlock' {
    It 'inflates what zlib packed' {
        $raw = New-TestBytes 5000
        Expand-BffZlibBlock -Data (ConvertTo-TestZlib $raw) | Should -Be $raw
    }

    It 'refuses data that is not zlib, rather than inflate it to garbage' -TestCases @(
        @{ Data = [byte[]] @(0x04, 0x22, 0x4D, 0x18) }, @{ Data = [byte[]] @(0x78) }
    ) {
        { Expand-BffZlibBlock -Data $Data } | Should -Throw -ExpectedMessage 'chunk is not zlib compressed*'
    }
}

Describe 'Read-BffBa2GnrlHeader' {
    BeforeAll {
        function Get-TestEntry {
            param([byte[]] $Data, [switch] $Compress)
            $path = New-TestBa2 -Path (New-TestPath) -Type GNRL -Entry @((New-TestEntry $face -Data $Data -Compress:$Compress))
            @((Read-BffBa2Index -Path $path).Entries)[0]
        }
    }

    It 'reads size, mips and the DXGI format from a DX10 header' {
        $e = Get-TestEntry (New-TestDds -Width 2048 -Height 1024 -Mips 12 -Dxgi 99)
        Read-BffBa2GnrlHeader -Entry $e | Should -BeTrue
        "$($e.Width)x$($e.Height) $($e.Format) $($e.MipLevels)" | Should -Be '2048x1024 BC7_UNORM_SRGB 12'
        $e.HasMetadata | Should -BeTrue
    }

    It 'inflates a compressed file to read its header' {
        $e = Get-TestEntry (New-TestDds -Width 512 -Dxgi 83 -PayloadSize 4096) -Compress
        Read-BffBa2GnrlHeader -Entry $e | Should -BeTrue
        $e.Format | Should -Be 'BC5_UNORM'
        $e.Width  | Should -Be 512
    }

    It 'reads the older four-character formats' -TestCases @(
        @{ FourCC = 'DXT1'; Format = 'BC1_UNORM' }, @{ FourCC = 'DXT3'; Format = 'BC2_UNORM' }
        @{ FourCC = 'DXT5'; Format = 'BC3_UNORM' }, @{ FourCC = 'ATI1'; Format = 'BC4_UNORM' }
        @{ FourCC = 'BC4U'; Format = 'BC4_UNORM' }, @{ FourCC = 'ATI2'; Format = 'BC5_UNORM' }
        @{ FourCC = 'BC5U'; Format = 'BC5_UNORM' }, @{ FourCC = 'RXGB'; Format = 'FOURCC_RXGB' }
    ) {
        $e = Get-TestEntry (New-TestDds -FourCC $FourCC)
        Read-BffBa2GnrlHeader -Entry $e | Should -BeTrue
        $e.Format | Should -Be $Format
    }

    It 'does not read a DX10 format from a header too short to hold one' {
        $e = Get-TestEntry ((New-TestDds -Dxgi 98 -PayloadSize 0)[0..139])
        Read-BffBa2GnrlHeader -Entry $e | Should -BeTrue
        $e.Format | Should -Be 'FOURCC_DX10'
    }

    It 'gives up on a file too short to be a DDS, or that is not one' -TestCases @(
        @{ Kind = 'short' }, @{ Kind = 'not dds' }
    ) {
        $data = if ($Kind -eq 'short') { New-TestBytes 100 } else { New-TestBytes 200 }
        $e = Get-TestEntry $data
        Read-BffBa2GnrlHeader -Entry $e | Should -BeFalse
        $e.HasMetadata | Should -BeFalse
    }

    It 'gives up, without failing, when the archive has gone' {
        $e = New-Object BffArchiveEntry
        $e.ArchivePath = Join-Path $TestDrive 'gone.ba2'; $e.InternalPath = $face; $e.UnpackedSize = 148
        Read-BffBa2GnrlHeader -Entry $e | Should -BeFalse
    }
}

Describe 'New-BffDdsHeader' {
    BeforeAll {
        function Get-UInt32 { param([byte[]] $Bytes, [int] $At) [BitConverter]::ToUInt32($Bytes, $At) }
    }

    It 'writes a 148-byte DDS header with the DX10 extension' {
        $h = New-BffDdsHeader -Width 1024 -Height 512 -MipLevels 11 -DxgiFormat 83
        $h.Length | Should -Be 148
        [System.Text.Encoding]::ASCII.GetString($h, 0, 4)  | Should -Be 'DDS '
        Get-UInt32 $h 12 | Should -Be 512
        Get-UInt32 $h 16 | Should -Be 1024
        Get-UInt32 $h 28 | Should -Be 11
        [System.Text.Encoding]::ASCII.GetString($h, 84, 4) | Should -Be 'DX10'
        Get-UInt32 $h 128 | Should -Be 83
        Get-UInt32 $h 132 | Should -Be 3
        Get-UInt32 $h 140 | Should -Be 1
    }

    It 'sizes the top mip by the format''s block size' -TestCases @(
        @{ Dxgi = 71; Linear = 8192 }, @{ Dxgi = 80; Linear = 8192 }, @{ Dxgi = 98; Linear = 16384 }
    ) {
        Get-UInt32 (New-BffDdsHeader -Width 128 -Height 128 -MipLevels 1 -DxgiFormat $Dxgi) 20 | Should -Be $Linear
    }

    It 'counts a texture smaller than a block as one block' {
        Get-UInt32 (New-BffDdsHeader -Width 2 -Height 2 -MipLevels 1 -DxgiFormat 71) 20 | Should -Be 8
    }

    It 'marks a mip chain as one, and leaves a single image plain' {
        Get-UInt32 (New-BffDdsHeader -Width 64 -Height 64 -MipLevels 7 -DxgiFormat 71) 108 | Should -Be 0x401008
        Get-UInt32 (New-BffDdsHeader -Width 64 -Height 64 -MipLevels 1 -DxgiFormat 71) 108 | Should -Be 0x1000
    }

    It 'marks a cube map, and an array size' {
        $h = New-BffDdsHeader -Width 64 -Height 64 -MipLevels 1 -DxgiFormat 71 -IsCubemap $true -ArraySize 6
        Get-UInt32 $h 108 | Should -Be 0x1008
        Get-UInt32 $h 112 | Should -Be 0xFE00
        Get-UInt32 $h 136 | Should -Be 0x4
        Get-UInt32 $h 140 | Should -Be 6
    }
}

Describe 'Expand-BffBa2Texture' {
    It 'rebuilds a DX10 texture: a header, then every chunk, compressed or not' -TestCases @(
        @{ Compress = $false }, @{ Compress = $true }
    ) {
        $top = New-TestBytes 2048 3; $next = New-TestBytes 512 5
        $path = New-TestBa2 -Path (New-TestPath) -Entry @(
            (New-TestEntry $face -Chunk @($top, $next) -Width 64 -Mips 2 -Dxgi 71 -Compress:$Compress)
        )
        $entry = @((Read-BffBa2Index -Path $path).Entries)[0]
        $out   = Join-Path $TestDrive "out\$Compress\malehead_d.dds"
        Expand-BffBa2Texture -Entry $entry -Destination $out | Should -Be $out

        $bytes = [System.IO.File]::ReadAllBytes($out)
        $bytes.Length | Should -Be (148 + 2048 + 512)
        [BitConverter]::ToUInt32($bytes, 128) | Should -Be 71
        $bytes[148..(148 + 2047)] | Should -Be $top
        $bytes[(148 + 2048)..($bytes.Length - 1)] | Should -Be $next
    }

    It 'copies a GNRL file out as it was, compressed or not' -TestCases @(
        @{ Compress = $false }, @{ Compress = $true }
    ) {
        $dds  = New-TestDds -Dxgi 98 -PayloadSize 3000
        $path = New-TestBa2 -Path (New-TestPath) -Type GNRL -Entry @((New-TestEntry $face -Data $dds -Compress:$Compress))
        $entry = @((Read-BffBa2Index -Path $path).Entries)[0]
        $out   = Expand-BffBa2Texture -Entry $entry -Destination (New-TestPath '.dds')
        [System.IO.File]::ReadAllBytes($out) | Should -Be $dds
    }

    It 'writes a relative destination where PowerShell is, not where the process started' {
        $path  = New-TestBa2 -Path (New-TestPath) -Type GNRL -Entry @((New-TestEntry $face -Data (New-TestDds)))
        $entry = @((Read-BffBa2Index -Path $path).Entries)[0]
        Push-Location $TestDrive
        try { Expand-BffBa2Texture -Entry $entry -Destination 'relative.dds' | Should -Be (Join-Path $TestDrive 'relative.dds') }
        finally { Pop-Location }
    }

    It 'gives texdiag a texture it can read' {
        # 64x64 BC1 is 16x16 blocks of 8 bytes; zeros are valid block data.
        $path = New-TestBa2 -Path (New-TestPath) -Entry @(
            (New-TestEntry $face -Chunk @((New-Object byte[] 2048), (New-Object byte[] 512)) -Width 64 -Mips 2 -Dxgi 71)
        )
        $entry = @((Read-BffBa2Index -Path $path).Entries)[0]
        $out   = Expand-BffBa2Texture -Entry $entry -Destination (New-TestPath '.dds')

        $info = @(Get-BffTextureInfo -Path $out -TexDiagPath (Get-BffTexDiagPath -Root $tool))[0]
        $info.Ok | Should -BeTrue
        "$($info.Width)x$($info.Height) $($info.Format) $($info.MipLevels)" | Should -Be '64x64 BC1_UNORM 2'
    }
}
