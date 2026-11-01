// Marcas viales (solo escritorio, Gráficos alto): pintura blanca algo gastada, con un pequeño desplazamiento de
// profundidad hacia la cámara que crece con la distancia (las líneas no parpadean contra el asfalto a lo lejos)
// y que pierde contraste a lo lejos (líneas de 15 cm en menos de un píxel: menos centelleo).
shader_type spatial;
render_mode diffuse_burley;

uniform vec3 color : source_color = vec3(0.86, 0.86, 0.84);
uniform vec3 color_lejos : source_color = vec3(0.45, 0.45, 0.44);
uniform sampler2D grano : filter_linear_mipmap, repeat_enable;
uniform sampler2D ruido : filter_linear_mipmap, repeat_enable;

varying vec3 pw;

void vertex() {
	pw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 pv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	pv.xyz *= 0.9993;    // 7 cm a 100 m, 35 cm a 500 m: misma posición en pantalla, algo más cerca en profundidad
	POSITION = PROJECTION_MATRIX * pv;
}

void fragment() {
	float dist = length(VERTEX);
	float n = texture(grano, pw.xz * (1.0 / 0.6)).r;
	float d = texture(ruido, pw.xz * (1.0 / 17.0)).r;
	float desgaste = 0.82 + 0.18 * smoothstep(0.2, 0.8, d) + (n - 0.5) * 0.18;
	vec3 c = mix(color * desgaste, color_lejos, smoothstep(120.0, 600.0, dist) * 0.6);
	ALBEDO = c * vec3(1.04, 1.0, 0.94);
	ROUGHNESS = 0.62;
	SPECULAR = 0.3;
	AO = 0.8;
	AO_LIGHT_AFFECT = 0.0;
}
