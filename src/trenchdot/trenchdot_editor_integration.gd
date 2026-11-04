@tool
class_name TrenchDotEditorIntegration extends Node
## Editor side integration with the TrenchDot level editor:
## automatic game config export and a live link that rebuilds maps when TrenchDot saves them.
##
## Live link protocol: newline delimited JSON over TCP on 127.0.0.1, every message answered by one line that echoes its
## [code]seq[/code]. Events:
## [code]status[/code] (project, Godot version, pid, the edited scene and its maps with their build epoch),
## [code]map_saved {path}[/code] and [code]build {path, text}[/code] (full builds of the edited scene, naming the
## background scene tabs that use the map too, which build a missed save when shown, and what the builds could not
## find, see [method build_summary], a saved prefab also rebuilds the maps that use it, see
## [method rebuild_prefab_users]), [code]focus[/code], [code]export_game_config[/code], [code]scan[/code] (see
## [method scan]), [code]play[/code] (see [method play]), and for live mode
## [code]live_begin {path, text, content}[/code],
## [code]live_resync {path, text}[/code], [code]live_delta {path, ops}[/code] and [code]live_end {path, revert}[/code]
## (see [TrenchDotLiveSession], the replies to the first three name the classes built without a definition and the
## map settings, see [method with_unresolved]), [code]capture {path, camera, width, height, text}[/code] (a PNG of the scene through
## a camera, see [TrenchDotCapture]) and [code]walkable {path, agent, text}[/code] (the navigation mesh of the scene,
## see [TrenchDotWalkable]).

const SETTING_CONFIG := "trenchdot/game_config"
const SETTING_AUTO_EXPORT := "trenchdot/auto_export_game_config"
const SETTING_LIVE_LINK := "trenchdot/live_link_enabled"
const SETTING_PORT := "trenchdot/live_link_port"
const DEFAULT_CONFIG := "res://addons/func_godot/game_config/trenchdot/trenchdot_game_config.tres"
const DEFAULT_PORT := 7842
## Ports below 1024 need admin rights on most systems, so the setting stays in this range.
const MIN_PORT := 1024
const MAX_PORT := 65535
## How often to try the port again while another program holds it.
const LISTEN_RETRY_MSEC := 3000
## A peer whose unfinished line grows past this is dropped. The map texts TrenchDot sends stay far below it.
const MAX_BUFFER := 64 << 20
## Build warnings a save or build reply carries at most.
const MAX_REPLY_WARNINGS := 20

var plugin: EditorPlugin
var _server: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {}
var _export_timer: Timer
## Path key to build epoch. Goes up whenever a map using the path is built outside a live session or the maps change.
var _epochs: Dictionary = {}
## Path key to the instance ids of the FuncGodotMap nodes that used it at the last status.
var _map_ids: Dictionary = {}
var _sessions: Dictionary = {}
var _port := 0
var _next_listen := 0
## Instance id of the root of a background scene tab to the saved map files (path key to path) it missed. They are
## built when the tab is shown.
var _waiting: Dictionary = {}
var _shown_root_id := 0
## The last warning about the port setting. settings_changed fires for every setting, so a bad port is only reported once.
var _port_problem := ""
## Set from a scan event until that scan is done.
var _scan_requested := false
## Counts the scan events, and the last one whose scan is done.
var _scans := 0
var _scans_done := 0

static func ensure_setting(name: String, value: Variant, type: int, hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, value)
	ProjectSettings.add_property_info({ "name": name, "type": type, "hint": hint, "hint_string": hint_string })
	ProjectSettings.set_initial_value(name, value)
	ProjectSettings.set_as_basic(name, true)

## The port from the project setting, or the default when it was cleared or set out of range.
static func live_link_port(value: Variant) -> int:
	return DEFAULT_PORT if live_link_port_problem(value) != "" else int(value)

## Why the port setting cannot be used, empty when it is fine.
static func live_link_port_problem(value: Variant) -> String:
	var port := int(value) if value is int or value is float else 0
	if port < MIN_PORT or port > MAX_PORT:
		return "[TrenchDot] live link port %s is not between %d and %d, using %d" % [value, MIN_PORT, MAX_PORT, DEFAULT_PORT]
	return ""

