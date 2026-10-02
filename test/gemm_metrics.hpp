#pragma once
#include <cstdint>

struct GemmTimings {
    double reset_us = 0, pack_us = 0, submit_us = 0, wait_us = 0, decode_us = 0;
    uint64_t steps = 0, output_tiles = 0;
};
