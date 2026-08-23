# VanillaFaceTextures.psd1 - GENERATED, do not edit by hand.
#
# Built from the TXST records whose EditorID starts with 'SkinHead' in:
#   Fallout4.esm                     17 sets
#
# These are the face texture paths the game itself declares, which is how the
# tool finds head textures whose file name does not contain "head" -
# Preston_d.dds, Mayor_s.dds and Piper's set would all be missed otherwise.
#
# Paths are lower case, backslash separated and relative to textures\.

@{
    Textures = @{
        'actors\character\basehumanfemale\basefemalehead_d.dds' = 'Diffuse'
        'actors\character\basehumanfemale\basefemalehead_n.dds' = 'Normal'
        'actors\character\basehumanfemale\basefemalehead_s.dds' = 'Specular'
        'actors\character\basehumanfemale\basefemaleheadwrinkles_n.dds' = 'Normal'
        'actors\character\basehumanfemale\femaleheadweathered1_d.dds' = 'Diffuse'
        'actors\character\basehumanfemale\femaleheadweathered1_n.dds' = 'Normal'
        'actors\character\basehumanfemale\femaleheadweathered1_s.dds' = 'Specular'
        'actors\character\basehumanmale\basemalehead_d.dds' = 'Diffuse'
        'actors\character\basehumanmale\basemalehead_n.dds' = 'Normal'
        'actors\character\basehumanmale\basemalehead_s.dds' = 'Specular'
        'actors\character\basehumanmale\headwrinkles_n.dds' = 'Normal'
        'actors\character\basehumanmale\youngmalehead_d.dds' = 'Diffuse'
        'actors\character\basehumanmale\youngmalehead_n.dds' = 'Normal'
        'actors\character\basehumanmale\youngmalehead_s.dds' = 'Specular'
        'actors\character\mayor\mayor_d.dds' = 'Diffuse'
        'actors\character\mayor\mayor_n.dds' = 'Normal'
        'actors\character\mayor\mayor_s.dds' = 'Specular'
        'actors\character\midagedfemale\midagefemalehead_d.dds' = 'Diffuse'
        'actors\character\midagedfemale\midagefemalehead_n.dds' = 'Normal'
        'actors\character\midagedfemale\midagefemalehead_s.dds' = 'Specular'
        'actors\character\oldhumanfemale\oldhumanfemalehead_d.dds' = 'Diffuse'
        'actors\character\oldhumanfemale\oldhumanfemalehead_n.dds' = 'Normal'
        'actors\character\oldhumanfemale\oldhumanfemalehead_s.dds' = 'Specular'
        'actors\character\oldhumanmale\oldhumanmalehead_d.dds' = 'Diffuse'
        'actors\character\oldhumanmale\oldhumanmalehead_n.dds' = 'Normal'
        'actors\character\oldhumanmale\oldhumanmalehead_s.dds' = 'Specular'
        'actors\character\piper\piperhead_d.dds' = 'Diffuse'
        'actors\character\piper\piperhead_n.dds' = 'Normal'
        'actors\character\piper\piperhead_s.dds' = 'Specular'
        'actors\character\preston\preston_d.dds' = 'Diffuse'
        'actors\character\preston\preston_n.dds' = 'Normal'
        'actors\character\preston\preston_s.dds' = 'Specular'
    }

    # Shared helper maps referenced by face texture sets that must never be
    # resized: they are not per-actor face textures.
    Exclude = @(
        'actors\character\humancommon\blankdetailmap.dds'
    )
}
