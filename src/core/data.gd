@icon("res://addons/func_godot/icons/icon_godot_ranger.svg")
class_name FuncGodotData
## Container that holds various data structs to be used in the [FuncGodotMap] build process.
##
## FuncGodot utilizes multiple custom data structs to hold information parsed from the map file 
## and read and modified by the other core build classes. 
## All data structs extend from [RefCounted], therefore all data is passed by reference.
## [br][br]
## [FuncGodotData.FaceData][br]
## [FuncGodotData.BrushData][br]
## [FuncGodotData.GroupData][br]
## [FuncGodotData.EntityData][br]

## Data struct representing both a single map plane and a mesh face. Generated during parsing by plane definitions in the map file, 
## it is further modified and utilized during the geo generation stage to create the final entity meshes.
class FaceData extends RefCounted:
	## Vertex array for the face. Only populated in combination with other faces, as a result of planar intersections.
	var vertices: PackedVector3Array = []
	## Index array for the face. Used in ArrayMesh creation.
	var indices: PackedInt32Array = []
	## Vertex normal array for the face. 
	## By default, set to the planar normal, which results in flat shading. May be modified to adjust shading.
	var normals: PackedVector3Array = []
	## Tangent data for the face.
	var tangents: PackedFloat32Array = []
	## Local path to the texture without the extension, relative to the FuncGodotMap node's settings' base texture directory.
	var texture: String
	## UV offset (origin) and scale (basis) generated during the parsing stage.
	var uv: Transform2D
	## U and V texture axes of the face, used to calculate UVs and tangents.
	var uv_axes: PackedVector3Array = []
	## Raw plane data parsed from the map file using the id Tech coordinate system.
	var plane: Plane
	## Exact face polygon from the editor (id space, scaled). Used instead of plane clipping when set.
	var exact_vertices: PackedVector3Array = []
	## Free form per face properties (collision layers, smoothing groups).
	var props: Dictionary = {}
	## Vertex paint, one color per entry of [member vertices] (alpha is the blend weight).
	var vertex_colors: PackedColorArray = []
	## Displacement surface (id space, scaled). Empty for regular faces.
	var disp_vertices: PackedVector3Array = []
	## Flat positions of the displacement grid, used for texture coordinates.
	var disp_base: PackedVector3Array = []
	var disp_normals: PackedVector3Array = []
	var disp_indices: PackedInt32Array = []
	var disp_alphas: PackedFloat32Array = []
	## Mesh faces: explicit texture coordinates and vertex colors per surface vertex.
	var disp_uvs: PackedVector2Array = []
	var disp_colors: PackedColorArray = []
	## Covered by a coplanar face of another solid, left out of the visual mesh but kept for collision.
	var render_hidden: bool = false

	func is_displacement() -> bool:
		return not disp_indices.is_empty()

	func has_colors() -> bool:
		return not vertex_colors.is_empty() or is_displacement()

	## Returns the average position of all vertices in the face. Only valid when the face has at least one vertex.
	func get_centroid() -> Vector3:
		return FuncGodotUtil.op_vec3_avg(vertices)
	
	## Returns an arbitrary coplanar direction to use for winding the face.
	## Only valid when the face has at least two vertices.
	func get_basis() -> Vector3:
		if vertices.size() < 2:
			push_error("Cannot get winding basis without at least 2 vertices!")
			return Vector3.ZERO
		return (vertices[1] - vertices[0]).normalized()
	
	## Prepares the face for OpenGL triangle winding order. 
	## Sorts the vertex array in-place by angle from the centroid.
	func wind() -> void:
		var centroid: Vector3 = get_centroid()
		var u_axis: Vector3 = get_basis()
		var v_axis: Vector3 = u_axis.cross(plane.normal).normalized()
		var cmp_winding_angle: Callable = (
			func(a: Vector3, b: Vector3) -> bool:
				var dir_a: Vector3 = a - centroid
				var dir_b: Vector3 = b - centroid
				var angle_a: float = atan2(dir_a.dot(v_axis), dir_a.dot(u_axis))
				var angle_b: float = atan2(dir_b.dot(v_axis), dir_b.dot(u_axis))
				return angle_a < angle_b
		)

		var _vertices: Array[Vector3]
		_vertices.assign(vertices)
		_vertices.sort_custom(cmp_winding_angle)
		vertices = _vertices
	
	## Repopulate the [member indices] array to create a triangle fan. 
	## The face must be properly wound for the resulting indices to be valid.
	func index_vertices() -> void:
		var tri_count: int = vertices.size() - 2
		indices.resize(tri_count * 3)
		var index: int = 0
		for i in tri_count:
			indices[index] = 0
			indices[index + 1] = i + 1
			indices[index + 2] = i + 2
			index += 3

## Data struct representing a single map format brush. It is largely meant as a container for [FuncGodotData.FaceData] data.
class BrushData extends RefCounted:
	## Raw plane data parsed from the map file using the id Tech coordinate system.
	var planes: Array[Plane]
	## Collection of [FuncGodotData.FaceData].
	var faces: Array[FaceData]
	## [code]true[/code] if this brush is completely covered in the [i]Origin[/i] texture defined in [FuncGodotMapSettings].
	## Determined during [FuncGodotParser] and utilized during [FuncGodotGeometryGenerator].
	var origin: bool = false
	## Faces carry [member FaceData.exact_vertices], so no hyperplane clipping is needed.
	var exact: bool = false
	## Brush has displacement faces. Only those become geometry, like in Hammer.
	var has_disp: bool = false
	## The brush is a free form mesh whose faces are all custom surfaces.
	var is_mesh: bool = false
	## False for open meshes (sheets with border edges), brushes are always closed.
	var closed: bool = true
	## The map node id, older nodes win when coplanar faces overlap.
	var node_id: int = 0

