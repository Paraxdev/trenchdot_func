class_name TrenchDotBuildReport extends RefCounted
## What one [FuncGodotMap] build made and what it could not find: the time of each step, entities per class, the
## vertex count, missing entity definitions, models and materials, tool textures the map settings do not know,
## targets that match no node in the map, logic_script entities that carry GDScript, and resource paths it refused to
## load because they point outside the project or at the wrong kind of file. [method FuncGodotMap.build]
## returns it as [method to_dictionary] and keeps it in [member FuncGodotMap.build_report]. The
## [code]Print Build Report[/code] build flag prints it.

## Tool texture names the TrenchDot editor uses unless the game config names them otherwise.
const EDITOR_TOOL_TEXTURES := { "clip": "special/clip", "skip": "special/skip", "origin": "special/origin", "sky": "special/sky" }
# Note: copies of TrenchDotEditorIntegration's settings, and the game config below is read untyped. Referring to
# either class here closes a parse cycle through FuncGodotMap, and the editor integration is not for runtime use.
const _CONFIG_SETTING := "trenchdot/game_config"
const _DEFAULT_CONFIG := "res://addons/func_godot/game_config/trenchdot/trenchdot_game_config.tres"

var map_file := ""
## Why the build stopped early, empty when it finished.
var error := ""
## [code]{step, ms}[/code] in build order.
var steps: Array[Dictionary] = []
## Classname to entity count.
var entities: Dictionary = {}
var vertices := 0
var missing_classes: PackedStringArray = []
## Model path to the names of the entities using it.
var missing_models: Dictionary = {}
## Face textures with neither a material file nor an image, which build with the checker texture.
var missing_materials: PackedStringArray = []
## Tool texture used on faces to the map settings property that names it differently, e.g. special/clip to clip_texture.
var unknown_tool_textures: Dictionary = {}
## [code]{entity, target}[/code] for outputs and target properties no node of the map answers to.
var unresolved_targets: Array[Dictionary] = []
## Names of the logic_script entities whose source or expression holds code, which runs when the scene plays.
var map_scripts: PackedStringArray = []
## Paths the map names that [method TrenchDotBuild.map_resource_path] refused.
var refused_paths: PackedStringArray = []

var _start := 0
var _step := ""
var _step_start := 0

func _init(file: String) -> void:
	map_file = file
	_start = Time.get_ticks_usec()

## Ends the running step and starts [param name]. Connected to the declare_step signals of the build stages.
func step(name: String) -> void:
	var now := Time.get_ticks_usec()
	if _step != "":
		steps.append({ "step": _step, "ms": (now - _step_start) / 1000.0 })
	_step = name
	_step_start = now

func finish() -> void:
	step("")

## Starts collecting the paths [method TrenchDotBuild.map_resource_path] refuses, until [method take_refused_paths].
func collect_refused_paths() -> void:
	TrenchDotBuild.refused_paths.clear()
	TrenchDotBuild.collecting_refused = true

## Keeps the refused paths and warns once for each.
func take_refused_paths() -> void:
	TrenchDotBuild.collecting_refused = false
	refused_paths = PackedStringArray(TrenchDotBuild.refused_paths.keys())
	TrenchDotBuild.refused_paths.clear()
	for path in refused_paths:
		push_warning("[TrenchDot] the map names %s, which is not loaded: maps may only name models, images, sounds, materials and prefabs inside the project" % path)

func time_ms() -> float:
	return (Time.get_ticks_usec() - _start) / 1000.0 if steps.is_empty() else steps.reduce(func(sum, s): return sum + s["ms"], 0.0)

