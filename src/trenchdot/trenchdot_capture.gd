@tool
class_name TrenchDotCapture extends RefCounted
## Renders the world a built map lives in from a camera given in map units, for the live link's capture event.

const FRAMES := 12
const TIMEOUT_MSEC := 20000

## Global transform of a camera at [param position] looking along [param forward], both in the map's units and axes.
static func camera_transform(map: FuncGodotMap, position: Vector3, forward: Vector3) -> Transform3D:
	var scale := map.map_settings.scale_factor if map.map_settings else 1.0 / 32.0
	var xform := map.global_transform
	var dir := (xform.basis * forward).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	return Transform3D(Basis.looking_at(dir, up), xform * (position * scale))

## Renders [param world] through a camera with the horizontal [param fov] in degrees into an image of [param size],
## with the project's anti-aliasing and shadow settings, as the game would draw it. Returns the PNG as base64.
static func render(parent: Node, world: World3D, xform: Transform3D, fov: float, size: Vector2i) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return { "ok": false, "error": "Godot runs headless and renders nothing, open the project in a Godot editor with a window" }
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.world_3d = world
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
	viewport.screen_space_aa = ProjectSettings.get_setting("rendering/anti_aliasing/quality/screen_space_aa", 0)
	viewport.use_taa = ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa", false)
	viewport.use_debanding = ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_debanding", false)
	viewport.positional_shadow_atlas_size = ProjectSettings.get_setting("rendering/lights_and_shadows/positional_shadow/atlas_size", 4096)
	var camera := Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = clampf(fov, 1.0, 179.0)
	viewport.add_child(camera)
	parent.add_child(viewport)
	camera.global_transform = xform
	camera.current = true

	# Temporal effects such as volumetric fog and TAA need a few frames to settle.
	var drawn := [0]
	var count := func() -> void: drawn[0] += 1
	RenderingServer.frame_post_draw.connect(count)
	var start := Time.get_ticks_msec()
	while drawn[0] < FRAMES and Time.get_ticks_msec() - start < TIMEOUT_MSEC:
		await parent.get_tree().process_frame
		# An idle editor in low processor mode draws nothing until something changes on screen.
		RenderingServer.force_draw(false)
	RenderingServer.frame_post_draw.disconnect(count)
	var image := viewport.get_texture().get_image() if drawn[0] >= FRAMES else null
	viewport.queue_free()
	if drawn[0] < FRAMES:
		return { "ok": false, "error": "Godot drew no frames for %d s" %(TIMEOUT_MSEC / 1000) }
	if not image or image.is_empty():
		return { "ok": false, "error": "Godot rendered no image" }
	return { "ok": true, "width": image.get_width(), "height": image.get_height(), "png": Marshalls.raw_to_base64(image.save_png_to_buffer()) }

## Collects the errors and warnings Godot logs while it is added with [method OS.add_logger], from any thread.
class Collector extends Logger:
	const LIMIT := 50
	var lines: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := "%s: %s" % ["warning" if error_type == ERROR_TYPE_WARNING else "error", rationale if rationale != "" else code]
		# push_warning and push_error report their own C++ location, which says nothing about the map.
		_add(text + (" (%s:%d)" % [file, line] if file.begins_with("res://") else ""))

	func _log_message(message: String, error: bool) -> void:
		if error:
			_add("error: " + message.strip_edges())

	func _add(text: String) -> void:
		_mutex.lock()
		if lines.size() < LIMIT and not lines.has(text):
			lines.append(text)
		_mutex.unlock()
