@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name FuncGodotFGDPropertyChoices extends FuncGodotFGDProperty
## FGD Entity class property definition for Choices property types.
##
## FGD Entity class property definition used to generate a choices property
## for the level editor and [FuncGodotParser] retrieval.[br][br]
## Choices are created through the [member choices] [Dictionary] entries.
## Each entry corresponds to a single choice option, where the dictionary key corresponds to
## the choice option value while the dictionary value corresponds to the choice option description.
##
## @tutorial(Valve Developer Wiki FGD Article): https://developer.valvesoftware.com/wiki/FGD#Class_Types_and_Properties

## [Dictionary] of choices shown in the level editor. The dictionary key is the choice option's value,
## while the dictionary value is the choice option's description.[br][br]
## The choice option value may be an [int], [String], [StringName], or [NodePath],
## but the choice option description must be a [String].
@export var choices: Dictionary[Variant, String]

## [member FuncGodotFGDProperty.default_value], or the first choice's value when it is not set.
func get_default_value() -> Variant:
	if default_value != null:
		return default_value
	if not choices.is_empty():
		return choices.keys().front()
	return 0
