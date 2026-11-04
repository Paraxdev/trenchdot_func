class_name TrenchDotLegacy extends RefCounted
## The names TrenchDot went by as GodotTrench. Projects set up back then keep working, so the old names live here.

const MAP_EXTENSION := "gtm"
const MAP_FORMAT := "godottrench-map"
const MAP_IMPORTER := "godottrench.gtm"
const _CLASSNAME_PREFIX := "gt_"

## The classname an entity of an old map builds as: gt_door becomes td_door when [param defs] has no definition for
## the old name and one for the new, else [param classname] itself.
static func classname_alias(classname: String, defs: Dictionary) -> String:
	if not classname.begins_with(_CLASSNAME_PREFIX) or defs.has(classname):
		return classname
	var modern := "td_" + classname.trim_prefix(_CLASSNAME_PREFIX)
	return modern if defs.has(modern) else classname
