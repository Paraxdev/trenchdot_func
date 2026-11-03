class_name FuncGodotUtil
## Static class with a number of reuseable utility methods that can be called at Editor or Run Time.

const _VERTEX_EPSILON: float = 0.008

## Connected by the [FuncGodotMap] node to the build process' sub-components if the 
## [member FuncGodotMap.build_flags]'s SHOW_PROFILE_INFO flag is set.
static func print_profile_info(message: String, signature: String) -> void:
	prints(signature, message)

#region MATH

static func op_vec3_sum(lhs: Vector3, rhs: Vector3) -> Vector3: 
	return lhs + rhs

static func op_vec3_avg(array: Array[Vector3]) -> Vector3:
	if array.is_empty():
		push_error("Cannot average empty Vector3 array!")
		return Vector3()
	return array.reduce(op_vec3_sum, Vector3()) / array.size()

## Conversion from id tech coordinate system to Godot, from a top-down perspective.
static func id_to_opengl(vec: Vector3) -> Vector3: 
	return Vector3(vec.y, vec.z, vec.x)

## Check if a point is inside a convex hull defined by a series of planes by an epsilon constant.
static func is_point_in_convex_hull(planes: Array[Plane], vertex: Vector3) -> bool:
	for plane in planes:
		var distance: float = plane.normal.dot(vertex) - plane.d
		if distance > _VERTEX_EPSILON:
			return false
	return true

#endregion

#region TEXTURES

## Fallback texture if the one a face names cannot be found.
const default_texture_path: String = "res://addons/func_godot/textures/default_texture.png"
## Texture size in pixels for a material with no albedo texture and no image to measure, the TrenchDot editor's
## default fallback size.
const FALLBACK_TEXTURE_SIZE := 64
## Holds the default texture and the TrenchDot editor's built in dev/ colours, used when the project has no
## texture of that name.
const builtin_texture_dir: String = "res://addons/func_godot/textures"

const _pbr_textures: PackedInt32Array = [
	StandardMaterial3D.TEXTURE_ALBEDO,
	StandardMaterial3D.TEXTURE_NORMAL,
	StandardMaterial3D.TEXTURE_METALLIC,
	StandardMaterial3D.TEXTURE_ROUGHNESS,
	StandardMaterial3D.TEXTURE_EMISSION,
	StandardMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
	StandardMaterial3D.TEXTURE_HEIGHTMAP,
	ORMMaterial3D.TEXTURE_ORM,
	]

# Used during auto-PBR processing. Must match the _pbr_textures order.
# -1 means the feature is permanantly enabled.
const _pbr_features: PackedInt32Array = [
	-1,
	BaseMaterial3D.FEATURE_NORMAL_MAPPING,
	-1,
	-1,
	BaseMaterial3D.FEATURE_EMISSION,
	BaseMaterial3D.FEATURE_AMBIENT_OCCLUSION,
	BaseMaterial3D.FEATURE_HEIGHT_MAPPING,
	-1,
]

## Searches for a Texture2D within the base texture directory. If not found, a default texture is returned.
static func load_texture(texture_name: String, map_settings: FuncGodotMapSettings) -> Texture2D:
	for texture_file_extension in map_settings.texture_file_extensions:
		var texture_path: String = TrenchDotBuild.map_resource_path(map_settings.base_texture_dir.path_join(texture_name + "." + texture_file_extension), TrenchDotBuild.IMAGE_FILES, texture_name)
		if texture_path != "" and ResourceLoader.exists(texture_path):
			var texture_file = load(texture_path)
			if texture_file is Texture2D:
				return texture_file
			else:
				printerr("Error: Texture load failed! (%s) not a valid Texture2D resource", texture_path)
	
	if texture_name.begins_with("dev/"):
		var builtin: String = TrenchDotBuild.map_resource_path(builtin_texture_dir.path_join(texture_name + ".png"), TrenchDotBuild.IMAGE_FILES, texture_name)
		if builtin != "" and ResourceLoader.exists(builtin):
			return load(builtin)
	return load(default_texture_path)

