class_name TrenchDotLightmap extends RefCounted
## Lighting baked in the TrenchDot editor (Bake Lighting), built into a [LightmapGI]. The map stores the light and
## sun shadow atlases and, per baked face, two affine rows that turn a position into its atlas coordinate, see
## crates/td_doc/src/lightmap.rs. The build gives baked meshes those coordinates as UV2 and registers them with a
## [LightmapGIData] filled from the atlases, so nothing is baked again in Godot.
##
## Light probes baked with it light moving objects. Their points and BSP planes come in map units and are scaled to
## meters here, the rest goes to [method LightmapGIData._set_probe_data] as Godot's own bake stores it.
##
## The atlas gets one extra texel row at the bottom holding the average light. Faces of a baked mesh that have no
## chart of their own, because they changed after the bake, point at it instead of at some other surface's light.

## Set on mesh instances that carry baked UV2, so the build can register them after chunking.
const BAKED_META := &"trenchdot_baked"
const NODE_NAME := "baked_lighting"
const _VERSION := 1

## The [code]lightmap[/code] entry of a decoded map in one shape, whichever layout it came from. Empty when the map
## has no usable bake. Keys: width, height, light (RGB half floats), shadow, fallback (Color), charts (node id to
## face to eight editor space row values, already squeezed for the fallback row), probes (see [method _probes], empty
## when the bake has none).
static func decode(raw: Variant) -> Dictionary:
	if not raw is Dictionary or int(raw.get("version", 0)) > _VERSION:
		return {}
	var width := int(raw.get("width", 0))
	var height := int(raw.get("height", 0))
	var light := _bytes(raw.get("light"))
	var shadow := _bytes(raw.get("shadow"))
	var texels := width * height
	if texels <= 0 or light.size() != texels * 6 or shadow.size() != texels:
		return {}
	var stale := {}
	for id in _ints(raw.get("stale")):
		stale[id] = true
	var keys := _ints(raw.get("chart_keys"))
	var rows := _floats(raw.get("chart_rows"))
	# Atlas v to the atlas with the fallback row added below it.
	var squeeze := float(height) / (height + 1)
	var charts := {}
	for c in mini(keys.size() / 2, rows.size() / 8):
		var node := keys[c * 2]
		if stale.has(node):
			continue
		var r := rows.slice(c * 8, c * 8 + 8)
		for k in range(4, 8):
			r[k] *= squeeze
		if not charts.has(node):
			charts[node] = {}
		charts[node][keys[c * 2 + 1]] = r
	var fallback := _floats(raw.get("fallback"))
	return {
		"width": width,
		"height": height,
		"light": light,
		"shadow": shadow,
		"fallback": Color(fallback[0], fallback[1], fallback[2]) if fallback.size() >= 3 else Color(0.2, 0.2, 0.2),
		"charts": charts,
		"probes": _probes(raw),
	}

## Probe columns of the chunk when they add up: points (map units), sh (nine RGB per point), tetrahedra (four point
## indices each), bsp_planes (normal and distance in map units per node), bsp_children (over and under per node).
static func _probes(raw: Dictionary) -> Dictionary:
	var points := _floats(raw.get("probe_points"))
	var sh := _floats(raw.get("probe_sh"))
	var tetrahedra := _ints(raw.get("probe_tetrahedra"))
	var planes := _floats(raw.get("probe_bsp_planes"))
	var children := _ints(raw.get("probe_bsp_children"))
	var n := points.size() / 3
	var nodes := planes.size() / 4
	if n < 4 or points.size() != n * 3 or sh.size() != n * 27 or tetrahedra.is_empty() or tetrahedra.size() % 4 != 0:
		return {}
	if nodes == 0 or planes.size() != nodes * 4 or children.size() != nodes * 2:
		return {}
	for i in tetrahedra:
		if i < 0 or i >= n:
			return {}
	return { "points": points, "sh": sh, "tetrahedra": tetrahedra, "bsp_planes": planes, "bsp_children": children }

