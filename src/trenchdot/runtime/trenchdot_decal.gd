@tool
class_name TrenchDotDecal extends Decal
## Decal entity for TrenchDot maps. Properties:
## [code]material[/code] a TrenchDot material name such as [code]base/stain[/code] or a res:// material, whose
## albedo, normal, ORM and emission textures and albedo color the decal takes, and whose [code]texture_size[/code]
## metadata sets the footprint while [code]size[/code] is left at its default.
## [code]texture[/code] res:// path of an albedo texture, used without a material,
## [code]size[/code] projector size in map units (x, depth, z),
## [code]modulate[/code] color, [code]normal_texture[/code] optional normal map.

const DEFAULT_SIZE := Vector3(64, 32, 64)

func _func_godot_apply_properties(props: Dictionary) -> void:
	var scale_factor := 1.0 / float(ProjectSettings.get_setting("func_godot/default_inverse_scale_factor", 32.0))
	var tex = props.get("texture", "")
	if tex is String and tex != "" and ResourceLoader.exists(tex):
		texture_albedo = load(tex)
	var normal_tex = props.get("normal_texture", "")
	if normal_tex is String and normal_tex != "" and ResourceLoader.exists(normal_tex):
		texture_normal = load(normal_tex)
	var s = props.get("size", DEFAULT_SIZE)
	if s is String:
		var parts: PackedFloat64Array = s.split_floats(" ")
		s = Vector3(parts[0], parts[1], parts[2]) if parts.size() >= 3 else DEFAULT_SIZE
	if not s is Vector3:
		s = DEFAULT_SIZE
	var tint = props.get("modulate", null)
	if tint is Color:
		modulate = tint
	var mat := _material(str(props.get("material", "")))
	if mat:
		texture_albedo = mat.albedo_texture
		modulate *= mat.albedo_color
		if mat.normal_enabled and mat.normal_texture:
			texture_normal = mat.normal_texture
		if mat is ORMMaterial3D:
			texture_orm = mat.orm_texture
		if mat.emission_enabled and mat.emission_texture:
			texture_emission = mat.emission_texture
			emission_energy = mat.emission_energy_multiplier
		var footprint := FuncGodotUtil.material_texture_size(mat)
		if s == DEFAULT_SIZE and footprint != Vector2.ZERO:
			s = Vector3(footprint.x, s.y, footprint.y)
	size = s * scale_factor

## The material named like a map face's, from the default map settings, or a res:// path.
static func _material(name: String) -> BaseMaterial3D:
	if name == "":
		return null
	if name.begins_with("res://"):
		return load(name) as BaseMaterial3D if ResourceLoader.exists(name) else null
	var settings := load(ProjectSettings.get_setting("func_godot/default_map_settings", "res://addons/func_godot/func_godot_default_map_settings.tres")) as FuncGodotMapSettings
	if not settings:
		return null
	var dir := settings.base_material_dir if not settings.base_material_dir.is_empty() else settings.base_texture_dir
	var path := dir.path_join(name) + "." + settings.material_file_extension
	if ResourceLoader.exists(path):
		return load(path) as BaseMaterial3D
	var texture := FuncGodotUtil.load_texture(name, settings)
	if not texture or texture.resource_path == FuncGodotUtil.default_texture_path:
		return null
	var plain := StandardMaterial3D.new()
	plain.albedo_texture = texture
	return plain
