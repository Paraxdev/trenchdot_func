class_name TrenchDotParser extends RefCounted
## Converts TrenchDot .tdm maps into [FuncGodotData] so the regular FuncGodot build pipeline can use them.
##
## TrenchDot stores maps Y-up in Godot's axis convention with exact brush vertices.
## FuncGodot works in id Tech axes internally, so everything is rotated into that space
## ([code]id = (g.z, g.x, g.y)[/code], a pure rotation, so windings and UV axes stay valid).

const _GroupData := FuncGodotData.GroupData
const _EntityData := FuncGodotData.EntityData
const _BrushData := FuncGodotData.BrushData
const _FaceData := FuncGodotData.FaceData
const _ParseData := FuncGodotData.ParseData

const FORMAT_NAME := "trenchdot-map"
## Newest map version this importer understands, the same as FORMAT_VERSION in crates/td_doc/src/format.rs.
const FORMAT_VERSION := 1
const MAX_INSTANCE_DEPTH := 8
## Values that prefab instances may add to one build in all, counted per instance from what its prefab holds, see
## [method _size]. Instances of instances could otherwise multiply a small map past anything a build can take.
const MAX_INSTANCED := 1 << 21

## Godot space (map units, Y-up) to FuncGodot's id space.
static func to_id(v: Vector3) -> Vector3:
	return Vector3(v.z, v.x, v.y)

static func vec3(a: Variant, fallback := Vector3.ZERO) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func vec2(a: Variant, fallback := Vector2.ONE) -> Vector2:
	if a is Array and a.size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return fallback

## The texture scale of a face's uv, where a zero part counts as 1 like FaceUv::texel in the editor.
static func uv_scale_of(uv: Dictionary) -> Vector2:
	var s := vec2(uv.get("scale"), Vector2.ONE)
	return Vector2(s.x if absf(s.x) >= 1e-9 else 1.0, s.y if absf(s.y) >= 1e-9 else 1.0)

## TrenchDot angles are node rotation degrees (YXZ). FuncGodot applies (-a0, a1 + 180, -a2) to Quake angles.
static func angles_to_quake(angles: Vector3) -> String:
	return "%s %s %s" % [-angles.x, angles.y - 180.0, -angles.z]

static func rotation_basis(angles: Vector3) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(angles.x), deg_to_rad(angles.y), deg_to_rad(angles.z)), EULER_ORDER_YXZ)


## Entity keys that name other entities and so get an instance's fixup, besides any property an entity definition
## declares as a target. Kept in step with FIXUP_KEYS in crates/td_doc/src/map.rs.
const FIXUP_KEYS: Array[String] = ["targetname", "target", "destination", "call_target"]
## Properties the game config exports as target_destination by their name unless the definition declares another type
## or gives a FuncGodotFGDProperty, see TrenchDotGameConfig._property_def. The editor then fixes them up too.
const INFERRED_TARGET_KEYS: Array[String] = ["target", "killtarget", "parent"]

class Context:
	var map_settings: FuncGodotMapSettings
	## Classname to the keys that get a fixup, filled on first use inside an instance.
	var fixup_keys: Dictionary = {}
	var entity_defs: Variant = null
	var parse_data: _ParseData
	var map_path: String
	var worldspawn: _EntityData
	var next_group_id := 1
	var instance_depth := 0
	## Prefabs read by this build, by path: the parsed map and its [method _size], or null when it cannot be read.
	var prefabs: Dictionary = {}
	## What instances have added so far, see [constant MAX_INSTANCED].
	var instanced := 0
	## Id namespace of the instance occurrence currently being parsed, 0 at the top level. Every [method _parse_instance]
	## call gets its own value from [member next_instance_ns], so two copies of the same prefab never share ids, however
	## deep they are nested.
	var instance_ns := 0
	var next_instance_ns := 1
	## Transform applied to everything parsed at the current instance level (Godot space, map units).
	var xform := Transform3D.IDENTITY
	var name_prefix := ""
	## Brushes and meshes waiting to be converted, see [method TrenchDotParser._convert_geometry].
	var geometry: Array[Dictionary] = []
	## The map's baked lighting, see [method TrenchDotLightmap.decode]. Empty when it has none or it is not used.
	var lightmap: Dictionary = {}
	## Names of the textures laid out by world projection, see [method TrenchDotParser._texture_settings].
	var world_projected: Dictionary = {}