## Warns about a bad port setting unless the last call already did for the same problem. Returns whether it warned.
func warn_port_problem(value: Variant) -> bool:
	var problem := live_link_port_problem(value)
	var warn := problem != "" and problem != _port_problem
	if warn:
		push_warning(problem)
	_port_problem = problem
	return warn

## Comparable form of a map path: global, forward slashes, lower case.
static func path_key(path: String) -> String:
	var global := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	return global.replace("\\", "/").trim_suffix("/").to_lower()

## The file a map node builds from, with uid:// resolved.
static func resolved_map_path(map: FuncGodotMap) -> String:
	var file: String = map.global_map_file if map.global_map_file != "" else map.local_map_file
	if file.begins_with("uid://"):
		file = ResourceUID.get_id_path(ResourceUID.text_to_id(file))
	return file

func _ready() -> void:
	ensure_setting(SETTING_CONFIG, DEFAULT_CONFIG, TYPE_STRING, PROPERTY_HINT_FILE, "*.tres")
	ensure_setting(SETTING_AUTO_EXPORT, true, TYPE_BOOL)
	ensure_setting(SETTING_LIVE_LINK, true, TYPE_BOOL)
	ensure_setting(SETTING_PORT, DEFAULT_PORT, TYPE_INT, PROPERTY_HINT_RANGE, "%d,%d" % [MIN_PORT, MAX_PORT])
	ensure_setting(TrenchDotBuild.SETTING_THREADED, true, TYPE_BOOL)
	ensure_setting(TrenchDotLiveSession.SETTING_CHUNK_SIZE, TrenchDotLiveSession.DEFAULT_CHUNK_SIZE, TYPE_FLOAT, PROPERTY_HINT_RANGE, "2,256,1,suffix:m")
	ensure_setting(TrenchDotCSharp.SETTING, PackedStringArray(["res://"]), TYPE_PACKED_STRING_ARRAY, PROPERTY_HINT_TYPE_STRING, "%d/%d:" % [TYPE_STRING, PROPERTY_HINT_DIR])

	_export_timer = Timer.new()
	_export_timer.one_shot = true
	_export_timer.wait_time = 1.5
	_export_timer.timeout.connect(export_game_config)
	add_child(_export_timer)

	var fs := EditorInterface.get_resource_filesystem()
	if fs and not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed)
	if fs and not fs.script_classes_updated.is_connected(check_definitions):
		fs.script_classes_updated.connect(check_definitions)
	if plugin and not plugin.resource_saved.is_connected(_on_resource_saved):
		plugin.resource_saved.connect(_on_resource_saved)
	TrenchDotCSharp.keep_file_list = true

	apply_link_settings()
	if not ProjectSettings.settings_changed.is_connected(apply_link_settings):
		ProjectSettings.settings_changed.connect(apply_link_settings)
	_install_pack_for_maps.call_deferred()

func _exit_tree() -> void:
	TrenchDotCSharp.keep_file_list = false
	if ProjectSettings.settings_changed.is_connected(apply_link_settings):
		ProjectSettings.settings_changed.disconnect(apply_link_settings)
	stop_live_link()

## Starts, stops or moves the live link to match the project settings, so a changed port applies right away.
func apply_link_settings() -> void:
	var value: Variant = ProjectSettings.get_setting(SETTING_PORT, DEFAULT_PORT)
	warn_port_problem(value)
	var port := live_link_port(value)
	if not ProjectSettings.get_setting(SETTING_LIVE_LINK, true):
		if _port > 0:
			stop_live_link()
			print("[TrenchDot] live link stopped")
	elif port != _port:
		stop_live_link()
		start_live_link(port)

func stop_live_link() -> void:
	_port = 0
	if _server:
		_server.stop()
		_server = null
	for p in _peers:
		p.disconnect_from_host()
	_peers.clear()

func _on_filesystem_changed() -> void:
	if ProjectSettings.get_setting(SETTING_AUTO_EXPORT, true):
		_export_timer.start()
	check_definitions()

func _on_resource_saved(_resource: Resource) -> void:
	check_definitions()

## Lets every live session build its maps again when their entity definitions changed since, see
## [method TrenchDotLiveSession.check_definitions]. Runs when files or script classes change and when a resource
## is saved, which covers an FGD edited in the Inspector.
func check_definitions() -> void:
	TrenchDotCSharp.files_changed()
	TrenchDotFGDFile.files_changed()
	for session: TrenchDotLiveSession in _sessions.values():
		session.check_definitions()

