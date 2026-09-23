class_name TrenchDotNav extends RefCounted
## Navigation meshes for built maps.
##
## Bakes from the collision of every [StaticBody3D] under a node, so clip brushes, terrain and prop collision count and
## illusionary brushes do not. Doors, buttons, platforms and trains build as [AnimatableBody3D] and are left out with
## everything under them, like triggers and physics props, so closed doors do not seal their doorways. Put a body in
## [constant IGNORE_GROUP] to leave it out too. The result is in the local space of the node it was baked from.
## [codeblock]
## map.build()
## var region := await TrenchDotNav.bake_region(map)
## [/codeblock]

## Bodies in this group, and everything under them, are left out of the bake.
const IGNORE_GROUP := &"navigation_ignore"
## Name of the [NavigationRegion3D] [method bake_region] adds.
const REGION_NAME := &"navigation"
const CACHE_DIR := "user://trenchdot_navigation"
## Cached bakes kept on disk, the oldest go first.
const CACHE_KEEP := 8
const _CACHE_VERSION := "1"
const _SOURCE_GROUP := &"_trenchdot_navigation_source"

## A [NavigationMesh] for an agent of this size in meters, with 0.1 m cells and the sizes snapped to them.
static func profile(radius := 0.3, height := 1.8, max_climb := 0.3, max_slope := 45.0) -> NavigationMesh:
	var nav := NavigationMesh.new()
	nav.cell_size = 0.1
	nav.cell_height = 0.1
	nav.agent_radius = radius
	nav.agent_height = height
	nav.agent_max_climb = max_climb
	nav.agent_max_slope = max_slope
	# Drops the small patches on top of tables and crates, 8 squared cells.
	nav.region_min_size = 8.0
	nav.filter_low_hanging_obstacles = true
	nav.filter_ledge_spans = true
	nav.filter_walkable_low_height_spans = true
	return snap_to_cells(nav)

## Snaps the agent sizes of [param nav] to its cells the way the bake would, so the bake does not warn about it.
static func snap_to_cells(nav: NavigationMesh) -> NavigationMesh:
	# Note: the bake divides in 32 bit floats, so a size that rounds up when stored lands in the next cell. The nudge
	# keeps it on the near side and well inside the bake's precision check.
	nav.agent_radius = ceilf(nav.agent_radius / nav.cell_size - 0.001) * nav.cell_size - 2e-6
	nav.agent_height = ceilf(nav.agent_height / nav.cell_height - 0.001) * nav.cell_height - 2e-6
	nav.agent_max_climb = floorf(nav.agent_max_climb / nav.cell_height + 0.001) * nav.cell_height + 2e-6
	return nav

## Bakes the maps under [param root] on this thread and returns the navigation mesh. [param agent] sets the agent
## size and bake settings, see [method profile], and is not changed.
static func bake(root: Node3D, agent: NavigationMesh = null) -> NavigationMesh:
	var nav := _prepare(agent)
	var source := parse(root, nav)
	if not source:
		return null
	NavigationServer3D.bake_from_source_geometry_data(nav, source)
	return nav

## Like [method bake] but on a worker thread, so await it. With [param cache] a bake of the same collision and settings
## loads from [constant CACHE_DIR] instead.
static func bake_async(root: Node3D, agent: NavigationMesh = null, cache := true) -> NavigationMesh:
	var nav := _prepare(agent)
	var source := parse(root, nav)
	if not source:
		return null
	var path := "%s/%s.res" % [CACHE_DIR, _cache_key(nav, source)] if cache else ""
	if path != "" and ResourceLoader.exists(path):
		var cached := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as NavigationMesh
		if cached and cached.get_polygon_count() > 0:
			return cached
	var done := [false]
	NavigationServer3D.bake_from_source_geometry_data_async(nav, source, func(): done[0] = true)
	var tree := root.get_tree()
	while not done[0]:
		await tree.process_frame
	if path != "" and nav.get_polygon_count() > 0:
		_save_cache(nav, path)
	return nav

## Bakes the maps under [param root] off the main thread into a [NavigationRegion3D] child named
## [constant REGION_NAME], reused on the next call, and returns it once paths over it work. Sets the cell size of the
## navigation map to the bake's. Call it again after the map rebuilds, a build frees the region.
static func bake_region(root: Node3D, agent: NavigationMesh = null, cache := true) -> NavigationRegion3D:
	var nav := await bake_async(root, agent, cache)
	if not nav:
		return null
	var region := root.get_node_or_null(NodePath(REGION_NAME)) as NavigationRegion3D
	if not region:
		region = NavigationRegion3D.new()
		region.name = REGION_NAME
		root.add_child(region)
	var map := region.get_navigation_map()
	NavigationServer3D.map_set_cell_size(map, nav.cell_size)
	NavigationServer3D.map_set_cell_height(map, nav.cell_height)
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	region.navigation_mesh = nav
	await wait_for_sync(region, iteration)
	return region

