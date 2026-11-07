class_name TrenchDotVoidCull extends RefCounted
## Leaves out faces that face the void of a sealed map, the way qbsp does, like the TrenchDot editor does. A lattice
## is flooded from every point entity through the empty space between the static solids. When the flood stays inside
## the map, a face that no flooded point can see the front of is never visible to a player and is hidden. When the
## flood reaches the border of the lattice the map leaks, nothing is hidden and a warning names the entity.
##
## Everything is in map units. Sky brushes seal the map like walls do, even though they draw nothing. Collision keeps
## every face.

## Distance between lattice points. It doubles until the lattice fits [constant MAX_POINTS], so gaps narrower than it
## may be missed.
const SPACING := 8.0
## Mirrors BOX_POINTS in the editor's void_cull.rs.
const MAX_POINTS := 1 << 24
## Lattice points popped, neighbours tested and solids looked at that the flood of one build may spend. Past it the
## map counts as unfinished and every face is kept. Only a map made to stall a build gets there.
## The editor's void_cull.rs counts reached points against its own WORK instead.
const FLOOD_WORK := 1 << 24
## Samples and solids that the face tests of one build may spend. Past it the faces still to be tested are kept.
const FACE_WORK := 1 << 24
## Walls count as this much thicker, so lattice points lying on a surface are blocked and a touch is not a crossing.
const TOLERANCE := 0.01
## How far in front of a face its sample points sit.
const SURFACE_PUSH := 0.5
const GRID_CELL := 32.0
const MAX_GRID_CELLS := 1 << 12
## Crossing tests of closed meshes reach this far past both ends, a lattice point lying on the surface has no side.
const MESH_REACH := 0.05
const _LEAKED := -3
const _SPENT := -2
const _STEPS: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

## Static solids bucketed in a grid, answering what blocks a point or a segment.
class Walls:
	var solids: Array[TrenchDotFaceCull.Solid] = []
	var bounds := AABB()
	var work: TrenchDotFaceCull.Work
	var _cells: Dictionary = {}
	var _large := PackedInt32Array()
	var _seen := PackedInt32Array()
	var _stamp := 0
	var _none := PackedInt32Array()

	func _init(list: Array[TrenchDotFaceCull.Solid], budget: TrenchDotFaceCull.Work) -> void:
		solids = list
		work = budget
		_seen.resize(solids.size())
		_seen.fill(0)
		for i in solids.size():
			var s := solids[i]
			bounds = s.bounds if i == 0 else bounds.merge(s.bounds)
			var b := s.reach.grow(MESH_REACH)
			var lo := Vector3i((b.position / GRID_CELL).floor())
			var hi := Vector3i((b.end / GRID_CELL).floor())
			var span := hi - lo + Vector3i.ONE
			if float(span.x) * span.y * span.z > MAX_GRID_CELLS:
				_large.append(i)
				continue
			for x in range(lo.x, hi.x + 1):
				for y in range(lo.y, hi.y + 1):
					for z in range(lo.z, hi.z + 1):
						var key := Vector3i(x, y, z)
						if not _cells.has(key):
							_cells[key] = PackedInt32Array()
						_cells[key].append(i)

	func _near(lo: Vector3, hi: Vector3) -> PackedInt32Array:
		var a := Vector3i((lo / GRID_CELL).floor())
		var b := Vector3i((hi / GRID_CELL).floor())
		if a == b and _large.is_empty() and not _cells.has(a):
			return _none
		_stamp += 1
		var out := PackedInt32Array()
		for x in range(a.x, b.x + 1):
			for y in range(a.y, b.y + 1):
				for z in range(a.z, b.z + 1):
					var list: Variant = _cells.get(Vector3i(x, y, z))
					if list != null:
						for i in list:
							if _seen[i] != _stamp:
								_seen[i] = _stamp
								out.append(i)
		out.append_array(_large)
		work.left -= out.size()
		return out

	## Whether a wall holds [param p].
	func holds(p: Vector3) -> bool:
		for i in _near(p, p):
			var s := solids[i]
			if not s.reach.has_point(p):
				continue
			if s.is_mesh:
				if s.contains(p, work):
					return true
				continue
			var inside := true
			for k in s.normals.size():
				if s.normals[k].dot(p) - s.dists[k] > TOLERANCE:
					inside = false
					break
			if inside:
				return true
		return false

	## Whether a wall lies between [param a] and [param b], or either end is inside one.
	func crosses(a: Vector3, b: Vector3) -> bool:
		var lo := a.min(b)
		var hi := a.max(b)
		var box := AABB(lo, hi - lo).grow(MESH_REACH + TOLERANCE)
		for i in _near(box.position, box.end):
			var s := solids[i]
			if not s.reach.intersects(box):
				continue
			if s.is_mesh:
				var dir := (b - a).normalized()
				var from := a - dir * MESH_REACH
				var to := b + dir * MESH_REACH
				var tris := s.tris
				for t in s.near(box, work):
					if TrenchDotFaceCull._segment_hits_triangle(from, to, tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]):
						return true
				continue
			var t0 := 0.0
			var t1 := 1.0
			var hit := true
			for k in s.normals.size():
				var f0 := s.normals[k].dot(a) - s.dists[k] - TOLERANCE
				var f1 := s.normals[k].dot(b) - s.dists[k] - TOLERANCE
				if f0 > 0.0 and f1 > 0.0:
					hit = false
					break
				if f0 > 0.0:
					t0 = maxf(t0, f0 / (f0 - f1))
				elif f1 > 0.0:
					t1 = minf(t1, f0 / (f0 - f1))
				if t0 >= t1:
					hit = false
					break
			if hit:
				return true
		return false

