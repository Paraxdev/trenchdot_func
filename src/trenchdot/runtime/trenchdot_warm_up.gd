class_name TrenchDotWarmUp extends SubViewport
## Compiles the render pipelines a scene needs before play, so they are not built on the first frame an area shows.
##
## Godot compiles a pipeline for each material, mesh format and render pass the first time it draws them with the
## game's environment and lights. A built map brings dozens of materials, so without a warm-up the first frames of play
## and the first look into each new area hitch. [method warm_shaders] finds every distinct way of drawing in what it is
## given: meshes, MultiMeshes, skinned meshes, particles and sprites, with their materials, overrides and shadow
## settings, plus the scenes and models that scripts under a node reference, such as a spawner's template. It draws one
## copy of each, in chunks, into a small hidden viewport that shares the game's world, environment and viewport
## settings, lit by the scene's directional lights and a shadowed omni and spot light of its own. Copies are built from
## scratch, so no scripts run and nothing plays. Nothing is drawn on screen and the game keeps running meanwhile.
##
## Call it behind the loading screen once the maps, the game's environment and the player are in:
## [codeblock]
## var warm := TrenchDotWarmUp.warm_shaders([get_tree().current_scene, preload("res://enemy.tscn")])
## warm.progress.connect(func(done, total): bar.value = 100.0 * done / total)
## await warm.finished
## [/codeblock]
## [FuncGodotMap] also warms its own map after a build, see [member FuncGodotMap.warm_up_shaders].

## Emitted after each chunk with the copies drawn so far and the total.
signal progress(done: int, total: int)
## Emitted once every chunk is drawn, right before the helper frees itself.
signal finished

## The render layer the copies and the camera use, so no game camera draws them.
const LAYER := 1 << 19
## Far below any map, outside every game camera's range.
const ORIGIN := Vector3(0.0, -20000.0, 0.0)
const MIN_FRAMES := 2
const MAX_FRAMES := 60
const _COMPILATIONS: Array[int] = [
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION,
]
const _SCENE_EXTENSIONS: PackedStringArray = ["tscn", "scn", "glb", "gltf", "bbmodel", "blend", "fbx", "obj"]

## Nodes, [PackedScene]s, [Mesh]es and [Material]s to warm up.
var sources: Array = []
## Copies drawn per chunk. Bigger chunks finish sooner, smaller ones report progress more often.
var chunk_size := 256
## Copies to draw, one per distinct mesh format, material and draw setup.
var total := 0
var done := 0
## Pipelines compiled while the warm-up ran, 0 without a GPU.
var pipelines := 0
var frames := 0
var msec := 0

var _copies: Array[Node3D] = []
var _chunk: Array[Node3D] = []
var _started := 0
var _chunk_frames := 0
var _last_total := -1
var _quiet := 0
var _rig: Node3D
var _cols := 1

## Starts a warm-up of [param what], a node, [PackedScene], [Mesh] or [Material] or an array of them, and returns it.
## Await its [signal finished]. It joins the scene tree on the next idle frame, so this is safe to call from
## [method Node._ready].
static func warm_shaders(what: Variant, chunk := 256) -> TrenchDotWarmUp:
	var w := TrenchDotWarmUp.new()
	w.name = &"TrenchDotWarmUp"
	w.sources = what if what is Array else [what]
	w.chunk_size = maxi(1, chunk)
	var host: Viewport = (Engine.get_main_loop() as SceneTree).root
	for s in w.sources:
		if s is Node and (s as Node).is_inside_tree():
			host = (s as Node).get_viewport()
			break
	host.add_child.call_deferred(w, false, Node.INTERNAL_MODE_BACK)
	return w

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started = Time.get_ticks_msec()
	_copy_viewport_settings(get_parent() as Viewport)
	_copies = collect(sources)
	total = _copies.size()
	_rig = Node3D.new()
	add_child(_rig)
	_rig.global_transform = Transform3D(Basis.IDENTITY, ORIGIN)
	_cols = maxi(1, ceili(sqrt(float(mini(chunk_size, maxi(total, 1))))))
	var camera := Camera3D.new()
	camera.cull_mask = LAYER
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = _cols * 4.0 + 20.0
	var game_camera := (get_parent() as Viewport).get_camera_3d()
	if game_camera:
		camera.environment = game_camera.environment
		camera.attributes = game_camera.attributes
		camera.compositor = game_camera.compositor
	_rig.add_child(camera)
	camera.position = Vector3(0.0, 0.0, _cols * 0.75 + 1.5)
	camera.current = true
	_add_lights()
	_next_chunk()

