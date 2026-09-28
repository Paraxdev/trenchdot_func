@tool
class_name TDVoxelGI extends VoxelGI
## env_voxel_gi: the brush is the box of a VoxelGI, see [TrenchDotProbes]. Baked in the Godot editor after each
## map build unless bake_on_build is off, then through the VoxelGI's own Bake button.

@export var energy := 1.0
@export var bake_on_build := true

func _func_godot_apply_properties(props: Dictionary) -> void:
	match str(props.get("subdiv", "128")).strip_edges():
		"64":
			subdiv = SUBDIV_64
		"256":
			subdiv = SUBDIV_256
		"512":
			subdiv = SUBDIV_512
		_:
			subdiv = SUBDIV_128
	energy = maxf(float(props.get("energy", 1.0)), 0.0)
	bake_on_build = TrenchDotIO.to_bool(props.get("bake_on_build", true))

func bake_now() -> void:
	if not bake_on_build:
		return
	bake()
	if data:
		data.energy = energy