## A point entity, where a player may stand.
class Seed:
	var origin: Vector3
	var classname: String

## The points of a box around the walls, spaced [member spacing] apart and counted from [member low]. Points are
## classified, reached and expanded as the flood gets to them.
class Lattice:
	const WALL := 1
	const EMPTY := 2
	const KNOWN := 3
	## Within one step of a wall's bounds, the only points whose steps need a closer look.
	const NEAR := 4
	const BORDER := 8
	var spacing := SPACING
	var low: Vector3i
	var dims: Vector3i
	var walls: Walls
	## [constant WALL] or [constant EMPTY] once classified, plus [constant NEAR] and [constant BORDER].
	var _kind := PackedByteArray()
	## 0 not reached, 1 to 6 the step it was reached by, 7 reached from a seed.
	var _from := PackedByteArray()
	var _roots: Dictionary = {}
	var _steps: Array[int] = []

	func _init(solid_walls: Walls) -> void:
		walls = solid_walls
		var box := walls.bounds
		while true:
			low = Vector3i(((box.position - Vector3.ONE * 2.0 * spacing) / spacing).floor())
			var high := Vector3i(((box.end + Vector3.ONE * 2.0 * spacing) / spacing).ceil())
			dims = high - low + Vector3i.ONE
			if float(dims.x) * dims.y * dims.z <= MAX_POINTS:
				break
			spacing *= 2.0
		_kind.resize(dims.x * dims.y * dims.z)
		_from.resize(_kind.size())
		for step in _STEPS:
			_steps.append((step.x * dims.y + step.y) * dims.z + step.z)
		for x in dims.x:
			for y in dims.y:
				if x == 0 or y == 0 or x == dims.x - 1 or y == dims.y - 1:
					for z in dims.z:
						_kind[(x * dims.y + y) * dims.z + z] = BORDER
				else:
					_kind[(x * dims.y + y) * dims.z] = BORDER
					_kind[(x * dims.y + y) * dims.z + dims.z - 1] = BORDER
		for solid in walls.solids:
			var box_low := Vector3i(((solid.reach.position - Vector3.ONE * (spacing + MESH_REACH)) / spacing).floor()) - low
			var box_high := Vector3i(((solid.reach.end + Vector3.ONE * (spacing + MESH_REACH)) / spacing).ceil()) - low
			box_low = box_low.max(Vector3i.ZERO)
			box_high = box_high.min(dims - Vector3i.ONE)
			var count := (box_high.x - box_low.x + 1) * (box_high.y - box_low.y + 1) * (box_high.z - box_low.z + 1)
			if count <= 0:
				continue
			walls.work.left -= count >> 2
			for x in range(box_low.x, box_high.x + 1):
				for y in range(box_low.y, box_high.y + 1):
					var row := (x * dims.y + y) * dims.z
					for z in range(box_low.z, box_high.z + 1):
						_kind[row + z] |= NEAR

	func index(c: Vector3i) -> int:
		return (c.x * dims.y + c.y) * dims.z + c.z

	func cell(idx: int) -> Vector3i:
		return Vector3i(idx / (dims.y * dims.z), (idx / dims.z) % dims.y, idx % dims.z)

	func point(c: Vector3i) -> Vector3:
		return Vector3(low + c) * spacing

	func reached(idx: int) -> bool:
		return _from[idx] != 0

	func in_range(c: Vector3i) -> bool:
		return c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < dims.x and c.y < dims.y and c.z < dims.z

	func _empty(idx: int, p: Vector3) -> bool:
		var k := _kind[idx]
		if k & KNOWN == 0:
			k |= WALL if walls.holds(p) else EMPTY
			_kind[idx] = k
		return k & KNOWN == EMPTY

	## Floods from [param seeds]. Returns the index of the first border point reached ([constant _LEAKED] when a seed
	## stands outside the lattice), or -1 when the flood ends inside, or [constant _SPENT] once [member Walls.work] runs
	## out. [param out_seed] receives the index in [param seeds] of the seed the leak came from.
	func flood(seeds: Array[Seed], out_seed: PackedInt32Array) -> int:
		var queue := PackedInt32Array()
		for si in seeds.size():
			var o := seeds[si].origin
			var c := Vector3i((o / spacing).floor()) - low
			if not in_range(c) or not in_range(c + Vector3i.ONE):
				out_seed[0] = si
				return _LEAKED
			if walls.holds(o):
				continue
			for corner in 8:
				var cc := c + Vector3i(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
				var idx := index(cc)
				if _from[idx] != 0:
					continue
				var p := point(cc)
				if not _empty(idx, p) or walls.crosses(o, p):
					continue
				_from[idx] = 7
				_roots[idx] = si
				if _kind[idx] & BORDER:
					out_seed[0] = si
					return idx
				queue.append(idx)
		var head := 0
		var work := walls.work
		while head < queue.size():
			if work.left <= 0:
				return _SPENT
			var idx := queue[head]
			head += 1
			work.left -= 8
			var near := _kind[idx] & NEAR
			var c := Vector3i.ZERO
			var p := Vector3.ZERO
			if near:
				c = cell(idx)
				p = point(c)
			for d in 6:
				var n := idx + _steps[d]
				if _from[n] != 0:
					continue
				var k := _kind[n]
				if near or k & NEAR:
					if near == 0:
						c = cell(idx)
						p = point(c)
					var nc := c + _STEPS[d]
					var q := point(nc)
					if not _empty(n, q) or walls.crosses(p, q):
						continue
				_from[n] = d + 1
				if k & BORDER:
					out_seed[0] = _root_of(n)
					return n
				queue.append(n)
		return -1

	func _root_of(idx: int) -> int:
		while _from[idx] != 7:
			idx -= _steps[_from[idx] - 1]
		return _roots[idx]

	## Whether a reached lattice point next to [param p] sees it.
	func sees(p: Vector3) -> bool:
		var c := Vector3i((p / spacing).floor()) - low
		for corner in 8:
			var cc := c + Vector3i(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
			if in_range(cc) and _from[index(cc)] != 0 and not walls.crosses(p, point(cc)):
				return true
		return false

## Hides faces nothing in a sealed map can see, returns how many. [param map_path] names the map in warnings.
static func apply(entities: Array[FuncGodotData.EntityData], settings: FuncGodotMapSettings, materials: Dictionary, map_path := "") -> int:
	var key := settings.cull_void_faces_property
	var enabled := false
	for entity in entities:
		if str(entity.properties.get("classname", "")) == "worldspawn" and _switch(entity.properties.get(key), false):
			enabled = true
	if not enabled:
		return 0
	var inv_scale := 1.0 / maxf(settings.scale_factor, 1e-9)
	var solids: Array[TrenchDotFaceCull.Solid] = []
	var seeds: Array[Seed] = []
	for entity in entities:
		var classname := str(entity.properties.get("classname", ""))
		if entity.brushes.is_empty():
			var origin: Variant = _origin(entity.properties.get("origin"))
			if classname != "worldspawn" and origin != null and not entity.definition is FuncGodotFGDSolidClass:
				var s := Seed.new()
				s.origin = origin
				s.classname = classname
				seeds.append(s)
			continue
		if not TrenchDotFaceCull._static_entity(entity):
			continue
		for brush in entity.brushes:
			if brush.origin or (brush.has_disp and not brush.is_mesh) or not brush.closed or brush.faces.is_empty():
				continue
			var walled := true
			for f in brush.faces:
				if not FuncGodotUtil.is_sky(f.texture, settings) and (FuncGodotUtil.filter_face(f.texture, settings) or not TrenchDotFaceCull._opaque(materials.get(f.texture))):
					walled = false
					break
			if walled:
				var solid := TrenchDotFaceCull._solid(brush, inv_scale)
				if solid:
					solids.append(solid)
	if solids.is_empty() or seeds.is_empty():
		return 0

	var walls := Walls.new(solids, TrenchDotFaceCull.Work.new(FLOOD_WORK))
	var lattice := Lattice.new(walls)
	var from := PackedInt32Array([0])
	var end := lattice.flood(seeds, from)
	if end == _SPENT:
		push_warning("[TDM] %s is too big to find out whether it leaks in time, void faces are kept" % map_path)
		return 0
	if end != -1:
		var s := seeds[from[0]]
		var near := s.origin if end == _LEAKED else lattice.point(lattice.cell(end))
		push_warning("[TDM] %s leaks: %s at %s reaches the outside near %s, void faces are kept" % [map_path, s.classname, _id_text(s.origin), _id_text(near)])
		return 0

	var any := false
	for idx in lattice._from.size():
		if lattice.reached(idx):
			any = true
			break
	if not any:
		return 0
	walls.work = TrenchDotFaceCull.Work.new(FACE_WORK)
	var hidden := 0
	for entity in entities:
		if entity.brushes.is_empty() or not _switch(entity.properties.get(key), true) or not TrenchDotFaceCull._static_entity(entity):
			continue
		for brush in entity.brushes:
			if brush.origin or (brush.has_disp and not brush.is_mesh):
				continue
			for fi in brush.faces.size():
				var face := brush.faces[fi]
				if face.render_hidden or FuncGodotUtil.filter_face(face.texture, settings) or not TrenchDotFaceCull._opaque(materials.get(face.texture)):
					continue
				if walls.work.left <= 0:
					push_warning("[TDM] %s has too many faces to test against the void in time, some void faces are still drawn" % map_path)
					return hidden
				var entry := TrenchDotFaceCull._entry(face, brush, fi, inv_scale)
				if entry and not _seen(lattice, entry, walls.work):
					face.render_hidden = true
					hidden += 1
	return hidden

## Whether a lattice point sees the front of [param entry], tested at its corners, centre and points no further than
## [constant SPACING] apart in between.
static func _seen(lattice: Lattice, entry: TrenchDotFaceCull.Entry, work: TrenchDotFaceCull.Work) -> bool:
	var basis := TrenchDotFaceCull._plane_basis(entry.normal)
	var flat := TrenchDotFaceCull._flatten(entry.points, basis)
	var lo := flat[0]
	var hi := flat[0]
	var centre := Vector2.ZERO
	for q in flat:
		lo = lo.min(q)
		hi = hi.max(q)
		centre += q
	centre /= float(flat.size())
	var offset := entry.normal * (entry.dist + SURFACE_PUSH)
	var samples: Array[Vector2] = [centre]
	samples.append_array(flat)
	for q in samples:
		work.left -= 16
		if lattice.sees(basis[0] * q.x + basis[1] * q.y + offset):
			return true
	var counts := Vector2i(maxi(ceili((hi.x - lo.x) / lattice.spacing), 1), maxi(ceili((hi.y - lo.y) / lattice.spacing), 1))
	if counts.x * counts.y <= 1:
		return false
	var step := (hi - lo) / Vector2(counts)
	for i in counts.x:
		for j in counts.y:
			if work.left <= 0:
				return true
			var q := lo + Vector2((i + 0.5) * step.x, (j + 0.5) * step.y)
			if not Geometry2D.is_point_in_polygon(q, flat):
				continue
			work.left -= 16
			if lattice.sees(basis[0] * q.x + basis[1] * q.y + offset):
				return true
	return false

## A switch property in any of the shapes a map's properties come in, [param fallback] when it is not set.
static func _switch(value: Variant, fallback: bool) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return value != 0
		TYPE_STRING, TYPE_STRING_NAME:
			var text := str(value).strip_edges().to_lower()
			if text.is_empty():
				return fallback
			return not (text in ["0", "false", "no", "off"])
	return fallback

## An entity's origin in id space map units, null when it has none.
static func _origin(value: Variant) -> Variant:
	if value is Vector3 or value is Vector3i:
		return Vector3(value)
	if value is String:
		var parts: PackedFloat64Array = (value as String).split_floats(" ")
		if parts.size() > 2:
			return Vector3(parts[0], parts[1], parts[2])
	return null

static func _id_text(p: Vector3) -> String:
	return "%d %d %d" % [roundi(p.x), roundi(p.y), roundi(p.z)]
