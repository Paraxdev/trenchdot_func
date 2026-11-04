class_name TrenchDotCollision extends RefCounted
## Collision for entities that build from a model: prop_model, prop_physics, npc_walker and scatter sets.
## "collision" picks the shape, "collision_layer" and "collision_mask" list layer numbers such as "1, 3".
## Empty keys fall back to the project settings below.

const SETTING_SHAPE := "trenchdot/collision/model_shape"
const SETTING_LAYER := "trenchdot/collision/model_layer"
const SETTING_MASK := "trenchdot/collision/model_mask"
const MODES: Array[String] = ["none", "box", "convex", "decomposition", "trimesh"]

## The shape [param key] names, [param fallback] or the project default when it is empty or "default".
static func mode(key: Variant, fallback := "") -> String:
	var m := str(key).strip_edges().to_lower()
	if m == "" or m == "default":
		m = fallback if fallback != "" else str(ProjectSettings.get_setting(SETTING_SHAPE, "convex"))
	return m if m in MODES else "convex"

## Layer numbers such as "1, 3" or "none" as a bitmask, -1 when [param key] is empty.
static func layers(key: Variant) -> int:
	var text := str(key).strip_edges().to_lower()
	if text == "" or text == "default":
		return -1
	var bits := 0
	for part in text.replace(",", " ").split(" ", false):
		if part.is_valid_int() and part.to_int() >= 1 and part.to_int() <= 32:
			bits |= 1 << (part.to_int() - 1)
		elif part != "none":
			push_warning("[TrenchDot] collision layer '%s' in '%s' is not a layer number from 1 to 32, it is ignored" % [part, key])
	return bits

## Sets [param body]'s layer and mask from the keys, else from the project defaults.
static func apply_layers(body: CollisionObject3D, properties: Dictionary) -> void:
	var layer := layers(properties.get("collision_layer", ""))
	var mask := layers(properties.get("collision_mask", ""))
	body.collision_layer = layer if layer >= 0 else int(ProjectSettings.get_setting(SETTING_LAYER, 1))
	body.collision_mask = mask if mask >= 0 else int(ProjectSettings.get_setting(SETTING_MASK, 1))

## [Shape3D, Transform3D] pairs for the meshes under [param root], placed in [param space], an ancestor of root or
## root itself. Trimesh needs a static body, so [param allow_trimesh] false builds convex hulls instead.
static func shapes(root: Node, space: Node, shape_mode: String, allow_trimesh := true) -> Array:
	var out := []
	if shape_mode == "trimesh" and not allow_trimesh:
		shape_mode = "convex"
	var meshes := _mesh_instances(root)
	if shape_mode == "none" or meshes.is_empty():
		return out
	if shape_mode == "box":
		var bounds: AABB
		for i in meshes.size():
			var b: AABB = relative_transform(meshes[i], space) * meshes[i].mesh.get_aabb()
			bounds = b if i == 0 else bounds.merge(b)
		var box := BoxShape3D.new()
		box.size = bounds.size.max(Vector3.ONE * 0.01)
		out.append([box, Transform3D(Basis.IDENTITY, bounds.get_center())])
		return out
	for mi in meshes:
		var t := relative_transform(mi, space)
		match shape_mode:
			"trimesh":
				out.append([mi.mesh.create_trimesh_shape(), t])
			"decomposition":
				for shape in decompose(mi.mesh):
					out.append([shape, t])
			_:
				out.append([mi.mesh.create_convex_shape(), t])
	return out

## Convex hulls approximating [param mesh], from Godot's V-HACD convex decomposition.
static func decompose(mesh: Mesh) -> Array[Shape3D]:
	var out: Array[Shape3D] = []
	var settings := MeshConvexDecompositionSettings.new()
	settings.max_convex_hulls = 16
	settings.max_concavity = 0.05
	var tmp := MeshInstance3D.new()
	tmp.mesh = mesh
	tmp.create_multiple_convex_collisions(settings)
	for body in tmp.get_children():
		for cs in body.get_children():
			if cs is CollisionShape3D and cs.shape:
				out.append(cs.shape)
	tmp.free()
	if out.is_empty():
		out.append(mesh.create_convex_shape())
	return out

## A [CollisionShape3D] child of [param body] per pair from [method shapes], owned by [param owner] when set.
static func add_shapes(body: CollisionObject3D, pairs: Array, owner: Node = null, offset := Transform3D.IDENTITY) -> void:
	for pair in pairs:
		var cs := CollisionShape3D.new()
		cs.shape = pair[0]
		cs.transform = offset * pair[1]
		body.add_child(cs)
		if owner:
			cs.owner = owner

static func relative_transform(node: Node3D, space: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n and n != space:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

static func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			out.append(n)
		stack.append_array(n.get_children())
	return out
