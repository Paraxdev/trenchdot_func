@tool
class_name TrenchDotEnvironment extends RefCounted
## Builds a WorldEnvironment with a procedural sky, fog and a sun light from worldspawn keys, matching the
## TrenchDot editor's lit preview: sun_angles ("pitch yaw"), sun_color, sun_energy, ambient_color,
## sky_top_color, sky_horizon_color, sky_ground_color, fog_color and fog_density (per meter). For night maps
## ambient_energy and sky_energy scale the ambient light and the sky, and glow_intensity above 0 turns on glow so
## emissive materials and lamps bloom, while ssr 1 turns on screen space reflections for wet streets and glossy
## floors. Colors are "r g b" as [method TrenchDotIO.to_color] reads them. sky_panorama, a res:// image, replaces
## the procedural sky with a panorama, as texture conversion writes for a Source skybox. The worldspawn key "environment" set to sun_only builds
## only the sun, 0 or none builds nothing. A WorldEnvironment or DirectionalLight3D the scene has already, outside the
## map, is left to do its job and none is added, so of several maps in one scene the first one built lights it.

const KEYS := ["sun_angles", "sun_color", "sun_energy", "sun_bake_mode", "ambient_color", "sky_top_color", "sky_panorama", "sky_horizon_color", "sky_ground_color", "fog_color", "fog_density", "ambient_energy", "sky_energy", "glow_intensity", "ssr"]

static func parse_color(text: String, fallback: Color) -> Color:
	return TrenchDotIO.to_color(text, fallback)

## The WorldEnvironment of the scene [param map_node] is built into, leaving out the map's own nodes.
static func scene_environment(map_node: Node) -> WorldEnvironment:
	return _scene_node(map_node, func(n: Node): return n is WorldEnvironment)

## The first DirectionalLight3D of the scene [param map_node] is built into, leaving out the map's own nodes.
static func scene_sun(map_node: Node) -> DirectionalLight3D:
	return _scene_node(map_node, func(n: Node): return n is DirectionalLight3D)

static func _scene_node(map_node: Node, wanted: Callable) -> Node:
	var start := TrenchDotBuild.scene_owner(map_node)
	# A map a game builds at runtime often has no owner, then the whole running scene counts.
	if start == map_node and map_node.is_inside_tree() and not Engine.is_editor_hint():
		start = map_node.get_tree().root
	var stack: Array[Node] = [start]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node == map_node:
			continue
		if wanted.call(node):
			return node
		stack.append_array(node.get_children())
	return null

## The worldspawn key "environment": full, sun_only or none.
static func mode(properties: Dictionary) -> String:
	match str(properties.get("environment", "1")).strip_edges().to_lower():
		"0", "none":
			return "none"
		"sun_only":
			return "sun_only"
	return "full"

static func wants_environment(properties: Dictionary) -> bool:
	match mode(properties):
		"none":
			return false
		"sun_only":
			return true
	for key in KEYS:
		if properties.has(key):
			return true
	return false

## Returns the created nodes (WorldEnvironment and DirectionalLight3D), empty when the worldspawn has no environment keys.
static func build(map_node: Node3D, properties: Dictionary) -> Array[Node]:
	var out: Array[Node] = []
	if not wants_environment(properties):
		return out
	if mode(properties) == "full" and not scene_environment(map_node):
		out.append(_world_environment(properties))
	if not scene_sun(map_node):
		out.append(_sun(properties))
	var scene_root := TrenchDotBuild.scene_owner(map_node)
	for node in out:
		map_node.add_child(node)
		node.owner = scene_root
	return out

static func _world_environment(properties: Dictionary) -> WorldEnvironment:
	var sky_energy := maxf(str(properties.get("sky_energy", "1")).to_float(), 0.0)
	var panorama_path := TrenchDotBuild.map_resource_path(str(properties.get("sky_panorama", "")), TrenchDotBuild.IMAGE_FILES)
	var sky := Sky.new()
	if panorama_path != "" and ResourceLoader.exists(panorama_path):
		var panorama := PanoramaSkyMaterial.new()
		panorama.panorama = load(panorama_path)
		panorama.energy_multiplier = sky_energy
		sky.sky_material = panorama
	else:
		var sky_material := ProceduralSkyMaterial.new()
		sky_material.sky_top_color = parse_color(str(properties.get("sky_top_color", "")), Color(0.32, 0.5, 0.78))
		sky_material.sky_horizon_color = parse_color(str(properties.get("sky_horizon_color", "")), Color(0.72, 0.8, 0.88))
		sky_material.ground_bottom_color = parse_color(str(properties.get("sky_ground_color", "")), Color(0.42, 0.44, 0.46))
		sky_material.ground_horizon_color = sky_material.sky_horizon_color
		sky_material.energy_multiplier = sky_energy
		sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	if properties.has("ambient_color"):
		env.ambient_light_color = parse_color(str(properties["ambient_color"]), Color(0.26, 0.28, 0.33))
		env.ambient_light_sky_contribution = 0.5
	env.ambient_light_energy = maxf(str(properties.get("ambient_energy", "1")).to_float(), 0.0)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var glow := str(properties.get("glow_intensity", "0")).to_float()
	if glow > 0.0:
		env.glow_enabled = true
		env.glow_intensity = glow
		env.glow_bloom = 0.05
		env.glow_hdr_threshold = 0.9
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	if TrenchDotIO.to_bool(properties.get("ssr", false)):
		env.ssr_enabled = true
		env.ssr_max_steps = 96
	var density := str(properties.get("fog_density", "0")).to_float()
	if density > 0.0:
		env.fog_enabled = true
		env.fog_density = density
		env.fog_sky_affect = 0.3
		env.fog_light_color = parse_color(str(properties.get("fog_color", "")), Color(0.7, 0.78, 0.86))

	var world_env := WorldEnvironment.new()
	world_env.name = "environment"
	world_env.environment = env
	return world_env

static func _sun(properties: Dictionary) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "sun"
	var angles := str(properties.get("sun_angles", "-40 -45")).split_floats(" ", false)
	if angles.size() >= 2:
		sun.rotation_degrees = Vector3(angles[0], angles[1], 0.0)
	sun.light_color = parse_color(str(properties.get("sun_color", "")), Color(1.0, 0.96, 0.88))
	sun.light_energy = str(properties.get("sun_energy", "1.1")).to_float()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	return sun
