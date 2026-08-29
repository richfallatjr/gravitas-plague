#ifndef TURING_POCKETSPHINX_BRIDGE_H
#define TURING_POCKETSPHINX_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct trl_engine trl_engine_t;

typedef enum trl_status {
    TRL_STATUS_OK = 0,
    TRL_STATUS_INVALID_ARGUMENT = 1,
    TRL_STATUS_MODEL_LOAD_FAILED = 2,
    TRL_STATUS_DICTIONARY_FAILED = 3,
    TRL_STATUS_OOV = 4,
    TRL_STATUS_FIRST_PASS_FAILED = 5,
    TRL_STATUS_SECOND_PASS_FAILED = 6,
    TRL_STATUS_ALIGNMENT_MISSING = 7,
    TRL_STATUS_CANCELLED = 8,
    TRL_STATUS_DEADLINE_EXCEEDED = 9,
    TRL_STATUS_ALLOCATION_FAILED = 10,
    TRL_STATUS_ALLPHONE_FAILED = 11
} trl_status_t;

typedef enum trl_alignment_mode {
    TRL_ALIGNMENT_FORCED_TEXT = 1,
    TRL_ALIGNMENT_ALLPHONE = 2
} trl_alignment_mode_t;

typedef int (*trl_should_cancel_fn)(void *context);

typedef struct trl_phone_segment {
    int32_t start_frame;
    int32_t duration_frames;
    int32_t acoustic_score;
    char phone[16];
} trl_phone_segment_t;

typedef struct trl_alignment_result {
    trl_alignment_mode_t mode;
    int32_t alignment_frame_rate;
    int32_t searched_audio_frame_count;
    trl_phone_segment_t *segments;
    size_t segment_count;
} trl_alignment_result_t;

typedef struct trl_error {
    trl_status_t status;
    char message[256];
} trl_error_t;

trl_engine_t *trl_engine_create(
    const char *acoustic_model_path,
    const char *dictionary_path,
    const char *allphone_lm_path,
    trl_error_t *error
);

void trl_engine_destroy(trl_engine_t *engine);

trl_status_t trl_engine_add_pronunciation(
    trl_engine_t *engine,
    const char *word,
    const char *phones,
    int update_search,
    trl_error_t *error
);

int trl_engine_has_word(trl_engine_t *engine, const char *word);

trl_status_t trl_engine_force_align(
    trl_engine_t *engine,
    const char *normalized_words,
    const int16_t *pcm16,
    size_t sample_count,
    uint64_t deadline_monotonic_nanoseconds,
    trl_should_cancel_fn should_cancel,
    void *cancellation_context,
    trl_alignment_result_t *result,
    trl_error_t *error
);

trl_status_t trl_engine_allphone_align(
    trl_engine_t *engine,
    const int16_t *pcm16,
    size_t sample_count,
    uint64_t deadline_monotonic_nanoseconds,
    trl_should_cancel_fn should_cancel,
    void *cancellation_context,
    trl_alignment_result_t *result,
    trl_error_t *error
);

void trl_alignment_result_destroy(trl_alignment_result_t *result);

uint64_t trl_monotonic_nanoseconds(void);

const char *trl_pocketsphinx_version(void);

#ifdef __cplusplus
}
#endif

#endif
