#version 440
// The sky's vertex stage: Qt's standard ShaderEffect transform, built for the
// same GLSL targets as atmosphere.frag (Qt's built-in vertex shader shares no
// GLSL ES version with it, so on an OpenGL ES context the pair would not
// link). The uniform block must match atmosphere.frag's exactly
// (tests/shader-block.test.js checks it).
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_res;
    float u_time;
    vec3 u_cam;
    vec2 u_sun;
    float u_cover;
    vec3 u_high;
    vec3 u_mid;
    vec4 u_low;
    float u_rain;
    float u_snow;
    float u_wind;
    float u_thunder;
    float u_haze;
    vec2 u_cbFeat;
    float u_windOff;
    float u_evo;
    float u_filtAmt;
    vec3 u_filtTint;
    float u_filtSat;
    float u_filtLift;
    float u_p3;
    float u_headroom;
    vec4 u_tone;
    vec4 u_pol;
    vec4 u_sky;
    vec2 u_radiant;
    vec4 u_calm;
};

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
