# HD DLC - DLCUltraHighResolution enabled.
#
# Since game patch 1.9.4 the engine forces head specular maps to 1024 instead of
# 512 when it sees DLCUltraHighResolution as an enabled plugin. Mod textures that
# still ship a 512 specular then mismatch the 1024 tint specular, which is the
# black/dark face bug.

@{
    Name        = 'HD DLC'
    Description = 'HD Texture Pack DLC enabled, no 2K/4K face replacer.'

    Sizes = @{
        Diffuse  = 1024
        Normal   = 1024
        Specular = 1024
        Skin     = 1024
        Other    = 1024
    }

    F4EE = @{
        uTintWidth  = 1024
        uTintHeight = 1024
    }
}
