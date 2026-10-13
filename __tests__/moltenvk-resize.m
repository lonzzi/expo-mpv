#import <Foundation/Foundation.h>
#include <assert.h>
#include "../ios/context_moltenvk.m.inc"

// Exercise the real backend control path without allocating a Vulkan device.
// Match ra_vk_ctx_resize's contract: it writes dimensions even on failure.
static int resize_count;
static bool fail_resize;
static int wakeup_count;
void vo_wakeup(struct vo *vo)
{
    wakeup_count++;
}
bool ra_vk_ctx_resize(struct ra_ctx *ctx, int width, int height)
{
    resize_count++;
    ctx->vo->dwidth = width;
    ctx->vo->dheight = height;
    return !fail_resize;
}

int main(void)
{
    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer layer];
        struct priv backend = {.layer = layer};
        struct vo output = {.dwidth = 1206, .dheight = 2622};
        struct ra_ctx ctx = {.vo = &output, .priv = &backend};
        ExpoMpvMetalSizeObserver *observer = [[ExpoMpvMetalSizeObserver alloc]
                                              initWithLayer:layer output:&output];
        int events = 0;

        // Regression: mpv starts in portrait, then UIKit presents landscape.
        layer.drawableSize = CGSizeMake(2622, 1206);
        [[NSNotificationCenter defaultCenter] postNotificationName:
            drawable_size_notification object:layer];
        assert(wakeup_count == 1);
        assert(moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL) == VO_TRUE);
        assert(output.dwidth == 2622 && output.dheight == 1206);
        assert(events == (VO_EVENT_RESIZE | VO_EVENT_EXPOSE));
        assert(resize_count == 1);

        // A woken paused player checks events; unchanged surfaces do no GPU work.
        events = 0;
        moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL);
        assert(events == 0 && resize_count == 1);

        // Rotation back, without reopening the file or changing playback state.
        layer.drawableSize = CGSizeMake(1206, 2622);
        moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL);
        assert(output.dwidth == 1206 && output.dheight == 2622);
        assert(events == (VO_EVENT_RESIZE | VO_EVENT_EXPOSE));

        // Ignore transient detached/empty view geometry.
        layer.drawableSize = CGSizeMake(0, 0);
        events = 0;
        moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL);
        assert(output.dwidth == 1206 && output.dheight == 2622 && events == 0);
        assert(resize_count == 2);

        // A failed swapchain resize must be retried on the following check.
        layer.drawableSize = CGSizeMake(1600, 900);
        fail_resize = true;
        moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL);
        assert(output.dwidth == 1206 && output.dheight == 2622 && events == 0);
        fail_resize = false;
        moltenvk_control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL);
        assert(output.dwidth == 1600 && output.dheight == 900);
        assert(events == (VO_EVENT_RESIZE | VO_EVENT_EXPOSE) && resize_count == 4);

        events = 0;
        assert(moltenvk_control(&ctx, &events, VOCTRL_PAUSE, NULL) == VO_NOTIMPL);
        assert(events == 0 && resize_count == 4);
        [observer invalidate];
        int previous_wakeups = wakeup_count;
        layer.drawableSize = CGSizeMake(1206, 2622);
        [[NSNotificationCenter defaultCenter] postNotificationName:
            drawable_size_notification object:layer];
        assert(wakeup_count == previous_wakeups);
        [observer release];
        puts("MoltenVK rotation, paused redraw, empty layout, and failure retry passed");
    }
    return 0;
}
