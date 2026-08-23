# 2K face replacer (the mod, not the HD DLC).
#
# With a 2K face mod every slot is 2048, HD DLC or not. This only works when
# LooksMenu is told about it: the engine otherwise downsamples everything to 1024,
# which costs performance and reintroduces the mismatch. Set uTintWidth and
# uTintHeight in F4SE\Plugins\f4ee.ini to 2048.

@{
    Name        = '2K'
    Description = '2K face replacer installed (all slots 2048, HD DLC irrelevant).'

    Sizes = @{
        Diffuse  = 2048
        Normal   = 2048
        Specular = 2048
        Skin     = 2048
        Other    = 2048
    }

    F4EE = @{
        uTintWidth  = 2048
        uTintHeight = 2048
    }
}
