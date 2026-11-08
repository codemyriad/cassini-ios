#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct CassiniVAD CassiniVAD;
CassiniVAD *cassini_vad_create(const char *model, char *error, size_t capacity);
int cassini_vad_probability(CassiniVAD *, const float *, float *, char *, size_t);
void cassini_vad_reset(CassiniVAD *);
void cassini_vad_destroy(CassiniVAD *);
void cassini_whistle_fir(const float *, const float *, int64_t, int64_t, int64_t, float *, size_t);
