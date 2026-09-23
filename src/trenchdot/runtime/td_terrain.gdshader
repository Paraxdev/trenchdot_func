shader_type spatial;
// TrenchDot terrain: four texture layers blended by vertex color weights (r, g, b, a), projected triplanar so
// cliffs are not stretched. The same projection as the editor preview.

uniform sampler2D layer0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer3 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// Meters covered by one repeat of each layer.
uniform vec4 tiles = vec4(8.0);
// Per layer strength of the de-tiling, 0 leaves the texture repeating as authored.
uniform vec4 detiles = vec4(0.0);
// Per layer crispness of the de-tiled blend: 0 mixes the cells evenly and looks softest, 1 keeps one cell over
// almost all of its area and only mixes in a narrow band, so the texture stays as sharp as it was authored.
uniform vec4 sharpens = vec4(0.5);
// Terrain origin in map space, so textures line up with the editor.
uniform vec3 map_offset = vec3(0.0);
// Each layer's normal map, like BaseMaterial3D's normal_texture and normal_scale.
uniform sampler2D normal_texture0 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture1 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture2 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture3 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Per layer 1 when its normal map is set, so layers without one skip the samples.
uniform vec4 normal_mapped = vec4(0.0);
uniform vec4 normal_scales = vec4(1.0);
// Each layer's roughness texture, or its ambient occlusion texture when it has no roughness texture. An ORM
// texture holds both, so one sample gives the two.
uniform sampler2D surface_texture0 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_texture1 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_texture2 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_texture3 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Per layer roughness, times the surface texture channel picked by column l of roughness_channels when
// roughness_textured is 1, like BaseMaterial3D.
uniform vec4 roughnesses = vec4(0.9);
uniform vec4 roughness_textured = vec4(0.0);
uniform mat4 roughness_channels;
// Per layer 1 when the surface texture holds the layer's ambient occlusion, in the channel column l of
// ao_channels picks.
uniform vec4 ao_textured = vec4(0.0);
uniform mat4 ao_channels;
uniform vec4 ao_light_affects = vec4(0.0);
// Emission of each layer's material, like BaseMaterial3D: (color + texture) or (color * texture), times energy,
// weighted by the layer. The same as the editor preview.
uniform vec4 glow_color0 : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 glow_color1 : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 glow_color2 : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 glow_color3 : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D glow_texture0 : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D glow_texture1 : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D glow_texture2 : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D glow_texture3 : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 glow_energy = vec4(0.0);
// Per layer 1 when its emission texture is set, so layers without one skip the samples.
uniform vec4 glow_textured = vec4(0.0);
// Per layer 1 for BaseMaterial3D's multiply emission operator.
uniform vec4 glow_multiply = vec4(0.0);

varying vec3 map_position;
varying vec3 map_normal;

struct Surface {
	vec3 albedo;
	// How far the normal maps turn the geometric normal, in the terrain's local space.
	vec3 bend;
	float roughness;
	float ao;
	float ao_light_affect;
	vec3 emission;
};

void vertex() {
	map_position = VERTEX + map_offset;
	map_normal = NORMAL;
}

vec2 hash2(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.xx + q.yz) * q.zy);
}

// One repeat of the texture, turned and shifted by an amount fixed per cell. A tileable texture stays seamless
// however it is turned, so this breaks up the grid the repeat would otherwise show. A normal map comes back
// unpacked to -1..1 with its xy turned by the same angle, so the bumps keep facing the way the texture shows them.
vec4 cell_sample(sampler2D t, vec2 uv, vec2 cell, float strength, bool normal_map) {
	vec2 h = hash2(cell);
	float angle = (h.x - 0.5) * 6.2831853 * strength;
	float ca = cos(angle);
	float sa = sin(angle);
	vec2 pivot = cell + 0.5;
	vec2 d = uv - pivot;
	vec2 turned = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
	vec4 c = texture(t, pivot + turned + (h - 0.5) * strength);
	if (normal_map) {
		vec2 n = c.xy * 2.0 - 1.0;
		c.xy = vec2(n.x * ca - n.y * sa, n.x * sa + n.y * ca);
	}
	return c;
}

// Blends the four cells nearest to the sample. In the middle of a cell one of them carries all the weight, at
// the corners where the seams would be they mix, so the joins are blurred out instead of lining up.
// [param sharpen] raises the weights to a power, which pulls the mixing into a narrow band around the corners
// and leaves the rest of each cell a single crisp read, undoing the softness an even mix would give.
vec4 detiled(sampler2D t, vec2 uv, float strength, float sharpen, bool normal_map) {
	if (strength <= 0.0) {
		vec4 c = texture(t, uv);
		return normal_map ? vec4(c.xy * 2.0 - 1.0, c.zw) : c;
	}
	vec2 g = uv - 0.5;
	vec2 base = floor(g);
	vec2 f = g - base;
	vec2 w = f * f * (3.0 - 2.0 * f);
	float power = mix(1.0, 8.0, clamp(sharpen, 0.0, 1.0));
	vec4 sum = vec4(0.0);
	float total = 0.0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			vec2 corner = base + vec2(float(i), float(j));
			float weight = pow(mix(1.0 - w.x, w.x, float(i)) * mix(1.0 - w.y, w.y, float(j)), power);
			sum += cell_sample(t, uv, corner, strength, normal_map) * weight;
			total += weight;
		}
	}
	return sum / max(total, 0.00001);
}