## Folders and names of tool textures that build no visual mesh besides the four the map settings name. The
## TrenchDot editor keeps the same lists in game.rs and hides the same faces.
const NODRAW_FOLDERS: PackedStringArray = ["special/", "tools/", "td/"]
const NODRAW_NAMES: PackedStringArray = ["clip", "skip", "origin", "sky", "trigger", "nodraw", "hint", "hintskip", "caulk", "null", "areaportal", "playerclip", "occluder"]
## Of those, the ones that do not collide either, like skip.
const NONSOLID_TOOL_NAMES: PackedStringArray = ["skip", "origin", "hint", "hintskip", "null", "areaportal"]
## Of those, the ones whose faces feed the entity's occluder instead.
const OCCLUDER_TOOL_NAMES: PackedStringArray = ["occluder"]

## True when faces with [param texture] build no visual mesh, by its folder or name.
static func is_nodraw(texture: String) -> bool:
	var lower := texture.to_lower()
	for folder in NODRAW_FOLDERS:
		if lower.begins_with(folder):
			return true
	return lower.get_file() in NODRAW_NAMES

## The name of a nodraw tool texture without its folder, empty for any other texture.
static func _nodraw_name(texture: String) -> String:
	return texture.to_lower().get_file() if is_nodraw(texture) else ""

## True for faces with an occluder tool texture.
static func is_occluder(texture: String) -> bool:
	return _nodraw_name(texture) in OCCLUDER_TOOL_NAMES

## Filters faces textured with Skip, or a nodraw tool texture that does not collide, during the geometry generation step.
static func is_skip(texture: String, map_settings: FuncGodotMapSettings) -> bool:
	if map_settings:
		return texture.to_lower() == map_settings.skip_texture or _nodraw_name(texture) in NONSOLID_TOOL_NAMES
	return false

## Filters faces textured with Clip during the geometry generation step of the build process.
static func is_clip(texture: String, map_settings: FuncGodotMapSettings) -> bool:
	if map_settings:
		return texture.to_lower() == map_settings.clip_texture
	return false

## Filters faces textured with Origin during the parsing and geometry generation steps of the build process.
static func is_origin(texture: String, map_settings: FuncGodotMapSettings) -> bool:
	if map_settings:
		return texture.to_lower() == map_settings.origin_texture
	return false

## Filters faces textured with Sky during the geometry generation step of the build process.
static func is_sky(texture: String, map_settings: FuncGodotMapSettings) -> bool:
	if map_settings:
		return texture.to_lower() == map_settings.sky_texture
	return false

## Filters faces textured with any of the tool textures during the geometry generation step of the build process.
static func filter_face(texture: String, map_settings: FuncGodotMapSettings) -> bool:
	if map_settings:
		texture = TrenchDotDecalMesh.base(texture).to_lower()
		if (texture == map_settings.skip_texture
			or texture == map_settings.clip_texture
		 	or texture == map_settings.origin_texture
			or texture == map_settings.sky_texture
			or is_nodraw(texture)
			):
			return true
	return false

