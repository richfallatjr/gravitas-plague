#include "TuringPocketSphinxBridge.h"

#include <pocketsphinx.h>
#include <pocketsphinx/alignment.h>
#include <pocketsphinx/search.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TRL_CHUNK_SAMPLES 1280U
#define TRL_ALIGNMENT_FRAME_RATE 100

struct trl_engine {
    ps_decoder_t *decoder;
    char *allphone_lm_path;
    int allphone_loaded;
};

static void
trl_clear_error(trl_error_t *error)
{
    if (error == NULL)
        return;
    memset(error, 0, sizeof(*error));
    error->status = TRL_STATUS_OK;
}

static trl_status_t
trl_fail(trl_error_t *error, trl_status_t status, const char *message)
{
    if (error != NULL) {
        error->status = status;
        snprintf(error->message, sizeof(error->message), "%s", message);
    }
    return status;
}

uint64_t
trl_monotonic_nanoseconds(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static int
trl_should_stop(
    uint64_t deadline,
    trl_should_cancel_fn should_cancel,
    void *context,
    trl_status_t *status
)
{
    if (should_cancel != NULL && should_cancel(context)) {
        *status = TRL_STATUS_CANCELLED;
        return 1;
    }
    if (deadline != 0 && trl_monotonic_nanoseconds() >= deadline) {
        *status = TRL_STATUS_DEADLINE_EXCEEDED;
        return 1;
    }
    return 0;
}

static trl_status_t
trl_decode(
    ps_decoder_t *decoder,
    const int16_t *pcm16,
    size_t sample_count,
    uint64_t deadline,
    trl_should_cancel_fn should_cancel,
    void *context,
    trl_status_t failure_status,
    trl_error_t *error
)
{
    trl_status_t status = TRL_STATUS_OK;
    size_t offset = 0;
    int started = 0;

    if (ps_start_utt(decoder) < 0)
        return trl_fail(error, failure_status, "ps_start_utt failed");
    started = 1;

    while (offset < sample_count) {
        size_t remaining;
        size_t chunk;
        int full_utterance;

        if (trl_should_stop(deadline, should_cancel, context, &status)) {
            ps_end_utt(decoder);
            return trl_fail(
                error,
                status,
                status == TRL_STATUS_CANCELLED ? "alignment cancelled" :
                    "alignment deadline exceeded"
            );
        }

        remaining = sample_count - offset;
        chunk = remaining < TRL_CHUNK_SAMPLES ? remaining : TRL_CHUNK_SAMPLES;
        full_utterance = chunk == remaining;
        if (ps_process_raw(
                decoder,
                pcm16 + offset,
                chunk,
                0,
                full_utterance
            ) < 0) {
            ps_end_utt(decoder);
            return trl_fail(error, failure_status, "ps_process_raw failed");
        }
        offset += chunk;
    }

    if (started && ps_end_utt(decoder) < 0)
        return trl_fail(error, failure_status, "ps_end_utt failed");
    return TRL_STATUS_OK;
}

static trl_status_t
trl_copy_alignment(
    ps_decoder_t *decoder,
    trl_alignment_mode_t mode,
    trl_alignment_result_t *result,
    trl_error_t *error
)
{
    ps_alignment_t *alignment;
    ps_alignment_iter_t *iterator;
    size_t count = 0;
    size_t index = 0;

    alignment = ps_get_alignment(decoder);
    if (alignment == NULL)
        return trl_fail(error, TRL_STATUS_ALIGNMENT_MISSING,
                        "ps_get_alignment returned null");

    for (iterator = ps_alignment_phones(alignment);
         iterator != NULL;
         iterator = ps_alignment_iter_next(iterator)) {
        ++count;
    }
    if (count == 0)
        return trl_fail(error, TRL_STATUS_ALIGNMENT_MISSING,
                        "phone alignment was empty");

    result->segments = calloc(count, sizeof(*result->segments));
    if (result->segments == NULL)
        return trl_fail(error, TRL_STATUS_ALLOCATION_FAILED,
                        "phone allocation failed");

    for (iterator = ps_alignment_phones(alignment);
         iterator != NULL;
         iterator = ps_alignment_iter_next(iterator)) {
        int start = 0;
        int duration = 0;
        const char *phone = ps_alignment_iter_name(iterator);
        int score = ps_alignment_iter_seg(iterator, &start, &duration);
        trl_phone_segment_t *segment = &result->segments[index++];
        segment->start_frame = (int32_t)start;
        segment->duration_frames = (int32_t)duration;
        segment->acoustic_score = (int32_t)score;
        snprintf(segment->phone, sizeof(segment->phone), "%s",
                 phone == NULL ? "" : phone);
    }

    result->mode = mode;
    result->alignment_frame_rate = TRL_ALIGNMENT_FRAME_RATE;
    result->searched_audio_frame_count = ps_get_n_frames(decoder);
    result->segment_count = count;
    return TRL_STATUS_OK;
}

static trl_status_t
trl_copy_allphone_segments(
    ps_decoder_t *decoder,
    trl_alignment_result_t *result,
    trl_error_t *error
)
{
    ps_seg_t *iterator;
    size_t count = 0;
    size_t index = 0;

    for (iterator = ps_seg_iter(decoder);
         iterator != NULL;
         iterator = ps_seg_next(iterator)) {
        ++count;
    }
    if (count == 0)
        return trl_fail(error, TRL_STATUS_ALLPHONE_FAILED,
                        "all-phone segmentation was empty");

    result->segments = calloc(count, sizeof(*result->segments));
    if (result->segments == NULL)
        return trl_fail(error, TRL_STATUS_ALLOCATION_FAILED,
                        "all-phone allocation failed");

    for (iterator = ps_seg_iter(decoder);
         iterator != NULL;
         iterator = ps_seg_next(iterator)) {
        int start = 0;
        int end = -1;
        const char *phone = ps_seg_word(iterator);
        trl_phone_segment_t *segment = &result->segments[index++];
        ps_seg_frames(iterator, &start, &end);
        segment->start_frame = (int32_t)start;
        segment->duration_frames = (int32_t)(end >= start ? end - start + 1 : 0);
        segment->acoustic_score = 0;
        snprintf(segment->phone, sizeof(segment->phone), "%s",
                 phone == NULL ? "" : phone);
    }

    result->mode = TRL_ALIGNMENT_ALLPHONE;
    result->alignment_frame_rate = TRL_ALIGNMENT_FRAME_RATE;
    result->searched_audio_frame_count = ps_get_n_frames(decoder);
    result->segment_count = count;
    return TRL_STATUS_OK;
}

trl_engine_t *
trl_engine_create(
    const char *acoustic_model_path,
    const char *dictionary_path,
    const char *allphone_lm_path,
    trl_error_t *error
)
{
    ps_config_t *config;
    trl_engine_t *engine;

    trl_clear_error(error);
    if (acoustic_model_path == NULL || dictionary_path == NULL ||
        allphone_lm_path == NULL || acoustic_model_path[0] == '\0' ||
        dictionary_path[0] == '\0' || allphone_lm_path[0] == '\0') {
        trl_fail(error, TRL_STATUS_INVALID_ARGUMENT, "invalid model path");
        return NULL;
    }

    config = ps_config_init(NULL);
    if (config == NULL) {
        trl_fail(error, TRL_STATUS_ALLOCATION_FAILED, "ps_config_init failed");
        return NULL;
    }
    if (ps_config_set_str(config, "hmm", acoustic_model_path) == NULL ||
        ps_config_set_str(config, "dict", dictionary_path) == NULL ||
        ps_config_set_int(config, "samprate", 16000) == NULL ||
        ps_config_set_int(config, "frate", TRL_ALIGNMENT_FRAME_RATE) == NULL ||
        ps_config_set_bool(config, "bestpath", 0) == NULL ||
        ps_config_set_str(config, "loglevel", "ERROR") == NULL) {
        ps_config_free(config);
        trl_fail(error, TRL_STATUS_MODEL_LOAD_FAILED,
                 "PocketSphinx configuration failed");
        return NULL;
    }

    engine = calloc(1, sizeof(*engine));
    if (engine == NULL) {
        ps_config_free(config);
        trl_fail(error, TRL_STATUS_ALLOCATION_FAILED, "engine allocation failed");
        return NULL;
    }
    engine->decoder = ps_init(config);
    ps_config_free(config);
    if (engine->decoder == NULL) {
        free(engine);
        trl_fail(error, TRL_STATUS_MODEL_LOAD_FAILED, "ps_init failed");
        return NULL;
    }
    if (ps_config_int(ps_get_config(engine->decoder), "samprate") != 16000 ||
        ps_config_int(ps_get_config(engine->decoder), "frate") !=
            TRL_ALIGNMENT_FRAME_RATE) {
        ps_free(engine->decoder);
        free(engine);
        trl_fail(error, TRL_STATUS_MODEL_LOAD_FAILED,
                 "PocketSphinx sample/frame-rate mismatch");
        return NULL;
    }
    engine->allphone_lm_path = strdup(allphone_lm_path);
    if (engine->allphone_lm_path == NULL) {
        ps_free(engine->decoder);
        free(engine);
        trl_fail(error, TRL_STATUS_ALLOCATION_FAILED,
                 "all-phone path allocation failed");
        return NULL;
    }
    return engine;
}

void
trl_engine_destroy(trl_engine_t *engine)
{
    if (engine == NULL)
        return;
    if (engine->decoder != NULL)
        ps_free(engine->decoder);
    free(engine->allphone_lm_path);
    memset(engine, 0, sizeof(*engine));
    free(engine);
}

trl_status_t
trl_engine_add_pronunciation(
    trl_engine_t *engine,
    const char *word,
    const char *phones,
    int update_search,
    trl_error_t *error
)
{
    trl_clear_error(error);
    if (engine == NULL || word == NULL || phones == NULL ||
        word[0] == '\0' || phones[0] == '\0')
        return trl_fail(error, TRL_STATUS_INVALID_ARGUMENT,
                        "invalid pronunciation");
    if (ps_add_word(engine->decoder, word, phones, update_search) < 0)
        return trl_fail(error, TRL_STATUS_DICTIONARY_FAILED,
                        "ps_add_word failed");
    return TRL_STATUS_OK;
}

int
trl_engine_has_word(trl_engine_t *engine, const char *word)
{
    char *pronunciation;
    if (engine == NULL || word == NULL || word[0] == '\0')
        return 0;
    pronunciation = ps_lookup_word(engine->decoder, word);
    if (pronunciation == NULL)
        return 0;
    free(pronunciation);
    return 1;
}

trl_status_t
trl_engine_force_align(
    trl_engine_t *engine,
    const char *normalized_words,
    const int16_t *pcm16,
    size_t sample_count,
    uint64_t deadline,
    trl_should_cancel_fn should_cancel,
    void *context,
    trl_alignment_result_t *result,
    trl_error_t *error
)
{
    trl_status_t status;
    trl_clear_error(error);
    if (result != NULL)
        memset(result, 0, sizeof(*result));
    if (engine == NULL || normalized_words == NULL ||
        normalized_words[0] == '\0' || pcm16 == NULL ||
        sample_count == 0 || result == NULL)
        return trl_fail(error, TRL_STATUS_INVALID_ARGUMENT,
                        "invalid forced-alignment input");

    if (ps_set_align_text(engine->decoder, normalized_words) < 0)
        return trl_fail(error, TRL_STATUS_OOV, "ps_set_align_text failed");
    status = trl_decode(engine->decoder, pcm16, sample_count, deadline,
                        should_cancel, context, TRL_STATUS_FIRST_PASS_FAILED,
                        error);
    if (status != TRL_STATUS_OK)
        return status;
    if (ps_get_hyp(engine->decoder, NULL) == NULL)
        return trl_fail(error, TRL_STATUS_FIRST_PASS_FAILED,
                        "first-pass hypothesis missing");
    if (ps_set_alignment(engine->decoder, NULL) < 0)
        return trl_fail(error, TRL_STATUS_SECOND_PASS_FAILED,
                        "ps_set_alignment failed");
    status = trl_decode(engine->decoder, pcm16, sample_count, deadline,
                        should_cancel, context, TRL_STATUS_SECOND_PASS_FAILED,
                        error);
    if (status != TRL_STATUS_OK)
        return status;
    return trl_copy_alignment(engine->decoder, TRL_ALIGNMENT_FORCED_TEXT,
                              result, error);
}

trl_status_t
trl_engine_allphone_align(
    trl_engine_t *engine,
    const int16_t *pcm16,
    size_t sample_count,
    uint64_t deadline,
    trl_should_cancel_fn should_cancel,
    void *context,
    trl_alignment_result_t *result,
    trl_error_t *error
)
{
    trl_status_t status;
    trl_clear_error(error);
    if (result != NULL)
        memset(result, 0, sizeof(*result));
    if (engine == NULL || pcm16 == NULL || sample_count == 0 || result == NULL)
        return trl_fail(error, TRL_STATUS_INVALID_ARGUMENT,
                        "invalid all-phone input");

    if (!engine->allphone_loaded) {
        if (ps_add_allphone_file(engine->decoder, "turing-allphone",
                                 engine->allphone_lm_path) < 0)
            return trl_fail(error, TRL_STATUS_ALLPHONE_FAILED,
                            "ps_add_allphone_file failed");
        engine->allphone_loaded = 1;
    }
    if (ps_activate_search(engine->decoder, "turing-allphone") < 0)
        return trl_fail(error, TRL_STATUS_ALLPHONE_FAILED,
                        "ps_activate_search failed");

    status = trl_decode(engine->decoder, pcm16, sample_count, deadline,
                        should_cancel, context, TRL_STATUS_ALLPHONE_FAILED,
                        error);
    if (status != TRL_STATUS_OK)
        return status;
    return trl_copy_allphone_segments(engine->decoder, result, error);
}

void
trl_alignment_result_destroy(trl_alignment_result_t *result)
{
    if (result == NULL)
        return;
    free(result->segments);
    memset(result, 0, sizeof(*result));
}

const char *
trl_pocketsphinx_version(void)
{
    return "5.1.1";
}
