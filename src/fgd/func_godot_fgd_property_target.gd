@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name FuncGodotFGDPropertyTarget extends FuncGodotFGDProperty
## FGD Entity class property definition for target_source and target_destination property types.
##
## FGD Entity class property definition used to generate a target_source or target_destination property for the level editor.
## Inside a prefab instance these properties get the instance's name fixup.

enum FGDTargetType {
	TARGET_SOURCE,
	TARGET_DESTINATION,
}
## The property type shown in the level editor.
@export var fgd_target_type: FGDTargetType = FGDTargetType.TARGET_SOURCE

func get_default_value() -> Variant:
	match typeof(default_value):
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH: return default_value
	return ""