static func parse(text: String, map_settings: FuncGodotMapSettings, parse_data: _ParseData, map_path: String = "") -> _ParseData:
	return parse_dict(JSON.parse_string(text), map_settings, parse_data, map_path)


## Like [method parse] for a map that is already parsed JSON, e.g. the live model of the TrenchDot editor.
## [param use_lightmap] false ignores the lighting baked in the editor.
static func parse_dict(json: Variant, map_settings: FuncGodotMapSettings, parse_data: _ParseData, map_path: String = "", use_lightmap := true) -> _ParseData:
	if not _readable(json, map_path):
		return null
	var ctx := Context.new()
	ctx.map_settings = map_settings
	ctx.parse_data = parse_data
	ctx.map_path = map_path
	if use_lightmap:
		ctx.lightmap = TrenchDotLightmap.decode(json.get("lightmap"))
		parse_data.lightmap = ctx.lightmap

	_texture_settings(ctx, json.get("textures"))
	var world := _EntityData.new()
	world.properties["classname"] = "worldspawn"
	for key in json.get("properties", {}):
		world.properties[key] = str(json["properties"][key])
	world.properties["classname"] = "worldspawn"
	world.node_id = 0
	ctx.worldspawn = world
	parse_data.entities.append(world)

	for layer in json.get("layers", []):
		if _is_layer(layer):
			_parse_node(ctx, layer, null)
	_convert_geometry(ctx)
	return parse_data


## Reads the settings the map keeps per texture: a repeat size in map units that replaces the texture's own, and
## world projection, which ignores each face's alignment. Baking settings only matter to the editor's bake.
static func _texture_settings(ctx: Context, textures: Variant) -> void:
	if not textures is Dictionary:
		return
	for name in textures:
		var settings: Variant = textures[name]
		if not settings is Dictionary:
			continue
		var size := vec2(settings.get("size"), Vector2.ZERO)
		if size.x > 0.0 and size.y > 0.0:
			ctx.parse_data.texture_sizes[str(name)] = size
		if settings.get("projection", "face") == "world":
			ctx.world_projected[str(name)] = true

## The texture axes the editor gives a face with [param normal] when it is reset, in Godot space, see paraxial_axes
## in crates/td_geom/src/uv.rs.
static func paraxial_axes(normal: Vector3) -> Array[Vector3]:
	var a := normal.abs()
	if a.x >= a.y and a.x >= a.z:
		return [Vector3.FORWARD if normal.x >= 0.0 else Vector3.BACK, Vector3.DOWN]
	if a.y >= a.z:
		return [Vector3.RIGHT, Vector3.BACK]
	return [Vector3.RIGHT if normal.z >= 0.0 else Vector3.LEFT, Vector3.DOWN]

## Refuses what the editor refuses to open: another format, or a version newer than this importer knows.
static func _readable(json: Variant, path: String) -> bool:
	if not json is Dictionary or json.get("format", "") != FORMAT_NAME:
		push_error("[TDM] %s is not a TrenchDot map" % path)
		return false
	if int(json.get("version", 0)) > FORMAT_VERSION:
		push_error("[TDM] %s is map version %s, newer than this addon supports (%s), update the addon" % [path, json.get("version"), FORMAT_VERSION])
		return false
	return true

## The editor only keeps layers at the top of a map, so anything else there is ignored here too.
static func _is_layer(node: Variant) -> bool:
	return node is Dictionary and node.get("type", "") == "layer"

