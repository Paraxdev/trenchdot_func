@icon("res://addons/func_godot/icons/icon_godambler.svg")
class_name FuncGodotParser extends RefCounted
## .tdm map parser class that is instantiated by a [FuncGodotMap] node during the build process.

const _SIGNATURE: String = "[PRS]"

const _GroupData	:= FuncGodotData.GroupData
const _EntityData	:= FuncGodotData.EntityData
const _ParseData	:= FuncGodotData.ParseData

## Emitted when a step in the parsing process is completed. 
## It is connected to [method FuncGodotUtil.print_profile_info] method if [member FuncGodotMap.build_flags] SHOW_PROFILE_INFO flag is set.
signal declare_step(step: String)

## Parses the .tdm map file, generating entity and group data and sub-data.
func parse_map_data(map_file: String, map_settings: FuncGodotMapSettings) -> _ParseData:
	declare_step.emit("Loading map file %s" % map_file)
	
	# Retrieve real path if needed
	if map_file.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(map_file)
		if not ResourceUID.has_id(uid):
			printerr("Error: failed to retrieve path for UID (%s)" % map_file)
			return _ParseData.new()
		map_file = ResourceUID.get_id_path(uid)
	
	if map_file.get_extension().to_lower() != "tdm":
		printerr("Error: %s is not a .tdm map" % map_file)
		return _ParseData.new()
	var map = TrenchDotTdmFile.load_map(map_file)
	return parse_tdm(map, map_settings, map_file) if map != null else _ParseData.new()

## Parses a .tdm map given as text or as already parsed JSON, without reading the file.
## [param source_path] resolves relative prefab paths.
func parse_tdm(map: Variant, map_settings: FuncGodotMapSettings, source_path: String) -> _ParseData:
	var json: Variant = JSON.parse_string(map) if map is String else map
	var parse_data := TrenchDotParser.parse_dict(json, map_settings, _ParseData.new(), source_path)
	if parse_data == null:
		printerr("Error: Failed to parse map (%s)" % source_path)
		return _ParseData.new()
	return post_process(parse_data, map_settings)