func _process(_delta: float) -> void:
	frames += 1
	_chunk_frames += 1
	var now := _compilations()
	_quiet = _quiet + 1 if now == _last_total else 0
	pipelines += now - _last_total
	_last_total = now
	if _chunk_frames < MIN_FRAMES or (_quiet < 2 and _chunk_frames < MAX_FRAMES):
		return
	done += _chunk.size()
	for copy in _chunk:
		copy.queue_free()
	_chunk.clear()
	progress.emit(done, total)
	if done < total:
		_next_chunk()
		return
	set_process(false)
	msec = Time.get_ticks_msec() - _started
	finished.emit()
	queue_free()

func _next_chunk() -> void:
	var count := mini(chunk_size, _copies.size() - done)
	for i in count:
		var copy := _copies[done + i]
		var cell := Vector3(float(i % _cols) - (_cols - 1) * 0.5, float(i / _cols) - (_cols - 1) * 0.5, 0.0)
		_place(copy, cell)
		_chunk.append(copy)
	_chunk_frames = 0
	_quiet = 0
	_last_total = _compilations()

static func _compilations() -> int:
	var sum := 0
	for info in _COMPILATIONS:
		sum += RenderingServer.get_rendering_info(info)
	return sum

## Anything that picks a different pipeline for the same material has to match the game's viewport.
func _copy_viewport_settings(from: Viewport) -> void:
	size = Vector2i(320, 180)
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if not from:
		return
	msaa_3d = from.msaa_3d
	screen_space_aa = from.screen_space_aa
	use_taa = from.use_taa
	use_debanding = from.use_debanding
	use_hdr_2d = from.use_hdr_2d
	scaling_3d_mode = from.scaling_3d_mode
	vrs_mode = from.vrs_mode
	positional_shadow_atlas_size = from.positional_shadow_atlas_size
	positional_shadow_atlas_16_bits = from.positional_shadow_atlas_16_bits
	for q in 4:
		set_positional_shadow_atlas_quadrant_subdiv(q, from.get_positional_shadow_atlas_quadrant_subdiv(q))

## One unplaced copy per distinct way of drawing found in [param what], see [method warm_shaders].
static func collect(what: Array) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var seen := {}
	var scenes := {}
	for s in what:
		if s is Node:
			_collect_tree(s, out, seen, scenes)
		elif s is PackedScene:
			_collect_scene(s, out, seen, scenes)
		elif s is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = s
			_add(mi, out, seen)
			mi.free()
		elif s is Material:
			var mi := MeshInstance3D.new()
			mi.mesh = QuadMesh.new()
			mi.material_override = s
			_add(mi, out, seen)
			mi.free()
	return out

static func _collect_tree(root: Node, out: Array[Node3D], seen: Dictionary, scenes: Dictionary) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is GeometryInstance3D:
			_add(node, out, seen)
		if node.get_script():
			for prop in node.get_property_list():
				if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
					var scene := _referenced_scene(node.get(prop["name"]))
					if scene:
						_collect_scene(scene, out, seen, scenes)

## A scene a script property holds or points at, so a spawner's template is warmed before it first spawns.
static func _referenced_scene(value: Variant) -> PackedScene:
	if value is PackedScene:
		return value
	if value is String and (value as String).get_extension().to_lower() in _SCENE_EXTENSIONS and ResourceLoader.exists(value):
		return load(value) as PackedScene
	return null

## Reads the scene's nodes without instancing it, so none of its scripts run.
static func _collect_scene(scene: PackedScene, out: Array[Node3D], seen: Dictionary, scenes: Dictionary) -> void:
	if scenes.has(scene):
		return
	scenes[scene] = true
	var state := scene.get_state()
	for i in state.get_node_count():
		var nested := state.get_node_instance(i)
		if nested:
			_collect_scene(nested, out, seen, scenes)
		var type := state.get_node_type(i)
		if type == "" or not ClassDB.is_parent_class(type, &"GeometryInstance3D") or not ClassDB.can_instantiate(type):
			continue
		var node := ClassDB.instantiate(type) as GeometryInstance3D
		for p in state.get_node_property_count(i):
			var prop := state.get_node_property_name(i, p)
			if prop != &"script":
				node.set(prop, state.get_node_property_value(i, p))
		if node is MeshInstance3D and not node.skeleton.is_empty() and not node.skin:
			node.set_meta(&"_td_bones", _skin_size(state, i))
		_add(node, out, seen)
		node.free()

