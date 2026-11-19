// SPDX-License-Identifier: MIT
// Fuzz one swayimg decoder through its public ImageFormat interface.
// Built once per format with -DFUZZ_FORMAT="<name>" (the name the decoder
// registers with FormatFactory, e.g. "bmp", "tga", "jpg").
//
// Every decoder registers itself with FormatFactory from a static object, so
// the factory is the entry point the application uses; asking it for one
// decoder by name keeps a low-priority decoder (tga has no signature and runs
// last) from being shadowed by the formats tried before it.

#include "formatfactory.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>

#ifndef FUZZ_FORMAT
#error "FUZZ_FORMAT must name the decoder"
#endif

static ImageFormat* format;

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    format = FormatFactory::self().get(FUZZ_FORMAT);
    if (!format) {
        // the decoder was not compiled in: a build bug, not an input bug
        abort();
    }
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    ImageFormat::Data src;
    src.data = data;
    src.size = size;

    ImagePtr image = format->decode(src);
    if (image) {
        // the viewer applies EXIF orientation to every decoded image
        format->fix_orientation(image);
    }
#ifdef FUZZ_PREVIEW
    // gallery thumbnail path (embedded EXIF thumbnail for JPEG)
    (void)format->preview(src, 64, true);
#endif
    return 0;
}
