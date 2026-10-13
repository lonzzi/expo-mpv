/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"

// This backend is compiled against the pinned mpv 0.41.0 headers. The rest
// of MPVKit stays unchanged; fail at compile time if a header layout drifts.
_Static_assert(offsetof(struct ra_ctx, priv) == 80, "ra_ctx ABI changed");
_Static_assert(sizeof(struct mpvk_ctx) == 48, "mpvk_ctx ABI changed");
_Static_assert(offsetof(struct vo, opts) == 224, "vo ABI changed");
_Static_assert(offsetof(struct mp_vo_opts, WinID) == 288, "vo options ABI changed");

// Used by the build script to verify every architecture, including cached builds.
const unsigned int expo_mpv_moltenvk_resize_v2 = 2;

static NSString *const drawable_size_notification = @"ExpoMpvMetalDrawableSizeDidChange";

// A paused VO can sleep indefinitely. Wake it when UIKit/MoltenVK changes the
// surface instead of polling on a timer. CAMetalLayer.drawableSize does not
// emit KVO notifications, so ExpoMpvView explicitly posts after its layout.
// Disconnect under the same lock as the
// callback so teardown cannot race a notification using the old vo pointer.
@interface ExpoMpvMetalSizeObserver : NSObject {
    CAMetalLayer *_layer;
    struct vo *_vo;
}
- (instancetype)initWithLayer:(CAMetalLayer *)layer output:(struct vo *)vo;
- (void)invalidate;
@end

@implementation ExpoMpvMetalSizeObserver
- (instancetype)initWithLayer:(CAMetalLayer *)layer output:(struct vo *)vo
{
    self = [super init];
    if (self) {
        _layer = [layer retain];
        _vo = vo;
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(surfaceSizeDidChange:)
            name:drawable_size_notification object:layer];
    }
    return self;
}

- (void)surfaceSizeDidChange:(NSNotification *)notification
{
    @synchronized(self) {
        if (_vo)
            vo_wakeup(_vo);
    }
}

- (void)invalidate
{
    CAMetalLayer *layer = nil;
    @synchronized(self) {
        _vo = NULL;
        layer = _layer;
        _layer = nil;
    }
    // Do not hold the callback lock while unregistering an in-flight delivery.
    if (layer) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
            name:drawable_size_notification object:layer];
        [layer release];
    }
}

- (void)dealloc
{
    [self invalidate];
    [super dealloc];
}
@end

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    ExpoMpvMetalSizeObserver *size_observer;
};

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    [p->size_observer invalidate];
    [p->size_observer release];
    p->size_observer = nil;
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    VkMetalSurfaceCreateInfoEXT info = {
         .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
         .pLayer = p->layer,
    };

    struct ra_ctx_params params = {0};

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    p->size_observer = [[ExpoMpvMetalSizeObserver alloc]
                       initWithLayer:p->layer output:ctx->vo];
    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    CGSize s = p->layer.drawableSize;
    return s.width > 1 && s.height > 1 &&
           ra_vk_ctx_resize(ctx, s.width, s.height);
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request != VOCTRL_CHECK_EVENTS)
        return VO_NOTIMPL;

    // Metal changes its surface size independently of mpv. Poll on the VO
    // thread so swapchain and viewport updates stay synchronized. The observer
    // also wakes a paused VO. Do not recreate the player or reload the source.
    struct priv *p = ctx->priv;
    CGSize s = p->layer.drawableSize;
    if (s.width > 1 && s.height > 1 &&
        ((int)s.width != ctx->vo->dwidth || (int)s.height != ctx->vo->dheight)) {
        int previous_width = ctx->vo->dwidth;
        int previous_height = ctx->vo->dheight;
        if (ra_vk_ctx_resize(ctx, s.width, s.height)) {
            *events |= VO_EVENT_RESIZE | VO_EVENT_EXPOSE;
        } else {
            // ra_vk_ctx_resize also writes dwidth/dheight on failure. Restore
            // them so the next event check retries the pending resize.
            ctx->vo->dwidth = previous_width;
            ctx->vo->dheight = previous_height;
        }
    }
    return VO_TRUE;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
