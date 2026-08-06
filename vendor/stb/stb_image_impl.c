#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
/* PNG for the symbol/glyph atlases the engine emits. JPEG for raster charts:
 * every community MBTiles measured is baseline JPEG, and without this stb
 * reports "unknown image type" for all of them. The other formats stay out —
 * nothing on either path reads BMP, TGA, PSD, GIF, HDR, PIC or PNM. */
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"
