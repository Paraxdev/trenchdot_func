@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name TrenchDotFGDFile extends FuncGodotFGDFile
## The addon's core entities, followed by the project's installed entity pack.
##
## The Gameplay entities pack is not part of the addon. Installing it copies its definitions and scripts into
## [member pack_fgd_path], where the project owns them. This file reads them from there, so every FGD that has it as a
## base, like the addon's defaults and the demo's, gets the pack without listing it. When two definitions share a
## classname the later one wins: the core, then the pack, then the entities of an FGD that has this one as its base.

## Where an installed entity pack keeps its FGD file. Nothing is added when there is no file there.
@export_file("*.tres") var pack_fgd_path := "res://trenchdot/entities/gameplay_fgd.tres"

var _merging := false
## Held so the pack is not freed and read from disk again for every build.
var _pack: FuncGodotFGDFile
var _pack_path := ""

## The installed pack's FGD file, null when the project has none.
func pack_fgd() -> FuncGodotFGDFile:
	if pack_fgd_path == "" or _merging or not ResourceLoader.exists(pack_fgd_path):
		return null
	if not _pack or _pack_path != pack_fgd_path:
		_pack = load(pack_fgd_path) as FuncGodotFGDFile
		_pack_path = pack_fgd_path
	return _pack

func get_entity_definitions() -> Dictionary[String, FuncGodotFGDEntityClass]:
	var res := super()
	var pack := pack_fgd()
	if pack:
		# A pack FGD that lists this file as a base would come back here.
		_merging = true
		var defs := pack.get_entity_definitions()
		_merging = false
		for key in defs:
			res[key] = defs[key]
	return res
