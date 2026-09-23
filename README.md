# TrenchDot addon for Godot

This is the Godot addon of [TrenchDot](https://github.com/Paraxdev/TrenchDot), a brush based level editor for
Godot. It builds the `.tdm` maps the editor saves into Godot scenes: brushes, meshes, displacements, terrains, scatter
sets, entities with their inputs and outputs, and prefabs. It also exports the game config the editor reads to learn
your entities and textures, and keeps a live link to the editor so maps rebuild when you save them.

The documentation lives with the editor at https://paraxdev.github.io/TrenchDot/.

## Installing

The addon has to end up in `res://addons/func_godot`, the folder name the code and its resources expect.

* Download `func_godot-trenchdot-addon.zip` from the
  [TrenchDot releases](https://github.com/Paraxdev/TrenchDot/releases/latest) and extract it into your project
  folder.
* Or add this repository as a git submodule: `git submodule add https://github.com/Paraxdev/trenchdot_func.git addons/func_godot`.

Then enable *TrenchDot* under *Project > Project Settings > Plugins*. Godot 4.7 or newer is needed, and the .NET build
if you want to write entities in C#. The [getting started guide](https://paraxdev.github.io/TrenchDot/getting-started.html)
walks through the first map.

Changes to the addon are tested by the Godot project in the TrenchDot repository, which uses this repository as a
submodule.

## Credits

The addon started as a fork of [FuncGodot](https://github.com/func-godot/func_godot_plugin) by Hannah "EMBYR"
Crawford, Emberlynn Bland, Tim "RhapsodyInGeek" Maccabe and Vera "sinewavey" Lux, itself a rework of
[Qodot](https://github.com/QodotPlugin/Qodot) by Josh "Shifty" Palmer. The `FuncGodot` class names are kept from it.
MIT licensed, see [LICENSE](LICENSE).
