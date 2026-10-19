#include <ass/ass.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Exercise libass's internal retained-frame/cache lifetime, not a public API.
void ass_frame_ref(ASS_Image *image);
void ass_frame_unref(ASS_Image *image);

static uint64_t sample(const ASS_Image *image)
{
    uint64_t hash = 1469598103934665603ULL;
    for (; image; image = image->next) {
        hash = (hash ^ image->color ^ image->dst_x ^ image->dst_y ^ image->w ^ image->h) * 1099511628211ULL;
        if (!image->w || !image->h)
            continue;
        for (int y = 0; y < image->h; y += image->h / 3 + 1)
            for (int x = 0; x < image->w; x += image->w / 7 + 1)
                hash = (hash ^ image->bitmap[y * image->stride + x]) * 1099511628211ULL;
    }
    return hash;
}

int main(int argc, char **argv)
{
    assert(argc == 7);
    int width = atoi(argv[4]), height = atoi(argv[5]);
    ASS_Library *library = ass_library_init();
    ASS_Renderer *renderer = ass_renderer_init(library);
    ass_set_frame_size(renderer, width, height);
    ass_set_storage_size(renderer, 1920, 1080);
    ass_set_fonts(renderer, argv[2], "Noto Sans CJK SC", ASS_FONTPROVIDER_NONE, NULL, 0);
    // Small limits force eviction while a previously returned frame is retained.
    ass_set_cache_limits(renderer, 10, 2);
    ASS_Track *track = ass_read_file(library, argv[1], "UTF-8");
    assert(track);
    ASS_Image *retained = NULL;
    uint64_t retained_hash = 0;
    char *cursor = argv[6], *end;
    int frame = 0;
    do {
        long long timestamp = strtoll(cursor, &end, 10);
        int changed;
        ASS_Image *images = ass_render_frame(renderer, track, timestamp, &changed);
        if (!retained && images) {
            retained = images;
            ass_frame_ref(retained);
            retained_hash = sample(retained);
        }
        if (retained)
            assert(sample(retained) == retained_hash);
        size_t size = (size_t)width * height * 3;
        unsigned char *pixels = malloc(size);
        assert(pixels);
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++) {
                unsigned char *p = pixels + ((size_t)y * width + x) * 3;
                p[0] = (x * 3 + y) & 255;
                p[1] = (x + y * 3) & 255;
                p[2] = (x + y) & 255;
            }
        for (ASS_Image *image = images; image; image = image->next) {
            unsigned alpha = 255 - (image->color & 255);
            unsigned color[3] = {image->color >> 24, (image->color >> 16) & 255, (image->color >> 8) & 255};
            for (int y = 0; y < image->h; y++) {
                int yy = y + image->dst_y;
                if (yy < 0 || yy >= height)
                    continue;
                for (int x = 0; x < image->w; x++) {
                    int xx = x + image->dst_x;
                    if (xx < 0 || xx >= width)
                        continue;
                    unsigned a = (image->bitmap[y * image->stride + x] * alpha + 127) / 255;
                    if (!a)
                        continue;
                    unsigned char *p = pixels + ((size_t)yy * width + xx) * 3;
                    for (int c = 0; c < 3; c++)
                        p[c] = (color[c] * a + p[c] * (255 - a) + 127) / 255;
                }
            }
        }
        char filename[4096];
        assert(snprintf(filename, sizeof(filename), "%s-%d.rgb", argv[3], frame++) < (int)sizeof(filename));
        FILE *out = fopen(filename, "wb");
        assert(out);
        assert(fwrite(pixels, 1, size, out) == size);
        fclose(out);
        free(pixels);
        cursor = *end ? end + 1 : end;
    } while (*cursor);
    // Frame references must survive both eviction and renderer reconfiguration.
    ass_set_frame_size(renderer, width / 2, height / 2);
    int changed;
    ass_render_frame(renderer, track, 500, &changed);
    ass_free_track(track);
    if (retained) {
        assert(sample(retained) == retained_hash);
        ass_frame_unref(retained);
    }
    ass_renderer_done(renderer);
    ass_library_done(library);
    printf("rendered=%d retained-frame=ok\n", frame);
    return 0;
}
