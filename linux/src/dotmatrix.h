// Text on 5 x 7 dot-matrix displays (the dashboard's VFD and the console's neon plasma panel).

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace dotmatrix {

constexpr int rows = 7;
/// Glyph index of the musical note (after '~' in the font).
constexpr int note = 95;

/// The message as dot columns, one bit per row (bit 0 is the top row), with a blank column after each character.
/// Accents are dropped (é → e); characters the font doesn't have show as '?'.
std::vector<uint8_t> columns(const std::string& utf8);

/// Columns of a single glyph (0 = space ... 94 = '~', 95 = the note).
std::vector<uint8_t> glyphColumns(int glyph);

} // namespace dotmatrix
