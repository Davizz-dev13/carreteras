// Suelo del mapa abierto (ma_mundo.gd): ortofoto real del IGN (PNOA) de cada tesela y del horizonte.
// De cerca (< ~150 m) la ortofoto de 5 m/píxel se ve borrosa: se usa su color medio (mipmap borroso) con un grano
// procedural que solo varía el brillo; de 150 a 500 m se pasa a la ortofoto con todo su detalle.
// El ajuste de color (saturación, contraste, brillo, tinte) es el mismo que el del paisaje de las zonas (paisaje.gd).
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D orto : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detalle : filter_linear_mipmap, repeat_enable;
uniform vec4 marco;            // x0, z0, x1, z1 (m, coordenadas del juego) que cubre la imagen
uniform float saturacion = 1.25;
uniform float contraste = 1.12;
uniform float brillo = 0.92;
uniform vec3 tinte = vec3(1.12, 1.0, 0.74);   // compensa la luz azulada del cielo
uniform float oclusion = 0.65;   // menos luz ambiente (azul) del cielo sobre el suelo
uniform float cerca_ini = 150.0;
uniform float cerca_fin = 500.0;
uniform float lejos = 0.0;     // 1 = horizonte (sin grano)
uniform float talud = 0.0;     // 1 (aspecto.gd): talud/arcén de tierra; UV.y = 0 en el borde del asfalto, 1 abajo
uniform sampler2D grano : filter_linear_mipmap, repeat_enable;

varying vec3 pw;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec3 ajustar(vec3 c) {
	float l0 = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(l0), c, saturacion), vec3(0.0));
	return pow(c, vec3(contraste)) * brillo * tinte;
}

void fragment() {
	vec2 uv = clamp((pw.xz - marco.xy) / (marco.zw - marco.xy), vec2(0.0), vec2(1.0));
	float dist = length(VERTEX);
	vec3 c = texture(orto, uv).rgb;
	if (lejos < 0.5) {
		vec3 cb = textureLod(orto, uv, 3.5).rgb;
		c = mix(cb, c, smoothstep(cerca_ini, cerca_fin, dist));
		float d1 = texture(detalle, pw.xz * (1.0 / 60.0)).r;
		float d2 = texture(detalle, pw.xz * (1.0 / 7.0)).r;
		float d3 = texture(detalle, pw.xz * (1.0 / 1.3)).r;
		float cerca = 1.0 - smoothstep(150.0, 900.0, dist);
		float muy_cerca = 1.0 - smoothstep(25.0, 140.0, dist);
		c *= mix(1.0, (0.82 + 0.36 * d1) * (0.8 + 0.4 * d2), cerca);
		c *= mix(vec3(1.0), mix(vec3(0.78, 0.8, 0.74), vec3(1.15, 1.12, 1.0), d3), muy_cerca);
	}
	c = ajustar(c);
	if (talud > 0.5) {
		// talud y arcén de tierra: la ortofoto junto a la carretera es la propia carretera (gris), así que aquí no se usa:
		// tierra y hierba seca con grano, más oscuro hacia abajo, y una franja de grava junto al asfalto (bermas)
		float g = texture(grano, pw.xz * (1.0 / 0.9)).r;
		float m = texture(detalle, pw.xz * (1.0 / 9.0) + vec2(0.4, 0.1)).r;
		vec3 tierra = mix(vec3(0.30, 0.25, 0.18), vec3(0.33, 0.31, 0.19), smoothstep(0.35, 0.65, m)) * (0.8 + 0.4 * g);
		vec3 grava = vec3(0.34, 0.31, 0.26) * (0.78 + 0.44 * g) * (0.9 + 0.2 * texture(detalle, pw.xz * (1.0 / 7.0)).r);
		c = mix(grava, tierra * mix(1.0, 0.8, UV.y), smoothstep(0.05, 0.22, UV.y));
	}

	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;   // sin reflejo del cielo (sin esto el suelo sale blanco azulado)
	AO = oclusion;
	AO_LIGHT_AFFECT = 0.0;
}
