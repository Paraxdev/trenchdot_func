class_name TrenchDotProbes extends RefCounted
## Probe volumes: the brushes of env_reflection_probe and env_voxel_gi only give the box of a [ReflectionProbe] or
## [VoxelGI]. The build measures their mesh, or their brushes when a tool texture leaves them without one, centers the
## node on it, sizes the probe and drops the mesh.

## Sizes every probe volume among [param entities]. Runs before the chunk streamer so no probe mesh gets grouped.
static func fit_volumes(entities: Array) -> void:
	for entity in entities:
		if entity.node is ReflectionProbe or entity.node is VoxelGI:
			var corners := PackedVector3Array()
			for brush in entity.brushes:
				for face in brush.faces:
					for v in face.vertices:
						corners.append(FuncGodotUtil.id_to_opengl(v - entity.origin))
			fit(entity.node, corners)

## [param corners] are brush corners in the node's space, measured when the volume has no mesh.
static func fit(node: Node3D, corners := PackedVector3Array()) -> void:
	var box := AABB()
	var found := false
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh and child.mesh.get_surface_count() > 0:
			var b: AABB = child.transform * child.mesh.get_aabb()
			box = box.merge(b) if found else b
			found = true
	if not found and not corners.is_empty():
		box = AABB(corners[0], Vector3.ZERO)
		for c in corners:
			box = box.expand(c)
		found = true
	if not found:
		return
	for child in node.get_children():
		if child is MeshInstance3D or child is CollisionShape3D:
			node.remove_child(child)
			child.free()
	node.position += node.basis * box.get_center()
	node.size = box.size.max(Vector3.ONE * 0.1)

## Bakes the VoxelGI volumes under [param map_node] that ask for it. Only the Godot editor can bake them.
static func bake_voxel_gi(map_node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	for gi in map_node.find_children("*", "VoxelGI", true, false):
		if gi.has_method("bake_now"):
			gi.bake_now()