## Bones in the skeleton a scene's skinned mesh points at, found by name among the scene's Skeleton3D nodes.
static func _skin_size(state: SceneState, mesh_index: int) -> int:
	for i in state.get_node_count():
		if state.get_node_type(i) == "Skeleton3D":
			var bones := 0
			for p in state.get_node_property_count(i):
				if String(state.get_node_property_name(i, p)).begins_with("bones/") and String(state.get_node_property_name(i, p)).ends_with("/name"):
					bones += 1
			return bones
	return 0

static func _add(node: GeometryInstance3D, out: Array[Node3D], seen: Dictionary) -> void:
	var keys := _keys(node)
	if keys.is_empty() or keys.all(func(k): return seen.has(k)):
		return
	for k in keys:
		seen[k] = true
	var copy := _copy(node)
	if copy:
		out.append(copy)

static func _id(o: Object) -> int:
	return o.get_instance_id() if o else 0

## The draw setups a node uses, as keys that match when two nodes compile the same pipelines.
static func _keys(node: GeometryInstance3D) -> Array:
	var shared := [node.get_class(), _id(node.material_override), _id(node.material_overlay),
		node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, node.transparency > 0.0 or _fades(node),
		_mirrored(node)]
	var keys := []
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		if not mesh:
			return keys
		for i in mesh.get_surface_count():
			keys.append(shared + [_format(mesh, i), _id(node.get_active_material(i)), _bones(node) > 0])
	elif node is MultiMeshInstance3D:
		var mm: MultiMesh = node.multimesh
		if not mm or not mm.mesh:
			return keys
		for i in mm.mesh.get_surface_count():
			keys.append(shared + [mm.transform_format, mm.use_colors, mm.use_custom_data, _format(mm.mesh, i),
				_id(mm.mesh.surface_get_material(i))])
	elif node is GPUParticles3D:
		var passes := []
		for i in node.draw_passes:
			passes.append(_id(node.get_draw_pass_mesh(i)))
		keys.append(shared + [_id(node.process_material), node.transform_align, passes])
	elif node is CPUParticles3D:
		keys.append(shared + [_id(node.mesh)])
	elif node is SpriteBase3D or node is Label3D:
		keys.append(shared + [node.billboard, node.get(&"transparent"), node.shaded, node.double_sided, node.no_depth_test,
			node.alpha_cut, node.texture_filter, _id(node.get(&"texture")), _id(node.get(&"font"))])
	return keys

static func _mirrored(node: Node3D) -> bool:
	return node.is_inside_tree() and node.global_basis.determinant() < 0.0

## A node that fades in or out with distance also draws in the transparent pass.
static func _fades(node: GeometryInstance3D) -> bool:
	return node.visibility_range_fade_mode != GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED \
		and (node.visibility_range_begin_margin > 0.0 or node.visibility_range_end_margin > 0.0)

## Primitive meshes do not report their surface format and primitive, but one class always builds the same.
static func _format(mesh: Mesh, surface: int) -> Variant:
	return [mesh.surface_get_format(surface), mesh.surface_get_primitive_type(surface)] if mesh is ArrayMesh else mesh.get_class()

## Bones a skinned mesh draws with, 0 for a static one. Skinned meshes are drawn from a skinned copy of their
## vertices, which compiles pipelines of its own.
static func _bones(node: MeshInstance3D) -> int:
	if node.skin:
		return node.skin.get_bind_count()
	if node.has_meta(&"_td_bones"):
		return node.get_meta(&"_td_bones")
	var skeleton := node.get_node_or_null(node.skeleton) as Skeleton3D if node.is_inside_tree() and not node.skeleton.is_empty() else null
	return skeleton.get_bone_count() if skeleton else 0

