shader_type spatial;
// Coche del jugador (LOD0): material PBR de las piezas que no son chapa ni cristal, con oclusión ambiental por vértice
// (COLOR.r, calculada fuera de línea con rayos contra el propio coche; los cristales no tapan). Así el interior no se
// ilumina con todo el cielo como si estuviera fuera (el salpicadero y las puertas salían gris azulado) y los cromados de
// dentro no brillan; la luz directa del sol no cambia (AO_LIGHT_AFFECT = 0), las sombras siguen siendo las del motor.
render_mode cull_disabled;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D textura : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float fuerza_ao : hint_range(0.0, 1.0) = 1.0;
uniform float curva_ao : hint_range(0.5, 3.0) = 1.5;    // >1 oscurece más los rincones cerrados (dentro de la cabina)

void fragment() {
	ALBEDO = albedo.rgb * texture(textura, UV).rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	AO = mix(1.0, pow(COLOR.r, curva_ao), fuerza_ao);
	AO_LIGHT_AFFECT = 0.0;
}