## Adds PBR textures to an existing [BaseMaterial3D].
static func build_base_material(map_settings: FuncGodotMapSettings, material: BaseMaterial3D, texture: String) -> void:
	var path: String = map_settings.base_texture_dir.path_join(texture)
	# Check if there is a subfolder with our PBR textures
	if DirAccess.open(path):
		path = path.path_join(texture)
	
	var pbr_suffixes: PackedStringArray = [
		map_settings.albedo_map_pattern,
		map_settings.normal_map_pattern,
		map_settings.metallic_map_pattern,
		map_settings.roughness_map_pattern,
		map_settings.emission_map_pattern,
		map_settings.ao_map_pattern,
		map_settings.height_map_pattern,
		map_settings.orm_map_pattern,
	]
	
	for i in pbr_suffixes.size():
		if not pbr_suffixes[i].is_empty():
			var pbr: String = pbr_suffixes[i]
			var token: int = pbr.find("%s", 0)
			if token != -1:
				if pbr.find("%s", token + 1) != -1:
					token = 2
				else:
					token = 1
			
			if token < 1:
				printerr("No string replacement tokens found in auto-PBR pattern \'" + pbr + "\'! Must have at least one instance of \'%s\' per pattern.")
				continue
			
			if token > 0:
				for texture_file_extension in map_settings.texture_file_extensions:
					if token > 1:
						pbr = pbr_suffixes[i] % [path, texture_file_extension]
					else:
						pbr = pbr_suffixes[i] % [path]
						pbr += "." + texture_file_extension
					pbr = TrenchDotBuild.map_resource_path(pbr, TrenchDotBuild.IMAGE_FILES, texture)
					if pbr != "" and ResourceLoader.exists(pbr):
						print(pbr)
						if _pbr_features[i] > -1:
							material.set_feature(_pbr_features[i], true)
						material.set_texture(_pbr_textures[i], load(pbr))
						break

## The world size in map units one repeat of the material's texture covers, from its
## [code]texture_size[/code] metadata, or [constant Vector2.ZERO] when it has none. Photos are often a thousand
## pixels wide or more, so dividing UVs by their pixel size would stretch them over dozens of meters.
static func material_texture_size(material: Material) -> Vector2:
	if not material or not material.has_meta("texture_size"):
		return Vector2.ZERO
	var size = material.get_meta("texture_size")
	if size is Vector2 or size is Vector2i:
		return Vector2(size) if size.x > 0 and size.y > 0 else Vector2.ZERO
	if (size is float or size is int) and size > 0:
		return Vector2.ONE * float(size)
	return Vector2.ZERO

