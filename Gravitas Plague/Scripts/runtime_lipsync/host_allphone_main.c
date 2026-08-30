#include "TuringPocketSphinxBridge.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t u16le(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t u32le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int load_pcm16_wav(const char *path, int16_t **samples, size_t *count) {
    FILE *file = fopen(path, "rb");
    unsigned char header[12];
    int format_ok = 0;
    if (!file || fread(header, 1, sizeof(header), file) != sizeof(header) ||
        memcmp(header, "RIFF", 4) || memcmp(header + 8, "WAVE", 4)) {
        if (file) fclose(file);
        return 0;
    }
    while (!feof(file)) {
        unsigned char chunk[8];
        if (fread(chunk, 1, sizeof(chunk), file) != sizeof(chunk)) break;
        uint32_t size = u32le(chunk + 4);
        if (!memcmp(chunk, "fmt ", 4)) {
            unsigned char fmt[16];
            if (size < sizeof(fmt) || fread(fmt, 1, sizeof(fmt), file) != sizeof(fmt)) {
                fclose(file); return 0;
            }
            format_ok = u16le(fmt) == 1 && u16le(fmt + 2) == 1 &&
                        u32le(fmt + 4) == 16000 && u16le(fmt + 14) == 16;
            if (size > sizeof(fmt)) fseek(file, (long)(size - sizeof(fmt)), SEEK_CUR);
        } else if (!memcmp(chunk, "data", 4)) {
            if (!format_ok || size == 0 || (size & 1)) { fclose(file); return 0; }
            *samples = malloc(size);
            if (!*samples || fread(*samples, 1, size, file) != size) {
                free(*samples); fclose(file); return 0;
            }
            *count = size / sizeof(int16_t);
            fclose(file);
            return 1;
        } else {
            fseek(file, (long)size, SEEK_CUR);
        }
        if (size & 1) fseek(file, 1, SEEK_CUR);
    }
    fclose(file);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s acoustic dict phone-lm input.wav output.json\n", argv[0]);
        return 2;
    }
    int16_t *samples = NULL;
    size_t sample_count = 0;
    if (!load_pcm16_wav(argv[4], &samples, &sample_count)) {
        fprintf(stderr, "invalid 16 kHz mono PCM16 WAV\n");
        return 3;
    }
    trl_error_t error = {0};
    trl_engine_t *engine = trl_engine_create(argv[1], argv[2], argv[3], &error);
    if (!engine) {
        fprintf(stderr, "engine create failed: %s\n", error.message);
        free(samples);
        return 4;
    }
    trl_alignment_result_t result = {0};
    trl_status_t status = trl_engine_allphone_align(
        engine, samples, sample_count, UINT64_MAX, NULL, NULL, &result, &error
    );
    free(samples);
    if (status != TRL_STATUS_OK) {
        fprintf(stderr, "all-phone failed (%d): %s\n", status, error.message);
        trl_engine_destroy(engine);
        return 5;
    }
    FILE *output = fopen(argv[5], "wb");
    if (!output) {
        trl_alignment_result_destroy(&result);
        trl_engine_destroy(engine);
        return 6;
    }
    fprintf(output,
            "{\n  \"schemaVersion\": 1,\n  \"engine\": \"pocketsphinx\",\n"
            "  \"engineVersion\": \"%s\",\n  \"frameRate\": %u,\n  \"phones\": [\n",
            trl_pocketsphinx_version(), result.alignment_frame_rate);
    for (size_t i = 0; i < result.segment_count; ++i) {
        const trl_phone_segment_t *segment = &result.segments[i];
        fprintf(output,
                "    {\"phone\": \"%s\", \"startFrame\": %u, "
                "\"durationFrames\": %u, \"acousticScore\": %" PRId32 "}%s\n",
                segment->phone, segment->start_frame, segment->duration_frames,
                segment->acoustic_score, i + 1 == result.segment_count ? "" : ",");
    }
    fprintf(output, "  ]\n}\n");
    fclose(output);
    trl_alignment_result_destroy(&result);
    trl_engine_destroy(engine);
    return 0;
}
