# 4K face replacer.
#
# Same rule as 2K, one step up. f4ee.ini uTintWidth/uTintHeight must be 4096 or the
# engine renders your tints at 1024 against 4096 head textures.
#
# Be aware that 4096 tint masks are expensive: LooksMenu allocates the tint render
# target at this size, so character creation and any makeup change get noticeably
# slower.

@{
    Name        = '4K'
    Description = '4K face replacer installed (all slots 4096).'

    Sizes = @{
        Diffuse  = 4096
        Normal   = 4096
        Specular = 4096
        Skin     = 4096
        Other    = 4096
    }

    F4EE = @{
        uTintWidth  = 4096
        uTintHeight = 4096
    }
}