## Builds both materials and sizes dictionaries for use in the geometry generation step of the build process. 
## Both dictionaries use texture names as keys. The materials dictionary uses [Material] as values, 
## while the sizes dictionary saves the albedo texture sizes to aid in UV mapping.
static func build_texture_map(entity_data: Array[FuncGodotData.EntityData], map_settings: FuncGodotMapSettings) -> Array[Dictionary]:
	var texture_materials: Dictionary[String, Material] = {}
	var texture_sizes: Dictionary[String, Vector2] = {}
	
	# Decal variants are made from their base material once every base is loaded.
	var decals: Array[String] = []
	for entity in entity_data:
		if not entity.is_visual():
			continue

		for brush in entity.brushes:
			for face in brush.faces:
				var texture_name: String = face.texture
				if TrenchDotDecalMesh.is_decal(texture_name):
					if not texture_name in decals:
						decals.append(texture_name)
					texture_name = TrenchDotDecalMesh.base(texture_name)
				
				if filter_face(texture_name, map_settings):
					continue
				if texture_materials.has(texture_name):
					continue
				if TrenchDotBlend.is_blend(texture_name):
					var blend: Array = TrenchDotBlend.build(texture_name, map_settings)
					texture_materials[texture_name] = blend[0]
					texture_sizes[texture_name] = blend[1]
					continue

				var material_path: String = map_settings.base_material_dir if not map_settings.base_material_dir.is_empty() else map_settings.base_texture_dir
				material_path = material_path.path_join(texture_name) + "." + map_settings.material_file_extension
				material_path = TrenchDotBuild.map_resource_path(material_path.replace("*", ""), TrenchDotBuild.MATERIAL_FILES, texture_name)
				
				if material_path != "" and ResourceLoader.exists(material_path):
					var material: Material = load(material_path)
					texture_materials[texture_name] = material
					if material is BaseMaterial3D:
						var albedo = material.albedo_texture
						if albedo is Texture2D:
							texture_sizes[texture_name] = material.albedo_texture.get_size()
					elif material is ShaderMaterial:
						var albedo = material.get_shader_parameter(map_settings.default_material_albedo_uniform)
						if albedo is Texture2D:
							texture_sizes[texture_name] = albedo.get_size()
					if not texture_sizes.has(texture_name):
						var texture: Texture2D = load_texture(texture_name, map_settings)
						if texture:
							texture_sizes[texture_name] = texture.get_size()
					if not texture_sizes.has(texture_name):
						texture_sizes[texture_name] = Vector2.ONE * FALLBACK_TEXTURE_SIZE
					var world_size := material_texture_size(material)
					if world_size != Vector2.ZERO:
						texture_sizes[texture_name] = world_size
				
				# Material generation
				elif map_settings.default_material:
					var material = map_settings.default_material.duplicate(false)
					var texture: Texture2D = load_texture(texture_name, map_settings)
					texture_sizes[texture_name] = texture.get_size()
					
					if material is BaseMaterial3D:
						material.albedo_texture = texture
						build_base_material(map_settings, material, texture_name)
					elif material is ShaderMaterial:
						material.set_shader_parameter(map_settings.default_material_albedo_uniform, texture)
						var path: String = map_settings.base_texture_dir
						for uniform in map_settings.shader_material_uniform_map_patterns.keys():
							if map_settings.shader_material_uniform_map_patterns[uniform].find("%s") < 0:
								printerr("No string replacement tokens fuond in ShaderMaterial uniform map pattern \'" + map_settings.shader_material_uniform_map_patterns[uniform] + "\'! Must have one instance of \'%s\' per pattern.")
								continue
							for texture_file_extension in map_settings.texture_file_extensions:
								var uniform_texture_path: String = map_settings.shader_material_uniform_map_patterns[uniform] % [texture_name] + "." + texture_file_extension
								uniform_texture_path = TrenchDotBuild.map_resource_path(path.path_join(uniform_texture_path), TrenchDotBuild.IMAGE_FILES, texture_name)
								if uniform_texture_path != "" and ResourceLoader.exists(uniform_texture_path):
									material.set_shader_parameter(uniform, load(uniform_texture_path))
									break
					
					if (map_settings.save_generated_materials and material and material_path != ""
						and texture_name != map_settings.clip_texture 
						and texture_name != map_settings.skip_texture 
						and texture_name != map_settings.origin_texture 
						and texture_name != map_settings.sky_texture 
						and not texture.resource_path.begins_with(builtin_texture_dir)):
						# Make sure our material directory exists
						var dir := DirAccess.open(material_path.get_base_dir())
						if not dir:
							dir = DirAccess.open("res://")
							dir.make_dir_recursive(material_path.get_base_dir().trim_prefix("res://"))
						# Save the new material
						ResourceSaver.save(material, material_path)
					
					texture_materials[texture_name] = material
				else: # No default material exists
					printerr("Error: No default material found in map settings")
	
	var decal_shaders := {}
	for decal in decals:
		var base := TrenchDotDecalMesh.base(decal)
		if texture_materials.has(base):
			texture_materials[decal] = TrenchDotDecalMesh.material(texture_materials[base], decal_shaders)
		if texture_sizes.has(base):
			texture_sizes[decal] = texture_sizes[base]
	
	return [texture_materials, texture_sizes]

#endregion

#region UV MAPPING

## Returns UV coordinate calculated from the Valve 220 UV format.
static func get_valve_uv(vertex: Vector3, u_axis: Vector3, v_axis: Vector3, uv_basis := Transform2D.IDENTITY, texture_size := Vector2.ONE) -> Vector2:
	var uv := Vector2(u_axis.dot(vertex), v_axis.dot(vertex))
	var scale := Vector2(uv_basis.x.x, uv_basis.y.y)
	if absf(scale.x) < 1e-9:
		scale.x = 1.0
	if absf(scale.y) < 1e-9:
		scale.y = 1.0
	uv += (uv_basis.origin * scale)
	uv /= scale;
	uv.x /= texture_size.x
	uv.y /= texture_size.y
	return uv

## Returns the UV coordinate of a vertex on the face.
static func get_face_vertex_uv(vertex: Vector3, face: FuncGodotData.FaceData, texture_size: Vector2) -> Vector2:
	return get_valve_uv(vertex, face.uv_axes[0], face.uv_axes[1], face.uv, texture_size)