func load_config() -> TrenchDotGameConfig:
	var path: String = ProjectSettings.get_setting(SETTING_CONFIG, DEFAULT_CONFIG)
	if not ResourceLoader.exists(path):
		push_warning("[TrenchDot] game config %s not found" % path)
		return null
	return load(path) as TrenchDotGameConfig

## Maps made while the gameplay entities were part of the addon keep them after an update.
func _install_pack_for_maps() -> void:
	if TrenchDotEntityPack.installed() or not TrenchDotEntityPack.available():
		return
	var config := load_config()
	if not TrenchDotEntityPack.install_for_maps(config.fgd_file if config else null).is_empty():
		EditorInterface.get_resource_filesystem().scan()

func export_game_config() -> void:
	var config := load_config()
	if config:
		config.export_file()

## Listens on [param port]. While another program holds it, usually a second Godot editor with the same project, the
## port is tried again every few seconds, so this editor takes the link over once that one closes.
func start_live_link(port: int) -> void:
	_port = port
	_listen(true)

func is_listening() -> bool:
	return _server != null and _server.is_listening()

func _listen(first: bool) -> void:
	var server := TCPServer.new()
	var err := server.listen(_port, "127.0.0.1")
	if err != OK:
		_next_listen = Time.get_ticks_msec() + LISTEN_RETRY_MSEC
		if first:
			push_warning("[TrenchDot] live link could not listen on port %d (%s). If another Godot editor has this project open, TrenchDot talks to that one: close it and this editor takes over within a few seconds. Otherwise give the project its own port in trenchdot/live_link_port and in TrenchDot's preferences." % [_port, error_string(err)])
		return
	_server = server
	print("[TrenchDot] live link listening on 127.0.0.1:%d" % _port)

## Complete lines at the start of [param buffer], split on the newline byte so multibyte characters are never cut.
## The rest stays in the buffer.
static func take_lines(buffer: PackedByteArray) -> Array:
	var lines: PackedStringArray = []
	var start := 0
	var newline := buffer.find(10)
	while newline >= 0:
		lines.append(buffer.slice(start, newline).get_string_from_utf8())
		start = newline + 1
		newline = buffer.find(10, start)
	return [lines, buffer.slice(start)]

func _process(_delta: float) -> void:
	for session: TrenchDotLiveSession in _sessions.values():
		session.process()
	if Engine.is_editor_hint():
		var root := EditorInterface.get_edited_scene_root()
		var id := root.get_instance_id() if root else 0
		if id != _shown_root_id:
			_shown_root_id = id
			build_waiting()
		if _scan_requested and not EditorInterface.get_resource_filesystem().is_scanning():
			_scan_requested = false
			_scans_done = _scans
			check_definitions()
	if not _server and _port > 0 and Time.get_ticks_msec() >= _next_listen:
		_listen(false)
	if not _server:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		_peers.append(peer)
		_buffers[peer] = PackedByteArray()
	for peer: StreamPeerTCP in _peers.duplicate():
		peer.poll()
		var status: StreamPeerTCP.Status = peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
				_peers.erase(peer)
				_buffers.erase(peer)
			continue
		var available: int = peer.get_available_bytes()
		if available <= 0:
			continue
		var received: Array = peer.get_data(available)
		if received[0] != OK:
			continue
		var buffer: PackedByteArray = _buffers[peer]
		buffer.append_array(received[1])
		# A long line is only split once its newline arrives, not searched again with every read.
		if (received[1] as PackedByteArray).find(10) < 0:
			_buffers[peer] = buffer
			if buffer.size() > MAX_BUFFER:
				_drop(peer)
			continue
		var split := take_lines(buffer)
		_buffers[peer] = split[1]
		for line in split[0]:
			# Note: every message is one JSON object, so anything else, like the HTTP request a web page sends, ends
			# the connection before a line of it is handled.
			if not line.begins_with("{"):
				_drop(peer)
				break
			_respond(peer, line)
		if _buffers.has(peer) and (_buffers[peer] as PackedByteArray).size() > MAX_BUFFER:
			_drop(peer)