## A fresh node that draws like [param node], with none of its scripts or children. A skinned mesh comes back as the
## child of a skeleton of its own.
static func _copy(node: GeometryInstance3D) -> Node3D:
	var copy: GeometryInstance3D
	var root: Node3D
	if node is MeshInstance3D:
		var mi := MeshInstance3D.new()
		mi.mesh = node.mesh
		for i in node.get_surface_override_material_count():
			mi.set_surface_override_material(i, node.get_surface_override_material(i))
		var bones := _bones(node)
		if bones > 0:
			var skeleton := Skeleton3D.new()
			for b in bones:
				skeleton.add_bone("b%d" % b)
			mi.skin = node.skin
			skeleton.add_child(mi)
			mi.skeleton = NodePath("..")
			root = skeleton
		copy = mi
	elif node is MultiMeshInstance3D:
		var src: MultiMesh = node.multimesh
		var mm := MultiMesh.new()
		mm.transform_format = src.transform_format
		mm.use_colors = src.use_colors
		mm.use_custom_data = src.use_custom_data
		mm.mesh = src.mesh
		mm.instance_count = 1
		if mm.transform_format == MultiMesh.TRANSFORM_3D:
			mm.set_instance_transform(0, Transform3D.IDENTITY)
		else:
			mm.set_instance_transform_2d(0, Transform2D.IDENTITY)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		copy = mmi
	else:
		copy = node.duplicate(0) as GeometryInstance3D
		if not copy:
			return null
		for child in copy.get_children():
			copy.remove_child(child)
			child.free()
		if copy is GPUParticles3D or copy is CPUParticles3D:
			copy.one_shot = false
			copy.emitting = true
		if copy is GPUParticles3D:
			copy.visibility_aabb = AABB(Vector3(-1000, -1000, -1000), Vector3(2000, 2000, 2000))
	copy.material_override = node.material_override
	copy.material_overlay = node.material_overlay
	copy.cast_shadow = node.cast_shadow
	copy.transparency = 0.5 if _fades(node) and node.transparency == 0.0 else node.transparency
	copy.visible = true
	copy.layers = LAYER
	copy.visibility_range_begin = 0.0
	copy.visibility_range_end = 0.0
	copy.ignore_occlusion_culling = true
	copy.extra_cull_margin = 16384.0
	if not root:
		root = copy
	if _mirrored(node):
		root.set_meta(&"_td_mirror", true)
	return root

func _place(root: Node3D, cell: Vector3) -> void:
	var copy := (root.get_child(0) if root is Skeleton3D else root) as GeometryInstance3D
	var aabb := copy.get_aabb()
	if copy is MultiMeshInstance3D and copy.multimesh.mesh:
		aabb = copy.multimesh.mesh.get_aabb()
	var s := 0.8 / maxf(aabb.get_longest_axis_size(), 0.001)
	var basis := Basis.from_scale(Vector3(-s if root.has_meta(&"_td_mirror") else s, s, s))
	_rig.add_child(root)
	root.transform = Transform3D(basis, cell - basis * aabb.get_center())

## A shadowed omni and spot light, so the shadow passes compile too. Games often add these later, a torch or a
## muzzle flash, so they are there even when the scene has none yet. Directional shadows draw with the same pipelines
## as spot shadows, and the scene's own directional lights reach the copies wherever they are. An omni in dual
## paraboloid mode compiles a shadow pass of its own, so it gets one when the scene uses that mode.
func _add_lights() -> void:
	var omni_modes := {OmniLight3D.SHADOW_CUBE: true}
	for light in get_tree().root.find_children("*", "OmniLight3D", true, false):
		omni_modes[light.omni_shadow_mode] = true
	var reach := _cols * 1.5 + 4.0
	for mode in omni_modes:
		var o := OmniLight3D.new()
		o.omni_range = reach
		o.omni_shadow_mode = mode
		_light(o, Vector3(0.0, 0.0, 1.0))
	var s := SpotLight3D.new()
	s.spot_range = reach
	s.spot_angle = 80.0
	_light(s, Vector3(0.0, 0.0, 2.0))
	# A reflection probe renders materials into its own framebuffer format, so they compile for it too.
	if not get_tree().root.find_children("*", "ReflectionProbe", true, false).is_empty():
		var probe := ReflectionProbe.new()
		probe.size = Vector3(_cols + 2.0, _cols + 2.0, 4.0)
		probe.cull_mask = LAYER
		probe.reflection_mask = LAYER
		_rig.add_child(probe)

func _light(light: Light3D, at: Vector3) -> void:
	light.shadow_enabled = true
	light.light_cull_mask = LAYER
	light.shadow_caster_mask = LAYER
	_rig.add_child(light)
	light.position = at
