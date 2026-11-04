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

## Set while [method pack_fgd] leaves the pack out because Godot's filesystem does not list it yet.
var waiting_for_scan := false
var _merging := false
## Held so the pack is not freed and read from disk again for every build.
var _pack: FuncGodotFGDFile
var _pack_path := ""
var _pack_version := -1

## Makes every TrenchDotFGDFile look for its pack again, the editor integration calls it when project files change.
static func files_changed() -> void:
	TrenchDotBuild.pack_files_version += 1

## The installed pack's FGD file, null when the project has none. In the editor also null until Godot's filesystem
## lists the file: a pack copied in while Godot runs would otherwise load scripts that use pack classes before the
## scan registers those, and those scripts stay broken until a restart.
func pack_fgd() -> FuncGodotFGDFile:
	if pack_fgd_path == "" or _merging or not ResourceLoader.exists(pack_fgd_path):
		return null
	if _pack and _pack_path == pack_fgd_path and _pack_version == TrenchDotBuild.pack_files_version:
		return _pack
	if Engine.is_editor_hint() and not _listed(pack_fgd_path):
		# Note: while Godot scans it lists no file at all, so the pack read before stays.
		if _pack and _pack_path == pack_fgd_path:
			return _pack
		waiting_for_scan = true
		return null
	waiting_for_scan = false
	_pack = load(pack_fgd_path) as FuncGodotFGDFile
	_pack_path = pack_fgd_path
	_pack_version = TrenchDotBuild.pack_files_version
	if _pack and Engine.is_editor_hint():
		_reload_broken_scripts(_pack)
	return _pack

## Compiles the pack's entity scripts again that failed to, like those of an older pack that Godot loaded before it
## registered the classes they use. Godot keeps such a script broken until a restart otherwise.
static func _reload_broken_scripts(pack: FuncGodotFGDFile) -> void:
	for def in pack.get_fgd_classes():
		var script: Script = def.get(&"script_class")
		if script and not script.can_instantiate():
			script.reload(true)

## Whether the editor's filesystem lists [param path]. Starts a scan when it does not, and gives up waiting for a file
## that one scan did not list, like one in a folder Godot ignores.
static func _listed(path: String) -> bool:
	if not Engine.has_singleton(&"EditorInterface"):
		return true
	var fs: Object = Engine.get_singleton(&"EditorInterface").get_resource_filesystem()
	if fs.get_file_type(path) != "":
		TrenchDotBuild.pack_scans.erase(path)
		return true
	if fs.is_scanning():
		return false
	if TrenchDotBuild.pack_scans.has(path):
		return true
	TrenchDotBuild.pack_scans[path] = true
	fs.scan()
	return false

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