## Leaves a slot for a brush or mesh node in [param entity], filled by [method _convert_geometry].
static func _queue_geometry(ctx: Context, node: Dictionary, entity: _EntityData) -> void:
	entity.brushes.append(null)
	ctx.geometry.append({ "node": node, "xform": ctx.xform, "ns": ctx.instance_ns, "entity": entity, "slot": entity.brushes.size() - 1 })


## Converts the queued brushes and meshes, on worker threads for bigger maps. Only data is created there.
static func _convert_geometry(ctx: Context) -> void:
	var jobs := ctx.geometry
	var results := []
	results.resize(jobs.size())
	var clip_budget := TrenchDotMesh.ClipBudget.new()
	var convert := func(i: int) -> void:
		var job: Dictionary = jobs[i]
		var node: Dictionary = job["node"]
		var brush: _BrushData
		if node.get("type", "") == "mesh":
			brush = TrenchDotMesh.parse(node, job["xform"], ctx.map_settings.scale_factor, ctx.map_settings.origin_texture, clip_budget)
		else:
			brush = _parse_brush(ctx.map_settings, job["xform"], node, ctx.world_projected)
		if brush:
			brush.node_id = int(node.get("id", 0)) + int(job["ns"]) * 1000000
			# Only the map's own nodes were baked, prefab contents are the same node ids in another file.
			if int(job["ns"]) == 0 and not ctx.lightmap.is_empty():
				_apply_charts(brush, ctx.lightmap["charts"].get(int(node.get("id", 0)), {}), ctx.map_settings.scale_factor)
		results[i] = brush
	if TrenchDotBuild.threaded() and jobs.size() >= 32:
		var task := WorkerThreadPool.add_group_task(convert, jobs.size(), -1, false, "Convert TrenchDot brushes")
		WorkerThreadPool.wait_for_group_task_completion(task)
	else:
		for i in jobs.size():
			convert.call(i)
	if clip_budget.spent():
		push_warning("[TDM] %s has mesh faces with too many corners to triangulate in time, some were split into fans and may look wrong" % ctx.map_path)
	var touched := {}
	for i in jobs.size():
		var entity: _EntityData = jobs[i]["entity"]
		entity.brushes[jobs[i]["slot"]] = results[i]
		touched[entity] = true
	for entity: _EntityData in touched:
		for k in range(entity.brushes.size() - 1, -1, -1):
			if entity.brushes[k] == null:
				entity.brushes.remove_at(k)
		if not ctx.lightmap.is_empty():
			_fill_charts(entity, TrenchDotLightmap.fallback_rows(ctx.lightmap))
	jobs.clear()


## Gives each face of [param brush] its light map rows in id space, keyed by the face's index in the map node.
static func _apply_charts(brush: _BrushData, charts: Dictionary, scale: float) -> void:
	if charts.is_empty():
		return
	for face in brush.faces:
		if charts.has(face.source_index):
			face.lightmap_rows = TrenchDotLightmap.id_rows(charts[face.source_index], scale)


## Marks [param entity] baked when any of its faces has light map rows, and points its other faces at the fallback
## row, since a mesh either takes its lighting from the light map everywhere or nowhere.
static func _fill_charts(entity: _EntityData, fallback: PackedFloat32Array) -> void:
	for brush in entity.brushes:
		for face in brush.faces:
			if not face.lightmap_rows.is_empty():
				entity.baked = true
	if not entity.baked:
		return
	for brush in entity.brushes:
		for face in brush.faces:
			if face.lightmap_rows.is_empty():
				face.lightmap_rows = fallback


static func _make_group(ctx: Context, node: Dictionary, parent: _GroupData, is_layer: bool) -> _GroupData:
	var group := _GroupData.new()
	group.id = int(node.get("id", ctx.next_group_id)) + ctx.instance_ns * 1000000
	ctx.next_group_id += 1
	group.type = _GroupData.GroupType.LAYER if is_layer else _GroupData.GroupType.GROUP
	var label: String = str(node.get("name", "")).replace(" ", "_")
	group.name = ("layer_" if is_layer else "group_") + str(group.id) + ("_" + label if label != "" else "")
	if parent:
		group.parent_id = parent.id
		group.parent = parent
	group.omit = bool(node.get("omit_from_export", false))
	ctx.parse_data.groups.append(group)
	return group