## The dictionary [method LightmapGIData._set_probe_data] takes, for positions in meters [param scale] per map unit.
static func probe_data(probes: Dictionary, scale: float) -> Dictionary:
	var src: PackedFloat32Array = probes["points"]
	var points := PackedVector3Array()
	var bounds := AABB()
	for k in src.size() / 3:
		var p := Vector3(src[k * 3], src[k * 3 + 1], src[k * 3 + 2]) * scale
		points.append(p)
		bounds = AABB(p, Vector3.ZERO) if k == 0 else bounds.expand(p)
	var sh_src: PackedFloat32Array = probes["sh"]
	var sh := PackedColorArray()
	for k in sh_src.size() / 3:
		sh.append(Color(sh_src[k * 3], sh_src[k * 3 + 1], sh_src[k * 3 + 2]))
	var tetrahedra := PackedInt32Array(Array(probes["tetrahedra"]))
	# Godot keeps each BSP node as six int32: the plane's four floats by their bits, then the children.
	var planes: PackedFloat32Array = probes["bsp_planes"]
	var children: PackedInt64Array = probes["bsp_children"]
	var nodes := planes.size() / 4
	var bytes := PackedByteArray()
	bytes.resize(nodes * 24)
	for k in nodes:
		for c in 3:
			bytes.encode_float(k * 24 + c * 4, planes[k * 4 + c])
		bytes.encode_float(k * 24 + 12, planes[k * 4 + 3] * scale)
		bytes.encode_s32(k * 24 + 16, children[k * 2])
		bytes.encode_s32(k * 24 + 20, children[k * 2 + 1])
	return {
		"bounds": bounds,
		"points": points,
		"sh": sh,
		"tetrahedra": tetrahedra,
		"bsp": bytes.to_int32_array(),
		"interior": false,
		"baked_exposure": 1.0,
	}

## Rows that send every point to the fallback row.
static func fallback_rows(lightmap: Dictionary) -> PackedFloat32Array:
	var h := int(lightmap["height"])
	return PackedFloat32Array([0, 0, 0, 0.5, 0, 0, 0, (h + 0.5) / (h + 1)])

## Editor space rows (map units, Y up) for positions in FuncGodot's id space scaled to meters, see
## [method TrenchDotParser.to_id].
static func id_rows(rows: PackedFloat32Array, scale: float) -> PackedFloat32Array:
	return PackedFloat32Array([rows[2] / scale, rows[0] / scale, rows[1] / scale, rows[3], rows[6] / scale, rows[4] / scale, rows[5] / scale, rows[7]])

## Editor space rows for Godot space positions in meters relative to [param offset], also in meters.
static func local_rows(rows: PackedFloat32Array, scale: float, offset: Vector3) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(8)
	for r in 2:
		var axis := Vector3(rows[r * 4], rows[r * 4 + 1], rows[r * 4 + 2]) / scale
		out[r * 4] = axis.x
		out[r * 4 + 1] = axis.y
		out[r * 4 + 2] = axis.z
		out[r * 4 + 3] = rows[r * 4 + 3] + axis.dot(offset)
	return out

static func uv2(rows: PackedFloat32Array, p: Vector3) -> Vector2:
	return Vector2(rows[0] * p.x + rows[1] * p.y + rows[2] * p.z + rows[3], rows[4] * p.x + rows[5] * p.y + rows[6] * p.z + rows[7])