## Waits until the navigation map of [param region] has taken in its mesh. The map syncs a few physics frames after a
## region changes, until then paths come back empty and closest points at the origin. Returns false after
## [param max_frames].
static func wait_for_sync(region: NavigationRegion3D, after_iteration := -1, max_frames := 600) -> bool:
	var nav := region.navigation_mesh
	if not nav or nav.vertices.is_empty():
		return false
	var map := region.get_navigation_map()
	var probe := region.global_transform * nav.vertices[0]
	var tree := region.get_tree()
	for i in max_frames:
		if NavigationServer3D.map_get_iteration_id(map) > after_iteration and NavigationServer3D.map_get_closest_point(map, probe).distance_to(probe) < nav.cell_size * 4.0:
			return true
		await tree.physics_frame
	return false

## A path from [param from] to [param to] over the navigation map of [param node], in global coordinates. Unlike a
## default query it has no polygon limit: Godot stops a search after 4096 polygons and returns the path so far, which
## on a big map looks like an unreachable spot. Set [member NavigationAgent3D.path_search_max_polygons] to 0 for the same.
static func path(node: Node3D, from: Vector3, to: Vector3) -> PackedVector3Array:
	var query := NavigationPathQueryParameters3D.new()
	query.map = node.get_world_3d().navigation_map
	query.start_position = from
	query.target_position = to
	query.path_search_max_polygons = 0
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(query, result)
	return result.path

## The parts of [param nav] that are not connected to each other, as lists of polygon indices, largest first. A part
## that should be reachable but is not usually has a doorway blocked by something low or a step too high.
static func islands(nav: NavigationMesh) -> Array[PackedInt32Array]:
	var parent: Array[int] = []
	parent.assign(range(nav.vertices.size()))
	for p in nav.get_polygon_count():
		var polygon := nav.get_polygon(p)
		var a := _find(parent, polygon[0])
		for v in polygon:
			var b := _find(parent, v)
			if a != b:
				parent[b] = a
	var by_root := {}
	for p in nav.get_polygon_count():
		var root := _find(parent, nav.get_polygon(p)[0])
		if not by_root.has(root):
			by_root[root] = []
		by_root[root].append(p)
	var out: Array[PackedInt32Array] = []
	for list in by_root.values():
		out.append(PackedInt32Array(list))
	out.sort_custom(func(a: PackedInt32Array, b: PackedInt32Array): return a.size() > b.size())
	return out

## The collision under [param root] that [method bake] uses, in the local space of [param root], which has to be in
## the scene tree. [param nav] gives the collision mask, see [member NavigationMesh.geometry_collision_mask].
static func parse(root: Node3D, nav: NavigationMesh) -> NavigationMeshSourceGeometryData3D:
	if not root.is_inside_tree():
		push_error("TrenchDotNav: %s has to be in the scene tree to bake" % root.name)
		return null
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_EXPLICIT
	nav.geometry_source_group_name = _SOURCE_GROUP
	var bodies: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.is_in_group(IGNORE_GROUP) or (node is CollisionObject3D and not (node is StaticBody3D) or node is AnimatableBody3D):
			continue
		if node is StaticBody3D:
			bodies.append(node)
		stack.append_array(node.get_children())
	for body in bodies:
		body.add_to_group(_SOURCE_GROUP)
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav, source, root)
	for body in bodies:
		body.remove_from_group(_SOURCE_GROUP)
	return source

static func _prepare(agent: NavigationMesh) -> NavigationMesh:
	var nav: NavigationMesh = agent.duplicate() if agent else profile()
	nav.clear()
	return snap_to_cells(nav)

static func _find(parent: Array[int], i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _cache_key(nav: NavigationMesh, source: NavigationMeshSourceGeometryData3D) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var settings := _CACHE_VERSION
	for property in nav.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE and not property.name in ["vertices", "polygons"]:
			settings += "|%s=%s" % [property.name, nav.get(property.name)]
	ctx.update(settings.to_utf8_buffer())
	ctx.update(source.get_vertices().to_byte_array())
	ctx.update(source.get_indices().to_byte_array())
	return ctx.finish().hex_encode()

static func _save_cache(nav: NavigationMesh, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	if ResourceSaver.save(nav, path) != OK:
		return
	var files: Array[String] = []
	for file in DirAccess.get_files_at(CACHE_DIR):
		files.append(CACHE_DIR.path_join(file))
	files.sort_custom(func(a: String, b: String): return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	for i in range(CACHE_KEEP, files.size()):
		DirAccess.remove_absolute(files[i])