## Counts entities per class and finds entities without a definition, model paths no resource answers to and
## logic_script entities with code.
func check_entities(data: Array[FuncGodotData.EntityData]) -> void:
	for entity in data:
		var classname := str(entity.properties.get("classname", ""))
		entities[classname] = entities.get(classname, 0) + 1
		if classname == "logic_script" and (str(entity.properties.get("source", "")).strip_edges() != "" or str(entity.properties.get("expression", "")).strip_edges() != ""):
			map_scripts.append(_entity_name(entity))
		if classname != "" and entity.definition and entity.definition.classname == "" and not classname in missing_classes:
			missing_classes.append(classname)
		var model := str(entity.properties.get("model", "")).strip_edges()
		# Quake brush entities keep their brush model as "*1".
		if model == "" or model.begins_with("*") or model.get_extension() == "":
			continue
		var path := TrenchDotBuild.map_resource_path(model, TrenchDotBuild.MODEL_FILES)
		if path == "" or ResourceLoader.exists(path):
			continue
		if not missing_models.has(model):
			missing_models[model] = []
		missing_models[model].append(_entity_name(entity))

## Finds materials the build made from the placeholder texture, and faces textured with an editor tool texture the map
## settings name differently. Those faces still build no mesh, but an origin brush no longer sets its entity origin.
func check_textures(data: Array[FuncGodotData.EntityData], materials: Dictionary, settings: FuncGodotMapSettings) -> void:
	var placeholder := load(FuncGodotUtil.default_texture_path)
	for name: String in materials:
		if TrenchDotDecalMesh.is_decal(name):
			continue
		var material: Material = materials[name]
		var albedo: Variant = null
		if material is BaseMaterial3D:
			albedo = (material as BaseMaterial3D).albedo_texture
		elif material is ShaderMaterial:
			albedo = (material as ShaderMaterial).get_shader_parameter(settings.default_material_albedo_uniform)
		if albedo != null and albedo == placeholder and material.resource_path == "":
			missing_materials.append(name)
	var tools := _tool_textures(settings)
	for entity in data:
		for brush in entity.brushes:
			for face in brush.faces:
				var texture := face.texture.to_lower()
				if tools.has(texture) and not unknown_tool_textures.has(texture) and str(settings.get(tools[texture] + "_texture")) != texture:
					unknown_tool_textures[texture] = tools[texture] + "_texture"

## Finds outputs and target properties whose target matches no targetname in [param map_node] or its overlays.
## Overlays instanced after the build are not there yet, so their targets count as unresolved here.
func check_targets(data: Array[FuncGodotData.EntityData], map_node: Node) -> void:
	var names := {}
	var stack: Array[Node] = [map_node]
	stack.append_array(TrenchDotOverlay.external_overlays(map_node))
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta(TrenchDotIO.TARGETNAME_META):
			names[str(n.get_meta(TrenchDotIO.TARGETNAME_META))] = true
		stack.append_array(n.get_children())
	for entity in data:
		var targets: Array = entity.outputs.map(func(o): return str(o.get("target", "")))
		targets.append(str(entity.properties.get("target", "")))
		var seen := {}
		for target: String in targets:
			if seen.has(target) or _resolves(target, names):
				continue
			seen[target] = true
			unresolved_targets.append({ "entity": _entity_name(entity), "target": target })

