#include <Libavformat/avformat.h>
#include <Libavcodec/packet.h>
#include <Libavutil/log.h>
#include <stdio.h>
#include <stdlib.h>

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

static void check_frame(const AVPacket *pkt, int second)
{
    check(pkt->pts == second * 90000, "PGS timestamps changed");
    check(pkt->size == 17 && pkt->data[0] == 0x16 && pkt->data[14] == 0x80,
          "A PGS packet must contain the complete presentation through END");
}

int main(int argc, char **argv)
{
    check(argc == 2, "Expected generated SUP fixture");
    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *context = NULL;
    check(avformat_open_input(&context, argv[1], NULL, NULL) == 0, "SUP open failed");
    check(avformat_find_stream_info(context, NULL) >= 0, "SUP stream discovery failed");
    check(context->streams[0]->codecpar->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE,
          "SUP must expose the PGS codec");
    AVPacket *pkt = av_packet_alloc();
    int count = 0;
    while (av_read_frame(context, pkt) >= 0) {
        check_frame(pkt, ++count);
        av_packet_unref(pkt);
    }
    check(count == 19, "SUP segments were lost, duplicated, or not merged");
    const int targets[] = {8, 3, 17, 1};
    for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        check(av_seek_frame(context, 0, targets[i] * 90000, AVSEEK_FLAG_BACKWARD) >= 0,
              "SUP seek failed");
        check(av_read_frame(context, pkt) >= 0, "No PGS frame after seek");
        check_frame(pkt, targets[i]);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    avformat_close_input(&context);
    puts("SUP packets, original timestamps and forward/backward seeks passed");
    return 0;
}