## Returns the tangent calculated from the Valve 220 UV format.
static func get_valve_tangent(u: Vector3, v: Vector3, normal: Vector3) -> PackedFloat32Array:
	var u_axis: Vector3 = u.normalized()
	var v_axis: Vector3 = v.normalized()
	var v_sign: float = -signf(normal.cross(u_axis).dot(v_axis))
	return [u_axis.x, u_axis.y, u_axis.z, v_sign]

	# NOTE: we may still need to orthonormalize tangents. Just in case, here's a rough outline.
	#var tangent: Vector3 = u.normalized() 
	#tangent = (tangent - normal * normal.dot(tangent)).normalized()
	#
	## in the case of parallel U or V axes to planar normal, reconstruct the tangent
	#if tangent.length_squared() < 0.01:
	#	if absf(normal.y) < 0.9:
	#		tangent = Vector3.UP.cross(normal)
	#	else:
	#		tangent = Vector3.RIGHT.cross(normal)
	#
	#tangent = tangent.normalized()
	#return [tangent.x, tangent.y, tangent.z, -signf(normal.cross(tangent).dot(v.normalized))]

static func get_face_tangent(face: FuncGodotData.FaceData) -> PackedFloat32Array:
	return get_valve_tangent(face.uv_axes[0], face.uv_axes[1], face.plane.normal)

#endregion

#region MESH

static func smooth_mesh_by_angle(mesh: ArrayMesh, angle_deg: float = 89.0) -> ArrayMesh:
	if not mesh:
		push_error("Need a source mesh to smooth")
		return null
	
	var angle: float = deg_to_rad(clampf(angle_deg, 0.0, 360.0))
	
	var mesh_vertices: 	Array[Vector3] = []
	var mesh_normals: 	Array[Vector3] = []
	var surface_data: 	Array[Dictionary] = []
	var mdt: MeshDataTool
	var st := SurfaceTool.new()
	
	# Collect surface information
	for surface_index in mesh.get_surface_count():
		mdt = MeshDataTool.new()
		
		if mdt.create_from_surface(mesh, surface_index) != OK:
			continue
		
		var info: Dictionary = {
			"mdt": mdt,
			"ofs": mesh_vertices.size(),
			"mat": mesh.surface_get_material(surface_index)
		}
		
		surface_data.append(info)
		
		for i in mdt.get_vertex_count():
			mesh_vertices.append(mdt.get_vertex(i))
			mesh_normals.append(mdt.get_vertex_normal(i))
	
	var groups: Dictionary = {}
	
	# Group vertices by position
	for i in mesh_vertices.size():
		var pos := mesh_vertices[i]
		
		# this is likely already snapped from the map building process
		var key := pos.snappedf(_VERTEX_EPSILON)
		
		if not groups.has(key):
			groups[key] = [i]
		else:
			groups[key].append(i)
	
	# Collect normals. Likely optimizable.
	for group in groups.values():
		for i in group:
			var this := mesh_normals[i]
			var normal_out := Vector3()
			for j in group:
				var other := mesh_normals[j]
				if this.angle_to(other) <= angle:
					normal_out += other
			
			mesh_normals[i] = normal_out.normalized()
	
	var smoothed_mesh := ArrayMesh.new()
	
	# Construct smoothed output mesh
	for dict in surface_data:
		mdt = dict["mdt"]
		var offset: int = dict["ofs"]
		for i in mdt.get_vertex_count():
			mdt.set_vertex_normal(i, mesh_normals[offset + i])
		
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(dict["mat"])
		
		for i in mdt.get_face_count():
			for j in 3:
				var index := mdt.get_face_vertex(i, j)
				st.set_normal(mdt.get_vertex_normal(index))
				st.set_uv(mdt.get_vertex_uv(index))
				st.set_tangent(mdt.get_vertex_tangent(index))
				st.add_vertex(mdt.get_vertex(index))
		
		smoothed_mesh = st.commit(smoothed_mesh)
	
	return smoothed_mesh

#endregion