## Data struct representing a map layer or group. 
## Generated during the parsing stage and utilized during both parsing and entity assembly stages.
class GroupData extends RefCounted:
	enum GroupType { GROUP, LAYER, }
	## Defines whether the group is a Group or a Layer. Currently only determines the name of the group.
	var type: GroupType = GroupType.GROUP
	## Group ID retrieved from the map file. Utilized during the parsing and entity assembly stages to determine 
	## which entities belong to which groups as well as which groups are children of other groups.
	var id: int
	## Generated during the parsing stage using the format of type_id_name, eg: group_2_Arkham.
	var name: String
	## ID of the parent group data, used to determine which group data is this group's parent.
	var parent_id: int = -1
	## Pointer to another group data that this group is a child of.
	var parent: GroupData = null
	## Pointer to generated Node3D representing this group in the SceneTree.
	var node: Node3D = null
	## If true, erases all entities assigned to this group and then the group itself at the end of the parsing stage, preventing those entities from being generated into nodes. 
	## Set for layers the map omits from the build.
	var omit: bool = false

## Data struct representing a map format entity.
class EntityData extends RefCounted:
	## All of the entity's key value pairs from the map file, retrieved during parsing. 
	## The func_godot_properties dictionary generated at the end of entity assembly is derived from this.
	var properties: Dictionary[String, Variant] = {}
	## The entity's brush data collected during the parsing stage. If the entity's FGD resource cannot be found, 
	## the presence of a single brush determines this entity to be a Solid Entity.
	var brushes: Array[BrushData] = []
	## Pointer to the group data this entity belongs to.
	var group: GroupData = null
	## The entity's FGD resource, determined by matching the classname properties of each. 
	## This can only be a [FuncGodotFGDSolidClass] or a [FuncGodotFGDPointClass].
	var definition: FuncGodotFGDEntityClass = null
	## Mesh resource generated during the geometry generation stage and applied during the entity assembly stage.
	var mesh: ArrayMesh = null
	## MeshInstance3D node generated during the entity assembly stage.
	var mesh_instance: MeshInstance3D = null
	## Optional mesh metadata compiled during the geometry generation stage, used to determine face information from collision.
	var mesh_metadata: Dictionary = {}
	## A collection of collision shape resources generated during the geometry generation stage and applied during the entity assembly stage.
	var shapes: Array[Shape3D] = []
	## Shape data computed on worker threads. Shape resources are created from it on the main thread,
	## because creating physics shapes concurrently from several threads corrupts physics server state.
	var pending_convex_points: Array[PackedVector3Array] = []
	var pending_concave_faces: PackedVector3Array = []
	## A collection of [CollisionShape3D] nodes generated during the entity assembly stage. Each node corresponds to a shape in the [member shapes] array.
	var collision_shapes: Array[CollisionShape3D] = []
	## [OccluderInstance3D] node generated during the entity assembly stage using the [member mesh] resource.
	var occluder_instance: OccluderInstance3D = null
	## True global position of the entity's generated node that the mesh's vertices are offset by during the geometry generation stage.
	var origin: Vector3 = Vector3.ZERO
	## Hammer style I/O connections ({output, target, input, parameter, delay, times}).
	var outputs: Array[Dictionary] = []
	## Node generated for this entity during assembly.
	var node: Node = null
	## The map node id, written to the generated node for live updates. -1 for entities made without one.
	var node_id: int = -1

	## Checks the entity's FGD resource definition, returning whether the Solid Class has a [MeshInstance3D] built for it.
	func is_visual() -> bool:
		return (definition
				and definition is FuncGodotFGDSolidClass
				and definition.build_visuals)

	func is_gi_enabled() -> bool:
		return (definition
				and definition is FuncGodotFGDSolidClass
				and definition.global_illumination_mode
		)
	
	## Checks the entity's FGD resource definition, returning whether the Solid Class CollisionShapeType is set to Convex.
	func is_collision_convex() -> bool:
		return (definition 
				and definition is FuncGodotFGDSolidClass 
				and definition.collision_shape_type == FuncGodotFGDSolidClass.CollisionShapeType.CONVEX
		)
	
	## Checks the entity's FGD resource definition, returning whether the Solid Class CollisionShapeType is set to Concave.
	func is_collision_concave() -> bool:
		return (definition 
				and definition is FuncGodotFGDSolidClass 
				and definition.collision_shape_type == FuncGodotFGDSolidClass.CollisionShapeType.CONCAVE
		)
	
	## Determines if the entity's mesh should be processed for normal smoothing. 
	## The smoothing property can be retrieved from [member FuncGodotMapSettings.entity_smoothing_property].
	func is_smooth_shaded(smoothing_property: String = "_phong") -> bool: 
		return int(properties.get(smoothing_property, 0)) > 0
  	
	## Retrieves the entity's smoothing angle to determine if the face should be smoothed. 
	## The smoothing angle property can be retrieved from [member FuncGodotMapSettings.entity_smoothing_angle_property].
	func get_smoothing_angle(smoothing_angle_property: String = "_phong_angle") -> float:
		return properties.get(smoothing_angle_property, 89.0)

class VertexGroupData:
	## Faces this vertex appears in.
	var faces: Array[FaceData]
	## Index within the associated face for this vertex.
	var face_indices: PackedInt32Array

class ParseData:
	var entities: Array[EntityData] = []
	var groups: Array[GroupData] = []
	## Heightmap terrains: {"data": Dictionary, "offset": Vector3 (map units), "group": GroupData}.
	var terrains: Array[Dictionary] = []
	## Scatter sets: {"data": Dictionary, "xform": Transform3D (map units), "group": GroupData, "id": int}.
	var scatters: Array[Dictionary] = []
