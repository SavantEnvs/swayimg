// SPDX-License-Identifier: MIT
// Fuzz the text/uri-list parser (drag-and-drop / clipboard data from other
// Wayland clients).

#include "urilist.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    const std::string text(reinterpret_cast<const char*>(data), size);
    (void)urilist_parse(text);
    return 0;
}
