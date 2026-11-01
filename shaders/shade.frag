#version 440
// A soft halo of `shadowColor` around whatever `source` draws (text over the
// sky): the source's alpha, blurred and offset, tinted. Only the halo is
// drawn; the text itself is drawn normally on top, so it stays pixel-crisp.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 shadowColor;
    vec2 texel;      // one source texel, in texture coordinates
    vec2 offset;     // the halo's offset, in texture coordinates
    float spread;    // tap distance, in texels
    float strength;  // alpha gain before clamping
};
layout(binding = 1) uniform sampler2D source;

void main() {
    float a = 0.0;
    float total = 0.0;
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float w = exp(-float(i * i + j * j) / 4.5);
            a += texture(source, qt_TexCoord0 - offset + vec2(float(i), float(j)) * texel * spread).a * w;
            total += w;
        }
    }
    float s = clamp(a / total * strength, 0.0, 1.0) * shadowColor.a * qt_Opacity;
    fragColor = vec4(shadowColor.rgb * s, s);
}
