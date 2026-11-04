@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name TrenchDotGameConfig extends Resource
## Game configuration for the TrenchDot level editor.
##
## Exports [code]trenchdot_game.json[/code] with entity definitions from a [FuncGodotFGDFile], texture settings
## from [FuncGodotMapSettings], and I/O outputs and inputs derived from entity scripts (signals and methods). Its
## [code]build[/code] block names the classes Godot builds maps with, see [method build_classes].

const FORMAT_VERSION := 1
const DEFAULT_OUTPUT := "res://trenchdot_game.json"
## Lint lists at most this many classnames per warning.
const LINT_NAMES := 8

@export_tool_button("Export TrenchDot Game Config") var _export_button: Callable = export_file

@export var game_name: String = "FuncGodot"
@export var fgd_file: FuncGodotFGDFile = preload("res://addons/func_godot/fgd/trenchdot_default_fgd.tres")
@export var map_settings: FuncGodotMapSettings = preload("res://addons/func_godot/func_godot_default_map_settings.tres")
## Written relative to the project, the TrenchDot editor looks for it in the project root.
@export_file("*.json") var output_path: String = DEFAULT_OUTPUT
## Texture size assumed by the editor when an image cannot be read.
@export var fallback_texture_size: int = FuncGodotUtil.FALLBACK_TEXTURE_SIZE
## Folders searched for C# entity classes ([TrenchDotEntity]) and C# node classes named by FGD entries.
@export var csharp_source_dirs: PackedStringArray = ["res://"]

static func _id_to_godot(v: Vector3) -> Array:
	return [v.y, v.z, v.x]

static func _color_hex(c: Color) -> String:
	return "#" + c.to_html(true)