static func _parse_node(ctx: Context, node: Dictionary, group: _GroupData) -> void:
	match node.get("type", ""):
		"layer":
			if bool(node.get("omit_from_export", false)):
				return
			var g := _make_group(ctx, node, group, true)
			for child in node.get("children", []):
				_parse_node(ctx, child, g)
		"group":
			var g := _make_group(ctx, node, group, false)
			for child in node.get("children", []):
				_parse_node(ctx, child, g)
		"brush", "mesh":
			_queue_geometry(ctx, node, ctx.worldspawn)
		"terrain":
			# Terrains stay axis aligned: an instance rotates the terrain's center about the instance origin, like
			# Terrain::transformed in the editor, but never the grid itself. TrenchDotTerrain.create does the rotation.
			var terrain := { "data": node, "xform": ctx.xform, "group": group, "id": int(node.get("id", 0)) + ctx.instance_ns * 1000000 }
			if ctx.instance_ns == 0 and not ctx.lightmap.is_empty():
				var charts: Dictionary = ctx.lightmap["charts"].get(int(node.get("id", 0)), {})
				if charts.has(0):
					terrain["lightmap_rows"] = charts[0]
			ctx.parse_data.terrains.append(terrain)
		"scatter":
			ctx.parse_data.scatters.append({ "data": node, "xform": ctx.xform, "group": group, "id": int(node.get("id", 0)) + ctx.instance_ns * 1000000 })
		"entity":
			_parse_entity(ctx, node, group)
		"instance":
			_parse_instance(ctx, node, group)


static func _parse_entity(ctx: Context, node: Dictionary, group: _GroupData) -> void:
	var ent := _EntityData.new()
	var props: Dictionary = node.get("properties", {})
	for key in props:
		ent.properties[key] = str(props[key])
	ent.properties["classname"] = str(node.get("classname", ""))
	ent.group = group
	ent.node_id = int(node.get("id", 0)) + ctx.instance_ns * 1000000

	if ctx.name_prefix != "":
		for key in _fixup_keys(ctx, ent.properties["classname"]):
			if ent.properties.has(key):
				ent.properties[key] = _fixup(ctx, ent.properties[key])

	var children: Array = node.get("children", [])
	if children.is_empty():
		var origin: Vector3 = ctx.xform * vec3(node.get("origin"))
		var angles := vec3(node.get("angles"))
		if ctx.xform != Transform3D.IDENTITY:
			var basis := (ctx.xform.basis * rotation_basis(angles)).orthonormalized()
			var euler := basis.get_euler(EULER_ORDER_YXZ)
			angles = Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))
		var id_origin := to_id(origin)
		ent.properties["origin"] = "%s %s %s" % [id_origin.x, id_origin.y, id_origin.z]
		if not ent.properties.has("angles") and not ent.properties.has("angle") and not ent.properties.has("mangle"):
			ent.properties["angles"] = angles_to_quake(angles)
	else:
		for child in children:
			if child.get("type", "") in ["brush", "mesh"]:
				_queue_geometry(ctx, child, ent)

	var outputs: Array = node.get("outputs", [])
	for o in outputs:
		var conn: Dictionary = o.duplicate()
		if conn.has("target"):
			conn["target"] = _fixup(ctx, str(conn["target"]))
		ent.outputs.append(conn)
	ctx.parse_data.entities.append(ent)


