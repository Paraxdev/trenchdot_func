@tool
class_name TrenchDotWalkable extends RefCounted
## The walkable area of a built map for the live link's walkable event: a navigation mesh baked by [TrenchDotNav],
## in the map's units and axes, with its unconnected parts.

## Bakes the collision under [param root] for an agent of [code]agent {radius, height, max_climb, max_slope}[/code]
## in meters and degrees, and returns the polygons in the local space of [param map] in map units. Vertices are a flat
## x, y, z list, islands lists of polygon indices, largest first.
static func report(root: Node3D, map: FuncGodotMap, agent: Dictionary) -> Dictionary:
	var profile := TrenchDotNav.profile(float(agent.get("radius", 0.3)), float(agent.get("height", 1.8)), float(agent.get("max_climb", 0.3)), float(agent.get("max_slope", 45.0)))
	var start := Time.get_ticks_msec()
	var nav := TrenchDotNav.bake(root, profile)
	if not nav:
		return { "ok": false, "error": "the scene could not be baked, it has to be open in the Godot editor" }
	var settings := map.get_map_settings()
	var units := settings.inverse_scale_factor if settings else 32.0
	var to_map := map.global_transform.affine_inverse() * root.global_transform
	var vertices := []
	for v in nav.vertices:
		var p := to_map * v * units
		vertices.append_array([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)])
	var polygons := []
	for i in nav.get_polygon_count():
		polygons.append(Array(nav.get_polygon(i)))
	var islands := []
	for island in TrenchDotNav.islands(nav):
		islands.append(Array(island))
	return {
		"ok": true, "units_per_meter": units, "vertices": vertices, "polygons": polygons, "islands": islands,
		"agent": {
			"radius": snappedf(nav.agent_radius, 0.001), "height": snappedf(nav.agent_height, 0.001),
			"max_climb": snappedf(nav.agent_max_climb, 0.001), "max_slope": nav.agent_max_slope,
		},
		"msec": Time.get_ticks_msec() - start,
	}
