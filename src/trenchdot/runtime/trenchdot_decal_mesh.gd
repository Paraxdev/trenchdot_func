class_name TrenchDotDecalMesh extends RefCounted
## Materials for mesh nodes flagged as decals. Kept free of other TrenchDot scripts because the FuncGodot material
## map uses it, and depending on the parser from there makes a cyclic reference.
##
## A decal is blended over the surface behind it without writing depth, so overlapping decals never fight each other,
## and its vertices are pulled toward the camera by [constant DEPTH_PULL] of their distance, so it always stays in
## front of its wall however far away or shallow the view is. The pull moves along the view ray, so nothing shifts on
## screen. Soft alpha stays soft, only a material in alpha scissor mode gets a hard cut at its threshold.

## Trails the texture name of a decal mesh's faces, so the material map gives them the decal variant.
const SUFFIX := "|decal|"
## Fraction of the camera distance a decal is drawn closer by: 0.5 mm at 1 m, 5 cm at 100 m.
const DEPTH_PULL := 0.0005

const _FILTERS: PackedStringArray = ["filter_nearest", "filter_linear", "filter_nearest_mipmap", "filter_linear_mipmap",
	"filter_nearest_mipmap_anisotropic", "filter_linear_mipmap_anisotropic"]

const _CODE := """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled%s;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, %s;
uniform bool use_vertex_color = false;
uniform bool use_normal_map = false;
uniform sampler2D texture_normal : hint_normal, %s;
uniform float normal_scale = 1.0;
uniform float roughness = 1.0;
uniform sampler2D texture_roughness : hint_default_white, %s;
uniform vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float metallic = 0.0;
uniform sampler2D texture_metallic : hint_default_white, %s;
uniform vec4 metallic_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float specular = 0.5;
uniform bool use_emission = false;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
uniform sampler2D texture_emission : source_color, hint_default_black, %s;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform float depth_pull = 0.0005;
uniform float alpha_scissor = -1.0;

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	vec3 eye = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	VERTEX = mix(VERTEX, eye, depth_pull);
}

void fragment() {
	vec4 color = albedo * texture(texture_albedo, UV);
	if (use_vertex_color) {
		color *= COLOR;
	}
	if (alpha_scissor >= 0.0) {
		if (color.a < alpha_scissor) {
			discard;
		}
		color.a = 1.0;
	}
	ALBEDO = color.rgb;
	ALPHA = color.a;
	if (use_normal_map) {
		NORMAL_MAP = texture(texture_normal, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	ROUGHNESS = roughness * dot(texture(texture_roughness, UV), roughness_texture_channel);
	METALLIC = metallic * dot(texture(texture_metallic, UV), metallic_texture_channel);
	SPECULAR = specular;
	if (use_emission) {
		EMISSION = (emission.rgb + texture(texture_emission, UV).rgb) * emission_energy;
	}
}
"""

const _CHANNELS: Array[Vector4] = [Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1),
	Vector4(0.333333, 0.333333, 0.333333, 0)]

static func is_decal(texture_name: String) -> bool:
	return texture_name.ends_with(SUFFIX)

static func base(texture_name: String) -> String:
	return texture_name.trim_suffix(SUFFIX)

## The decal variant of [param base]. A [BaseMaterial3D] becomes a decal shader with its textures and values, or
## when it uses a feature that shader lacks, a blended copy without the depth pull. A shader material is used as it
## is, since its blending is its own. [param shaders] caches the generated shaders for one build.
static func material(base: Material, shaders: Dictionary = {}) -> Material:
	if not base is BaseMaterial3D:
		return base
	var m := base as BaseMaterial3D
	var scissor := m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	if not _fits_shader(m):
		var copy := m.duplicate() as BaseMaterial3D
		if not scissor:
			copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		copy.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		copy.cull_mode = BaseMaterial3D.CULL_DISABLED
		return copy
	var repeat := "repeat_enable" if m.texture_repeat else "repeat_disable"
	var sampling := "%s, %s" % [_FILTERS[clampi(m.texture_filter, 0, _FILTERS.size() - 1)], repeat]
	var unshaded := ", unshaded" if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED else ""
	var key := sampling + unshaded
	if not shaders.has(key):
		var shader := Shader.new()
		shader.code = _CODE % [unshaded, sampling, sampling, sampling, sampling, sampling]
		shaders[key] = shader
	var mat := ShaderMaterial.new()
	mat.shader = shaders[key]
	mat.resource_name = m.resource_name
	for meta in m.get_meta_list():
		mat.set_meta(meta, m.get_meta(meta))
	mat.set_shader_parameter(&"albedo", m.albedo_color)
	mat.set_shader_parameter(&"texture_albedo", m.albedo_texture)
	mat.set_shader_parameter(&"use_vertex_color", m.vertex_color_use_as_albedo)
	mat.set_shader_parameter(&"use_normal_map", m.normal_enabled and m.normal_texture != null)
	mat.set_shader_parameter(&"texture_normal", m.normal_texture)
	mat.set_shader_parameter(&"normal_scale", m.normal_scale)
	mat.set_shader_parameter(&"roughness", m.roughness)
	mat.set_shader_parameter(&"texture_roughness", m.roughness_texture)
	mat.set_shader_parameter(&"roughness_texture_channel", _CHANNELS[m.roughness_texture_channel])
	mat.set_shader_parameter(&"metallic", m.metallic)
	mat.set_shader_parameter(&"texture_metallic", m.metallic_texture)
	mat.set_shader_parameter(&"metallic_texture_channel", _CHANNELS[m.metallic_texture_channel])
	mat.set_shader_parameter(&"specular", m.metallic_specular)
	mat.set_shader_parameter(&"use_emission", m.emission_enabled)
	mat.set_shader_parameter(&"emission", m.emission)
	mat.set_shader_parameter(&"emission_energy", m.emission_energy_multiplier)
	mat.set_shader_parameter(&"texture_emission", m.emission_texture)
	mat.set_shader_parameter(&"uv1_scale", m.uv1_scale)
	mat.set_shader_parameter(&"uv1_offset", m.uv1_offset)
	mat.set_shader_parameter(&"depth_pull", DEPTH_PULL)
	mat.set_shader_parameter(&"alpha_scissor", m.alpha_scissor_threshold if scissor else -1.0)
	return mat

static func _fits_shader(m: BaseMaterial3D) -> bool:
	return not (m is ORMMaterial3D or m.uv1_triplanar or m.detail_enabled or m.heightmap_enabled or m.ao_enabled
		or m.rim_enabled or m.clearcoat_enabled or m.anisotropy_enabled or m.subsurf_scatter_enabled
		or m.refraction_enabled or m.backlight_enabled or m.grow or m.proximity_fade_enabled or m.emission_on_uv2
		or m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED
		or m.distance_fade_mode != BaseMaterial3D.DISTANCE_FADE_DISABLED
		or m.emission_operator != BaseMaterial3D.EMISSION_OP_ADD)
