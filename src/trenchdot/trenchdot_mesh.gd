class_name TrenchDotMesh extends RefCounted
## Converts TrenchDot mesh nodes (free form polygons) into FuncGodot brush data with custom surfaces.
## Faces are triangulated here, smooth normals follow the node's smoothing angle exactly like the editor.

const _BrushData := FuncGodotData.BrushData
const _FaceData := FuncGodotData.FaceData
## Ear clipping work a face may take per corner and in all, counted in corners and grid rows looked at, the same as
## td_geom::polygon::triangulate. Past either the rest of the face is fanned, so a face made to block its own ears
## cannot stall an import. Ordinary faces of a few thousand corners stay well within it.
const CLIP_WORK_PER_CORNER := 256
const MAX_CLIP_WORK := 1 << 22
## GDScript clips ears about a hundred times slower than the editor, so the faces of a whole build or model import
## also share one [ClipBudget] of this much. Only a map made to stall a build runs out of it, and its later faces are
## fanned.
const BUILD_CLIP_WORK := 1 << 24

## Ear clipping work left to a build, shared by the threads that convert its meshes. A face only looks at it before
## it starts, so a build may run past it by one face's budget per thread.
class ClipBudget extends RefCounted:
	var _left := BUILD_CLIP_WORK
	var _lock := Mutex.new()

	func spent() -> bool:
		_lock.lock()
		var out := _left <= 0
		_lock.unlock()
		return out

	func take(work: int) -> void:
		_lock.lock()
		_left -= work
		_lock.unlock()

static func _newell(points: PackedVector3Array) -> Vector3:
	var n := Vector3.ZERO
	for i in points.size():
		var cur := points[i]
		var nxt := points[(i + 1) % points.size()]
		n.x += (cur.y - nxt.y) * (cur.z + nxt.z)
		n.y += (cur.z - nxt.z) * (cur.x + nxt.x)
		n.z += (cur.x - nxt.x) * (cur.y + nxt.y)
	return n

static func _cross2(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)

