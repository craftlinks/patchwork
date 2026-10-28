/*
 * wav.c: read the header of a PCM WAV file.
 * A sample for the gallery's code page (c.zig).
 */
#include <stdint.h>
#include <string.h>
#include "wav.h"

#define FOURCC(a, b, c, d) \
    ((uint32_t)(a) | (b) << 8 | (c) << 16 | (d) << 24)

typedef struct {
    uint16_t channels;
    uint32_t rate;
    uint16_t bits;
    size_t frames;
} wav_info;

static const char *const errors[] = {
    "ok", "not RIFF", "no \"fmt \" chunk",
};

/* Reads little-endian words from a byte buffer. */
static inline uint32_t le32(const uint8_t *p) {
    return p[0] | p[1] << 8 | p[2] << 16 | p[3] << 24;
}

int wav_read(const uint8_t *data, size_t len,
             wav_info *out) {
    if (len < 44 || memcmp(data, "RIFF", 4)) return 1;
    for (size_t at = 12; at + 8 <= len; at += 8) {
        uint32_t id = le32(data + at);
        uint32_t size = le32(data + at + 4);
        if (id == FOURCC('f', 'm', 't', ' ')) {
            out->channels = data[at + 10];
            out->rate = le32(data + at + 12);
            out->bits = data[at + 22];
        }
        at += size + (size & 1u);
    }
    float seconds = out->frames / (float)out->rate;
    return seconds > 0.5f ? 0 : 2;
}
