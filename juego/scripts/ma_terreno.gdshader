// Suelo del mapa abierto (ma_mundo.gd): ortofoto real del IGN (PNOA) de cada tesela y del horizonte.
// De cerca (< ~150 m) la ortofoto de 5 m/píxel se ve borrosa: se usa su color medio (mipmap borroso) con un grano
// procedural que solo varía el brillo; de 150 a 500 m se pasa a la ortofoto con todo su detalle.
// El ajuste de color (saturación, contraste, brillo, tinte) es el mismo que el del paisaje de las zonas (paisaje.gd).
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D orto : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detalle : filter_linear_mipmap, repeat_enable;
uniform vec4 marco;            // x0, z0, x1, z1 (m, coordenadas del juego) que cubre la imagen
uniform float saturacion = 1.0;
uniform float contraste = 1.06;
uniform float brillo = 1.12;
uniform vec3 tinte = vec3(1.06, 1.0, 0.86);   // compensa la luz azulada del cielo
uniform float oclusion = 0.65;   // menos luz ambiente (azul) del cielo sobre el suelo
uniform float cerca_ini = 150.0;
uniform float cerca_fin = 500.0;
uniform float lejos = 0.0;     // 1 = horizonte (sin grano)

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
	ALBEDO = ajustar(c);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;   // sin reflejo del cielo (sin esto el suelo sale blanco azulado)
	AO = oclusion;
	AO_LIGHT_AFFECT = 0.0;
}