func _drop(peer: StreamPeerTCP) -> void:
	peer.disconnect_from_host()
	_peers.erase(peer)
	_buffers.erase(peer)

## Captures answer after a few frames, every other event before this returns.
func _respond(peer: StreamPeerTCP, line: String) -> void:
	var reply: Dictionary = await handle_message(line)
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(reply) + "\n").to_utf8_buffer())

func handle_message(line: String) -> Dictionary:
	var json := JSON.new()
	var msg: Variant = json.data if json.parse(line) == OK else null
	if not msg is Dictionary:
		return { "ok": false, "error": "invalid json" }
	var reply: Dictionary
	if msg.get("event") == "capture":
		reply = await capture(msg)
	elif msg.get("event") == "walkable":
		reply = await walkable(msg)
	else:
		reply = _handle(msg)
	# JSON numbers parse as floats, the editor expects the seq back as an integer.
	if msg.get("seq") is float:
		reply["seq"] = int(msg["seq"])
	return reply

func _handle(msg: Dictionary) -> Dictionary:
	var path := str(msg.get("path", ""))
	match msg.get("event", ""):
		"hello":
			return { "ok": true, "project": ProjectSettings.globalize_path("res://"), "godot": Engine.get_version_info()["string"] }
		"status":
			return status()
		"map_saved":
			_sessions.erase(path_key(path))
			var reports := rebuild_maps(path)
			reports.append_array(rebuild_prefab_users(path))
			return built_reply(path, reports, true)
		"build":
			_sessions.erase(path_key(path))
			return built_reply(path, rebuild_maps(path, str(msg.get("text", ""))), false)
		"focus":
			DisplayServer.window_move_to_foreground()
			return { "ok": true }
		"export_game_config":
			export_game_config()
			return { "ok": true }
		"scan":
			return scan()
		"play":
			return play()
		"inspect":
			return inspect(path, msg.get("ids", []))
		"live_begin", "live_resync":
			var maps := maps_for(path)
			if maps.is_empty():
				return { "ok": false, "error": "no open scene uses this map" }
			var session := TrenchDotLiveSession.new(_local_path(path), maps)
			if not session.begin(str(msg.get("text", "")), msg.get("content")):
				return { "ok": false, "error": "invalid map" }
			_sessions[path_key(path)] = session
			return with_unresolved({ "ok": true, "epoch": _epochs.get(path_key(path), 0) }, session)
		"live_delta":
			var session: TrenchDotLiveSession = _sessions.get(path_key(path))
			if not session or not session.apply(msg.get("ops", [])):
				_sessions.erase(path_key(path))
				return { "ok": false, "resync": true }
			return with_unresolved({ "ok": true, "epoch": _epochs.get(path_key(path), 0) }, session)
		"live_end":
			_sessions.erase(path_key(path))
			if msg.get("revert", false):
				rebuild_maps(path)
			return { "ok": true }
	return { "ok": false, "error": "unknown event" }

## Starts a scan of the project files, for files the TrenchDot editor wrote, like an installed entity pack. Once it is
## done every live session checks its definitions, see [method check_definitions]. The reply numbers the scan, and
## [code]scanned[/code] in the status names the last one done.
func scan() -> Dictionary:
	if not Engine.is_editor_hint():
		return { "ok": false, "error": "only the Godot editor scans the project files" }
	# Note: unlike scan(), scan_sources() also reloads loaded resources whose files changed, as the window gaining focus
	# does, so an FGD edited outside Godot is read again.
	EditorInterface.get_resource_filesystem().scan_sources()
	_scan_requested = true
	_scans += 1
	return { "ok": true, "scan": _scans }

## Saves the open scenes and runs the project's main scene, as Play does in Godot, so the game starts from the scenes
## Godot shows, with live edits and builds that were not saved yet.
func play() -> Dictionary:
	var main := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main == "":
		return { "ok": false, "error": "the project has no main scene, set one in Godot's Project Settings under Application > Run" }
	if not ResourceLoader.exists(main):
		return { "ok": false, "error": "the project's main scene %s does not exist" % main }
	if not Engine.is_editor_hint():
		return { "ok": false, "error": "only the Godot editor plays the project" }
	EditorInterface.save_all_scenes()
	EditorInterface.play_main_scene()
	return { "ok": true }

