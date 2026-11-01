// Suelo de la versión web (y de "como_web" en pruebas): el color de siempre por altitud y pendiente (color de vértice),
// sin ortofoto (no se exporta a la web por tamaño), con lo barato del aspecto de escritorio: manchas grandes de hierba
// seca y más verde, grano de cerca y menos luz azul del cielo. Talud/arcén: grava junto al asfalto y tierra.
// 2 texturas de ruido de 256 px (las de aspecto.gd); unas 6 lecturas de textura por píxel.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D detalle : filter_linear_mipmap, repeat_enable;
uniform sampler2D grano : filter_linear_mipmap, repeat_enable;
uniform float talud = 0.0;        // 1: talud/arcén de tierra junto al asfalto (UV.y = 0 en el borde del asfalto, 1 abajo)
uniform float seco = 0.45;        // cuánto tira el prado hacia hierba seca / rastrojo en las manchas
uniform float oclusion = 0.7;     // menos luz ambiente (azul) del cielo sobre el suelo
uniform vec3 tinte = vec3(1.0, 1.0, 0.93);
uniform float saturacion = 0.85;   // en el navegador el verde salía más chillón que en escritorio

varying vec3 pw;
varying vec3 col_alt;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	col_alt = COLOR.rgb;
}

void fragment() {
	float dist = length(VERTEX);
	float d0 = texture(detalle, pw.xz * (1.0 / 420.0) + vec2(0.13, 0.57)).r;
	float d1 = texture(detalle, pw.xz * (1.0 / 60.0)).r;
	float d2 = texture(detalle, pw.xz * (1.0 / 7.0)).r;
	float d3 = texture(grano, pw.xz * (1.0 / 1.3)).r;
	float cerca = 1.0 - smoothstep(150.0, 900.0, dist);
	float muy_cerca = 1.0 - smoothstep(25.0, 140.0, dist);
	vec3 c = col_alt;
	// manchas grandes: prado algo más seco (pajizo) donde el ruido lo dice; las laderas de pinar (oscuras) casi no cambian
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	vec3 seca = vec3(0.42, 0.38, 0.25) * (l / 0.36);
	c = mix(c, seca, seco * smoothstep(0.35, 0.75, d0) * smoothstep(0.2, 0.33, l));
	c *= (0.88 + 0.24 * d1);
	c *= mix(1.0, (0.82 + 0.36 * d1) * (0.8 + 0.4 * d2), cerca);
	c *= mix(vec3(1.0), mix(vec3(0.8, 0.82, 0.76), vec3(1.13, 1.1, 1.0), d3), muy_cerca);
	if (talud > 0.5) {
		float g = texture(grano, pw.xz * (1.0 / 0.9)).r;
		float m = texture(detalle, pw.xz * (1.0 / 9.0) + vec2(0.4, 0.1)).r;
		vec3 tierra = mix(vec3(0.30, 0.25, 0.18), vec3(0.33, 0.31, 0.19), smoothstep(0.35, 0.65, m)) * (0.8 + 0.4 * g);
		vec3 grava = vec3(0.34, 0.31, 0.26) * (0.78 + 0.44 * g) * (0.9 + 0.2 * d2);
		c = mix(grava, tierra * mix(1.0, 0.8, UV.y), smoothstep(0.05, 0.22, UV.y));
	}
	c = mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, saturacion);
	ALBEDO = c * tinte;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	AO = oclusion;
	AO_LIGHT_AFFECT = 0.0;
}
