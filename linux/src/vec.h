// Minimal float vectors (stand-ins for SIMD2/3/4<Float>).

#pragma once

#include <cmath>

struct V2 {
    float x = 0, y = 0;
    V2() = default;
    V2(float x, float y) : x(x), y(y) {}
    V2 operator+(V2 o) const { return {x + o.x, y + o.y}; }
    V2 operator-(V2 o) const { return {x - o.x, y - o.y}; }
    V2 operator*(float s) const { return {x * s, y * s}; }
    V2 operator-() const { return {-x, -y}; }
};

inline float length(V2 v) { return std::sqrt(v.x * v.x + v.y * v.y); }
inline V2 normalize(V2 v) {
    float l = length(v);
    return l > 0 ? v * (1 / l) : v;
}

struct V3 {
    float x = 0, y = 0, z = 0;
};

inline float length(V3 v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }

struct V4 {
    float x = 0, y = 0, z = 0, w = 0;
};