func _local_path(path: String) -> String:
	var local := ProjectSettings.localize_path(path)
	return local if local.begins_with("res://") else path

## FuncGodotMap nodes of the edited scene that rebuild for TrenchDot and use [param path].
func maps_for(path: String) -> Array[FuncGodotMap]:
	var target := path_key(path)
	var out: Array[FuncGodotMap] = []
	out.assign(_scene_maps().filter(func(m: FuncGodotMap) -> bool: return path_key(resolved_map_path(m)) == target))
	return out

func _scene_maps() -> Array[FuncGodotMap]:
	return maps_under(EditorInterface.get_edited_scene_root())

## FuncGodotMap nodes under [param root] that rebuild for TrenchDot.
static func maps_under(root: Node) -> Array[FuncGodotMap]:
	var out: Array[FuncGodotMap] = []
	if not root:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is FuncGodotMap and n.auto_rebuild_on_save and resolved_map_path(n) != "":
			out.append(n)
	return out

func status() -> Dictionary:
	var ids := {}
	var files := {}
	for map in _scene_maps():
		var file := resolved_map_path(map)
		var key := path_key(file)
		if not ids.has(key):
			ids[key] = []
			files[key] = ProjectSettings.globalize_path(file)
		ids[key].append(map.get_instance_id())
		if not map.build_complete.is_connected(_on_map_built):
			map.build_complete.connect(_on_map_built.bind(map))
	for key in ids:
		ids[key].sort()
		if _map_ids.get(key, []) != ids[key]:
			_bump(key)
	_map_ids = ids
	for key in _sessions.keys():
		if not ids.has(key):
			_sessions.erase(key)
	var maps := []
	for key in files:
		maps.append({ "path": files[key], "epoch": _epochs.get(key, 0) })
	return {
		"ok": true, "project": ProjectSettings.globalize_path("res://"), "godot": Engine.get_version_info()["string"],
		"pid": OS.get_process_id(), "maps": maps, "scene": scene_name(EditorInterface.get_edited_scene_root()), "scanned": _scans_done,
	}

## The file of the scene under [param root], or its root name while it is unsaved. Empty without a scene.
static func scene_name(root: Node) -> String:
	if not root:
		return ""
	return root.scene_file_path if root.scene_file_path != "" else String(root.name)

## Reply to a save or build whose [param reports] are those of the maps it rebuilt in the scene Godot shows, see
## [method build_summary]. It names that scene and the background scene tabs that use [param path] too. With
## [param wait] those build the saved file when they are shown.
func built_reply(path: String, reports: Array, wait: bool) -> Dictionary:
	var reply := { "ok": true, "rebuilt": reports.size() }
	reply.merge(build_summary(reports))
	if not Engine.is_editor_hint():
		return reply
	var shown := EditorInterface.get_edited_scene_root()
	reply["scene"] = scene_name(shown)
	var waiting := []
	var target := path_key(path)
	for root: Node in EditorInterface.get_open_scene_roots():
		if root != shown and maps_under(root).any(func(m: FuncGodotMap) -> bool: return path_key(resolved_map_path(m)) == target):
			waiting.append(scene_name(root))
			if wait:
				var missed: Dictionary = _waiting.get_or_add(root.get_instance_id(), {})
				missed[target] = path
	if not waiting.is_empty():
		reply["waiting"] = waiting
	return reply

## What the TrenchDot editor shows after a save or build from the build [param reports]:
## [code]missing_classes[/code] (classnames without a definition in any of them), [code]settings[/code] (the map
## settings they used) and [code]warnings[/code] (the first [constant MAX_REPLY_WARNINGS] report warnings). Each key
## only when it has entries.
static func build_summary(reports: Array) -> Dictionary:
	var missing := {}
	var settings := {}
	var warnings := PackedStringArray()
	for report in reports:
		if not report is Dictionary:
			continue
		for classname in report.get("missing_classes", []):
			missing[str(classname)] = true
		if str(report.get("map_settings", "")) != "":
			settings[str(report["map_settings"])] = true
		for line in report.get("warnings", []):
			var one := str(line).replace("\n", " ")
			if warnings.size() < MAX_REPLY_WARNINGS and not one in warnings:
				warnings.append(one)
	var out := {}
	for pair in [["missing_classes", missing.keys()], ["settings", settings.keys()]]:
		if not pair[1].is_empty():
			pair[1].sort()
			out[pair[0]] = pair[1]
	if not warnings.is_empty():
		out["warnings"] = Array(warnings)
	return out

