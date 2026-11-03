class_name TrenchDotHotReload extends Node
## Autoload for running games: rebuilds FuncGodotMap nodes when the TrenchDot editor saves their map.
## Add it as an autoload (Project Settings > Globals) or instance it in a debug scene.
## Same protocol as the editor live link, on port 7843 by default.

## A peer whose unfinished line grows past this many characters is dropped, a map_saved line is far shorter.
const MAX_BUFFER := 64 << 10

@export var port := 7843
@export var enabled_in_exported_builds := false

var _server: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _buffers := {}

signal map_reloaded(map: FuncGodotMap)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not OS.has_feature("editor") and not enabled_in_exported_builds:
		return
	_server = TCPServer.new()
	if _server.listen(port, "127.0.0.1") != OK:
		push_warning("[TrenchDot] hot reload could not listen on port %d" % port)
		_server = null

func _exit_tree() -> void:
	if _server:
		_server.stop()

func _process(_delta: float) -> void:
	if not _server:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		_peers.append(peer)
		_buffers[peer] = ""
	# Saved path to the peers waiting for its reply, so however many saves arrive in a frame each map builds once.
	var saved := {}
	for peer: StreamPeerTCP in _peers.duplicate():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			if peer.get_status() in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]:
				_peers.erase(peer)
				_buffers.erase(peer)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		_buffers[peer] += peer.get_utf8_string(available)
		var buffer: String = _buffers[peer]
		var foreign := false
		while buffer.contains("\n"):
			var line := buffer.get_slice("\n", 0)
			buffer = buffer.substr(line.length() + 1)
			# Note: anything but a JSON object per line, like the HTTP request a web page sends, ends the connection.
			if not line.begins_with("{"):
				foreign = true
				break
			var json := JSON.new()
			var msg: Variant = json.data if json.parse(line) == OK else null
			if msg is Dictionary and msg.get("event", "") == "map_saved":
				var path := str(msg.get("path", "")).replace("\\", "/").to_lower()
				if not saved.has(path):
					saved[path] = []
				saved[path].append(peer)
			else:
				peer.put_data((JSON.stringify({ "ok": false }) + "\n").to_utf8_buffer())
		if foreign or buffer.length() > MAX_BUFFER:
			_drop(peer)
			continue
		_buffers[peer] = buffer
	for path: String in saved:
		var reply := (JSON.stringify({ "ok": true, "rebuilt": reload(path) }) + "\n").to_utf8_buffer()
		for peer: StreamPeerTCP in saved[path]:
			if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				peer.put_data(reply)

func _drop(peer: StreamPeerTCP) -> void:
	peer.disconnect_from_host()
	_peers.erase(peer)
	_buffers.erase(peer)

## The absolute, lowercased file [param map] builds from, with uid:// resolved, for comparing against saved paths.
static func map_path_key(map: FuncGodotMap) -> String:
	var file: String = map.global_map_file if map.global_map_file != "" else map.local_map_file
	if file.begins_with("uid://"):
		var id := ResourceUID.text_to_id(file)
		file = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	if file == "":
		return ""
	return ProjectSettings.globalize_path(file).replace("\\", "/").to_lower()

## Rebuilds every map in the running scene tree that uses [param path]. Returns how many were rebuilt.
func reload(path: String) -> int:
	var target := path.replace("\\", "/").to_lower()
	var count := 0
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is FuncGodotMap:
			var key := map_path_key(n)
			if key != "" and key == target:
				n.build()
				count += 1
				map_reloaded.emit(n)
	return count
