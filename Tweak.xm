/*
 * 26LockDim 0.2.12
 *
 * Lock Screen notification background dimming with hardware-accurate sticky clock.
 * Compatible with iOS 15 - 16.5+, RootHide / rootless jailbreaks.
 * Seamless integration with dynamic clock tweaks including liquidglass / liquidass.
 *
 * v0.2.1 changes:
 * - Top-anchored sticky clock: locks the TOP edge of the clock view rigidly at resting
 *   position on screen, completely invariant to internal font height scaling below.
 * - Removed transform modification from layoutSubviews, eliminating 120Hz infinite layout loops.
 * - Restored and perfected dimming: calibrated to 150pt travel with direct linear ramp and
 *   exponential decay smoothing (no deadzone, activates immediately from first pixel).
 * - Removed aggressive safety marker lockout and dangerous NSHashTable/dyld hooks.
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>

#define LD_SETTINGS @"/var/mobile/26LockDim.plist"
#define LD_LOGFILE  "/var/mobile/26LockDim.log"
#define LD_SAFEFILE @"/var/mobile/Media/26LockDim.safe"

static BOOL   g_enabled              = YES;
static BOOL   g_debug                = YES;
static BOOL   g_stickyClock          = YES;
static float  g_maxAlpha             = 0.48f;
static BOOL   g_roundBatteryEnabled  = YES;
static BOOL   g_noBatteryGapEnabled  = YES;
static double g_batteryOutsideRadius = 3.0;
static double g_batteryInsideRadius  = 2.0;

static IMP g_origBatteryOutsideRadius = NULL;
static IMP g_origBatteryInsideRadius  = NULL;
static IMP g_origBatteryLineWidthAndInterspace = NULL;
static IMP g_origBatteryLineWidthAndInterspaceClass = NULL;
static IMP g_origBatteryLayoutSubviews = NULL;

static __weak UIViewController *g_coverController;
static __weak UIView *g_coverRoot;
static __weak UIScrollView *g_notificationScroll;
static __weak UIView *g_clockContainerView;
static __weak UIView *g_clockTimeView;
static __weak UIView *g_liquidGlassView;
static __weak UIView *g_liquidPullBlurView;
static __weak UIView *g_overlayHost;
static __weak UIView *g_maskedView;
static UIView *g_overlay;
static CAGradientLayer *g_scrollGradientMask;
static CADisplayLink *g_displayLink;
static NSObject *g_displayTarget;

static BOOL     g_active;
static BOOL     g_safeMode;
static BOOL     g_baselineReady;
static CGRect   g_baseRect;
static CGFloat  g_baseOffsetY;
static CGSize   g_baseRootSize;
static CGFloat  g_baseClockTopOnScreen;
static CGFloat  g_baseClockBottomOnScreen;
static BOOL     g_clockBaselineReady;
static CGFloat  g_currentClockTranslateY;
static CGFloat  g_alpha;
static CGFloat  g_progress;
static CFTimeInterval g_lastFrame;
static CFTimeInterval g_lastLog;

static float ld_clampf(float value, float lo, float hi) {
    return fminf(fmaxf(value, lo), hi);
}

static float ld_smoothstep(float x) {
    x = ld_clampf(x, 0.0f, 1.0f);
    return x * x * (3.0f - 2.0f * x);
}

static void ld_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ld_log(NSString *format, ...) {
    if (!g_debug) return;

    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSLog(@"[26LockDim] %@", message);

    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:@LD_LOGFILE error:NULL];
        if (attrs && [attrs fileSize] > 200 * 1024)
            [fm removeItemAtPath:@LD_LOGFILE error:NULL];

        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        FILE *file = fopen(LD_LOGFILE, "a");
        if (file) {
            fputs([line UTF8String], file);
            fclose(file);
        }
    }
}

static void ld_readSettings(void) {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:LD_SETTINGS];
    if (!settings) return;

    id value = settings[@"enabled"];
    if ([value isKindOfClass:[NSNumber class]]) g_enabled = [value boolValue];

    value = settings[@"debug"];
    if ([value isKindOfClass:[NSNumber class]]) g_debug = [value boolValue];

    value = settings[@"stickyClock"];
    if ([value isKindOfClass:[NSNumber class]]) g_stickyClock = [value boolValue];

    value = settings[@"maxAlpha"];
    if ([value isKindOfClass:[NSNumber class]])
        g_maxAlpha = ld_clampf([value floatValue], 0.0f, 0.85f);

    value = settings[@"roundBatteryEnabled"];
    if ([value isKindOfClass:[NSNumber class]])
        g_roundBatteryEnabled = [value boolValue];

    value = settings[@"batteryOutsideRadius"];
    if ([value isKindOfClass:[NSNumber class]])
        g_batteryOutsideRadius = [value doubleValue];

    value = settings[@"batteryInsideRadius"];
    if ([value isKindOfClass:[NSNumber class]])
        g_batteryInsideRadius = [value doubleValue];

    value = settings[@"noBatteryGapEnabled"];
    if ([value isKindOfClass:[NSNumber class]])
        g_noBatteryGapEnabled = [value boolValue];
}

static void ld_clearSafetyMarker(void) {
    [[NSFileManager defaultManager] removeItemAtPath:LD_SAFEFILE error:NULL];
    g_safeMode = NO;
}

static void ld_armSafetyWindow(NSString *reason) {
    // Disabled to prevent false-positive lockouts
}

static void ld_checkSafetyMarker(void) {
    // Automatically clear any stale safety marker left from prior versions
    [[NSFileManager defaultManager] removeItemAtPath:LD_SAFEFILE error:NULL];
    g_safeMode = NO;
}

static NSString *ld_className(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static BOOL ld_isDescendant(UIView *view, UIView *root) {
    if (!view || !root) return NO;
    if (view == root) return YES;
    return [view isDescendantOfView:root];
}

/* Locate the actual ProminentTimeView (clock digits on iOS 16) */
static UIView *ld_findClockTimeView(UIView *view, int depth) {
    if (!view || depth > 20) return nil;
    NSString *name = ld_className(view);
    if ([name isEqualToString:@"CSProminentTimeView"] ||
        [name containsString:@"ProminentTime"]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = ld_findClockTimeView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

/* Fallback for iOS 15 legacy Lock Screen date view */
static UIView *ld_findLegacyClockView(UIView *view, int depth) {
    if (!view || depth > 20) return nil;
    NSString *name = ld_className(view);
    if ([name containsString:@"LockScreenDateView"]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = ld_findLegacyClockView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

/* Find the container view that wraps the clock (e.g. CSProminentDisplayView) */
static UIView *ld_findClockContainer(UIView *timeView, UIView *root) {
    if (!timeView) return nil;
    UIView *cur = timeView.superview;
    while (cur && cur != root) {
        NSString *name = ld_className(cur);
        if ([name containsString:@"ProminentDisplay"] ||
            [name containsString:@"LockScreenDateView"]) {
            return cur;
        }
        cur = cur.superview;
    }
    if (timeView.superview && timeView.superview != root) {
        return timeView.superview;
    }
    return timeView;
}

/* Data holder for LiquidGlass visual components */
@interface LDLiquidGlassContext : NSObject
@property (nonatomic, weak) UIView *glassView;     // LGLiveBackdropView (active when idle)
@property (nonatomic, weak) UIView *pullBlurView;  // LGSettingsLowBlurView (active during pull/scroll)
@property (nonatomic, weak) UIView *glyphMaskView; // View hosting the vector digit layers
@property (nonatomic, weak) UIView *activeView;    // The view currently responsible for rendering
@end

@implementation LDLiquidGlassContext
@end

static void ld_searchLiquidViewsRecursive(UIView *view, LDLiquidGlassContext *ctx, int depth) {
    if (!view || depth > 16) return;

    NSString *name = ld_className(view);
    if ([name containsString:@"LGLiveBackdropView"] || [name containsString:@"LiveBackdropView"]) {
        ctx.glassView = view;
        if (view.maskView) ctx.glyphMaskView = view.maskView;
    } else if ([name containsString:@"LGSettingsLowBlurView"] || [name containsString:@"LowBlurView"]) {
        ctx.pullBlurView = view;
        if (view.maskView) ctx.glyphMaskView = view.maskView;
    } else if (view.maskView) {
        for (CALayer *layer in view.maskView.layer.sublayers) {
            if ([layer isKindOfClass:[CAShapeLayer class]]) {
                CAShapeLayer *sl = (CAShapeLayer *)layer;
                if (sl.path) {
                    ctx.glyphMaskView = view.maskView;
                    break;
                }
            }
        }
    }

    for (UIView *sub in view.subviews) {
        ld_searchLiquidViewsRecursive(sub, ctx, depth + 1);
    }
}

static LDLiquidGlassContext *ld_getLiquidGlassContext(UIView *container, UIView *timeView, UIView *root) {
    LDLiquidGlassContext *ctx = [LDLiquidGlassContext new];

    if (container) ld_searchLiquidViewsRecursive(container, ctx, 0);
    if ((!ctx.glassView || !ctx.pullBlurView) && timeView) {
        ld_searchLiquidViewsRecursive(timeView, ctx, 0);
    }
    if ((!ctx.glassView || !ctx.pullBlurView) && root) {
        ld_searchLiquidViewsRecursive(root, ctx, 0);
    }
    if ((!ctx.glassView || !ctx.pullBlurView) && timeView && timeView.window) {
        ld_searchLiquidViewsRecursive(timeView.window, ctx, 0);
    }

    // Determine currently active rendering component:
    // When scrolling begins, liquidass sets glassView.hidden = YES and pullBlurView.hidden = NO.
    if (ctx.pullBlurView && !ctx.pullBlurView.hidden && ctx.pullBlurView.alpha > 0.01) {
        ctx.activeView = ctx.pullBlurView;
    } else if (ctx.glassView && !ctx.glassView.hidden && ctx.glassView.alpha > 0.01) {
        ctx.activeView = ctx.glassView;
    } else if (ctx.pullBlurView && ctx.pullBlurView.maskView) {
        ctx.activeView = ctx.pullBlurView;
    } else if (ctx.glassView) {
        ctx.activeView = ctx.glassView;
    }

    if (ctx.activeView && ctx.activeView.maskView) {
        ctx.glyphMaskView = ctx.activeView.maskView;
    }

    return ctx;
}

/* Extract bounding box of glyphs from liquidglass mask */
static CGRect ld_glyphBoundsForView(UIView *view, UIView *fallbackMask) {
    UIView *mask = (view && view.maskView) ? view.maskView : fallbackMask;
    if (mask) {
        for (CALayer *layer in mask.layer.sublayers) {
            if ([layer isKindOfClass:[CAShapeLayer class]]) {
                CAShapeLayer *sl = (CAShapeLayer *)layer;
                if (sl.path) {
                    CGRect box = CGPathGetBoundingBox(sl.path);
                    if (!CGRectIsEmpty(box) && !CGRectIsNull(box) && box.size.height > 10.0) {
                        return box;
                    }
                }
            }
        }
    }
    return CGRectZero;
}

/* Accurately measure the full on-screen rect of the clock digits */
static CGRect ld_clockScreenRect(UIView *timeView, UIView *container, UIView *root) {
    LDLiquidGlassContext *liq = ld_getLiquidGlassContext(container, timeView, root);
    UIView *active = liq.activeView;

    if (active && active.window) {
        CGRect box = ld_glyphBoundsForView(active, liq.glyphMaskView);
        if (!CGRectIsEmpty(box) && box.size.height > 10.0) {
            @try {
                CGRect sRect = [active convertRect:box toView:nil];
                if (sRect.origin.y > 10.0 && sRect.size.height > 10.0) {
                    return sRect;
                }
            } @catch (NSException *e) {}
        }
        @try {
            CGRect sRect = [active convertRect:active.bounds toView:nil];
            if (sRect.origin.y > 10.0 && sRect.size.height > 10.0) {
                return sRect;
            }
        } @catch (NSException *e) {}
    }

    if (timeView && timeView.window) {
        @try {
            CGRect sRect = [timeView convertRect:timeView.bounds toView:nil];
            if (sRect.origin.y > 10.0 && sRect.size.height > 10.0) {
                return sRect;
            }
        } @catch (NSException *e) {}
    }

    return CGRectZero;
}

static CGFloat ld_clockTopOnScreen(UIView *timeView, UIView *container, UIView *root) {
    if (timeView && timeView.window) {
        @try {
            CGRect sRect = [timeView convertRect:timeView.bounds toView:nil];
            if (sRect.origin.y > 10.0) return sRect.origin.y;
        } @catch (NSException *e) {}
    }
    if (container && container.window) {
        @try {
            CGRect sRect = [container convertRect:container.bounds toView:nil];
            if (sRect.origin.y > 10.0) return sRect.origin.y;
        } @catch (NSException *e) {}
    }
    LDLiquidGlassContext *liq = ld_getLiquidGlassContext(container, timeView, root);
    UIView *active = liq.activeView;
    if (active && active.window) {
        @try {
            CGRect sRect = [active convertRect:active.bounds toView:nil];
            if (sRect.origin.y > 10.0) return sRect.origin.y;
        } @catch (NSException *e) {}
    }
    return 0.0;
}

static CGFloat ld_clockBottomOnScreen(UIView *timeView, UIView *container, UIView *root) {
    if (timeView && timeView.window) {
        @try {
            CGRect sRect = [timeView convertRect:timeView.bounds toView:nil];
            if (sRect.origin.y > 10.0) return CGRectGetMaxY(sRect);
        } @catch (NSException *e) {}
    }
    if (container && container.window) {
        @try {
            CGRect sRect = [container convertRect:container.bounds toView:nil];
            if (sRect.origin.y > 10.0) return CGRectGetMaxY(sRect);
        } @catch (NSException *e) {}
    }
    return 0.0;
}

/* Find both timeView and its containerView reliably across iOS 15 & 16 */
static void ld_locateClockViews(UIView *root, UIView **outContainer, UIView **outTime) {
    UIView *timeView = nil;
    UIView *container = nil;

    // 1. Search root view tree
    if (root) {
        timeView = ld_findClockTimeView(root, 0);
    }
    // 2. Search root.window if not found directly under root
    if (!timeView && root && root.window) {
        timeView = ld_findClockTimeView(root.window, 0);
    }
    // 3. Search all application windows
    if (!timeView) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            timeView = ld_findClockTimeView(w, 0);
            if (timeView) break;
        }
    }
    // 4. Legacy iOS 15 fallback
    if (!timeView) {
        if (root) timeView = ld_findLegacyClockView(root, 0);
        if (!timeView && root && root.window) timeView = ld_findLegacyClockView(root.window, 0);
    }

    if (timeView) {
        container = ld_findClockContainer(timeView, root);
    }

    if (outTime) *outTime = timeView;
    if (outContainer) *outContainer = container;
}

/* Find the scroll surface that represents the Lock Screen notification list. */
static void ld_findNotificationScroll(UIView *view, UIView *root,
                                      UIScrollView **best, CGFloat *bestScore,
                                      int depth) {
    if (!view || !root || depth > 14) return;

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGRect rect = CGRectZero;
        @try {
            rect = [scroll convertRect:scroll.bounds toView:root];
        } @catch (NSException *exception) {
            rect = CGRectZero;
        }

        CGFloat rootArea = fmax(1.0, root.bounds.size.width * root.bounds.size.height);
        CGFloat area = fmax(0.0, rect.size.width * rect.size.height);
        NSString *name = [ld_className(scroll) lowercaseString];
        BOOL namedNotification = [name containsString:@"notification"] ||
                                 [name containsString:@"combinedlist"] ||
                                 [name containsString:@"bulletin"] ||
                                 [name containsString:@"coverlist"];
        BOOL blocked = [name containsString:@"widget"] ||
                       [name containsString:@"media"] ||
                       [name containsString:@"keyboard"] ||
                       [name containsString:@"quickaction"];
        BOOL verticallyScrollable = scroll.contentSize.height >
                                     scroll.bounds.size.height + 10.0;
        BOOL screenLike = rect.size.width >= root.bounds.size.width * 0.42 &&
                          rect.size.height >= root.bounds.size.height * 0.18;

        if (!blocked && screenLike && (namedNotification || verticallyScrollable)) {
            CGFloat score = area / rootArea * 50.0;
            if (namedNotification) score += 100.0;
            if (verticallyScrollable) score += 25.0;
            if (rect.size.width >= root.bounds.size.width * 0.75) score += 10.0;
            if (rect.size.height >= root.bounds.size.height * 0.45) score += 10.0;
            if (score > *bestScore) {
                *best = scroll;
                *bestScore = score;
            }
        }
    }

    for (UIView *subview in view.subviews)
        ld_findNotificationScroll(subview, root, best, bestScore, depth + 1);
}

static UIScrollView *ld_notificationScrollForRoot(UIView *root) {
    UIScrollView *best = nil;
    CGFloat bestScore = -1.0;
    ld_findNotificationScroll(root, root, &best, &bestScore, 0);
    return best;
}

static BOOL ld_hasNotificationSubviews(UIView *view, int depth) {
    if (!view || depth > 3) return NO;
    for (UIView *sub in view.subviews) {
        NSString *name = [ld_className(sub) lowercaseString];
        if ([name containsString:@"notification"] ||
            [name containsString:@"cell"] ||
            [name containsString:@"stack"] ||
            [name containsString:@"list"] ||
            [name containsString:@"bulletin"]) {
            if (sub.bounds.size.width > 90.0 && sub.bounds.size.height > 20.0)
                return YES;
        }
        if (ld_hasNotificationSubviews(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL ld_scrollHasNotifications(UIScrollView *scroll) {
    if (!scroll) return NO;
    if (scroll.contentSize.height > scroll.bounds.size.height + 8.0)
        return YES;
    return ld_hasNotificationSubviews(scroll, 0);
}

static void ld_captureBaseline(UIScrollView *scroll, UIView *root) {
    if (!scroll || !root) return;

    @try {
        g_baseRect = [scroll convertRect:scroll.bounds toView:root];
    } @catch (NSException *exception) {
        g_baseRect = scroll.frame;
    }

    g_baseOffsetY = scroll.contentOffset.y;
    g_baseRootSize = root.bounds.size;
    g_baselineReady = YES;
    ld_log(@"captured baseline scroll=%@ rect=%@ offset=%.1f",
           ld_className(scroll), NSStringFromCGRect(g_baseRect), g_baseOffsetY);
}

static UIView *ld_findInsertionBranch(UIView *root, UIView *child) {
    if (!root || !child) return nil;
    UIView *cur = child;
    while (cur && cur.superview && cur.superview != root)
        cur = cur.superview;
    return cur;
}

static void ld_attachOverlay(UIView *root, UIScrollView *scroll) {
    if (!root) return;

    UIView *host = root;
    NSInteger insertIndex = -1;

    UIView *scrollBranch = ld_findInsertionBranch(root, scroll);
    if (scrollBranch) {
        NSInteger branchIndex = [root.subviews indexOfObject:scrollBranch];
        if (branchIndex != NSNotFound) {
            host = root;
            insertIndex = branchIndex;
        }
    }

    if (host == root && insertIndex < 0) {
        UIView *timeView = nil;
        UIView *containerView = nil;
        ld_locateClockViews(root, &containerView, &timeView);
        UIView *clockBranch = ld_findInsertionBranch(root, containerView ?: timeView);
        if (clockBranch) {
            NSInteger branchIndex = [root.subviews indexOfObject:clockBranch];
            if (branchIndex != NSNotFound) {
                host = root;
                insertIndex = branchIndex;
            }
        }
    }

    if (!g_overlay) {
        g_overlay = [[UIView alloc] initWithFrame:host.bounds];
        g_overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight;
        g_overlay.backgroundColor = [UIColor blackColor];
        g_overlay.userInteractionEnabled = NO;
        g_overlay.alpha = 0.0f;
        g_overlay.hidden = YES;
    }

    if (g_overlay.superview != host) {
        [g_overlay removeFromSuperview];
        if (insertIndex >= 0 && insertIndex <= (NSInteger)host.subviews.count)
            [host insertSubview:g_overlay atIndex:(NSUInteger)insertIndex];
        else
            [host addSubview:g_overlay];
        g_overlayHost = host;
        ld_log(@"attached overlay to host=%@ at index=%ld",
               ld_className(host), (long)insertIndex);
    } else {
        g_overlay.frame = host.bounds;
        if (insertIndex >= 0) {
            NSInteger curIndex = [host.subviews indexOfObject:g_overlay];
            if (curIndex != NSNotFound && curIndex > insertIndex)
                [host insertSubview:g_overlay atIndex:(NSUInteger)insertIndex];
        }
    }
}

static void ld_scanPanProgress(UIView *view, UIView *root, CGFloat *outMax, int depth) {
    if (!view || depth > 10) return;

    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) continue;
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gr;
        if (pan.state != UIGestureRecognizerStateChanged &&
            pan.state != UIGestureRecognizerStateBegan) continue;

        CGPoint trans = CGPointZero;
        @try {
            trans = [pan translationInView:root];
        } @catch (NSException *e) {
            continue;
        }

        if (trans.y < -0.5) {
            CGFloat panProgress = ld_clampf((float)(-trans.y / 150.0), 0.0f, 1.0f);
            if (panProgress > *outMax) *outMax = panProgress;
        }
    }

    for (UIView *sub in view.subviews)
        ld_scanPanProgress(sub, root, outMax, depth + 1);
}

static CGFloat ld_progressForScroll(UIScrollView *scroll, UIView *root) {
    if (!scroll || !root || !g_baselineReady) return 0.0f;

    if (fabs(root.bounds.size.width - g_baseRootSize.width) > 30.0 ||
        fabs(root.bounds.size.height - g_baseRootSize.height) > 30.0) {
        ld_captureBaseline(scroll, root);
        return 0.0f;
    }

    CGRect currentRect = CGRectZero;
    @try {
        currentRect = [scroll convertRect:scroll.bounds toView:root];
    } @catch (NSException *exception) {
        currentRect = scroll.frame;
    }

    // 150pt travel distance matches the natural physical gap from resting notifications to clock foot
    CGFloat travelDistance = 150.0f;

    // 1. Upward frame movement
    CGFloat upwardMove = fmax(0.0, g_baseRect.origin.y - currentRect.origin.y);
    CGFloat pFrame = upwardMove > 0.5
        ? ld_clampf((float)(upwardMove / travelDistance), 0.0f, 1.0f)
        : 0.0f;

    // 2. Upward scroll content offset
    CGFloat offsetDelta = fabs(scroll.contentOffset.y - g_baseOffsetY);
    CGFloat pOffset = offsetDelta > 0.5
        ? ld_clampf((float)(offsetDelta / travelDistance), 0.0f, 1.0f)
        : 0.0f;

    // 3. Pan gesture drag
    CGFloat pPan = 0.0f;
    ld_scanPanProgress(root, root, &pPan, 0);

    return fmaxf(pFrame, fmaxf(pOffset, pPan));
}

static void ld_setActive(BOOL active) {
    g_active = active;
    if (!active) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        if (g_maskedView) {
            g_maskedView.layer.mask = nil;
            g_maskedView = nil;
        }
        g_scrollGradientMask = nil;

        if (g_clockTimeView) {
            @try {
                g_clockTimeView.transform = CGAffineTransformIdentity;
            } @catch (NSException *e) {}
            g_clockTimeView = nil;
        }
        if (g_clockContainerView) {
            @try {
                g_clockContainerView.transform = CGAffineTransformIdentity;
            } @catch (NSException *e) {}
            g_clockContainerView = nil;
        }
        if (g_liquidGlassView) {
            @try {
                g_liquidGlassView.transform = CGAffineTransformIdentity;
            } @catch (NSException *e) {}
            g_liquidGlassView = nil;
        }
        if (g_liquidPullBlurView) {
            @try {
                g_liquidPullBlurView.transform = CGAffineTransformIdentity;
            } @catch (NSException *e) {}
            g_liquidPullBlurView = nil;
        }

        [CATransaction commit];

        g_clockTimeView = nil;
        g_clockBaselineReady = NO;
        g_currentClockTranslateY = 0.0f;
        g_baseClockTopOnScreen = 0.0f;
        g_baseClockBottomOnScreen = 0.0f;

        if (g_displayLink) {
            [g_displayLink invalidate];
            g_displayLink = nil;
        }
        g_displayTarget = nil;
        if (g_overlay) {
            [g_overlay removeFromSuperview];
            g_overlay = nil;
        }
        g_overlayHost = nil;
        g_notificationScroll = nil;
        g_baselineReady = NO;
        g_alpha = 0.0f;
        g_progress = 0.0f;
        g_lastFrame = 0.0;
        g_lastLog = 0.0;
    }
}

static void ld_tick(CADisplayLink *link);
static void ld_tick_impl(CADisplayLink *link);

@interface LDDisplayTarget : NSObject
@end

@implementation LDDisplayTarget
- (void)ld_tick:(CADisplayLink *)link {
    ld_tick(link);
}
@end

static void ld_start(UIViewController *controller) {
    ld_readSettings();
    if (g_safeMode || !g_enabled) return;

    ld_armSafetyWindow(@"cover");
    g_coverController = controller;
    g_coverRoot = controller.view;
    ld_setActive(g_enabled);
    if (!g_enabled) return;

    if (!g_displayLink) {
        g_displayTarget = [LDDisplayTarget new];
        g_displayLink = [CADisplayLink displayLinkWithTarget:g_displayTarget
                                                    selector:@selector(ld_tick:)];
        if (@available(iOS 15.0, *)) {
            g_displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0, 120.0, 120.0);
        } else {
            g_displayLink.preferredFramesPerSecond = 0;
        }
        [g_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                             forMode:NSRunLoopCommonModes];
    }
    ld_log(@"cover start root=%@", ld_className(g_coverRoot));
}

static void ld_stopIfController(id object) {
    UIViewController *controller = (UIViewController *)object;
    if (g_coverController && controller != g_coverController) return;
    ld_log(@"cover stop");
    g_coverController = nil;
    g_coverRoot = nil;
    ld_setActive(NO);
    if (!g_safeMode) ld_clearSafetyMarker();
}

static void ld_tick_impl(CADisplayLink *link) {
    if (!g_active) return;
    ld_readSettings();
    if (!g_enabled) {
        ld_setActive(NO);
        return;
    }

    UIView *root = g_coverRoot;
    if (!root || !root.window) {
        ld_stopIfController(g_coverController);
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = g_lastFrame > 0.0 ? now - g_lastFrame : 1.0 / 60.0;
    g_lastFrame = now;
    dt = fmin(0.10, fmax(0.001, dt));

    UIScrollView *scroll = g_notificationScroll;
    if (!ld_isDescendant(scroll, root)) scroll = nil;
    if (!scroll) scroll = ld_notificationScrollForRoot(root);

    CGFloat targetProgress = 0.0f;
    if (scroll && ld_scrollHasNotifications(scroll)) {
        if (scroll != g_notificationScroll || !g_baselineReady) {
            g_notificationScroll = scroll;
            ld_captureBaseline(scroll, root);
        }
        ld_attachOverlay(root, scroll);
        targetProgress = ld_progressForScroll(scroll, root);
    }

    // Silky smooth dimming animation with exponential decay
    g_progress += (targetProgress - g_progress) *
                  (1.0f - expf((float)(-dt / 0.045f)));
    g_progress = ld_clampf(g_progress, 0.0f, 1.0f);

    CGFloat targetAlpha = g_maxAlpha * g_progress;
    g_alpha += (targetAlpha - g_alpha) *
               (1.0f - expf((float)(-dt / 0.055f)));
    g_alpha = ld_clampf(g_alpha, 0.0f, g_maxAlpha);

    if (g_overlay) {
        g_overlay.hidden = (g_alpha < 0.001f);
        g_overlay.alpha = g_alpha;
    }

    // Hardware-Accurate Sticky Anchoring for Lock Screen Clock (TOP-ANCHORED)
    if (g_stickyClock) {
        UIView *container = g_clockContainerView;
        UIView *timeView = g_clockTimeView;
        if (!container || !timeView || !timeView.window) {
            ld_locateClockViews(root, &container, &timeView);
            g_clockContainerView = container;
            g_clockTimeView = timeView;
        }

        if (timeView && timeView.window) {
            // Idle state: capture resting top baseline ONCE
            if (!g_clockBaselineReady) {
                CGFloat top = ld_clockTopOnScreen(timeView, container, root);
                CGFloat bottom = ld_clockBottomOnScreen(timeView, container, root);
                if (top > 10.0) {
                    g_baseClockTopOnScreen = top;
                    g_baseClockBottomOnScreen = (bottom > top) ? bottom + 8.0 : top + 90.0;
                    g_clockBaselineReady = YES;
                    g_currentClockTranslateY = 0.0f;
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    if (container) container.transform = CGAffineTransformIdentity;
                    [CATransaction commit];
                    ld_log(@"clock baseline anchored top=%.1f bottom=%.1f",
                           g_baseClockTopOnScreen, g_baseClockBottomOnScreen);
                }
            }

            // Smooth gradient fade mask: notifications softly fade right below the status bar (no divider under clock)
            if (scroll && root) {
                UIView *clipHost = scroll.superview;
                if (clipHost && !ld_isDescendant(timeView, clipHost)) {
                    @try {
                        CGFloat rootW = root.bounds.size.width;
                        CGFloat rootH = root.bounds.size.height;

                        CGFloat statusBarH = 48.0;
                        if (root.window && root.window.safeAreaInsets.top > 20.0) {
                            statusBarH = root.window.safeAreaInsets.top;
                        }

                        CGFloat fadeHeight = 26.0;
                        CGFloat startFadeY = statusBarH - 2.0;
                        CGFloat maskHeight = fmax(10.0, rootH - startFadeY);

                        CGRect visibleRectInRoot = CGRectMake(0.0, startFadeY, rootW, maskHeight);
                        CGRect maskRectInHost = [clipHost convertRect:visibleRectInRoot fromView:root];

                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];

                        if (!g_scrollGradientMask) {
                            g_scrollGradientMask = [CAGradientLayer layer];
                            g_scrollGradientMask.startPoint = CGPointMake(0.5, 0.0);
                            g_scrollGradientMask.endPoint = CGPointMake(0.5, 1.0);
                            g_scrollGradientMask.colors = @[
                                (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
                                (id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
                                (id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor
                            ];
                        }

                        CGFloat fadeRatio = ld_clampf((float)(fadeHeight / maskHeight), 0.01f, 0.50f);
                        g_scrollGradientMask.locations = @[
                            @(0.0),
                            @(fadeRatio),
                            @(1.0)
                        ];

                        g_scrollGradientMask.frame = maskRectInHost;
                        if (clipHost.layer.mask != g_scrollGradientMask) {
                            clipHost.layer.mask = g_scrollGradientMask;
                            g_maskedView = clipHost;
                        }

                        [CATransaction commit];
                    } @catch (NSException *e) {}
                }
            }
        }
    } else if ((g_clockTimeView || g_clockContainerView) && fabs(g_currentClockTranslateY) > 0.0f) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (g_clockTimeView) g_clockTimeView.transform = CGAffineTransformIdentity;
        if (g_clockContainerView) g_clockContainerView.transform = CGAffineTransformIdentity;
        if (g_liquidGlassView) g_liquidGlassView.transform = CGAffineTransformIdentity;
        if (g_liquidPullBlurView) g_liquidPullBlurView.transform = CGAffineTransformIdentity;
        g_currentClockTranslateY = 0.0f;
        if (g_maskedView) {
            g_maskedView.layer.mask = nil;
            g_maskedView = nil;
        }
        g_scrollGradientMask = nil;
        [CATransaction commit];
    }

    if (g_debug && now - g_lastLog > 0.20) {
        ld_log(@"tick progress=%.3f alpha=%.3f scroll=%@ clockTop=%.1f transY=%.1f",
               g_progress, g_alpha, ld_className(scroll),
               g_baseClockTopOnScreen, g_currentClockTranslateY);
        g_lastLog = now;
    }
}

static void ld_tick(CADisplayLink *link) {
    @try {
        ld_tick_impl(link);
    } @catch (NSException *exception) {
        NSLog(@"[26LockDim] tick exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

static IMP ld_swizzle(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) return NULL;

    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            own = methods[i];
            break;
        }
    }
    free(methods);

    if (own) {
        IMP original = method_getImplementation(own);
        method_setImplementation(own, replacement);
        return original;
    }

    Class super = class_getSuperclass(cls);
    Method inherited = class_getInstanceMethod(super, selector);
    if (!inherited) return NULL;

    const char *types = method_getTypeEncoding(inherited);
    if (class_addMethod(cls, selector, replacement, types)) {
        return method_getImplementation(inherited);
    }
    return NULL;
}

typedef void (*LDViewAppearFn)(id, SEL, BOOL);

static IMP g_origCSAppear = NULL;
static IMP g_origCSDisappear = NULL;
static IMP g_origSBAppear = NULL;
static IMP g_origSBDisappear = NULL;
static IMP g_origDisplayViewLayout = NULL;
static IMP g_origSBFDateViewLayout = NULL;

static void ld_prominentDisplayView_layoutSubviews(UIView *self, SEL _cmd) {
    if (g_origDisplayViewLayout) {
        ((void (*)(id, SEL))g_origDisplayViewLayout)(self, _cmd);
    }
}

static void ld_sbfDateView_layoutSubviews(UIView *self, SEL _cmd) {
    if (g_origSBFDateViewLayout) {
        ((void (*)(id, SEL))g_origSBFDateViewLayout)(self, _cmd);
    }
}

static IMP g_origLGApplyReason = NULL;
static void *kLDRestingTopKey = &kLDRestingTopKey;

static void ld_lgClockState_applyReason(id self, SEL selector, NSString *reason) {
    if (g_origLGApplyReason) {
        ((void (*)(id, SEL, NSString *))g_origLGApplyReason)(self, selector, reason);
    }

    if (g_enabled) {
        @try {
            UIView *maskView = [self valueForKey:@"glyphMaskView"];
            CAShapeLayer *maskLayer = [self valueForKey:@"glyphMaskLayer"];
            if (maskView && maskLayer && maskLayer.path) {
                CGRect pathBounds = CGPathGetPathBoundingBox(maskLayer.path);
                if (!CGRectIsNull(pathBounds) && !CGRectIsEmpty(pathBounds)) {
                    NSNumber *restingNum = objc_getAssociatedObject(self, kLDRestingTopKey);
                    if (!restingNum || g_progress < 0.001f || ![reason isEqualToString:@"motion"]) {
                        // At rest or during non-motion updates: record the baseline top coordinate of glyphs
                        objc_setAssociatedObject(self, kLDRestingTopKey, @(pathBounds.origin.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        maskView.transform = CGAffineTransformIdentity;
                    } else {
                        CGFloat restingTop = [restingNum doubleValue];
                        CGFloat overflow = restingTop - pathBounds.origin.y;
                        if (overflow > 0.5f) {
                            // Compensate upward overflow: digits stay locked right beneath the date subtitle, never overlapping it
                            maskView.transform = CGAffineTransformMakeTranslation(0.0, overflow);
                        } else {
                            maskView.transform = CGAffineTransformIdentity;
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
    }
}

static void ld_installLiquidGlassHooks(void) {
    static BOOL s_installed = NO;
    if (s_installed) return;

    Class lgState = NSClassFromString(@"LGClockState");
    if (lgState) {
        s_installed = YES;
        g_origLGApplyReason = ld_swizzle(lgState, @selector(applyReason:),
                                         (IMP)ld_lgClockState_applyReason);
        ld_log(@"Liquid Glass adaptive clock hook installed: state=%p applyReason=%p",
               lgState, g_origLGApplyReason);
    }
}

static void ld_csViewWillAppear(id self, SEL selector, BOOL animated) {
    if (g_origCSAppear) ((LDViewAppearFn)g_origCSAppear)(self, selector, animated);
    ld_installLiquidGlassHooks();
    @try {
        ld_start((UIViewController *)self);
    } @catch (NSException *exception) {
        NSLog(@"[26LockDim] start exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

static void ld_csViewDidDisappear(id self, SEL selector, BOOL animated) {
    if (g_origCSDisappear) ((LDViewAppearFn)g_origCSDisappear)(self, selector, animated);
    ld_stopIfController(self);
}

static void ld_sbViewWillAppear(id self, SEL selector, BOOL animated) {
    if (g_origSBAppear) ((LDViewAppearFn)g_origSBAppear)(self, selector, animated);
    ld_installLiquidGlassHooks();
    @try {
        ld_start((UIViewController *)self);
    } @catch (NSException *exception) {
        NSLog(@"[26LockDim] start exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

static void ld_sbViewDidDisappear(id self, SEL selector, BOOL animated) {
    if (g_origSBDisappear) ((LDViewAppearFn)g_origSBDisappear)(self, selector, animated);
    ld_stopIfController(self);
}

static BOOL ld_isInsideControlCenter(UIView *view) {
    if (!view) return NO;
    for (UIView *v = view; v; v = v.superview) {
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"CCUI"] || [cls containsString:@"ControlCenter"]) {
            return YES;
        }
    }
    return NO;
}

static double ld_batteryOutsideRadius(id self, SEL _cmd, id trait) {
    if (g_roundBatteryEnabled) {
        double baseOut = (g_batteryOutsideRadius > 0.0) ? g_batteryOutsideRadius : 3.0;
        if ([self isKindOfClass:[UIView class]] && ld_isInsideControlCenter((UIView *)self)) {
            // Scale proportionally for Control Center expanded status bar
            return baseOut * 1.15;
        }
        return baseOut;
    }
    if (g_origBatteryOutsideRadius) {
        return ((double (*)(id, SEL, id))g_origBatteryOutsideRadius)(self, _cmd, trait);
    }
    return 3.0;
}

static double ld_batteryInsideRadius(id self, SEL _cmd, id trait) {
    if (g_roundBatteryEnabled) {
        double outR = ld_batteryOutsideRadius(self, _cmd, trait);
        double inset = (g_noBatteryGapEnabled ? 1.0 : 1.6);
        return fmax(1.0, outR - inset);
    }
    if (g_origBatteryInsideRadius) {
        return ((double (*)(id, SEL, id))g_origBatteryInsideRadius)(self, _cmd, trait);
    }
    return 1.5;
}

static double ld_batteryLineWidthAndInterspace(id self, SEL _cmd, id trait) {
    if (g_roundBatteryEnabled && g_noBatteryGapEnabled) {
        if ([self isKindOfClass:[UIView class]] && ld_isInsideControlCenter((UIView *)self)) {
            return 1.15;
        }
        return 1.0;
    }
    if (g_origBatteryLineWidthAndInterspace) {
        return ((double (*)(id, SEL, id))g_origBatteryLineWidthAndInterspace)(self, _cmd, trait);
    }
    return 1.0;
}

static double ld_batteryLineWidthAndInterspaceClass(id self, SEL _cmd, long long iconSize) {
    if (g_roundBatteryEnabled && g_noBatteryGapEnabled) {
        return (iconSize == 2) ? 1.15 : 1.0;
    }
    if (g_origBatteryLineWidthAndInterspaceClass) {
        return ((double (*)(id, SEL, long long))g_origBatteryLineWidthAndInterspaceClass)(self, _cmd, iconSize);
    }
    return 1.0;
}

static void ld_batteryView_layoutSubviews(UIView *self, SEL _cmd) {
    if (g_origBatteryLayoutSubviews) {
        ((void (*)(id, SEL))g_origBatteryLayoutSubviews)(self, _cmd);
    }
    if (g_roundBatteryEnabled) {
        @try {
            BOOL isCC = ld_isInsideControlCenter(self);
            double baseOut = (g_batteryOutsideRadius > 0.0) ? g_batteryOutsideRadius : 3.0;
            double outR = isCC ? (baseOut * 1.15) : baseOut;
            double inset = (g_noBatteryGapEnabled ? 1.0 : 1.6);
            double inR = fmax(1.0, outR - inset);

            CALayer *body = [self valueForKey:@"bodyLayer"];
            if (body) {
                body.cornerCurve = kCACornerCurveCircular;
            }
            CALayer *fill = [self valueForKey:@"fillLayer"];
            if (fill) {
                fill.cornerCurve = kCACornerCurveCircular;
                fill.cornerRadius = inR;
            }
        } @catch (NSException *e) {}
    }
}

static void ld_installBatteryHooksForClass(Class cls) {
    if (!cls) return;
    if (class_getInstanceMethod(cls, @selector(_outsideCornerRadiusForTraitCollection:))) {
        IMP orig = ld_swizzle(cls, @selector(_outsideCornerRadiusForTraitCollection:),
                              (IMP)ld_batteryOutsideRadius);
        if (!g_origBatteryOutsideRadius) g_origBatteryOutsideRadius = orig;
    }
    if (class_getInstanceMethod(cls, @selector(_insideCornerRadiusForTraitCollection:))) {
        IMP orig = ld_swizzle(cls, @selector(_insideCornerRadiusForTraitCollection:),
                              (IMP)ld_batteryInsideRadius);
        if (!g_origBatteryInsideRadius) g_origBatteryInsideRadius = orig;
    }
    if (class_getInstanceMethod(cls, @selector(_lineWidthAndInterspaceForTraitCollection:))) {
        IMP orig = ld_swizzle(cls, @selector(_lineWidthAndInterspaceForTraitCollection:),
                              (IMP)ld_batteryLineWidthAndInterspace);
        if (!g_origBatteryLineWidthAndInterspace) g_origBatteryLineWidthAndInterspace = orig;
    }
    if (class_getClassMethod(cls, @selector(_lineWidthAndInterspaceForIconSize:))) {
        Class meta = object_getClass(cls);
        IMP orig = ld_swizzle(meta, @selector(_lineWidthAndInterspaceForIconSize:),
                              (IMP)ld_batteryLineWidthAndInterspaceClass);
        if (!g_origBatteryLineWidthAndInterspaceClass) g_origBatteryLineWidthAndInterspaceClass = orig;
    }
    IMP origLayout = ld_swizzle(cls, @selector(layoutSubviews),
                                (IMP)ld_batteryView_layoutSubviews);
    if (!g_origBatteryLayoutSubviews) g_origBatteryLayoutSubviews = origLayout;
}

__attribute__((constructor))
static void ld_init(void) {
    @autoreleasepool {
        ld_readSettings();
        ld_checkSafetyMarker();
        if (g_safeMode || !g_enabled) {
            ld_log(@"not installing hooks safe=%d enabled=%d", g_safeMode, g_enabled);
            return;
        }
        ld_armSafetyWindow(@"constructor");

        Class cs = NSClassFromString(@"CSCoverSheetViewController");
        Class sb = NSClassFromString(@"SBCoverSheetViewController");
        Class promDisplay = NSClassFromString(@"CSProminentDisplayView");
        Class sbfDateView = NSClassFromString(@"SBFLockScreenDateView");

        if (cs) {
            g_origCSAppear = ld_swizzle(cs, @selector(viewWillAppear:),
                                        (IMP)ld_csViewWillAppear);
            g_origCSDisappear = ld_swizzle(cs, @selector(viewDidDisappear:),
                                           (IMP)ld_csViewDidDisappear);
        }
        if (sb) {
            g_origSBAppear = ld_swizzle(sb, @selector(viewWillAppear:),
                                        (IMP)ld_sbViewWillAppear);
            g_origSBDisappear = ld_swizzle(sb, @selector(viewDidDisappear:),
                                           (IMP)ld_sbViewDidDisappear);
        }
        if (promDisplay) {
            g_origDisplayViewLayout = ld_swizzle(promDisplay, @selector(layoutSubviews),
                                                 (IMP)ld_prominentDisplayView_layoutSubviews);
        }
        if (sbfDateView) {
            g_origSBFDateViewLayout = ld_swizzle(sbfDateView, @selector(layoutSubviews),
                                                 (IMP)ld_sbfDateView_layoutSubviews);
        }

        ld_installBatteryHooksForClass(NSClassFromString(@"_UIBatteryView"));
        ld_installBatteryHooksForClass(NSClassFromString(@"_UIStaticBatteryView"));
        ld_installBatteryHooksForClass(NSClassFromString(@"STUIStatusBarStaticBatteryView"));

        ld_installLiquidGlassHooks();

        ld_log(@"loaded v0.2.12 enabled=%d sticky=%d maxAlpha=%.2f CS=%@ SB=%@ PromDisplay=%@ SBFDate=%@",
               g_enabled, g_stickyClock, g_maxAlpha,
               cs ? NSStringFromClass(cs) : @"missing",
               sb ? NSStringFromClass(sb) : @"missing",
               promDisplay ? NSStringFromClass(promDisplay) : @"missing",
               sbfDateView ? NSStringFromClass(sbfDateView) : @"missing");
    }
}
