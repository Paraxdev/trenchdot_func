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