vec4 layer(sampler2D t, float tile, float detile, float sharpen, vec3 blend) {
	float s = 1.0 / max(tile, 0.001);
	vec4 sum = vec4(0.0);
	if (blend.y > 0.0) {
		sum += detiled(t, map_position.xz * s, detile, sharpen, false) * blend.y;
	}
	if (blend.x > 0.0) {
		sum += detiled(t, vec2(map_position.z, -map_position.y) * s, detile, sharpen, false) * blend.x;
	}
	if (blend.z > 0.0) {
		sum += detiled(t, vec2(map_position.x, -map_position.y) * s, detile, sharpen, false) * blend.z;
	}
	return sum;
}

float normal_z(vec2 n) {
	return sqrt(max(0.0, 1.0 - dot(n, n)));
}

// How far the layer's normal map turns [param normal], through the same projections as layer(). Each one's
// tangent runs along its u and its binormal against its v, since normal maps point green up. Unpacked like
// BaseMaterial3D does, so a layer shades like its material on a brush.
vec3 layer_bend(sampler2D t, float tile, float detile, float sharpen, vec3 blend, vec3 normal) {
	float s = 1.0 / max(tile, 0.001);
	vec3 bend = vec3(0.0);
	if (blend.y > 0.0) {
		vec2 n = detiled(t, map_position.xz * s, detile, sharpen, true).xy;
		bend += (vec3(n.x, 0.0, -n.y) + normal * (normal_z(n) - 1.0)) * blend.y;
	}
	if (blend.x > 0.0) {
		vec2 n = detiled(t, vec2(map_position.z, -map_position.y) * s, detile, sharpen, true).xy;
		bend += (vec3(0.0, n.y, n.x) + normal * (normal_z(n) - 1.0)) * blend.x;
	}
	if (blend.z > 0.0) {
		vec2 n = detiled(t, vec2(map_position.x, -map_position.y) * s, detile, sharpen, true).xy;
		bend += (vec3(n.x, n.y, 0.0) + normal * (normal_z(n) - 1.0)) * blend.z;
	}
	return bend;
}

// Adds layer [param l] at [param weight]. Layers the splat leaves out cost no samples.
void add_layer(inout Surface s, int l, float weight, vec3 blend, vec3 normal, sampler2D albedo_tex, sampler2D normal_tex, sampler2D surface_tex, sampler2D glow_tex, vec3 glow_color) {
	if (weight <= 0.0) {
		return;
	}
	float tile = tiles[l];
	float detile = detiles[l];
	float sharpen = sharpens[l];
	s.albedo += layer(albedo_tex, tile, detile, sharpen, blend).rgb * weight;
	if (normal_mapped[l] > 0.5) {
		s.bend += layer_bend(normal_tex, tile, detile, sharpen, blend, normal) * normal_scales[l] * weight;
	}
	float rough = roughnesses[l];
	float ao = 1.0;
	if (roughness_textured[l] > 0.5 || ao_textured[l] > 0.5) {
		vec4 maps = layer(surface_tex, tile, detile, sharpen, blend);
		if (roughness_textured[l] > 0.5) {
			rough *= dot(maps, roughness_channels[l]);
		}
		if (ao_textured[l] > 0.5) {
			ao = dot(maps, ao_channels[l]);
		}
	}
	s.roughness += rough * weight;
	s.ao += ao * weight;
	s.ao_light_affect += ao_light_affects[l] * weight;
	vec3 glow_tex_color = vec3(0.0);
	if (glow_textured[l] > 0.5) {
		glow_tex_color = layer(glow_tex, tile, detile, sharpen, blend).rgb;
	}
	s.emission += (glow_multiply[l] > 0.5 ? glow_color * glow_tex_color : glow_color + glow_tex_color) * glow_energy[l] * weight;
}

void fragment() {
	vec3 normal = normalize(map_normal);
	vec3 blend = pow(abs(normal), vec3(6.0));
	blend /= max(blend.x + blend.y + blend.z, 0.0001);
	// Projections with a negligible share are dropped, so flat ground reads each texture once instead of three
	// times. Matches terrain.wgsl.
	blend *= step(vec3(0.002), blend);
	blend /= max(blend.x + blend.y + blend.z, 0.0001);
	vec4 w = COLOR;
	float sum = w.r + w.g + w.b + w.a;
	// An all zero splat means the first layer, matching Terrain::weights.
	w = sum > 0.0001 ? w / sum : vec4(1.0, 0.0, 0.0, 0.0);
	Surface s = Surface(vec3(0.0), vec3(0.0), 0.0, 0.0, 0.0, vec3(0.0));
	add_layer(s, 0, w.r, blend, normal, layer0, normal_texture0, surface_texture0, glow_texture0, glow_color0.rgb);
	add_layer(s, 1, w.g, blend, normal, layer1, normal_texture1, surface_texture1, glow_texture1, glow_color1.rgb);
	add_layer(s, 2, w.b, blend, normal, layer2, normal_texture2, surface_texture2, glow_texture2, glow_color2.rgb);
	add_layer(s, 3, w.a, blend, normal, layer3, normal_texture3, surface_texture3, glow_texture3, glow_color3.rgb);
	ALBEDO = s.albedo;
	ROUGHNESS = s.roughness;
	AO = s.ao;
	AO_LIGHT_AFFECT = s.ao_light_affect;
	EMISSION = s.emission;
	NORMAL = normalize(mat3(VIEW_MATRIX) * (MODEL_NORMAL_MATRIX * normalize(normal + s.bend)));
}