## Rebuilds the maps of the edited scene whose map file instances [param path], directly or through other prefabs,
## since the scene still shows the prefab as it was before the save. Those of background scene tabs build when the tab
## is shown, and live sessions build in full once edits pause, see [method queue_prefab_users]. Returns the build
## report of each map built now.
func rebuild_prefab_users(path: String) -> Array[Dictionary]:
	queue_prefab_users(path)
	var target := path_key(path)
	var users := {}
	var reports: Array[Dictionary] = []
	var shown := EditorInterface.get_edited_scene_root()
	for root: Node in EditorInterface.get_open_scene_roots():
		for map in maps_under(root):
			var file := resolved_map_path(map)
			var key := path_key(file)
			if key == target or _sessions.has(key):
				continue
			if not users.has(key):
				var model: Variant = TrenchDotTdmFile.read(file)["map"]
				users[key] = model is Dictionary and Array(TrenchDotParser.prefabs(model, file)).any(func(p: String) -> bool: return path_key(p) == target)
			if not users[key]:
				continue
			if root == shown:
				reports.append(map.build())
			else:
				var missed: Dictionary = _waiting.get_or_add(root.get_instance_id(), {})
				missed[key] = file
	if not reports.is_empty():
		EditorInterface.mark_scene_as_unsaved()
		print("[TrenchDot] rebuilt %d map(s) that instance %s" % [reports.size(), path])
	return reports

## Lets every live session whose map instances [param path], directly or through other prefabs, build in full, since
## its scene still shows the prefab as it was before the save.
func queue_prefab_users(path: String) -> void:
	var target := path_key(path)
	for session: TrenchDotLiveSession in _sessions.values():
		if Array(session.prefabs()).any(func(p: String) -> bool: return path_key(p) == target):
			session.queue_full_build()

## [param reply] to a live event, with [code]unresolved[/code] naming the classes the step [param session] just took
## built without a definition when there are any, see [method TrenchDotLiveSession.take_unresolved], and
## [code]settings[/code] the map settings it builds with.
static func with_unresolved(reply: Dictionary, session: TrenchDotLiveSession) -> Dictionary:
	var unresolved := session.take_unresolved()
	if not unresolved.is_empty():
		reply["unresolved"] = unresolved
	reply["settings"] = session.settings()
	return reply

## Rebuilds the maps that were saved while the scene tab Godot now shows was in the background.
func build_waiting() -> void:
	for id in _waiting.keys():
		if not is_instance_id_valid(id):
			_waiting.erase(id)
	var root := EditorInterface.get_edited_scene_root()
	var missed: Dictionary = _waiting.get(root.get_instance_id(), {}) if root else {}
	_waiting.erase(root.get_instance_id() if root else 0)
	for path: String in missed.values():
		rebuild_maps(path)

## Generated nodes of the map node ids [param ids] in the first map using [param path], for checking live updates.
func inspect(path: String, ids: Array) -> Dictionary:
	var maps := maps_for(path)
	if maps.is_empty():
		return { "ok": false, "error": "no open scene uses this map" }
	var by_id := TrenchDotBuild.nodes_by_id(maps[0])
	var nodes := {}
	for raw in ids:
		var node := by_id.get(int(raw)) as Node
		if node:
			var info := { "name": String(node.name), "class": node.get_class(), "children": node.get_child_count(), "instance": node.get_instance_id() }
			if node is Node3D:
				var p: Vector3 = node.position
				info["position"] = [p.x, p.y, p.z]
			nodes[str(int(raw))] = info
	var session: TrenchDotLiveSession = _sessions.get(path_key(path))
	return { "ok": true, "nodes": nodes, "live": session != null, "pending": session != null and session.pending() }