## Adds a [LightmapGI] under [param map_node] for every mesh instance the build marked with [constant BAKED_META],
## and sets each light's bake mode. Returns it, or null when nothing was baked.
static func build(map_node: Node3D, lightmap: Dictionary, entities: Array) -> LightmapGI:
	if lightmap.is_empty():
		return null
	var users: Array[MeshInstance3D] = []
	var stack: Array[Node] = [map_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.has_meta(BAKED_META):
			users.append(n)
		stack.append_array(n.get_children())
	if users.is_empty():
		return null

	var w := int(lightmap["width"])
	var h := int(lightmap["height"])
	var fallback: Color = lightmap["fallback"]
	var light: PackedByteArray = lightmap["light"].duplicate()
	var texel := PackedByteArray()
	texel.resize(6)
	texel.encode_half(0, fallback.r)
	texel.encode_half(2, fallback.g)
	texel.encode_half(4, fallback.b)
	for x in w:
		light.append_array(texel)
	var shadow: PackedByteArray = lightmap["shadow"].duplicate()
	var lit_row := PackedByteArray()
	lit_row.resize(w)
	lit_row.fill(255)
	shadow.append_array(lit_row)

	var light_images: Array[Image] = [Image.create_from_data(w, h + 1, false, Image.FORMAT_RGBH, light)]
	var light_texture := Texture2DArray.new()
	light_texture.create_from_images(light_images)
	var shadow_images: Array[Image] = [Image.create_from_data(w, h + 1, false, Image.FORMAT_L8, shadow)]
	var shadow_texture := Texture2DArray.new()
	shadow_texture.create_from_images(shadow_images)

	var gi := LightmapGI.new()
	gi.name = NODE_NAME
	map_node.add_child(gi)
	gi.owner = TrenchDotBuild.scene_owner(map_node)
	var data := LightmapGIData.new()
	var light_textures: Array[TextureLayered] = [light_texture]
	data.lightmap_textures = light_textures
	var shadow_textures: Array[TextureLayered] = [shadow_texture]
	data.shadowmask_textures = shadow_textures
	for mi in users:
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		data.add_user(gi.get_path_to(mi), Rect2(0, 0, 1, 1), 0, -1)
	if not lightmap.get("probes", {}).is_empty():
		var scale := 1.0 / 32.0
		if map_node is FuncGodotMap and map_node.map_settings:
			scale = map_node.map_settings.scale_factor
		data.call("_set_probe_data", probe_data(lightmap["probes"], scale))
	gi.light_data = data

	var sun_mode := LightmapGIData.SHADOWMASK_MODE_NONE
	for entity in entities:
		if entity.node is Light3D:
			entity.node.light_bake_mode = bake_mode(entity.properties, "bake_mode")
	if not entities.is_empty():
		var sun := map_node.get_node_or_null("sun") as DirectionalLight3D
		if sun:
			sun.light_bake_mode = bake_mode(entities[0].properties, "sun_bake_mode")
			if sun.light_bake_mode == Light3D.BAKE_DYNAMIC:
				sun_mode = LightmapGIData.SHADOWMASK_MODE_REPLACE
	gi.shadowmask_mode = sun_mode
	return gi

## Godot's bake mode for a light with [param properties], BakeMode::resolve in crates/td_editor/src/bake/collect.rs.
## Auto bakes a light unless I/O can switch it, which a baked light cannot follow.
static func bake_mode(properties: Dictionary, key: String) -> Light3D.BakeMode:
	match str(properties.get(key, "auto")).strip_edges():
		"baked", "static":
			return Light3D.BAKE_STATIC
		"bounce", "dynamic":
			return Light3D.BAKE_DYNAMIC
		"realtime", "disabled":
			return Light3D.BAKE_DISABLED
	var switchable := key == "bake_mode" and (str(properties.get("targetname", "")) != "" or str(properties.get("start_on", "1")) == "0")
	return Light3D.BAKE_DISABLED if switchable else Light3D.BAKE_STATIC

static func _bytes(v: Variant) -> PackedByteArray:
	if v is PackedByteArray:
		return v
	if v is String:
		return Marshalls.base64_to_raw(v)
	return PackedByteArray()

static func _ints(v: Variant) -> PackedInt64Array:
	if v is PackedInt64Array:
		return v
	var out := PackedInt64Array()
	if v is Array or v is PackedInt32Array or v is PackedFloat64Array or v is PackedFloat32Array:
		for x in v:
			out.append(int(x))
	return out

static func _floats(v: Variant) -> PackedFloat32Array:
	if v is PackedFloat32Array:
		return v
	var out := PackedFloat32Array()
	if v is Array or v is PackedFloat64Array:
		for x in v:
			out.append(float(x))
	return out