## Links groups, assigns entity definitions, converts property types and drops omitted groups.
func post_process(parse_data: _ParseData, map_settings: FuncGodotMapSettings) -> _ParseData:
	# Determine group hierarchy
	declare_step.emit("Determining groups hierarchy")
	var groups_data: Array[_GroupData] = parse_data.groups
	for g in groups_data:
		if g.parent_id != -1:
			for p in groups_data:
				if p.id == g.parent_id:
					g.parent = p
					break
	
	var entities_data: Array[_EntityData] = parse_data.entities
	var entity_defs: Dictionary[String, FuncGodotFGDEntityClass] = map_settings.entity_fgd.get_entity_definitions()
	# C# classes marked [TrenchDotEntity] define entities without FGD resources.
	if parse_data.entities.any(func(e): return not str(e.properties.get("classname", "")) in entity_defs):
		var csharp := TrenchDotCSharp.definitions()
		for classname in csharp:
			if not classname in entity_defs:
				entity_defs[classname] = csharp[classname]
	var missing_defs: PackedStringArray = []
	
	var default_point_class := FuncGodotFGDPointClass.new()
	default_point_class.node_class = "Marker3D"
	
	var default_solid_class := FuncGodotFGDSolidClass.new()
	default_solid_class.spawn_type = FuncGodotFGDSolidClass.SpawnType.ENTITY
	default_solid_class.build_occlusion = false
	default_solid_class.collision_shape_type = FuncGodotFGDSolidClass.CollisionShapeType.NONE
	default_solid_class.origin_type = FuncGodotFGDSolidClass.OriginType.BRUSH
	
	declare_step.emit("Checking entity omission, definition status, and property types")
	
	# Cache retrieved class property defaults. Format is Dictionary[Definition, Properties].
	var prop_defaults_cache: Dictionary = {}
	var prop_descriptions_cache: Dictionary = {}
	
	for i in range(entities_data.size() - 1, -1, -1):
		var entity: _EntityData = entities_data[i]
		
		# Delete entities from omitted groups
		if entity.group != null and entity.group.omit == true:
			entities_data.remove_at(i)
			continue
		
		# Provide entity definition to entity data. This gets used in both 
		# geo generation and entity assembly.
		if "classname" in entity.properties:
			var classname: String = entity.properties["classname"]
			if classname in entity_defs:
				entity.definition = entity_defs[classname]
				if not entity.definition is FuncGodotFGDSolidClass and not entity.definition is FuncGodotFGDPointClass:
					if missing_defs.find(classname) < 0:
						push_error("Invalid entity definition for \"" + classname + "\". Entity definition must be Solid Class or Point Class.")
						missing_defs.append(classname)
					entity.definition = null
			elif missing_defs.find(classname) < 0:
				push_error("No entity definition found for \"" + classname + "\"")
				missing_defs.append(classname)
		
		# Make sure we have a default definition to build entities from
		# This will make sure nothing goes wrong in the build processes
		if not entity.definition:
			if entity.brushes.is_empty():
				entity.definition = default_point_class
			else:
				entity.definition = default_solid_class
		
		# Convert the string values of the entity's properties Dictionary to various 
		# Variant formats based on the entity definition's class property defaults.
		var def := entity.definition
		var properties: Dictionary = entity.properties
		for property in properties:
			var prop_string = entity.properties[property]
			if property in def.class_properties:
				var prop_default: Variant = def.class_properties[property]
				
				match typeof(prop_default):
					TYPE_INT:
						properties[property] = prop_string.to_int()
					TYPE_FLOAT:
						properties[property] = prop_string.to_float()
					TYPE_BOOL:
						properties[property] = bool(prop_string.to_int())
					TYPE_VECTOR3:
						var prop_comps: PackedFloat64Array = prop_string.split_floats(" ")
						if prop_comps.size() > 2:
							properties[property] = Vector3(prop_comps[0], prop_comps[1], prop_comps[2])
						else:
							push_error("Invalid Vector3 format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
							properties[property] = prop_default
					TYPE_VECTOR3I:
						var prop_vec: Vector3i = prop_default
						var prop_comps: PackedStringArray = prop_string.split(" ")
						if prop_comps.size() > 2:
							for v in 3:
								prop_vec[v] = prop_comps[v].to_int()
						else:
							push_error("Invalid Vector3i format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
						properties[property] = prop_vec
					TYPE_COLOR:
						var prop_color: Color = prop_default
						var prop_comps: PackedStringArray = prop_string.split(" ")
						if prop_comps.size() > 2:
							prop_color.r8 = prop_comps[0].to_int()
							prop_color.g8 = prop_comps[1].to_int()
							prop_color.b8 = prop_comps[2].to_int()
							prop_color.a = 1.0
						else:
							push_error("Invalid Color format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
						properties[property] = prop_color
					TYPE_DICTIONARY:
						var prop_desc = def.class_property_descriptions[property]
						if prop_desc is Array and prop_desc.size() > 1 and prop_desc[1] is int:
							properties[property] = prop_string.to_int()
					TYPE_ARRAY:
						properties[property] = prop_string.to_int()
					TYPE_VECTOR2:
						var prop_comps: PackedFloat64Array = prop_string.split_floats(" ")
						if prop_comps.size() > 1:
							properties[property] = Vector2(prop_comps[0], prop_comps[1])
						else:
							push_error("Invalid Vector2 format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
							properties[property] = prop_default
					TYPE_VECTOR2I:
						var prop_vec: Vector2i = prop_default
						var prop_comps: PackedStringArray = prop_string.split(" ")
						if prop_comps.size() > 1:
							for v in 2:
								prop_vec[v] = prop_comps[v].to_int()
						else:
							push_error("Invalid Vector2i format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
							properties[property] = prop_vec
					TYPE_VECTOR4:
						var prop_comps: PackedFloat64Array = prop_string.split_floats(" ")
						if prop_comps.size() > 3:
							properties[property] = Vector4(prop_comps[0], prop_comps[1], prop_comps[2], prop_comps[3])
						else:
							push_error("Invalid Vector4 format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
							properties[property] = prop_default
					TYPE_VECTOR4I:
						var prop_vec: Vector4i = prop_default
						var prop_comps: PackedStringArray = prop_string.split(" ")
						if prop_comps.size() > 3:
							for v in 4:
								prop_vec[v] = prop_comps[v].to_int()
						else:
							push_error("Invalid Vector4i format for \'" + property + "\' in entity \'" + def.classname + "\': " + prop_string)
						properties[property] = prop_vec
					TYPE_STRING_NAME:
						properties[property] = StringName(prop_string)
					TYPE_NODE_PATH:
						if prop_string.begins_with("$") or prop_string.begins_with("%"):
							properties[property] = NodePath(prop_string)
						else:
							properties[property] = prop_string
					TYPE_OBJECT:
						properties[property] = prop_string
		
		# Retrieve default properties.
		# Keyed by definition, the default point and solid classes share an empty classname.
		if not prop_defaults_cache.has(def):
			prop_defaults_cache[def] = def.retrieve_all_class_properties()
			prop_descriptions_cache[def] = def.retrieve_all_class_property_descriptions()
		var def_properties: Dictionary[String, Variant] = prop_defaults_cache[def]
		var def_descriptions: Dictionary[String, Variant] = prop_descriptions_cache[def]
		
		# Assign properties not defined with defaults from the entity definition
		for property in def_properties:
			if not property in properties:
				var prop_default: Variant = def_properties[property]
				# Flags
				if prop_default is Array:
					var prop_flags_sum := 0
					for prop_flag in prop_default:
						if prop_flag is Array and prop_flag.size() > 2:
							if prop_flag[2] and prop_flag[1] is int:
								prop_flags_sum += prop_flag[1]
					properties[property] = prop_flags_sum
				# Choices
				elif prop_default is Dictionary:
					var prop_desc = def_descriptions.get(property, "")
					if prop_desc is Array and prop_desc.size() > 1 and (prop_desc[1] is int or prop_desc[1] is String):
						properties[property] = prop_desc[1]
					elif prop_default.size():
						properties[property] = prop_default[prop_default.keys().front()]
					else:
						properties[property] = 0
				# Materials, Shaders, and Sounds
				elif prop_default is Resource:
					properties[property] = prop_default.resource_path
				# Target Destination and Target Source
				elif prop_default is NodePath or prop_default is Object or prop_default == null:
					properties[property] = ""
				# Everything else
				else:
					properties[property] = prop_default
	
	# Delete omitted groups
	declare_step.emit("Removing omitted layers and groups")
	for i in range(groups_data.size() - 1, -1, -1):
		if groups_data[i].omit == true:
			groups_data.remove_at(i)
	
	declare_step.emit("Map parsing complete")
	return parse_data