func count_vertices(map_node: Node) -> void:
	var stack: Array[Node] = [map_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != map_node and TrenchDotOverlay.is_kept(n):
			continue
		var mesh: ArrayMesh = (n as MeshInstance3D).mesh as ArrayMesh if n is MeshInstance3D else null
		if mesh:
			for s in mesh.get_surface_count():
				vertices += mesh.surface_get_array_len(s)
		stack.append_array(n.get_children())

## One warning per missing model, material and tool texture, however many entities or faces share it, and one per
## logic_script with code.
func warn() -> void:
	for script in map_scripts:
		push_warning("[TrenchDot] logic_script %s runs GDScript stored in the map when the scene plays" % script)
	for model in missing_models:
		var users: Array = missing_models[model]
		var more: String = " and %d more" % (users.size() - 1) if users.size() > 1 else ""
		push_warning("[TrenchDot] model %s not found, used by %s%s" % [model, users[0], more])
	for name in missing_materials:
		push_warning("[TrenchDot] no material or texture for %s, its faces show the placeholder texture" % name)
	for texture in unknown_tool_textures:
		push_warning("[TrenchDot] faces use the tool texture %s, but the map settings' %s is not %s, so they build as visible faces" % [texture, unknown_tool_textures[texture], texture])

func to_dictionary() -> Dictionary:
	return {
		"map": map_file,
		"error": error,
		"time_ms": time_ms(),
		"steps": steps,
		"entities": entities,
		"vertices": vertices,
		"missing_classes": missing_classes,
		"missing_models": missing_models,
		"missing_materials": missing_materials,
		"unknown_tool_textures": unknown_tool_textures,
		"unresolved_targets": unresolved_targets,
		"map_scripts": map_scripts,
		"refused_paths": refused_paths,
	}

func print_report() -> void:
	print("[MAP] Build report for %s" % map_file)
	if error != "":
		print("  failed: ", error)
	var count: int = entities.values().reduce(func(sum, n): return sum + n, 0)
	print("  %.1f ms, %d entities, %d vertices" % [time_ms(), count, vertices])
	var slow := steps.duplicate()
	slow.sort_custom(func(a, b): return a["ms"] > b["ms"])
	print("  slowest steps: ", ", ".join(PackedStringArray(slow.slice(0, 5).map(func(s): return "%s %.1f ms" % [s["step"], s["ms"]]))))
	var classes := entities.keys()
	classes.sort_custom(func(a, b): return entities[a] > entities[b])
	print("  entities: ", ", ".join(PackedStringArray(classes.map(func(c): return "%s %d" % [c, entities[c]]))))
	if not missing_classes.is_empty():
		print("  classes without a definition: ", ", ".join(missing_classes))
	for model in missing_models:
		print("  missing model %s: %s" % [model, ", ".join(PackedStringArray(missing_models[model]))])
	if not missing_materials.is_empty():
		print("  missing materials: ", ", ".join(missing_materials))
	for texture in unknown_tool_textures:
		print("  tool texture %s is not the map settings' %s" % [texture, unknown_tool_textures[texture]])
	for t in unresolved_targets:
		print("  %s targets '%s', which matches nothing in this map" % [t["entity"], t["target"]])
	if not map_scripts.is_empty():
		print("  logic_script entities with GDScript: ", ", ".join(map_scripts))
	if not refused_paths.is_empty():
		print("  not loaded, outside the project or the wrong kind of file: ", ", ".join(refused_paths))

static func _resolves(target: String, names: Dictionary) -> bool:
	if target == "" or target.begins_with("!") or target.begins_with("@") or target.begins_with("/") or target.begins_with("%"):
		return true
	if target.ends_with("*"):
		var prefix := target.trim_suffix("*")
		return names.keys().any(func(n): return str(n).begins_with(prefix))
	return names.has(target)

static func _entity_name(entity: FuncGodotData.EntityData) -> String:
	if entity.node:
		return str(entity.node.name)
	var targetname := str(entity.properties.get("targetname", ""))
	return targetname if targetname != "" else str(entity.properties.get("classname", "entity"))

## The editor's tool texture names, from the registered game config when there is one, to the role each plays.
static func _tool_textures(settings: FuncGodotMapSettings) -> Dictionary:
	var out := {}
	for role in EDITOR_TOOL_TEXTURES:
		out[EDITOR_TOOL_TEXTURES[role]] = role
	var path := str(ProjectSettings.get_setting(_CONFIG_SETTING, _DEFAULT_CONFIG))
	var config: Resource = load(path) if path != "" and ResourceLoader.exists(path) else null
	var ms: FuncGodotMapSettings = null
	if config:
		ms = config.get(&"map_settings") as FuncGodotMapSettings
	if ms and ms != settings:
		for pair in [["clip", ms.clip_texture], ["skip", ms.skip_texture], ["origin", ms.origin_texture], ["sky", ms.sky_texture]]:
			if pair[1] != "":
				out[pair[1]] = pair[0]
	return out
