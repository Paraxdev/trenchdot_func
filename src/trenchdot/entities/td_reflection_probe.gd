@tool
class_name TDReflectionProbe extends ReflectionProbe
## env_reflection_probe: the brush is the box of a ReflectionProbe, see [TrenchDotProbes].

func _func_godot_apply_properties(props: Dictionary) -> void:
	intensity = float(props.get("intensity", intensity))
	update_mode = UPDATE_ALWAYS if str(props.get("update", "once")).strip_edges() == "always" else UPDATE_ONCE
	box_projection = TrenchDotIO.to_bool(props.get("box_projection", true))
	interior = TrenchDotIO.to_bool(props.get("interior", false))
	max_distance = maxf(float(props.get("max_distance", 0.0)), 0.0)
