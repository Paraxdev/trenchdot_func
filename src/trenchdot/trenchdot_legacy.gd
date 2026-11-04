class_name TrenchDotLegacy extends RefCounted
## The names TrenchDot went by as GodotTrench. Projects set up back then keep working, so the old names live here.

const MAP_EXTENSION := "gtm"
const MAP_FORMAT := "godottrench-map"
const MAP_IMPORTER := "godottrench.gtm"
const BBMODEL_IMPORTER := "godottrench.bbmodel"
## Where the Gameplay entities pack was installed.
const PACK_DIR := "res://godottrench/entities"
## The game config the editor read before trenchdot_game.json.
const GAME_FILE := "res://godottrench_game.json"
const PACK_FGD := PACK_DIR + "/gameplay_fgd.tres"
## Persistent group of nodes under a map that a rebuild keeps.
const KEEP_GROUP := &"godottrench_keep"
## Old metadata keys of nodes saved in scenes to the keys that replaced them. A test keeps the new ones in step with
## the constants that use them.
const METAS := {
	&"_gt_id": &"_td_id",
	&"_gt_group": &"_td_group",
	&"_gt_source_hash": &"_td_source_hash",
	&"_gt_definitions": &"_td_definitions",
	&"_gt_units_per_meter": &"_td_units_per_meter",
	&"gt_targetname": &"td_targetname",
	&"gt_transforms": &"td_transforms",
	&"gt_prop_generated": &"td_prop_generated",
	&"godottrench_baked": &"trenchdot_baked",
}
const _SETTINGS_ROOT := "godottrench/"
const _DEFAULT_CONFIG := "res://addons/func_godot/game_config/godottrench/godottrench_game_config.tres"
const _NEW_DEFAULT_CONFIG := "res://addons/func_godot/game_config/trenchdot/trenchdot_game_config.tres"
const _CLASSNAME_PREFIX := "gt_"

## The classname an entity of an old map builds as: gt_door becomes td_door when [param defs] has no definition for
## the old name and one for the new, else [param classname] itself.
static func classname_alias(classname: String, defs: Dictionary) -> String:
	if not classname.begins_with(_CLASSNAME_PREFIX) or defs.has(classname):
		return classname
	var modern := "td_" + classname.trim_prefix(_CLASSNAME_PREFIX)
	return modern if defs.has(modern) else classname

## Copies the project settings of the old [code]godottrench/[/code] section to [code]trenchdot/[/code] where the new
## one is unset, and erases the old ones. Returns whether any setting changed, the caller then saves the project.
static func migrate_settings() -> bool:
	var changed := false
	for info in ProjectSettings.get_property_list():
		var old: String = info["name"]
		if not old.begins_with(_SETTINGS_ROOT):
			continue
		var key := "trenchdot/" + old.trim_prefix(_SETTINGS_ROOT)
		var value: Variant = ProjectSettings.get_setting(old)
		if value is String and value == _DEFAULT_CONFIG:
			value = _NEW_DEFAULT_CONFIG
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, value)
		ProjectSettings.set_setting(old, null)
		changed = true
	return changed

## Moves [param key]'s old metadata name to [param key] on [param node], unless the node already has [param key].
static func upgrade_meta(node: Node, key: StringName) -> void:
	var old: Variant = METAS.find_key(key)
	if old != null and node.has_meta(old):
		if not node.has_meta(key):
			node.set_meta(key, node.get_meta(old))
		node.remove_meta(old)

## Renames the old metadata of [param root] and the nodes below it, like scenes saved by GodotTrench carry.
static func upgrade_metadata(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for old in node.get_meta_list():
			if METAS.has(old):
				upgrade_meta(node, METAS[old])
		stack.append_array(node.get_children())
