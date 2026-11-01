// Asfalto (solo escritorio, Gráficos alto): color base del aglomerado con variación real de cerca y de lejos, sin
// texturas de fotos: dos ruidos pequeños (256 px, mipmaps) muestreados en coordenadas del mundo.
//  · Manchas grandes (tramos más claros u oscuros) y grano del árido de cerca.
//  · Rodadas: bandas algo más oscuras y pulidas por donde pisan las ruedas, en cada carril (UV.x = m al eje, UV.y = semiancho).
//  · Borde: los últimos ~40 cm más sucios (polvo y tierra del arcén), salvo en las mallas sin UV (discos de los cruces).
shader_type spatial;
render_mode diffuse_burley;

uniform vec3 base : source_color = vec3(0.15, 0.15, 0.15);
uniform sampler2D ruido : filter_linear_mipmap, repeat_enable;   // suave (manchas)
uniform sampler2D grano : filter_linear_mipmap, repeat_enable;   // fino (árido)
uniform float carril = 3.5;
uniform float rodadas = 1.0;
uniform float con_uv = 1.0;

varying vec3 pw;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float dist = length(VERTEX);
	float n1 = texture(ruido, pw.xz * (1.0 / 90.0)).r;
	float n2 = texture(ruido, pw.xz * (1.0 / 13.0) + vec2(0.31, 0.77)).r;
	float n3 = texture(grano, pw.xz * (1.0 / 1.7)).r;
	float n4 = texture(grano, pw.xz * (1.0 / 0.41) + vec2(0.5, 0.2)).r;
	// tramos de distinto tono (asfaltados en años distintos) y manchas
	float tono = 0.86 + 0.30 * smoothstep(0.25, 0.75, n1);
	float mancha = 0.92 + 0.16 * n2;
	vec3 c = base * tono * mancha;
	// grano del árido (se apaga solo con los mipmaps a lo lejos)
	float g = (n3 - 0.5) * 0.22 + (n4 - 0.5) * 0.30;
	c *= 1.0 + g * (1.0 - smoothstep(20.0, 120.0, dist));
	float rough = 0.86 + 0.08 * n2;
	if (con_uv > 0.5 && UV.y > 0.5) {
		float hw = UV.y;
		float lat = UV.x;
		float nc = max(1.0, floor(2.0 * hw / carril + 0.35));
		float ac = 2.0 * hw / nc;
		float x = mod(lat + hw, ac) - ac * 0.5;          // m al centro del carril
		float r = exp(-pow((abs(x) - 0.85) / 0.30, 2.0));  // dos rodadas por carril (ancho de vía ~1,7 m)
		c *= 1.0 - 0.13 * r * rodadas * (0.7 + 0.6 * n2);
		rough -= 0.10 * r * rodadas;
		// suciedad del borde
		float b = smoothstep(hw - 0.55, hw - 0.05, abs(lat));
		c = mix(c, vec3(0.30, 0.27, 0.22) * (0.8 + 0.4 * n3), b * 0.45);
	}
	// el cielo del juego ilumina azulado (luz ambiente y reflejo): un poco de tono cálido y menos luz ambiente para que
	// el aglomerado se vea gris neutro y no azul
	ALBEDO = c * vec3(1.07, 1.0, 0.88);
	ROUGHNESS = clamp(rough, 0.5, 1.0);
	SPECULAR = 0.22;
	AO = 0.72;
	AO_LIGHT_AFFECT = 0.0;
}