## Renders the edited scene from [code]camera {position, forward, fov}[/code] in map units, after building it from
## [code]text[/code] when given and letting a live session catch up. Errors and warnings logged meanwhile come back too.
func capture(msg: Dictionary) -> Dictionary:
	var path := str(msg.get("path", ""))
	var maps := maps_for(path)
	if maps.is_empty():
		return { "ok": false, "error": "no scene open in the Godot editor uses %s, open one with a FuncGodotMap that builds it and has Auto Rebuild On Save on" % path.get_file() }
	var camera: Dictionary = msg.get("camera", {})
	var position = camera.get("position")
	var forward = camera.get("forward")
	if not (position is Array and position.size() == 3 and forward is Array and forward.size() == 3):
		return { "ok": false, "error": "camera needs position and forward" }
	var size := Vector2i(clampi(int(msg.get("width", 1280)), 16, 4096), clampi(int(msg.get("height", 720)), 16, 4096))

	var collector := TrenchDotCapture.Collector.new()
	OS.add_logger(collector)
	if msg.has("text"):
		_sessions.erase(path_key(path))
		rebuild_maps(path, str(msg["text"]))
	var session: TrenchDotLiveSession = _sessions.get(path_key(path))
	var start := Time.get_ticks_msec()
	while session and session.pending() and Time.get_ticks_msec() - start < 30000:
		await get_tree().process_frame
	OS.remove_logger(collector)
	maps = maps_for(path)
	var reply := { "ok": false, "error": "the map left the scene while it was being captured" }
	if not maps.is_empty():
		var xform := TrenchDotCapture.camera_transform(maps[0], Vector3(position[0], position[1], position[2]), Vector3(forward[0], forward[1], forward[2]))
		reply = await TrenchDotCapture.render(self, maps[0].get_world_3d(), xform, float(camera.get("fov", 90.0)), size)
	reply["warnings"] = collector.lines
	return reply

## Bakes the navigation mesh of the edited scene for [code]agent[/code], after building the map from [code]text[/code]
## when it differs from the last build and letting a live session catch up. The whole scene is baked, so other maps and
## Godot content next to the map count, and the polygons come back in the map's units.
func walkable(msg: Dictionary) -> Dictionary:
	var path := str(msg.get("path", ""))
	var maps := maps_for(path)
	if maps.is_empty():
		return { "ok": false, "error": "no scene open in the Godot editor uses %s, open one with a FuncGodotMap that builds it and has Auto Rebuild On Save on" % path.get_file() }
	if msg.has("text"):
		var text_hash := str(str(msg["text"]).hash())
		if maps.any(func(m: FuncGodotMap) -> bool: return str(m.get_meta(TrenchDotBuild.SOURCE_HASH_META, "")) != text_hash):
			_sessions.erase(path_key(path))
			rebuild_maps(path, str(msg["text"]))
	var session: TrenchDotLiveSession = _sessions.get(path_key(path))
	var start := Time.get_ticks_msec()
	while session and session.pending() and Time.get_ticks_msec() - start < 30000:
		await get_tree().process_frame
	maps = maps_for(path)
	if maps.is_empty():
		return { "ok": false, "error": "the map left the scene while it was being baked" }
	var root := EditorInterface.get_edited_scene_root() as Node3D
	var agent = msg.get("agent", {})
	return TrenchDotWalkable.report(root if root else maps[0], maps[0], agent if agent is Dictionary else {})

func _bump(key: String) -> void:
	_epochs[key] = int(_epochs.get(key, 0)) + 1
	_sessions.erase(key)

func _on_map_built(map: FuncGodotMap) -> void:
	if TrenchDotLiveSession.building == 0 and is_instance_valid(map):
		_bump(path_key(resolved_map_path(map)))

## Fully rebuilds every FuncGodotMap in the edited scene that uses [param path], from [param text] when given (unsaved
## edits) or from the file. Returns the build report of each. Only nodes inside the FuncGodotMap nodes are replaced.
func rebuild_maps(path: String, text: String = "") -> Array[Dictionary]:
	var fs := EditorInterface.get_resource_filesystem()
	var local := ProjectSettings.localize_path(path)
	if local.begins_with("res://") and fs and text == "":
		fs.update_file(local)
	var maps := maps_for(path)
	var reports: Array[Dictionary] = []
	for map in maps:
		reports.append(map.build_from_text(text) if text != "" else map.build())
	if not maps.is_empty():
		EditorInterface.mark_scene_as_unsaved()
		print("[TrenchDot] rebuilt %d map(s) from %s" % [maps.size(), "unsaved edits of " + path if text != "" else path])
	return reports