## Triangle corner indices of a polygon, counter-clockwise around [param normal]. Ear clipping, mirroring
## td_geom::polygon::triangulate exactly (including its shorter-diagonal quad split and its work budget) so the
## editor and the Godot build triangulate the same face the same way. [param budget] is shared with the other faces
## of a build, when it is spent the face is fanned right away.
static func triangulate(points: PackedVector3Array, normal: Vector3, budget: ClipBudget = null) -> PackedInt32Array:
	var n := points.size()
	if n < 3:
		return PackedInt32Array()
	if n == 3:
		return PackedInt32Array([0, 1, 2])
	var nn := normal.normalized() if normal.length_squared() > 1e-12 else Vector3.UP
	var helper := Vector3.UP if absf(nn.y) < 0.9 else Vector3.RIGHT
	var u := helper.cross(nn).normalized()
	var v := nn.cross(u)
	var p2 := PackedVector2Array()
	for p in points:
		p2.append(Vector2(p.dot(u), p.dot(v)))

	if n == 4:
		var convex_quad := true
		for i in 4:
			if _cross2(p2[i], p2[(i + 1) % 4], p2[(i + 2) % 4]) <= 0.0:
				convex_quad = false
				break
		if convex_quad:
			# Split along the shorter diagonal, it keeps slivers out of near-planar quads.
			if p2[0].distance_squared_to(p2[2]) <= p2[1].distance_squared_to(p2[3]):
				return PackedInt32Array([0, 1, 2, 0, 2, 3])
			return PackedInt32Array([0, 1, 3, 1, 2, 3])

	# The polygon left to clip as a ring of corners starting at head, so clipping an ear takes constant time.
	var nxt := PackedInt32Array()
	var prv := PackedInt32Array()
	nxt.resize(n)
	prv.resize(n)
	for i in n:
		nxt[i] = (i + 1) % n
		prv[i] = (i + n - 1) % n
	var head := 0
	var m := n
	# An ear of a simple polygon holds another corner only if it holds a reflex one, so only those are tested, found
	# through a square grid over the corners that start out reflex. Corners that turn reflex later, which takes a face
	# that crosses itself, are kept in late.
	var reflex := PackedByteArray()
	reflex.resize(n)
	var items := PackedInt32Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for j in n:
		if _cross2(p2[prv[j]], p2[j], p2[nxt[j]]) <= 1e-12:
			reflex[j] = 1
			items.append(j)
			lo = lo.min(p2[j])
			hi = hi.max(p2[j])
	var listed := reflex.duplicate()
	var late := PackedInt32Array()
	var side := maxi(int(sqrt(items.size())), 1)
	var scale_x: float = side / (hi.x - lo.x) if hi.x > lo.x else 0.0
	var scale_y: float = side / (hi.y - lo.y) if hi.y > lo.y else 0.0
	var cells := PackedInt32Array()
	for j in items:
		cells.append(_cell((p2[j].y - lo.y) * scale_y, side) * side + _cell((p2[j].x - lo.x) * scale_x, side))
	var starts := PackedInt32Array()
	starts.resize(side * side + 1)
	for cell in cells:
		starts[cell + 1] += 1
	for cell in side * side:
		starts[cell + 1] += starts[cell]
	var fill := starts.duplicate()
	var sorted := PackedInt32Array()
	sorted.resize(items.size())
	for t in items.size():
		sorted[fill[cells[t]]] = items[t]
		fill[cells[t]] += 1
	items = sorted

	var limit := mini(n * CLIP_WORK_PER_CORNER, MAX_CLIP_WORK)
	if budget and budget.spent():
		limit = 0
	var work := 0
	var out := PackedInt32Array()
	while m > 3:
		var clipped := false
		var ib := head
		for _step in m:
			work += 1
			if work > limit:
				break
			var ia := prv[ib]
			var ic := nxt[ib]
			var ear := Vector3i(ia, ib, ic)
			var a := p2[ia]
			var b := p2[ib]
			var c := p2[ic]
			var area := _cross2(a, b, c)
			var blocked := area <= 1e-12
			if not blocked:
				var longest := maxf(maxf(a.distance_to(b), b.distance_to(c)), c.distance_to(a))
				var shortest := minf(minf(a.distance_to(b), b.distance_to(c)), c.distance_to(a))
				var margin := 4.0 * (1e-9 / shortest + 1e-6 * longest) * longest * longest / area
				var x0 := _cell((minf(minf(a.x, b.x), c.x) - margin - lo.x) * scale_x, side)
				var x1 := _cell((maxf(maxf(a.x, b.x), c.x) + margin - lo.x) * scale_x, side)
				var y0 := _cell((minf(minf(a.y, b.y), c.y) - margin - lo.y) * scale_y, side)
				var y1 := _cell((maxf(maxf(a.y, b.y), c.y) + margin - lo.y) * scale_y, side)
				var narrow := margin <= longest and (x1 - x0 + 1) * (y1 - y0 + 1) <= items.size()
				if not narrow:
					var t := _blocker(p2, reflex, items, 0, items.size(), ear)
					work += 1 + t + int(t < items.size())
					blocked = t < items.size()
				else:
					for y in range(y0, y1 + 1):
						var from := starts[y * side + x0]
						var to := starts[y * side + x1 + 1]
						var t := _blocker(p2, reflex, items, from, to, ear)
						work += 1 + t - from + int(t < to)
						if t < to:
							blocked = true
							break
				if not blocked:
					var t := _blocker(p2, reflex, late, 0, late.size(), ear)
					work += 1 + t + int(t < late.size())
					blocked = t < late.size()
			if blocked:
				ib = ic
				continue
			out.append_array([ia, ib, ic])
			nxt[ia] = ic
			prv[ic] = ia
			if ib == head:
				head = ic
			for j in [ia, ic]:
				reflex[j] = 1 if _cross2(p2[prv[j]], p2[j], p2[nxt[j]]) <= 1e-12 else 0
				if reflex[j] and not listed[j]:
					listed[j] = 1
					late.append(j)
			clipped = true
			break
		if not clipped:
			break
		m -= 1
	var at := nxt[head]
	for _k in range(2, m):
		out.append_array([head, at, nxt[at]])
		at = nxt[at]
	if budget:
		budget.take(work)
	return out

