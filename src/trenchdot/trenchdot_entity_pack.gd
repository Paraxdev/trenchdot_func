@tool
class_name TrenchDotEntityPack extends RefCounted
## The Gameplay entities pack: doors, buttons, triggers, logic, spawners, props and effects.
##
## The addon keeps it in [constant TEMPLATE], which a [code].gdignore[/code] hides from Godot, and installing copies it
## into [constant DIR], where the project owns the copies. The TrenchDot editor installs and updates it from its setup
## window. Godot installs it by itself only when maps use its entities and the project defines them nowhere else, so
## maps made while the entities were part of the addon keep working after an update.

const TEMPLATE := "res://addons/func_godot/gameplay_pack"
const DIR := "res://trenchdot/entities"
const MANIFEST := "pack.json"
const NOT_COPIED := [".gdignore", MANIFEST]

static func available() -> bool:
	return FileAccess.file_exists(TEMPLATE.path_join(MANIFEST))

static func installed() -> bool:
	return FileAccess.file_exists(DIR.path_join(MANIFEST))

## Writes the template's .gdignore when it is missing, as after unpacking the addon without hidden files, which makes
## Godot load every pack class twice. Returns whether it wrote one.
static func hide_template(template := TEMPLATE) -> bool:
	if not FileAccess.file_exists(template.path_join(MANIFEST)) or FileAccess.file_exists(template.path_join(".gdignore")):
		return false
	return FileAccess.open(template.path_join(".gdignore"), FileAccess.WRITE) != null

static func classnames() -> PackedStringArray:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEMPLATE.path_join(MANIFEST)))
	var out := PackedStringArray()
	if manifest is Dictionary:
		for entity in manifest.get("entities", []):
			out.append(str(entity.get("classname", "")))
	return out

## The pack's classnames that the .tdm maps under [param root] use and [param defined] lacks.
static func missing(defined: Dictionary, root := "res://") -> PackedStringArray:
	var used := {}
	for path in _maps(root, PackedStringArray()):
		var map: Variant = TrenchDotTdmFile.read(path)["map"]
		if map != null:
			_classnames_in(map, used)
	return PackedStringArray(Array(classnames()).filter(func(c): return used.has(c) and not defined.has(c)))

## Adds every classname in a decoded map to [param out].
static func _classnames_in(map: Variant, out: Dictionary) -> void:
	var stack: Array = [map]
	while not stack.is_empty():
		var value: Variant = stack.pop_back()
		if value is Dictionary:
			if value.get("classname") is String:
				out[value["classname"]] = true
			stack.append_array(value.values())
		elif value is Array:
			stack.append_array(value)

static func _maps(dir: String, out: PackedStringArray) -> PackedStringArray:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in TrenchDotBuild.MAP_FILES:
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		var sub := dir.path_join(d)
		if not d.begins_with(".") and not FileAccess.file_exists(sub.path_join(".gdignore")):
			_maps(sub, out)
	return out

static func _files(dir: String, rel: String, out: PackedStringArray) -> PackedStringArray:
	for f in DirAccess.get_files_at(dir.path_join(rel)):
		var path := rel.path_join(f) if rel != "" else f
		if not path in NOT_COPIED:
			out.append(path)
	for d in DirAccess.get_directories_at(dir.path_join(rel)):
		_files(dir, rel.path_join(d) if rel != "" else d, out)
	return out

## Copies the template into [param to], keeping every file already there, and records what it wrote the way the
## TrenchDot editor does, so its updates can tell edited files apart. Returns the files written.
static func install(to_dir := DIR) -> PackedStringArray:
	var written := PackedStringArray()
	if not available():
		return written
	var record := {}
	for rel in _files(TEMPLATE, "", PackedStringArray()):
		var from := TEMPLATE.path_join(rel)
		var to := to_dir.path_join(rel)
		var hash := FileAccess.get_sha256(from)
		if FileAccess.file_exists(to):
			if FileAccess.get_sha256(to) == hash:
				record[rel] = hash
			continue
		DirAccess.make_dir_recursive_absolute(to.get_base_dir())
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(from), ProjectSettings.globalize_path(to)) == OK:
			written.append(rel)
			record[rel] = hash
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEMPLATE.path_join(MANIFEST)))
	if manifest is Dictionary:
		manifest["files"] = record
		var file := FileAccess.open(to_dir.path_join(MANIFEST), FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(manifest, "  ", false))
	return written

## Installs the pack when maps use entities of it that [param fgd] does not define. Returns the missing classnames.
static func install_for_maps(fgd: FuncGodotFGDFile) -> PackedStringArray:
	if installed() or not available():
		return PackedStringArray()
	var defined: Dictionary = fgd.get_entity_definitions() if fgd else {}
	var need := missing(defined)
	if not need.is_empty():
		var written := install()
		print("[TrenchDot] the maps use %s, which now come with the Gameplay entities pack. Installed it into %s (%d files), where the project owns it." % [", ".join(need), DIR, written.size()])
	return need
