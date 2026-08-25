# SlotRules.psd1 - which formats are valid for which texture slot.
#
# These rules are the same for every profile, so they live here and not in
# Profiles\*.psd1. Profiles only decide SIZES.
#
# Slots are matched on the filename suffix, i.e. the '_xxx' right before the
# extension. An empty string in Suffixes matches files with no suffix at all
# (plenty of tint masks are just 'AGCP Crescent.dds').
#
# AllowedFormats = formats that are kept as-is. A texture already in one of these
# is never re-encoded, which is what stops the quality loss from repeated runs.
# DefaultFormat  = what to convert to when the source format is NOT in the list.
# Use @('*') to accept any format, i.e. never re-encode this slot for format reasons.

@{
    Slots = @(
        @{
            # Tangent-space normal. Two channels, so BC5.
            Slot           = 'Normal'
            Suffixes       = @('_n', '_normal')
            AllowedFormats = @('BC5_UNORM', 'BC5_SNORM')
            DefaultFormat  = 'BC5_UNORM'
        },
        @{
            # Model-space normal. Deliberately NOT in the Normal slot: an _msn map
            # stores all three axes, so it is an RGB texture and the vanilla ones
            # ship as BC1 and BC3 (FemaleHeadWeathered1_msn.DDS is BC1_UNORM,
            # PiperHead_msn.DDS is BC3_UNORM). Forcing BC5 on those would throw the
            # blue axis away and break the map.
            Slot           = 'ModelSpaceNormal'
            Suffixes       = @('_msn')
            AllowedFormats = @(
                'BC1_UNORM', 'BC1_UNORM_SRGB',
                'BC3_UNORM', 'BC3_UNORM_SRGB',
                'BC7_UNORM', 'BC7_UNORM_SRGB'
            )
            # Vanilla ships _msn as BC1 and BC3, never BC7, so that is what a
            # conversion targets.
            DefaultFormat  = 'BC3_UNORM'
        },
        @{
            # '_specular' spelled out shows up in mods that do not follow the
            # one-letter convention (CaptiveTattoos ships Face_Specular.DDS, a
            # perfectly correct 512 BC5 map that would otherwise be read as a
            # diffuse and blown up to 1024 BC7).
            Slot           = 'Specular'
            Suffixes       = @('_s', '_spec', '_specular')
            AllowedFormats = @('BC5_UNORM', 'BC5_SNORM')
            DefaultFormat  = 'BC5_UNORM'
        },
        @{
            # Skin tone / subsurface / colour maps used by LooksMenu skin overrides.
            # The black face bug is about head diffuse/normal/specular matching the
            # tint masks per slot; these take no part in that, so neither their size
            # nor their format is touched. They are still listed in the report.
            # Without EnforceSize = $false a mod shipping a 2048 _SSS map would get
            # it downscaled to 1024 for no benefit at all.
            Slot           = 'Skin'
            Suffixes       = @('_sk', '_sss', '_c')
            AllowedFormats = @('*')
            # Never actually fires while AllowedFormats is '*', but it still has to
            # name a format the game uses for this slot: vanilla ships BC1 and BC3.
            DefaultFormat  = 'BC3_UNORM'
            EnforceSize    = $false
        },
        @{
            # Diffuse and every tint mask / face detail without a slot suffix.
            # Bethesda ships BC7_UNORM, the CK wiki asks for BC1, and mods use BC3
            # when they need alpha - all three are fine, so all three are kept.
            Slot           = 'Diffuse'
            Suffixes       = @('_d', '_diffuse', '')
            AllowedFormats = @(
                'BC1_UNORM', 'BC1_UNORM_SRGB',
                'BC3_UNORM', 'BC3_UNORM_SRGB',
                'BC7_UNORM', 'BC7_UNORM_SRGB'
            )
            # Reading the game's own archives: of the 220 face diffuse textures
            # Fallout 4 ships, 161 are BC3_UNORM and 59 are BC1_UNORM. Not one is
            # BC7. So when a conversion is unavoidable it targets BC3 - a format
            # the engine demonstrably handles for this slot, and one that keeps
            # the alpha a tint mask may carry.
            #
            # BC7 stays on the allowed list because the HD DLC assets use it and
            # it is strictly higher quality; there is no reason to convert an
            # existing BC7 away.
            DefaultFormat  = 'BC3_UNORM'
        }
    )

    # Slot used when the suffix matches nothing above.
    DefaultSlot = 'Diffuse'

    # Extra formats tolerated for textures under FaceDetails and TintMasks, on top
    # of whatever the slot allows.
    #
    # Fallout 4 itself never uses BC4 for a face texture - checked against all 425
    # in its own archives - so this is not a vanilla format. It is listed anyway
    # because these are greyscale masks rather than colour maps: some mods pick BC4
    # deliberately (Addictol's FaceTints), and converting a single channel mask to
    # a colour format only makes the file bigger and the mask worse. Leaving it
    # alone is the conservative choice; empty this list to convert them instead.
    TintExtraFormats = @('BC4_UNORM', 'BC4_SNORM')
}
