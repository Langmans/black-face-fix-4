# Vanilla - no HD Texture Pack DLC, no 2K/4K face replacer.
#
# The specular being 512 while diffuse and normal are 1024 is not a mistake:
# that is what the base game ships. See ousnius on Nexus 21907 and the CK wiki
# Dark Face Bug page.

@{
    Name        = 'Vanilla'
    Description = 'Base game: no HD Texture Pack DLC and no 2K/4K face replacer.'

    Sizes = @{
        Diffuse  = 1024
        Normal   = 1024
        Specular = 512
        Skin     = 1024
        Other    = 1024
    }

    # Expected LooksMenu [CharGen] setting. Used for the cross-check warning only;
    # nothing is written to f4ee.ini unless you ask for it.
    F4EE = @{
        uTintWidth  = 1024
        uTintHeight = 1024
    }
}