## Runs on worker threads, so it only creates data.
static func _parse_brush(map_settings: FuncGodotMapSettings, xform: Transform3D, node: Dictionary, world_projected: Dictionary = {}) -> _BrushData:
	var raw_vertices: Array = node.get("vertices", [])
	var faces: Array = node.get("faces", [])
	if raw_vertices.size() < 4 or faces.size() < 4:
		return null
	var scale := map_settings.scale_factor
	var vertices := PackedVector3Array()
	vertices.resize(raw_vertices.size())
	for i in raw_vertices.size():
		vertices[i] = xform * vec3(raw_vertices[i])

	var brush := _BrushData.new()
	brush.exact = true
	var origin_texture := map_settings.origin_texture
	brush.origin = true
	for face_index in faces.size():
		var f: Dictionary = faces[face_index]
		var indices: Array = f.get("indices", [])
		if indices.size() < 3:
			continue
		var godot_points := PackedVector3Array()
		for idx in indices:
			var i := int(idx)
			if i < 0 or i >= vertices.size():
				push_error("[TDM] brush %s has a face indexing vertex %d, out of range for %d vertices, skipping the brush" % [str(int(node["id"])) if node.has("id") else "?", i, vertices.size()])
				return null
			godot_points.append(vertices[i])

		# Newell normal is robust for any convex polygon, including slightly imprecise ones.
		var normal := Vector3.ZERO
		var centroid := Vector3.ZERO
		for i in godot_points.size():
			var cur := godot_points[i]
			var nxt := godot_points[(i + 1) % godot_points.size()]
			normal.x += (cur.y - nxt.y) * (cur.z + nxt.z)
			normal.y += (cur.z - nxt.z) * (cur.x + nxt.x)
			normal.z += (cur.x - nxt.x) * (cur.y + nxt.y)
			centroid += cur
		if normal.length_squared() < 1e-12:
			continue
		centroid /= godot_points.size()
		var id_normal := to_id(normal.normalized())
		var id_centroid := to_id(centroid) * scale
		var plane := Plane(id_normal, id_normal.dot(id_centroid))

		var face := _FaceData.new()
		face.source_index = face_index
		face.plane = plane
		face.texture = str(f.get("material", ""))
		var face_props: Dictionary = f.get("props", {})
		var blend_material := str(face_props.get("blend_material", ""))
		if blend_material != "":
			var detile := float(face_props.get("blend_detile", 0.0))
			var uv_scale := float(face_props.get("blend_uv_scale", 1.0))
			var sharpen := float(face_props.get("blend_detile_sharpen", 0.5))
			face.texture = TrenchDotBlend.key(face.texture, blend_material, detile, uv_scale, sharpen)
		for p in godot_points:
			face.exact_vertices.append(to_id(p) * scale)

		var uv: Dictionary = f.get("uv", {})
		var u_axis := vec3(uv.get("u_axis"), Vector3.RIGHT)
		var v_axis := vec3(uv.get("v_axis"), Vector3.BACK)
		var offset := vec2(uv.get("offset"), Vector2.ZERO)
		var uv_scale := uv_scale_of(uv)
		if world_projected.has(str(f.get("material", ""))):
			var axes := paraxial_axes(normal.normalized())
			u_axis = axes[0]
			v_axis = axes[1]
			offset = Vector2.ZERO
			uv_scale = Vector2.ONE
		elif xform != Transform3D.IDENTITY:
			# Keep textures locked to instance geometry.
			var inv_t := xform.basis.inverse().transposed()
			var t := xform.origin
			var mu := inv_t * u_axis
			var mv := inv_t * v_axis
			var lu := maxf(mu.length(), 1e-9)
			var lv := maxf(mv.length(), 1e-9)
			offset.x -= mu.dot(t) / uv_scale.x
			offset.y -= mv.dot(t) / uv_scale.y
			uv_scale = Vector2(uv_scale.x / lu, uv_scale.y / lv)
			u_axis = mu / lu
			v_axis = mv / lv
		face.uv_axes.append(to_id(u_axis))
		face.uv_axes.append(to_id(v_axis))
		face.uv = Transform2D.IDENTITY
		face.uv.origin = offset
		face.uv.x = Vector2(uv_scale.x, 0.0) * scale
		face.uv.y = Vector2(0.0, uv_scale.y) * scale
		face.props = f.get("props", {})

		var colors: Array = f.get("colors", [])
		if colors.size() == godot_points.size():
			for c in colors:
				face.vertex_colors.append(Color(float(c[0]), float(c[1]), float(c[2]), float(c[3])))

		var disp = f.get("disp", null)
		if disp is Dictionary and godot_points.size() == 4:
			var power := int(disp.get("power", 3))
			# Untyped, an Array variable would copy a packed array of any length before its size is checked.
			var heights = disp.get("heights", [])
			var alphas = disp.get("alphas", [])
			if TrenchDotDisplacement.fits(power, heights, alphas):
				var grid := TrenchDotDisplacement.build_grid(godot_points, normal.normalized(), power, Array(heights))
				for p in grid["positions"]:
					face.disp_vertices.append(to_id(p) * scale)
				for p in grid["base"]:
					face.disp_base.append(to_id(p) * scale)
				for nrm in grid["normals"]:
					face.disp_normals.append(to_id(nrm))
				face.disp_indices = grid["triangles"]
				for a in alphas:
					face.disp_alphas.append(float(a))
				brush.has_disp = true

		if face.texture.to_lower() != origin_texture:
			brush.origin = false
		brush.planes.append(plane)
		brush.faces.append(face)
	if brush.faces.size() < 4:
		return null
	return brush


