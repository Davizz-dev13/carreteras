// Terreno del paisaje real (ver paisaje.gd): ortofoto PNOA + detalle de cerca + nieve opcional.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D orto_cerca : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D orto_lejos : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detalle : filter_linear_mipmap, repeat_enable;
uniform vec4 marco_zona;    // x0, z0, x1, z1 (m, coordenadas del juego)
uniform vec4 marco_lejos;
uniform float nieve = 0.0;
uniform float cota_nieve = 1800.0;
uniform int depurar = 0;   // 1: color crudo de la ortofoto, 2: UV de la zona (--paisaje_depurar=N)
uniform float mix_orto = 1.0;   // 1: color de siempre de cerca y ortofoto desde ~150-600 m; 0: ortofoto en todas partes
uniform float saturacion = 1.45;
uniform float contraste = 1.12;
uniform float brillo = 1.35;
uniform float oclusion = 0.65;   // menos luz ambiente (azul) del cielo sobre el suelo
uniform vec3 tinte = vec3(1.12, 1.0, 0.74);   // compensa la luz azulada del cielo del juego
uniform float cerca_orto = 0.0;   // 1 (aspecto.gd): de cerca la ortofoto suavizada (color real) en vez del color por altitud
uniform float talud = 0.0;        // 1: talud/arcén de tierra junto al asfalto (UV.y = 0 en el borde del asfalto, 1 abajo)
uniform sampler2D grano : filter_linear_mipmap, repeat_enable;

varying vec3 pw;
varying float ny;
varying vec3 col_alt;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ny = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
	col_alt = COLOR.rgb;   // color de siempre (por altitud y pendiente); el relieve lejano no lo trae (blanco), pero está lejos
}

void fragment() {
	vec2 uc = (pw.xz - marco_zona.xy) / (marco_zona.zw - marco_zona.xy);
	vec2 ul = (pw.xz - marco_lejos.xy) / (marco_lejos.zw - marco_lejos.xy);
	vec3 cc = texture(orto_cerca, uc).rgb;
	vec3 cl = texture(orto_lejos, ul).rgb;
	vec2 b = step(vec2(0.0), uc) * step(uc, vec2(1.0));
	vec3 c = mix(cl, cc, b.x * b.y);
	// la ortofoto viene con bruma y poco contraste (vista desde el avión): un poco más de saturación y contraste
	float l0 = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(l0), c, saturacion), vec3(0.0));
	c = pow(c, vec3(contraste)) * brillo * tinte;
	float dist = length(VERTEX);
	float d1 = texture(detalle, pw.xz * (1.0 / 60.0)).r;
	float d2 = texture(detalle, pw.xz * (1.0 / 7.0)).r;
	float d3 = texture(detalle, pw.xz * (1.0 / 1.3)).r;
	float cerca = 1.0 - smoothstep(150.0, 900.0, dist);
	float muy_cerca = 1.0 - smoothstep(25.0, 140.0, dist);
	c *= mix(1.0, (0.82 + 0.36 * d1) * (0.8 + 0.4 * d2), cerca);
	// de cerca la ortofoto de 5 m/px se ve borrosa: hasta ~150 m se usa el color de siempre con grano, y de 150 a 600 m
	// se pasa a la ortofoto (que es la que da el color real de laderas, bosques y prados a media y larga distancia)
	vec3 c_alt = col_alt * (0.85 + 0.3 * d1) * (0.85 + 0.3 * d2);
	if (cerca_orto > 0.5 || talud > 0.5) {
		// la misma ortofoto, suavizada (mipmap ~ 25-40 m) y con el grano de cerca: colores reales del sitio sin el borrón
		vec3 cb = mix(textureLod(orto_lejos, ul, 2.0).rgb, textureLod(orto_cerca, uc, 2.6).rgb, b.x * b.y);
		float lb = dot(cb, vec3(0.2126, 0.7152, 0.0722));
		cb = max(mix(vec3(lb), cb, saturacion), vec3(0.0));
		cb = pow(cb, vec3(contraste)) * brillo * tinte;
		// de cerca algo más oscura que a lo lejos (sin la bruma del avión), con el mismo tono que la ortofoto lejana
		vec3 cn = cb * 0.68;
		cn = max(mix(vec3(dot(cn, vec3(0.2126, 0.7152, 0.0722))), cn, 1.1), vec3(0.0));
		c_alt = cn * (0.82 + 0.36 * d1) * (0.8 + 0.4 * d2);
	}
	c = mix(c_alt, c, mix_orto * smoothstep(150.0, 600.0, dist) + (1.0 - mix_orto));
	// de muy cerca: grano fino (hierba / tierra) que la ortofoto de 5 m no tiene; solo varía brillo y un poco el tono
	c *= mix(vec3(1.0), mix(vec3(0.78, 0.8, 0.74), vec3(1.15, 1.12, 1.0), d3), muy_cerca);
	if (talud > 0.5) {
		// talud y arcén de tierra: la ortofoto junto a la carretera es la propia carretera (gris), así que aquí no se usa:
		// tierra y hierba seca con grano, más oscuro hacia abajo, y una franja de grava junto al asfalto (bermas)
		float g = texture(grano, pw.xz * (1.0 / 0.9)).r;
		float m = texture(detalle, pw.xz * (1.0 / 9.0) + vec2(0.4, 0.1)).r;
		vec3 tierra = mix(vec3(0.30, 0.25, 0.18), vec3(0.33, 0.31, 0.19), smoothstep(0.35, 0.65, m)) * (0.8 + 0.4 * g);
		vec3 grava = vec3(0.34, 0.31, 0.26) * (0.78 + 0.44 * g) * (0.9 + 0.2 * d2);
		c = mix(grava, tierra * mix(1.0, 0.8, UV.y), smoothstep(0.05, 0.22, UV.y));
	}

	if (nieve > 0.5) {
		float h = pw.y + (d1 - 0.5) * 140.0;
		float s = smoothstep(cota_nieve - 80.0, cota_nieve + 120.0, h) * smoothstep(0.55, 0.8, ny);
		float lum = dot(c, vec3(0.3, 0.59, 0.11));
		s *= mix(0.35, 1.0, smoothstep(0.035, 0.12, lum));
		c = mix(c, vec3(0.60, 0.63, 0.68), s);   // nieve no blanca pura: con el sol del juego ya sale casi blanca y conserva el relieve
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;   // sin reflejo del cielo
	AO = oclusion;
	AO_LIGHT_AFFECT = 0.0;
	if (depurar == 1) { ALBEDO = vec3(0.0); EMISSION = cc; }
	if (depurar == 2) { ALBEDO = vec3(0.0); EMISSION = vec3(fract(uc * 10.0), 0.0); }
}
