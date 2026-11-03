@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name FuncGodotFGDPropertyColor extends FuncGodotFGDProperty
## FGD Entity class property definition for color property types.
##
## FGD Entity class property definition used to generate a color property for the level editor.
## Color properties can be two different types:[br]
## - [b]color255[/b] : 8 bit RGB values ranging between 0-255.[br]
## - [b]color1[/b] : Float RGB values ranging between 0.0-1.0.[br]

enum FGDColorType {
	COLOR255,
	COLOR1
}
## The scale the default value is written in, which the level editor then keeps when the color is edited.
@export var fgd_color_type: FGDColorType = FGDColorType.COLOR255

func get_default_value() -> Variant:
	if typeof(default_value) != TYPE_COLOR:
		return Color()
	return default_value

## Convert the raw property [String] to [Color] for [FuncGodotParser].[br][br]
## The scale is read from the value the way the TrenchDot editor reads it, see [method TrenchDotIO.to_color], so a
## map builds with the color the editor showed whatever [member fgd_color_type] says.
func get_color_from_property_string(classname: String, property_name: String, property_string: String) -> Color:
	if property_string.split_floats(" ", false).size() > 2:
		return TrenchDotIO.to_color(property_string)
	push_error("Invalid Color format for \'" + property_name + "\' in entity \'" + classname + "\': " + property_string)
	return get_default_value()
