// SPDX-License-Identifier: MIT
// Fuzz swayimg's image loading path for an arbitrary file: FormatFactory
// tries every enabled decoder in priority order, then reads EXIF/IPTC/XMP
// metadata (exiv2) and fixes the orientation; the gallery then builds a
// thumbnail the same way FormatFactory::preview does.

#include "formatfactory.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>

#include <unistd.h>

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    // The ttf "decoder" renders a font specimen sized to the application
    // window (Application::get_ui()), which does not exist outside the
    // running viewer; with no UI it dereferences null on any valid font.
    if (ImageFormat* ttf = FormatFactory::self().get("ttf")) {
        ttf->enable = false;
    }
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    ImageFormat::Data src;
    src.data = data;
    src.size = size;

    const FormatFactory& factory = FormatFactory::self();
    const ImagePtr image = factory.decode(src);
    if (image) {
        // FormatFactory::preview only takes a file (it mmaps the entry's
        // path), so stage the input in a scratch file for it.
        const char* tmp = getenv("TMPDIR");
        std::string path = std::string(tmp && *tmp ? tmp : "/tmp") +
            "/swayimg_fuzz_XXXXXX";
        const int fd = mkstemp(path.data());
        if (fd != -1) {
            const bool ok = write(fd, data, size) == static_cast<ssize_t>(size);
            close(fd);
            if (ok) {
                const ImageEntryPtr entry = std::make_shared<ImageEntry>();
                entry->path = path;
                (void)factory.preview(entry, 64, false);
            }
            unlink(path.c_str());
        }
    }
    return 0;
}
