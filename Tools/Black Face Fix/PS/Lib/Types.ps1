# Types.ps1 - data model for BlackFaceFix V4
#
# Dot-source this file BEFORE any other Lib file. PowerShell 5.1 classes are only
# visible to the caller when the defining file is dot-sourced (Import-Module hides
# them), which is why the whole library uses dot-sourcing instead of .psm1 modules.

# One texture "slot" (Diffuse / Normal / Specular / Skin). Which formats are legal
# for a slot never changes between profiles, so this lives in Rules\SlotRules.psd1
# and is shared by all four profiles.
class BffSlotRule {
    [string]   $Slot
    [string[]] $Suffixes        # '_s', '_n', ... ; '' means "no suffix at all"
    [string[]] $AllowedFormats  # DXGI names that are valid as-is for this slot
    [string]   $DefaultFormat   # what to convert to when the source format is invalid
    [bool]     $EnforceSize     # $false: report the size but never change it

    [bool] AllowsFormat([string] $dxgi) {
        # '*' means "any format is fine for this slot", i.e. never re-encode for
        # format reasons. Used by the Skin slot.
        if ($this.AllowedFormats -contains '*') { return $true }
        return $this.AllowedFormats -contains $dxgi
    }
}

# A resolution profile: vanilla / HD DLC / 2K / 4K. Holds sizes only - never formats.
class BffProfile {
    [string]    $Name
    [string]    $Description
    [hashtable] $Sizes          # slot name -> edge length in pixels
    [hashtable] $F4EE           # expected LooksMenu uTintWidth / uTintHeight
    [string]    $SourcePath

    [int] SizeFor([string] $slot) {
        if ($this.Sizes.ContainsKey($slot)) { return [int] $this.Sizes[$slot] }
        return [int] $this.Sizes['Other']
    }
}

# One texture found on disk or inside an archive, after texdiag/BA2 inspection.
class BffTexture {
    [string] $FullName       # loose file path, or the DDS path inside the archive
    [string] $Name
    [string] $RelativePath   # textures\actors\character\... (used for the output mod)
    [string] $ModName        # MO2 mod folder name, or '(game data)'
    [string] $Origin         # Loose | GameData | BA2
    [string] $ArchivePath    # only set when Origin is BA2
    [int]    $Width
    [int]    $Height
    [string] $Format         # DXGI name as reported by texdiag / the BA2 file table
    [int]    $MipLevels
    [string] $Slot

    [string] Describe() {
        return ('{0}x{1} {2}' -f $this.Width, $this.Height, $this.Format)
    }
}

# The decision for one texture, including the human-readable justification that
# ends up in the console table, the CSV and the GUI grid.
class BffPlan {
    [BffTexture] $Texture
    [int]        $TargetWidth
    [int]        $TargetHeight
    [string]     $TargetFormat
    [bool]       $SizeOk
    [bool]       $FormatOk
    # Skip              - already matches the profile, nothing to do
    # Resize            - wrong size, format is fine
    # Reformat          - right size, format is invalid for the slot
    # ResizeAndReformat - both
    # Review            - tripped a safety rail (not square / too small); reported, not touched
    # Error             - could not be read
    [string]     $Action
    [string]     $Reason
    [string]     $Destination
    [string]     $Error

    [bool] NeedsWork() {
        return $this.Action -in @('Resize', 'Reformat', 'ResizeAndReformat')
    }

    [string] Describe() {
        return ('{0}x{1} {2}' -f $this.TargetWidth, $this.TargetHeight, $this.TargetFormat)
    }
}

# One entry in a BA2 archive's file table.
class BffArchiveEntry {
    [string] $ArchivePath
    [string] $InternalPath
    [int]    $Width
    [int]    $Height
    [string] $Format
    [int]    $MipLevels
    [int]    $NumChunks
    [object] $Chunks         # array of hashtables: Offset/PackedSize/UnpackedSize/StartMip/EndMip
    [long]   $Offset         # GNRL only
    [int]    $PackedSize     # GNRL only
    [int]    $UnpackedSize   # GNRL only
    [bool]   $HasMetadata    # false for GNRL entries we did not probe
}
