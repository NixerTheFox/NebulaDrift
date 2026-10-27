// The cockpit canopy (G key): hull plating framing the window, with rivets, a rubber seal and stencils.
// The scratched glass itself is drawn in the shader so it can catch the light of what's outside.

#pragma once

#include <cairo.h>

/// Draws the frame into a y-down context covering `width` x `height`.
void drawCockpitFrame(cairo_t* c, double width, double height);
