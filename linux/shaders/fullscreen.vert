// One triangle covering the screen (port of bgVertex in Sources/Shaders.metal).

out vec2 ndc;

void main() {
    const vec2 p[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    gl_Position = vec4(p[gl_VertexID], 0.0, 1.0);
    ndc = p[gl_VertexID];
}
