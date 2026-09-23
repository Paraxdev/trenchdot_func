@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
@abstract class_name FuncGodotFGDEntityClass extends Resource
## Entity definition template. WARNING! Not to be used directly! Use [FuncGodotFGDBaseClass], [FuncGodotFGDSolidClass], or [FuncGodotFGDPointClass] instead.
##
## Entity definition template. It holds all of the common entity class properties shared between [FuncGodotFGDBaseClass], [FuncGodotFGDSolidClass], or [FuncGodotFGDPointClass]. 
## Not to be used directly, use one of the aforementioned FGD class types instead.
##
## @tutorial(Quake Wiki Entity Article): https://quakewiki.org/wiki/Entity
## @tutorial(Level Design Book: Entity Types and Settings): https://book.leveldesignbook.com/appendix/resources/formats/fgd#entity-types-and-settings-basic
## @tutorial(Valve Developer Wiki FGD Article): https://developer.valvesoftware.com/wiki/FGD#Class_Types_and_Properties
## @tutorial(Valve Developer Wiki Entity Descriptions): https://developer.valvesoftware.com/wiki/FGD#Entity_Description

@export_group("Entity Definition")

## Entity classname. [b][i]This is a required field in all entity types[/i][/b] as it is used by both the level editor and by FuncGodot on map build.
@export var classname : String = ""

## Entity description that appears in the level editor. Not required.
@export_multiline var description : String = ""

## [FuncGodotFGDBaseClass] resources to inherit [member class_properties] and [member class_descriptions] from.
@export var base_classes: Array[Resource] = []

## Key value pair properties that will appear in the level editor. After building the [FuncGodotMap] in Godot, these properties will be added to a [Dictionary] 
## that gets applied to the generated node, as long as that node is a tool script with an exported `func_godot_properties` Dictionary.
@export var class_properties : Dictionary[String, Variant] = {}

## Level editor descriptions for previously defined key value pair properties. Optional but recommended.
@export var class_property_descriptions : Dictionary[String, Variant] = {}

## Automatically applies entity class properties to matching properties in the generated node. 
## When using this feature, class properties need to be the correct type or you may run into errors on map build.
@export var auto_apply_to_matching_node_properties : bool = false

## Appearance properties for the level editor, like [code]size[/code] and [code]color[/code].
@export var meta_properties : Dictionary[String, Variant] = {
	"size": AABB(Vector3(-8, -8, -8), Vector3(8, 8, 8)),
	"color": Color(0.8, 0.8, 0.8)
}

@export_group("Node Generation")

## Node to generate on map build. This can be a built-in Godot class, a Script class, or a GDExtension class. 
## For Point Class entities that use Scene File instantiation leave this blank.
@export var node_class := ""

## Optional class property to use in naming the generated node. Overrides [member FuncGodotMapSettings.name_property].
## Naming occurs before adding to the [SceneTree] and applying properties.
## Nodes will be named `"entity_" + name_property`. An entity's name should be unique, otherwise you may run into unexpected behavior.
@export var name_property := ""

## Optional array of node groups to add the generated node to.
@export var node_groups : Array[String] = []

func retrieve_all_class_properties(properties: Dictionary[String, Variant] = {}) -> Dictionary[String, Variant]:
	for b in base_classes:
		properties = b.retrieve_all_class_properties(properties)
	for key in class_properties.keys():
		properties[key] = class_properties[key]
	return properties

func retrieve_all_class_property_descriptions(descriptions: Dictionary[String, Variant] = {}) -> Dictionary[String, Variant]:
	for b in base_classes:
		descriptions = b.retrieve_all_class_property_descriptions(descriptions)
	for key in class_property_descriptions.keys():
		descriptions[key] = class_property_descriptions[key]
	return descriptions