## The prefab an instance names, empty unless it is a .tdm in the project. A relative path is beside the map that
## names it and may not climb out with "..", so it only leaves the project for a map that is outside it already.
static func _resolve_instance_path(map_path: String, path: String) -> String:
	if path.begins_with("res://") or path.begins_with("uid://"):
		return TrenchDotBuild.map_resource_path(path, TrenchDotBuild.MAP_FILES)
	var rel := path.simplify_path()
	if rel == "" or rel.is_absolute_path() or rel.contains(":") or ".." in rel.split("/") or rel.get_extension().to_lower() != "tdm":
		return TrenchDotBuild.map_resource_path(path, TrenchDotBuild.MAP_FILES)
	var resolved := map_path.get_base_dir().path_join(rel)
	return TrenchDotBuild.map_resource_path(resolved, TrenchDotBuild.MAP_FILES) if resolved.begins_with("res://") else resolved

## The prefab files [param map] instances outside omitted layers, resolved from [param map_path] the way a build
## resolves them, and the ones those instance in turn.
static func prefabs(map: Dictionary, map_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	_collect_prefabs(map, map_path, out, 0)
	return out

static func _collect_prefabs(map: Dictionary, map_path: String, out: PackedStringArray, depth: int) -> void:
	if depth >= MAX_INSTANCE_DEPTH:
		return
	var stack := []
	for layer in map.get("layers", []):
		if _is_layer(layer) and not bool(layer.get("omit_from_export", false)):
			stack.append_array(layer.get("children", []))
	while not stack.is_empty():
		var node: Variant = stack.pop_back()
		if not node is Dictionary:
			continue
		if node.get("type", "") != "instance":
			stack.append_array(node.get("children", []))
			continue
		var path := _resolve_instance_path(map_path, str(node.get("path", "")))
		if path == "" or path in out:
			continue
		out.append(path)
		var prefab: Variant = TrenchDotTdmFile.read(path)["map"]
		if prefab is Dictionary:
			_collect_prefabs(prefab, path, out, depth + 1)


## [param name] as named inside the instance being parsed. Special (!self), group (@doors) and node path targets are
## left alone, the same rule as Instance::fixup_name in the editor.
static func _fixup(ctx: Context, name: String) -> String:
	if ctx.name_prefix == "" or name == "" or name[0] in ["!", "@", "/"]:
		return name
	return ctx.name_prefix + name

static func _fixup_keys(ctx: Context, classname: String) -> Array[String]:
	if ctx.fixup_keys.has(classname):
		return ctx.fixup_keys[classname]
	if ctx.entity_defs == null:
		var fgd: FuncGodotFGDFile = ctx.map_settings.entity_fgd if ctx.map_settings else null
		ctx.entity_defs = fgd.get_entity_definitions() if fgd else {}
	var keys: Array[String] = FIXUP_KEYS.duplicate()
	var def = ctx.entity_defs.get(classname)
	if def is FuncGodotFGDEntityClass:
		var declared: Dictionary = def.meta_properties.get("property_types", {})
		for key in declared:
			if str(declared[key]) in ["target_source", "target_destination"] and not key in keys:
				keys.append(str(key))
		for key in def.class_properties:
			if declared.has(key) or key in keys:
				continue
			var value: Variant = def.class_properties[key]
			if value is FuncGodotFGDPropertyTarget or (str(key) in INFERRED_TARGET_KEYS and not (value is FuncGodotFGDProperty)):
				keys.append(str(key))
	ctx.fixup_keys[classname] = keys
	return keys

static func _parse_instance(ctx: Context, node: Dictionary, group: _GroupData) -> void:
	if ctx.instance_depth >= MAX_INSTANCE_DEPTH:
		push_error("[TDM] instance nesting deeper than %d, skipping %s" % [MAX_INSTANCE_DEPTH, node.get("path", "")])
		return
	var path := _resolve_instance_path(ctx.map_path, str(node.get("path", "")))
	if path == "":
		return
	if not ctx.prefabs.has(path):
		var loaded = TrenchDotTdmFile.load_map(path)
		ctx.prefabs[path] = [loaded, _size(loaded)] if loaded != null and _readable(loaded, path) else null
	var prefab = ctx.prefabs[path]
	if prefab == null:
		return
	var json: Dictionary = prefab[0]
	if ctx.instanced <= MAX_INSTANCED and ctx.instanced + prefab[1] > MAX_INSTANCED:
		push_error("[TDM] %s places more prefab content than one build takes, leaving out %s and the instances after it" % [ctx.map_path, path])
	ctx.instanced += prefab[1]
	if ctx.instanced > MAX_INSTANCED:
		return

	var saved_xform := ctx.xform
	var saved_prefix := ctx.name_prefix
	var saved_path := ctx.map_path
	var saved_ns := ctx.instance_ns
	var local := Transform3D(rotation_basis(vec3(node.get("angles"))), vec3(node.get("origin")))
	ctx.xform = saved_xform * local
	var fixup := str(node.get("fixup", ""))
	if fixup != "":
		ctx.name_prefix = saved_prefix + fixup + "-"
	ctx.map_path = path
	ctx.instance_depth += 1
	# Every occurrence of an instance gets its own id namespace, so two copies of one prefab never collide, whichever
	# depth they nest at. Only the top level (namespace 0) keeps the ids the main map document was saved with.
	ctx.instance_ns = ctx.next_instance_ns
	ctx.next_instance_ns += 1

	for layer in json.get("layers", []):
		if not _is_layer(layer) or bool(layer.get("omit_from_export", false)):
			continue
		for child in layer.get("children", []):
			_parse_node(ctx, child, group)

	ctx.instance_depth -= 1
	ctx.instance_ns = saved_ns
	ctx.xform = saved_xform
	ctx.name_prefix = saved_prefix
	ctx.map_path = saved_path

## How many values the exported layers of [param json] hold, packed array items and every 8 characters of text
## included. An instance in it only counts as itself, the prefab it names is counted when it is placed.
static func _size(json: Variant) -> int:
	var total := 0
	var stack: Array = []
	for layer in json.get("layers", []):
		if _is_layer(layer) and not bool(layer.get("omit_from_export", false)):
			stack.append(layer)
	while not stack.is_empty():
		var value: Variant = stack.pop_back()
		total += 1
		if value is Dictionary:
			stack.append_array(value.values())
		elif value is Array:
			stack.append_array(value)
		elif value is String:
			total += value.length() / 8
		elif typeof(value) > TYPE_ARRAY and typeof(value) < TYPE_MAX:
			total += value.size()
	return total
