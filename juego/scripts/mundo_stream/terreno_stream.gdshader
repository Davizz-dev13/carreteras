// Terreno del mundo por teselas (terreno_stream.gd): ortofoto PNOA de cada tesela + grano de cerca + arcén junto a la
// calzada + curvatura de la Tierra a lo lejos. Barato: 1 textura propia por tesela (DXT1 en escritorio) y 2 de ruido.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D orto : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detalle : filter_linear_mipmap, repeat_enable;
uniform float saturacion = 1.0;
uniform float contraste = 1.04;
uniform float brillo = 0.78;
uniform vec3 tinte = vec3(1.05, 1.0, 0.90);
uniform float oclusion = 0.6;   // menos luz ambiente (azul) del cielo sobre el suelo   // compensa la luz azulada del cielo del juego
uniform float radio_tierra = 6371000.0;
uniform float curvatura_desde = 3000.0;      // m: de cerca nada (las carreteras y árboles no se curvan)
uniform float arcen = 1.0;                   // 0: sin arcén de tierra (depuración)
uniform int depurar = 0;                     // 1: foto cruda, 2: UV, 3: máscara del arcén

varying vec3 pw;
varying float mascara_arcen;
varying float ny;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 dc = pw.xz - CAMERA_POSITION_WORLD.xz;
	float d = max(length(dc) - curvatura_desde, 0.0);
	VERTEX.y -= d * d / (2.0 * radio_tierra);
	mascara_arcen = COLOR.r;
	ny = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
}

vec3 graduar(vec3 c) {
	float l0 = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(l0), c, saturacion), vec3(0.0));
	c = pow(c, vec3(contraste)) * brillo * tinte;
	// luces suaves: roca clara, aparcamientos y caminos de la foto se quemaban a blanco con el sol del juego
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	if (l > 0.28) {
		c *= (0.28 + (l - 0.28) * 0.4) / l;
	}
	return c;
}

void fragment() {
	vec3 c = graduar(texture(orto, UV).rgb);
	float dist = length(VERTEX);
	float d1 = texture(detalle, pw.xz * (1.0 / 47.0)).r;
	float d2 = texture(detalle, pw.xz * (1.0 / 6.3)).r;
	float d3 = texture(detalle, pw.xz * (1.0 / 1.1)).r;
	float cerca = 1.0 - smoothstep(60.0, 500.0, dist);
	float muy_cerca = 1.0 - smoothstep(10.0, 90.0, dist);
	// de cerca la foto (0,3 m/px) no tiene grano: manchas suaves y grano fino que solo cambian el brillo y algo el tono
	c *= mix(1.0, (0.88 + 0.24 * d1) * (0.86 + 0.28 * d2), cerca);
	c *= mix(vec3(1.0), mix(vec3(0.84, 0.86, 0.80), vec3(1.12, 1.10, 1.0), d3), muy_cerca);
	// laderas empinadas (taludes de la carretera, cortados, roquedos): la foto vertical se estira y se ve como un borrón;
	// ahí tierra y roca con grano, con el tono medio del sitio sacado de la propia foto
	float empinado = smoothstep(0.93, 0.76, ny) * (1.0 - smoothstep(150.0, 700.0, dist));
	if (empinado > 0.001) {
		float g2 = texture(detalle, pw.xz * (1.0 / 2.3) + pw.y * 0.21).r;
		float g3 = texture(detalle, vec2(pw.x + pw.z, pw.y) * (1.0 / 3.1)).r;
		vec3 medio = graduar(textureLod(orto, UV, 4.0).rgb);
		vec3 tierra = mix(vec3(0.40, 0.36, 0.29), vec3(0.47, 0.45, 0.42), smoothstep(0.4, 0.7, g3)) * (0.75 + 0.5 * g2);
		vec3 hierba = mix(vec3(0.27, 0.27, 0.17), vec3(0.33, 0.30, 0.20), g3) * (0.8 + 0.4 * g2);
		tierra = mix(hierba, tierra, smoothstep(0.80, 0.62, ny));    // talud tendido: hierba seca; muy empinado: tierra y roca
		tierra = mix(tierra, medio * (0.8 + 0.4 * g2), 0.30);
		c = mix(c, tierra, empinado);
	}
	if (arcen > 0.5 && mascara_arcen > 0.01) {
		// junto a la calzada: berma de grava y tierra con hierba seca (la foto trae ahí la carretera real, que no coincide
		// al metro con la nuestra); el tono sale de la propia foto muy suavizada para no desentonar con el sitio
		float g = texture(detalle, pw.xz * (1.0 / 0.8)).r;
		vec3 grava = vec3(0.36, 0.33, 0.28) * (0.8 + 0.4 * g) * (0.9 + 0.2 * d2);
		// junto al arcén la foto suele traer la calzada real, aparcamientos o la berma (gris claro): se oscurece a un tono de
		// suelo para que no salga una franja blanca al lado de nuestro asfalto
		vec3 cb = c;
		float lb = dot(cb, vec3(0.2126, 0.7152, 0.0722));
		cb = mix(cb, vec3(0.30, 0.28, 0.20) * (0.8 + 0.4 * d2), smoothstep(0.22, 0.45, lb));
		vec3 berma = mix(grava, cb * (0.85 + 0.3 * g), smoothstep(0.35, 0.9, 1.0 - mascara_arcen));
		c = mix(c, berma, smoothstep(0.0, 0.6, mascara_arcen));
	}
	if (depurar == 1) { c = texture(orto, UV).rgb; }
	if (depurar == 2) { c = vec3(UV, 0.0); }
	if (depurar == 3) { c = vec3(mascara_arcen); }
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	AO = oclusion;
	AO_LIGHT_AFFECT = 0.0;
	if (depurar == 4) { ALBEDO = vec3(0.0); EMISSION = texture(orto, UV).rgb; }
}
