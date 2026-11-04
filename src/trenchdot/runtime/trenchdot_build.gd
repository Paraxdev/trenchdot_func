class_name TrenchDotBuild extends RefCounted
## Shared helpers for building TrenchDot maps: node ownership and the map node ids kept on generated nodes.

## Map node id of a generated entity, terrain or scatter node.
const ID_META := &"_td_id"
## Map node id of a generated layer or group node.
const GROUP_META := &"_td_group"
## What the node was last fully built from: the hash of the map text for a build from text or a JSON file, the END
## chunk content id for a binary file, see [method TrenchDotTdmFile.content_id].
const SOURCE_HASH_META := &"_td_source_hash"
## The entity definitions the node was last fully built with, see [method definitions_id].
const DEFINITIONS_META := &"_td_definitions"
## Project setting: build steps that only compute data run on the WorkerThreadPool.
const SETTING_THREADED := "trenchdot/threaded_build"

## File kinds a map key may name, see [method map_resource_path].
const MODEL_FILES: PackedStringArray = ["glb", "gltf", "bbmodel", "obj", "fbx", "blend", "tscn", "scn"]
const IMAGE_FILES: PackedStringArray = ["png", "jpg", "jpeg", "webp", "svg", "tga", "bmp", "hdr", "exr", "dds", "ktx"]
const SOUND_FILES: PackedStringArray = ["ogg", "wav", "mp3"]
const MATERIAL_FILES: PackedStringArray = ["tres", "res", "material"]
const SCENE_FILES: PackedStringArray = ["tscn", "scn"]
const MAP_FILES: PackedStringArray = ["tdm", TrenchDotLegacy.MAP_EXTENSION]

## Paths [method map_resource_path] refused while a [FuncGodotMap] builds, whose report lists them. Outside a build
## each path it refuses warns once.
static var refused_paths: Dictionary = {}
static var collecting_refused := false
## Bumped by [method TrenchDotFGDFile.files_changed].
# Note: this and pack_scans live here because static vars on the TrenchDotFGDFile script made Godot crash on exit
# now and then.
static var pack_files_version := 0
## Pack files a filesystem scan was started for, see [method TrenchDotFGDFile._listed].
static var pack_scans := {}

static func threaded() -> bool:
	return bool(ProjectSettings.get_setting(SETTING_THREADED, true))

## [param path] from a map, simplified, when it names a file inside the project with one of [param extensions], else
## empty. uid:// paths count by the file they stand for. Loading a resource runs any script it embeds, so a map only
## reaches files of the kind its key is for, and never ones outside the project. A name the map gave, which
## [param path] joins to a folder, passes as [param named], so a refusal lists that name once.
static func map_resource_path(path: String, extensions: PackedStringArray, named := "") -> String:
	if path == "":
		return ""
	var simple := path
	if simple.begins_with("uid://"):
		var id := ResourceUID.text_to_id(simple)
		simple = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	simple = simple.simplify_path()
	if simple.begins_with("res://") and not ".." in simple.trim_prefix("res://").split("/") and simple.get_extension().to_lower() in extensions:
		return simple
	var shown := named if named != "" else path
	if collecting_refused:
		refused_paths[shown] = true
	elif not refused_paths.has(shown):
		refused_paths[shown] = true
		push_warning("[TrenchDot] %s is not loaded, a map may only name %s files inside the project" % [shown, ", ".join(extensions)])
	return ""

## Owner for generated nodes: the edited scene when the map is part of it, so the nodes are saved with the scene.
static func scene_owner(map_node: Node) -> Node:
	if map_node.is_inside_tree():
		var edited := map_node.get_tree().edited_scene_root
		if edited and (edited == map_node or edited.is_ancestor_of(map_node)):
			return edited
	return map_node.owner if map_node.owner else map_node

## Sets [param owner_node] on [param node] and its generated children, leaving the insides of instanced scenes alone.
static func set_owner_recursive(node: Node, owner_node: Node) -> void:
	if node != owner_node:
		node.owner = owner_node
	if node.scene_file_path != "" and node != owner_node:
		return
	for child in node.get_children():
		set_owner_recursive(child, owner_node)

## Generated nodes below [param map_node] by map node id, for entities, terrains and scatter sets. Overlays are
## skipped, so a generated node copied into one is never taken for the original.
static func nodes_by_id(map_node: Node) -> Dictionary:
	var out := {}
	var stack: Array[Node] = [map_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != map_node and TrenchDotOverlay.is_kept(n):
			continue
		if n != map_node and n.has_meta(ID_META):
			out[int(n.get_meta(ID_META))] = n
			continue
		stack.append_array(n.get_children())
	return out

## Generated layer and group nodes below [param map_node] by map node id.
static func groups_by_id(map_node: Node) -> Dictionary:
	var out := {}
	var stack: Array[Node] = [map_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != map_node and TrenchDotOverlay.is_kept(n):
			continue
		if n.has_meta(GROUP_META):
			out[int(n.get_meta(GROUP_META))] = n
		if n == map_node or n.has_meta(GROUP_META):
			stack.append_array(n.get_children())
	return out

## The entity definitions a build with [param settings] uses by classname: those of the Entity Fgd, then the C# ones it
## does not define, see [TrenchDotCSharp].
static func definitions(settings: FuncGodotMapSettings) -> Dictionary:
	var out := {}
	if not settings or not settings.entity_fgd:
		return out
	out.merge(settings.entity_fgd.get_entity_definitions())
	out.merge(TrenchDotCSharp.definitions())
	return out

## Identifies what the entity definitions of [param settings] build: every stored value of every definition, with
## resources by path, scripts by path, base class and whether they can be instantiated, and each Node Class by whether
## Godot or a script class knows it. A definition whose script or class only became usable later counts as another.
static func definitions_id(settings: FuncGodotMapSettings) -> int:
	var defs := definitions(settings)
	if defs.is_empty():
		return 0
	var global_classes := {}
	for c in ProjectSettings.get_global_class_list():
		global_classes[str(c["class"])] = true
	var names := defs.keys()
	names.sort()
	var parts := PackedStringArray()
	for classname in names:
		var def: Resource = defs[classname]
		parts.append(classname)
		for p in def.get_property_list():
			if p["usage"] & PROPERTY_USAGE_STORAGE:
				parts.append("%s=%s" % [p["name"], _stable(def.get(p["name"]))])
		var node_class := str(def.get(&"node_class"))
		parts.append("known=%s" % (node_class != "" and (ClassDB.class_exists(node_class) or global_classes.has(node_class) or ResourceLoader.exists(node_class, "Script"))))
	return "\n".join(parts).hash()

static func _stable(value: Variant) -> String:
	if value is Script:
		return "%s:%s:%s" % [value.resource_path, value.get_instance_base_type(), value.can_instantiate()]
	if value is Resource:
		return value.resource_path
	if value is Object:
		return value.get_class()
	if value is Array:
		return "[%s]" % ",".join(value.map(_stable))
	if value is Dictionary:
		return "{%s}" % ",".join(value.keys().map(func(k): return "%s:%s" % [k, _stable(value[k])]))
	return var_to_str(value)

## Whether [param map] was last fully built with the entity definitions its map settings hold now.
static func built_with_current_definitions(map: FuncGodotMap) -> bool:
	return int(map.get_meta(DEFINITIONS_META, 0)) == definitions_id(map.get_map_settings())
