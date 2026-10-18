// SUP stores individual PGS segments. Deliver complete display sets so mpv's
// subtitle packet cache and seek/redecode lifecycle operate on whole captions.
#include "libavcodec/bsf.h"

#define sup_read_header sup_read_segment_header
#define sup_read_packet sup_read_segment
#define ff_sup_demuxer ff_sup_segment_demuxer
#include "libavformat/supdec.c"
#undef ff_sup_demuxer
#undef sup_read_packet
#undef sup_read_header

typedef struct SUPFrameContext {
    AVBSFContext *merge;
    AVPacket *segment;
} SUPFrameContext;

static int sup_read_header(AVFormatContext *s)
{
    SUPFrameContext *ctx = s->priv_data;
    int ret = sup_read_segment_header(s);
    if (ret < 0)
        return ret;
    const AVBitStreamFilter *filter = av_bsf_get_by_name("pgs_frame_merge");
    if (!filter)
        return AVERROR_BSF_NOT_FOUND;
    if ((ret = av_bsf_alloc(filter, &ctx->merge)) < 0)
        return ret;
    if ((ret = avcodec_parameters_copy(ctx->merge->par_in, s->streams[0]->codecpar)) < 0)
        return ret;
    ctx->merge->time_base_in = s->streams[0]->time_base;
    if ((ret = av_bsf_init(ctx->merge)) < 0)
        return ret;
    ctx->segment = av_packet_alloc();
    return ctx->segment ? 0 : AVERROR(ENOMEM);
}

static int sup_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    SUPFrameContext *ctx = s->priv_data;
    while (1) {
        int ret = av_bsf_receive_packet(ctx->merge, pkt);
        if (ret != AVERROR(EAGAIN))
            return ret;
        ret = sup_read_segment(s, ctx->segment);
        if (ret < 0 && ret != AVERROR_EOF)
            return ret;
        ret = av_bsf_send_packet(ctx->merge, ret == AVERROR_EOF ? NULL : ctx->segment);
        if (ret < 0)
            return ret;
    }
}

static int sup_read_seek(AVFormatContext *s, int stream, int64_t timestamp, int flags)
{
    SUPFrameContext *ctx = s->priv_data;
    av_bsf_flush(ctx->merge);
    av_packet_unref(ctx->segment);
    return AVERROR(ENOSYS); // Use libavformat's generic index after flushing.
}

static int sup_read_close(AVFormatContext *s)
{
    SUPFrameContext *ctx = s->priv_data;
    av_packet_free(&ctx->segment);
    av_bsf_free(&ctx->merge);
    return 0;
}

const FFInputFormat ff_sup_demuxer = {
    .p.name         = "sup",
    .p.long_name    = NULL_IF_CONFIG_SMALL("raw HDMV Presentation Graphic Stream subtitles"),
    .p.extensions   = "sup",
    .p.mime_type    = "application/x-pgs",
    .p.flags        = AVFMT_GENERIC_INDEX,
    .flags_internal = FF_INFMT_FLAG_INIT_CLEANUP,
    .priv_data_size = sizeof(SUPFrameContext),
    .read_probe     = sup_probe,
    .read_header    = sup_read_header,
    .read_packet    = sup_read_packet,
    .read_seek      = sup_read_seek,
    .read_close     = sup_read_close,
};