static func _cell(f: float, side: int) -> int:
	if f >= side:
		return side - 1
	if f >= 0.0:
		return int(f)
	return 0

## Where in [param list], from [param from] up to [param to], the first reflex corner lies that blocks the ear
## [param ear] by sitting in it, [param to] when none does.
static func _blocker(p2: PackedVector2Array, reflex: PackedByteArray, list: PackedInt32Array, from: int, to: int, ear: Vector3i) -> int:
	var a := p2[ear.x]
	var b := p2[ear.y]
	var c := p2[ear.z]
	for t in range(from, to):
		var j := list[t]
		if reflex[j] and j != ear.x and j != ear.y and j != ear.z and p2[j] != a and p2[j] != b and p2[j] != c and _cross2(a, b, p2[j]) >= -1e-9 and _cross2(b, c, p2[j]) >= -1e-9 and _cross2(c, a, p2[j]) >= -1e-9:
			return t
	return to

## Brush data for one mesh node. [param xform] places it (Godot space, map units), [param scale] converts to FuncGodot units.
## [param budget] is the build's, see [method triangulate].
static func parse(node: Dictionary, xform: Transform3D, scale: float, origin_texture: String, budget: ClipBudget = null) -> _BrushData:
	var raw_vertices: Array = node.get("vertices", [])
	var raw_faces: Array = node.get("faces", [])
	var decal := bool(node.get("decal", false))
	if raw_vertices.size() < 3 or raw_faces.is_empty():
		return null
	var mirror := xform.basis.determinant() < 0.0
	var vertices := PackedVector3Array()
	vertices.resize(raw_vertices.size())
	for i in raw_vertices.size():
		vertices[i] = xform * TrenchDotParser.vec3(raw_vertices[i])
	var smooth_angle := float(node.get("smooth_angle", 0.0))

	# Face corner lists, normals and the faces around each vertex.
	var faces: Array[Dictionary] = []
	var vertex_faces: Dictionary = {}
	for source_index in raw_faces.size():
		var f: Dictionary = raw_faces[source_index]
		var indices: Array = f.get("indices", [])
		var uvs: Array = f.get("uvs", [])
		var colors: Array = f.get("colors", [])
		if indices.size() < 3:
			continue
		if mirror:
			indices = indices.duplicate()
			indices.reverse()
			uvs = uvs.duplicate()
			uvs.reverse()
			colors = colors.duplicate()
			colors.reverse()
		var pts := PackedVector3Array()
		var valid := true
		for idx in indices:
			if int(idx) < 0 or int(idx) >= vertices.size():
				valid = false
				break
			pts.append(vertices[int(idx)])
		if not valid:
			continue
		var raw_normal := _newell(pts)
		if raw_normal.length_squared() < 1e-12:
			continue
		var fi := faces.size()
		faces.append({ "indices": indices, "points": pts, "normal": raw_normal, "unit": raw_normal.normalized(), "uvs": uvs, "colors": colors, "src": f, "source": source_index })
		for idx in indices:
			if not vertex_faces.has(int(idx)):
				vertex_faces[int(idx)] = []
			vertex_faces[int(idx)].append(fi)

	var cos_limit := cos(deg_to_rad(smooth_angle)) - 1e-6
	var brush := _BrushData.new()
	brush.exact = true
	brush.has_disp = true
	brush.is_mesh = true
	brush.origin = false
	var edge_uses: Dictionary = {}
	for face_info in faces:
		var indices: Array = face_info["indices"]
		for k in indices.size():
			var a := int(indices[k])
			var b := int(indices[(k + 1) % indices.size()])
			var edge := Vector2i(mini(a, b), maxi(a, b))
			edge_uses[edge] = int(edge_uses.get(edge, 0)) + 1
	brush.closed = edge_uses.values().all(func(n): return n == 2)
	for face_info in faces:
		var pts: PackedVector3Array = face_info["points"]
		var unit: Vector3 = face_info["unit"]
		var indices: Array = face_info["indices"]
		var src: Dictionary = face_info["src"]

		var face := _FaceData.new()
		face.source_index = face_info["source"]
		var centroid := Vector3.ZERO
		for p in pts:
			centroid += p
		centroid /= pts.size()
		var id_normal := TrenchDotParser.to_id(unit)
		face.plane = Plane(id_normal, id_normal.dot(TrenchDotParser.to_id(centroid) * scale))
		face.texture = str(src.get("material", ""))
		var face_props: Dictionary = src.get("props", {})
		var blend_material := str(face_props.get("blend_material", ""))
		if blend_material != "":
			var detile := float(face_props.get("blend_detile", 0.0))
			var uv_scale := float(face_props.get("blend_uv_scale", 1.0))
			var sharpen := float(face_props.get("blend_detile_sharpen", 0.5))
			face.texture = TrenchDotBlend.key(face.texture, blend_material, detile, uv_scale, sharpen)
		if decal:
			face.texture += TrenchDotDecalMesh.SUFFIX
		for p in pts:
			var id_p := TrenchDotParser.to_id(p) * scale
			face.exact_vertices.append(id_p)
			face.disp_vertices.append(id_p)
			face.disp_base.append(id_p)
		for k in pts.size():
			var n := unit
			if smooth_angle > 0.0:
				var sum := Vector3.ZERO
				for other in vertex_faces.get(int(indices[k]), []):
					var of: Dictionary = faces[other]
					if (of["unit"] as Vector3).dot(unit) >= cos_limit:
						sum += of["normal"]
				if sum.length_squared() > 1e-12:
					n = sum.normalized()
			face.disp_normals.append(TrenchDotParser.to_id(n))
		face.disp_indices = triangulate(pts, unit, budget)

		var uvs: Array = face_info["uvs"]
		if uvs.size() == pts.size():
			for uv in uvs:
				face.disp_uvs.append(Vector2(float(uv[0]), float(uv[1])))
		var colors: Array = face_info["colors"]
		if colors.size() == pts.size():
			for c in colors:
				face.disp_colors.append(Color(float(c[0]), float(c[1]), float(c[2]), float(c[3])))

		var uv: Dictionary = src.get("uv", {})
		var u_axis := TrenchDotParser.vec3(uv.get("u_axis"), Vector3.RIGHT)
		var v_axis := TrenchDotParser.vec3(uv.get("v_axis"), Vector3.BACK)
		var offset := TrenchDotParser.vec2(uv.get("offset"), Vector2.ZERO)
		var uv_scale := TrenchDotParser.uv_scale_of(uv)
		if xform != Transform3D.IDENTITY:
			var inv_t := xform.basis.inverse().transposed()
			var t := xform.origin
			var mu := inv_t * u_axis
			var mv := inv_t * v_axis
			var lu := maxf(mu.length(), 1e-9)
			var lv := maxf(mv.length(), 1e-9)
			offset.x -= mu.dot(t) / uv_scale.x
			offset.y -= mv.dot(t) / uv_scale.y
			uv_scale = Vector2(uv_scale.x / lu, uv_scale.y / lv)
			u_axis = mu / lu
			v_axis = mv / lv
		face.uv_axes.append(TrenchDotParser.to_id(u_axis))
		face.uv_axes.append(TrenchDotParser.to_id(v_axis))
		face.uv = Transform2D.IDENTITY
		face.uv.origin = offset
		face.uv.x = Vector2(uv_scale.x, 0.0) * scale
		face.uv.y = Vector2(0.0, uv_scale.y) * scale
		face.props = src.get("props", {})
		brush.planes.append(face.plane)
		brush.faces.append(face)
	if brush.faces.is_empty():
		return null
	return brush