static func _property_def(name: String, value: Variant, description: Variant) -> Dictionary:
	var desc := ""
	var default_override: Variant = null
	if description is Array and description.size() > 0:
		desc = str(description[0])
		if description.size() > 1:
			default_override = description[1]
	elif description != null:
		desc = str(description)
	if value is FuncGodotFGDProperty:
		return _fgd_property_def(name, value, desc)
	var def := { "name": name, "type": "string", "default": "", "description": desc }
	match typeof(value):
		TYPE_INT:
			def["type"] = "int"
			def["default"] = str(value)
		TYPE_FLOAT:
			def["type"] = "float"
			def["default"] = str(value)
		TYPE_BOOL:
			def["type"] = "bool"
			def["default"] = "1" if value else "0"
		TYPE_STRING, TYPE_STRING_NAME:
			def["default"] = str(value)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			def["type"] = "vector2"
			def["default"] = "%s %s" % [value.x, value.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			def["type"] = "vector3"
			def["default"] = "%s %s %s" % [value.x, value.y, value.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			def["default"] = "%s %s %s %s" % [value[0], value[1], value[2], value[3]]
		TYPE_COLOR:
			def["type"] = "color"
			def["default"] = "%s %s %s" % [value.r8, value.g8, value.b8]
		TYPE_DICTIONARY:
			def["type"] = "choices"
			var options: Array = []
			for label in value:
				options.append([str(label), str(value[label])])
			def["options"] = options
			if default_override != null:
				def["default"] = str(default_override)
			elif value.size() > 0:
				def["default"] = str(value[value.keys()[0]])
		TYPE_ARRAY:
			def["type"] = "flags"
			var options: Array = []
			var defaults: Array = []
			var sum := 0
			for flag in value:
				if flag is Array and flag.size() >= 2:
					options.append([str(flag[0]), str(flag[1])])
					if flag.size() > 2 and flag[2]:
						defaults.append(int(flag[1]))
						sum += int(flag[1])
			def["options"] = options
			def["default_flags"] = defaults
			def["default"] = str(sum)
		TYPE_NODE_PATH:
			def["type"] = "target_destination"
		TYPE_OBJECT:
			if value is Resource:
				def["type"] = "resource"
				def["default"] = value.resource_path
			else:
				def["type"] = "target_source"
		TYPE_NIL:
			def["type"] = "target_source"
	# FuncGodot stores names as plain strings, the editor offers pickers for them.
	if name == "targetname":
		def["type"] = "target_source"
	elif name in ["target", "killtarget", "parent"]:
		def["type"] = "target_destination"
	return def

static func _class_property_defs(def: FuncGodotFGDEntityClass, skip: Dictionary) -> Array:
	var props: Array = []
	var declared_types: Dictionary = def.meta_properties.get("property_types", {})
	for key in def.class_properties:
		if skip.has(key):
			continue
		var prop := _property_def(key, def.class_properties[key], def.class_property_descriptions.get(key, null))
		if declared_types.has(key):
			prop["type"] = str(declared_types[key])
		props.append(prop)
	return props

## The resource sets the type itself, so unlike plain values it is not inferred from names like target or parent.
static func _fgd_property_def(name: String, prop: Variant, desc: String) -> Dictionary:
	if prop.description != "":
		desc = prop.description
	var def := { "name": name, "type": "string", "default": "", "description": desc }
	if prop is FuncGodotFGDPropertyChoices:
		def["type"] = "choices"
		var options: Array = []
		for value in prop.choices:
			options.append([prop.choices[value], str(value)])
		def["options"] = options
		def["default"] = str(prop.get_default_value())
	elif prop is FuncGodotFGDPropertyFlags:
		def["type"] = "flags"
		var options: Array = []
		var defaults: Array = []
		for flag in prop.flags:
			if not flag:
				continue
			var bit: int = 1 << flag.index
			options.append([flag.name if flag.name != "" else "Flag %d" % flag.index, str(bit)])
			if flag.enabled:
				defaults.append(bit)
		def["options"] = options
		def["default_flags"] = defaults
		def["default"] = str(prop.get_default_value())
	elif prop is FuncGodotFGDPropertyColor:
		def["type"] = "color"
		var c: Color = prop.get_default_value()
		# The editor and TrenchDotIO.to_color only read 0..1 when a part has a decimal point.
		if prop.fgd_color_type == FuncGodotFGDPropertyColor.FGDColorType.COLOR1:
			def["default"] = "%.3f %.3f %.3f" % [c.r, c.g, c.b]
		else:
			def["default"] = "%s %s %s" % [c.r8, c.g8, c.b8]
	elif prop is FuncGodotFGDPropertyTarget:
		var destination: bool = prop.fgd_target_type == FuncGodotFGDPropertyTarget.FGDTargetType.TARGET_DESTINATION
		def["type"] = "target_destination" if destination else "target_source"
		def["default"] = str(prop.get_default_value())
	else:
		return _property_def(name, prop.get_default_value(), desc)
	return def

## An input or output entry: its argument names and, in [code]type[/code], one type name for each of them (bool, int,
## float, string, vector3, color, node or variant), which the editor uses to offer the right parameter field.
static func _io(io_name: String, args: Array) -> Dictionary:
	var io := { "name": io_name, "parameter": ", ".join(args.map(func(a): return a["name"])) }
	if not args.is_empty():
		io["type"] = ", ".join(args.map(_io_type))
	return io

static func _io_type(arg: Dictionary) -> String:
	match int(arg.get("type", TYPE_NIL)):
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING, TYPE_STRING_NAME:
			return "string"
		TYPE_VECTOR3:
			return "vector3"
		TYPE_COLOR:
			return "color"
		TYPE_OBJECT:
			return "node" if _is_node_class(str(arg.get("class_name", ""))) else "variant"
	return "variant"

## True for Node and every engine or script class below it. An empty or unknown name is not one.
static func _is_node_class(class_id: String) -> bool:
	var bases := {}
	for entry in ProjectSettings.get_global_class_list():
		bases[str(entry["class"])] = str(entry["base"])
	var seen := {}
	while class_id != "" and not seen.has(class_id):
		if ClassDB.class_exists(class_id):
			return ClassDB.is_parent_class(class_id, "Node")
		seen[class_id] = true
		class_id = bases.get(class_id, "")
	return false

static func _script_io(script: Script, outputs: Array, inputs: Array) -> void:
	if not script:
		return
	for s in script.get_script_signal_list():
		outputs.append(_io(s["name"], s.get("args", [])))
	var seen := {}
	for m in script.get_script_method_list():
		var method_name: String = m["name"]
		if method_name.begins_with("_") or seen.has(method_name):
			continue
		seen[method_name] = true
		inputs.append(_io(method_name, m.get("args", [])))

static func _class_io(node_class: String, outputs: Array) -> void:
	if node_class == "" or not ClassDB.class_exists(node_class):
		return
	var cls := node_class
	# Walk up to (but not including) Node3D so e.g. Area3D reports body_entered but not tree_entered.
	while cls != "" and cls != "Node3D" and cls != "Node" and cls != "Object":
		for s in ClassDB.class_get_signal_list(cls, true):
			outputs.append(_io(s["name"], s.get("args", [])))
		cls = ClassDB.get_parent_class(cls)

## Where each classname of [param fgd] is defined, as an Array of res:// paths in the order FuncGodot merges them: base
## files first, then the file's own entities, then an installed pack. The last one is the one maps get.
static func definition_sources(fgd: FuncGodotFGDFile, out: Dictionary = {}, visiting: Array = []) -> Dictionary:
	if not fgd or fgd in visiting:
		return out
	visiting.append(fgd)
	for base in fgd.base_fgd_files:
		if base is FuncGodotFGDFile:
			definition_sources(base, out, visiting)
	for def in fgd.get_fgd_classes():
		if not (def is FuncGodotFGDPointClass or def is FuncGodotFGDSolidClass) or def.classname.replace(" ", "") == "":
			continue
		# Definitions saved inside the FGD file have a sub-resource path, the file names them better.
		var where: String = def.resource_path if def.resource_path != "" and not def.resource_path.contains("::") else fgd.resource_path
		var list: Array = out.get_or_add(def.classname, [])
		list.erase(where)
		list.append(where)
	if fgd is TrenchDotFGDFile:
		definition_sources(fgd.pack_fgd(), out, visiting)
	visiting.erase(fgd)
	return out

## What map nodes without map settings of their own build with, the ones the
## [code]func_godot/default_map_settings[/code] project setting names, as
## [code]{map_settings, entity_fgd, classes}[/code]: their path, the path of their Entity Fgd and the sorted classnames
## it defines, with the C# entity classes a build adds. The TrenchDot editor checks its entities against it.
static func build_classes() -> Dictionary:
	var settings := FuncGodotMap.default_map_settings()
	var fgd := settings.entity_fgd if settings else null
	var names := {}
	if fgd:
		for classname in fgd.get_entity_definitions():
			names[classname] = true
	for entry in TrenchDotCSharp.scan():
		names[str(entry["classname"])] = true
	var classes := PackedStringArray(names.keys())
	classes.sort()
	return {
		"map_settings": str(ProjectSettings.get_setting(FuncGodotMap.SETTING_DEFAULT_MAP_SETTINGS, FuncGodotMap.ADDON_MAP_SETTINGS)),
		"entity_fgd": fgd.resource_path if fgd else "",
		"classes": classes,
	}

func build_config() -> Dictionary:
	var entities: Array = []
	var defs: Dictionary = fgd_file.get_entity_definitions() if fgd_file else {}
	for classname in defs:
		var def: FuncGodotFGDEntityClass = defs[classname]
		var is_solid := def is FuncGodotFGDSolidClass
		var meta: Dictionary = def.meta_properties
		var entry := {
			"classname": classname,
			"type": "solid" if is_solid else "point",
			"description": def.description,
			"color": _color_hex(meta.get("color", Color(0.8, 0.8, 0.8))),
			"node_class": def.node_class,
			"group": classname.get_slice("_", 0),
		}
		# The groups the entity assembler adds the node to, so the editor can resolve @group targets.
		var groups: Array = []
		for g in (Array(map_settings.entity_node_groups) if map_settings else []) + Array(def.node_groups):
			if g != "" and not g in groups:
				groups.append(g)
		if not groups.is_empty():
			entry["node_groups"] = groups
		var size: Variant = meta.get("size", null)
		if size is AABB:
			# FuncGodot stores FGD sizes as AABB(min, max) in id axes.
			entry["size"] = [_id_to_godot(size.position), _id_to_godot(size.size)]

		var props := _class_property_defs(def, {})
		# Keys the editor lists that a build leaves out unless the map sets them, unlike class_properties, whose
		# defaults it fills in.
		var listed: Variant = meta.get("editor_properties", null)
		if listed is FuncGodotFGDEntityClass:
			props.append_array(_class_property_defs(listed, def.class_properties))
		entry["properties"] = props
		if meta.get("gizmos", []) is Array and not meta.get("gizmos", []).is_empty():
			entry["gizmos"] = meta["gizmos"]

		var outputs: Array = []
		var inputs: Array = []
		var script: Script = def.get("script_class")
		# C# global classes cannot load in non .NET builds, their I/O is read from the source instead.
		if not script and def.node_class != "" and not ClassDB.class_exists(def.node_class) and not FuncGodotEntityAssembler.get_script_by_class_name(def.node_class):
			var cs := TrenchDotCSharp.class_io(def.node_class, csharp_source_dirs)
			if not cs.is_empty():
				outputs.append_array(cs["outputs"])
				inputs.append_array(cs["inputs"])
				entry["script"] = cs["script"]
		if def is FuncGodotFGDPointClass and def.scene_file:
			entry["scene"] = def.scene_file.resource_path
			var scene: PackedScene = def.scene_file
			var ext: String = scene.resource_path.get_extension().to_lower()
			if ext == "glb" or ext == "gltf":
				entry["model"] = scene.resource_path
			var state: SceneState = scene.get_state()
			if state and state.get_node_count() > 0:
				for i in state.get_node_property_count(0):
					if state.get_node_property_name(0, i) == &"script":
						script = state.get_node_property_value(0, i)
				if entry["node_class"] == "":
					entry["node_class"] = str(state.get_node_type(0))
		if script:
			entry["script"] = script.resource_path
		elif def.node_class != "" and not ClassDB.class_exists(def.node_class):
			script = FuncGodotEntityAssembler.get_script_by_class_name(def.node_class)
		_script_io(script, outputs, inputs)
		_class_io(str(entry["node_class"]), outputs)
		# Curated lists keep helper methods of entity scripts out of the editor's input pickers.
		for pair in [["outputs", outputs], ["inputs", inputs]]:
			var allowed = meta.get(pair[0], null)
			if allowed is Array and not allowed.is_empty():
				var list: Array = pair[1]
				var kept := list.filter(func(io): return io["name"] in allowed)
				for name_value in allowed:
					if not kept.any(func(io): return io["name"] == name_value):
						kept.append({ "name": name_value, "parameter": "" })
				list.assign(kept)
		entry["outputs"] = outputs
		entry["inputs"] = inputs
		entities.append(entry)

	var known := entities.map(func(e): return e["classname"])
	for cs_entry in TrenchDotCSharp.scan(csharp_source_dirs):
		if not cs_entry["classname"] in known:
			entities.append(cs_entry)

	var clashes: Array = []
	var sources := definition_sources(fgd_file)
	for classname in sources:
		if sources[classname].size() > 1:
			clashes.append({ "classname": classname, "definitions": sources[classname] })

	var ms := map_settings if map_settings else FuncGodotMapSettings.new()
	var config := {
		"format": "trenchdot-game",
		"version": FORMAT_VERSION,
		"name": game_name,
		"units_per_meter": ms.inverse_scale_factor,
		"textures": {
			"base_dir": ms.base_texture_dir,
			"extensions": Array(ms.texture_file_extensions),
			"material_dir": ms.base_material_dir,
			"material_extension": ms.material_file_extension,
			"fallback_size": fallback_texture_size,
		},
		"tool_textures": { "clip": ms.clip_texture, "skip": ms.skip_texture, "origin": ms.origin_texture, "sky": ms.sky_texture },
		"entities": entities,
		"build": build_classes(),
	}
	if not clashes.is_empty():
		config["clashes"] = clashes
	return config

## Problems in [member fgd_file]'s [code]meta_properties[/code] that [method build_config] exports without complaint.
## An empty [code]inputs[/code] or [code]outputs[/code] array means no curation (every discovered one stays), not
## zero entries, and [code]size[/code] needs an [AABB] with a positive size on every axis. Also warns when
## [member fgd_file] and the Entity Fgd of the map settings maps build with, see [method build_classes], define
## different classes.
func lint() -> Array[String]:
	var warnings: Array[String] = []
	var defs: Dictionary = fgd_file.get_entity_definitions() if fgd_file else {}
	for classname in defs:
		var meta: Dictionary = defs[classname].meta_properties
		for key in ["inputs", "outputs"]:
			if meta.has(key) and meta[key] is Array and meta[key].is_empty():
				warnings.append("%s: meta_properties.%s is an empty array, which keeps every discovered one (no curation). Remove the key or list at least one name." % [classname, key])
		if meta.has("size"):
			var size: Variant = meta["size"]
			if not (size is AABB) or size.size.x <= 0.0 or size.size.y <= 0.0 or size.size.z <= 0.0:
				warnings.append("%s: meta_properties.size must be an AABB with a positive size on every axis." % classname)
	var settings := FuncGodotMap.default_map_settings()
	var build_fgd := settings.entity_fgd if settings else null
	if build_fgd and build_fgd != fgd_file:
		var theirs := build_fgd.get_entity_definitions().keys()
		var mine := defs.keys()
		var fgd := "fgd_file %s" % fgd_file.resource_path if fgd_file and fgd_file.resource_path != "" else "fgd_file"
		var built := "the FGD maps build with, %s (Entity Fgd of %s)" % [build_fgd.resource_path, settings.resource_path]
		var unbuilt := mine.filter(func(c): return not c in theirs)
		unbuilt.sort()
		if not unbuilt.is_empty():
			warnings.append("%s defines %s, which %s lacks. Maps that use them build plain nodes without script or collision." % [fgd, _names(unbuilt), built])
		var unoffered := theirs.filter(func(c): return not c in mine)
		unoffered.sort()
		if not unoffered.is_empty():
			warnings.append("%s defines %s, which %s lacks, so TrenchDot does not offer them." % [built, _names(unoffered), fgd])
	return warnings

static func _names(classnames: Array) -> String:
	var shown := ", ".join(PackedStringArray(classnames.slice(0, LINT_NAMES)))
	return shown + (" and %d more" % (classnames.size() - LINT_NAMES) if classnames.size() > LINT_NAMES else "")

func export_file() -> Error:
	for w in lint():
		push_warning("[TrenchDot] %s" % w)
	var text := JSON.stringify(build_config(), "  ", false)
	var path := DEFAULT_OUTPUT if output_path == TrenchDotLegacy.GAME_FILE else output_path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("[TrenchDot] cannot write %s" % path)
		return ERR_FILE_CANT_WRITE
	file.store_string(text)
	file.close()
	print("[TrenchDot] game config exported to ", ProjectSettings.globalize_path(path))
	if path == DEFAULT_OUTPUT and FileAccess.file_exists(TrenchDotLegacy.GAME_FILE):
		DirAccess.remove_absolute(TrenchDotLegacy.GAME_FILE)
	return OK
