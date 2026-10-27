// Port of starFragment in Sources/Shaders.metal.

in vec3 local;
in vec3 color;
in vec3 tailCol;
out vec4 fragColor;

void main() {
    float t = local.x;
    float L = local.z;
    float da = max(max(-t, t - L), 0.0);
    float d2 = da * da + local.y * local.y;
    float core = exp(-d2 * 4.0);
    float along = L > 0.01 ? saturate(t / L) : 1.0;
    float trail = L > 0.01 ? mix(0.12, 1.0, along) / (1.0 + L * 0.02) : 1.0;
    vec3 c = mix(tailCol, color, along * along);
    fragColor = vec4(c * core * trail, 1.0);
}
