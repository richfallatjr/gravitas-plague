#include "TuringPocketSphinxBridge.h"

#include <stdio.h>
#include <stdlib.h>

static int
read_pcm(const char *path, int16_t **samples, size_t *sample_count)
{
    FILE *file = fopen(path, "rb");
    long byte_count;
    if (file == NULL || fseek(file, 0, SEEK_END) != 0)
        return 0;
    byte_count = ftell(file);
    if (byte_count <= 0 || byte_count % (long)sizeof(int16_t) != 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return 0;
    }
    *samples = malloc((size_t)byte_count);
    if (*samples == NULL) {
        fclose(file);
        return 0;
    }
    if (fread(*samples, 1, (size_t)byte_count, file) != (size_t)byte_count) {
        free(*samples);
        *samples = NULL;
        fclose(file);
        return 0;
    }
    fclose(file);
    *sample_count = (size_t)byte_count / sizeof(int16_t);
    return 1;
}

int
main(int argc, char **argv)
{
    trl_engine_t *engine;
    trl_error_t error = {0};
    trl_alignment_result_t result = {0};
    int16_t *samples = NULL;
    size_t sample_count = 0;
    trl_status_t status;

    if (argc != 5) {
        fprintf(stderr, "usage: %s HMM DICT PHONE_LM PCM_RAW\n", argv[0]);
        return 2;
    }
    if (!read_pcm(argv[4], &samples, &sample_count)) {
        fprintf(stderr, "unable to read PCM fixture\n");
        return 3;
    }
    engine = trl_engine_create(argv[1], argv[2], argv[3], &error);
    if (engine == NULL) {
        fprintf(stderr, "engine create failed: %d %s\n", error.status,
                error.message);
        free(samples);
        return 4;
    }
    status = trl_engine_force_align(
        engine,
        "go forward ten meters",
        samples,
        sample_count,
        trl_monotonic_nanoseconds() + 5000000000ULL,
        NULL,
        NULL,
        &result,
        &error
    );
    if (status != TRL_STATUS_OK || result.segment_count == 0) {
        fprintf(stderr, "force align failed: %d %s\n", error.status,
                error.message);
        trl_alignment_result_destroy(&result);
        trl_engine_destroy(engine);
        free(samples);
        return 5;
    }
    printf("PocketSphinx %s forced phones=%zu frames=%d\n",
           trl_pocketsphinx_version(), result.segment_count,
           result.searched_audio_frame_count);
    trl_alignment_result_destroy(&result);
    trl_engine_destroy(engine);
    free(samples);
    return 0;
}
