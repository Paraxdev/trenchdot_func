@tool
class_name TrenchDotProp extends Node3D
## Prop entity that instantiates a model given by its "model" property (.bbmodel, .glb, .gltf or .tscn).
## "collision" picks the shape, see [TrenchDotCollision]. "model_node" keeps only the node of that name from the model, placed
## at the prop's origin, for files that hold several variants side by side.

@export var model: String = ""
@export var model_node: String = ""
@export_enum("default", "none", "box", "convex", "decomposition", "trimesh") var collision: String = "default"
@export var collision_layer := ""
@export var collision_mask := ""

## Set while a [FuncGodotMap] builds, whose report warns once per missing model instead.
static var quiet_missing := false

func _ready() -> void:
	# Scenes built before the build owned the model and collision were saved without them.
	if get_children().any(func(c: Node) -> bool: return c.has_meta(&"td_prop_generated")):
		return
	var path := TrenchDotBuild.map_resource_path(model, TrenchDotBuild.MODEL_FILES)
	if path != "" and ResourceLoader.exists(path):
		rebuild()

func _func_godot_apply_properties(properties: Dictionary) -> void:
	model = str(properties.get("model", model))
	model_node = str(properties.get("model_node", model_node)).strip_edges()
	collision = str(properties.get("collision", collision))
	collision_layer = str(properties.get("collision_layer", collision_layer))
	collision_mask = str(properties.get("collision_mask", collision_mask))
	rebuild()

func rebuild() -> void:
	for child in get_children():
		if child.has_meta(&"td_prop_generated"):
			remove_child(child)
			child.free()
	var path := TrenchDotBuild.map_resource_path(model, TrenchDotBuild.MODEL_FILES)
	if path == "" or not ResourceLoader.exists(path):
		if path != "" and not quiet_missing:
			push_warning("[TrenchDot] prop model %s not found" % model)
		return
	var scene := load(path) as PackedScene
	if not scene:
		return
	var flag := PackedScene.GEN_EDIT_STATE_INSTANCE if Engine.is_editor_hint() else PackedScene.GEN_EDIT_STATE_DISABLED
	var instance: Node = scene.instantiate(flag)
	if model_node != "":
		var picked := _pick_node(instance)
		if not picked:
			push_warning("[TrenchDot] prop model %s has no node %s" % [model, model_node])
			instance.free()
			return
		instance = picked
	instance.set_meta(&"td_prop_generated", true)
	add_child(instance)
	if owner:
		instance.owner = owner
		if model_node != "":
			_own_subtree(instance)
	var shape_mode := TrenchDotCollision.mode(collision)
	if shape_mode == "none" or _has_collision(instance):
		return
	var body := StaticBody3D.new()
	body.name = "prop_collision"
	body.set_meta(&"td_prop_generated", true)
	TrenchDotCollision.apply_layers(body, { "collision_layer": collision_layer, "collision_mask": collision_mask })
	add_child(body)
	if owner:
		body.owner = owner
	TrenchDotCollision.add_shapes(body, TrenchDotCollision.shapes(instance, self, shape_mode), owner)

## Takes the node named model_node out of the instanced model with its transform relative to the model root, minus the
## offset, and frees the rest.
func _pick_node(instance: Node) -> Node:
	var picked: Node = instance if instance.name == model_node else instance.find_child(model_node, true, false)
	if not picked:
		return null
	if picked == instance:
		if picked is Node3D:
			(picked as Node3D).position = Vector3.ZERO
		return picked
	var t := Transform3D.IDENTITY
	var n: Node = picked
	while n and n != instance:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	picked.get_parent().remove_child(picked)
	instance.free()
	if picked is Node3D:
		t.origin = Vector3.ZERO
		(picked as Node3D).transform = t
	return picked

## Nodes of a picked subtree lost their scene owner, so a saved build would drop them.
func _own_subtree(node: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own_subtree(c)

func _has_collision(node: Node) -> bool:
	if node is CollisionObject3D:
		return true
	for c in node.get_children():
		if _has_collision(c):
			return true
	return false
