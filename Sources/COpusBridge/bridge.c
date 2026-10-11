#include "COpusBridge.h"
int cassini_opus_lookahead(OpusEncoder *encoder) {
    int samples = 0;
    int status = opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(&samples));
    return status < 0 ? status : samples;
}
int cassini_opus_bitrate(OpusEncoder *encoder, int bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}
