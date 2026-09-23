@tool
@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name FuncGodotFGDFile extends Resource
## [Resource] file used to express a set of [FuncGodotFGDEntityClass] definitions. 
## 
## Used in conjunction with [FuncGodotMapSettings] to generate nodes in a [FuncGodotMap] node, and by [TrenchDotGameConfig] 
## to describe the entities to the level editor.
##
## @tutorial(Level Design Book FGD Chapter): https://book.leveldesignbook.com/appendix/resources/formats/fgd
## @tutorial(Valve Developer Wiki FGD Article): https://developer.valvesoftware.com/wiki/FGD

## Array of [FuncGodotFGDFile] resources whose entities are included before this file's own.
@export var base_fgd_files: Array[Resource] = []

## Array of resources that inherit from [FuncGodotFGDEntityClass]. This array defines the entities of the level editor and the nodes that will be generated in a [FuncGodotMap].
@export var entity_definitions: Array[Resource] = []

## This getter does a little bit of validation. Providing only an array of non-null uniquely-named entity definitions
func get_fgd_classes() -> Array:
	var res : Array = []
	for cur_ent_def_ind in range(entity_definitions.size()):
		var cur_ent_def = entity_definitions[cur_ent_def_ind]
		if cur_ent_def == null:
			continue
		elif not (cur_ent_def is FuncGodotFGDEntityClass):
			printerr("Bad value in entity definition set at position %s! Not an entity defintion." % cur_ent_def_ind)
			continue
		res.append(cur_ent_def)
	return res

func get_entity_definitions() -> Dictionary[String, FuncGodotFGDEntityClass]:
	var res: Dictionary[String, FuncGodotFGDEntityClass] = {}

	for base_fgd in base_fgd_files:
		var fgd_res = base_fgd.get_entity_definitions()
		for key in fgd_res:
			res[key] = fgd_res[key]

	for ent in get_fgd_classes():
		# Skip entities without classnames
		if ent.classname.replace(" ","") == "":
			printerr("Skipping " + ent.get_path() + ": Empty classname")
			continue
		
		if ent is FuncGodotFGDPointClass or ent is FuncGodotFGDSolidClass:
			var entity_def = ent.duplicate()
			var meta_properties: Dictionary[String, Variant] = {}
			var class_properties: Dictionary[String, Variant] = {}
			var class_property_descriptions: Dictionary[String, Variant] = {}

			for base_class in _generate_base_class_list(entity_def):
				for meta_property in base_class.meta_properties:
					meta_properties[meta_property] = base_class.meta_properties[meta_property]

				for class_property in base_class.class_properties:
					class_properties[class_property] = base_class.class_properties[class_property]

				for class_property_desc in base_class.class_property_descriptions:
					class_property_descriptions[class_property_desc] = base_class.class_property_descriptions[class_property_desc]

			for meta_property in entity_def.meta_properties:
				meta_properties[meta_property] = entity_def.meta_properties[meta_property]

			for class_property in entity_def.class_properties:
				class_properties[class_property] = entity_def.class_properties[class_property]

			for class_property_desc in entity_def.class_property_descriptions:
				class_property_descriptions[class_property_desc] = entity_def.class_property_descriptions[class_property_desc]

			entity_def.meta_properties = meta_properties
			entity_def.class_properties = class_properties
			entity_def.class_property_descriptions = class_property_descriptions

			res[ent.classname] = entity_def
	return res

func _generate_base_class_list(entity_def : Resource, visited_base_classes = []) -> Array:
	var base_classes : Array = []

	visited_base_classes.append(entity_def.classname)

	# End recursive search if no more base_classes
	if len(entity_def.base_classes) == 0:
		return base_classes

	# Traverse up to the next level of hierarchy, if not already visited
	for base_class in entity_def.base_classes:
		if not base_class.classname in visited_base_classes:
			base_classes.append(base_class)
			base_classes += _generate_base_class_list(base_class, visited_base_classes)
		else:
			printerr(str("Entity '", entity_def.classname,"' contains cycle/duplicate to Entity '", base_class.classname, "'"))

	return base_classes
