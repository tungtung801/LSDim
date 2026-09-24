/*
 * 26LockDim 0.1.4
 *
 * Lock Screen notification background dimming, kept separate from 26Unlock.
 * The tweak observes the live CoverSheet hierarchy and writes only a black
 * background layer below the notification branch and clock branch. It does not
 * change system brightness, notification alpha, the clock, or the unlock state machine.
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>

#define LD_SETTINGS @"/var/mobile/26LockDim.plist"
#define LD_LOGFILE  "/var/mobile/26LockDim.log"
#define LD_SAFEFILE @"/var/mobile/Media/26LockDim.safe"

static BOOL  g_enabled     = YES;
static BOOL  g_debug       = YES;
static BOOL  g_stickyClock = YES;
static float g_maxAlpha    = 0.48f;

static __weak UIViewController *g_coverController;
static __weak UIView *g_coverRoot;
static __weak UIScrollView *g_notificationScroll;
static __weak UIView *g_clockContainerView;
static __weak UIView *g_clockTimeView;
static __weak UIView *g_overlayHost;
static UIView *g_overlay;
static CADisplayLink *g_displayLink;
static NSObject *g_displayTarget;

static BOOL     g_active;
static BOOL     g_safeMode;
static BOOL     g_markerArmed;
static uint64_t g_safetyGeneration;
static BOOL     g_baselineReady;
static CGRect   g_baseRect;
static CGFloat  g_baseOffsetY;
static CGSize   g_baseRootSize;
static CGFloat  g_baseClockTopInRoot;
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
}

static void ld_clearSafetyMarker(void) {
    g_safetyGeneration++;
    g_markerArmed = NO;
    [[NSFileManager defaultManager] removeItemAtPath:LD_SAFEFILE error:NULL];
}

static void ld_armSafetyWindow(NSString *reason) {
    if (g_safeMode) return;

    g_safetyGeneration++;
    g_markerArmed = YES;
    NSDictionary *marker = @{
        @"reason": reason ?: @"unknown",
        @"time": @([[NSDate date] timeIntervalSince1970])
    };
    [marker writeToFile:LD_SAFEFILE atomically:YES];

    uint64_t gen = g_safetyGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_markerArmed && g_safetyGeneration == gen) {
            ld_clearSafetyMarker();
            ld_log(@"safety window cleared (%@)", reason);
        }
    });
}

static void ld_checkSafetyMarker(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:LD_SAFEFILE]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:LD_SAFEFILE error:NULL];
        NSDate *mdate = attrs ? [attrs fileModificationDate] : nil;
        NSTimeInterval age = mdate ? [[NSDate date] timeIntervalSinceDate:mdate] : 9999.0;
        if (age < 120.0) {
            g_safeMode = YES;
            NSLog(@"[26LockDim] *** SAFE MODE: marker present (age=%.1fs). Disabling. ***", age);
        } else {
            [fm removeItemAtPath:LD_SAFEFILE error:NULL];
        }
    }
}

static NSString *ld_className(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static BOOL ld_isDescendant(UIView *view, UIView *root) {
    if (!view || !root) return NO;
    if (view == root) return YES;
    return [view isDescendantOfView:root];
}

static UIView *ld_findViewMatching(UIView *view, NSString *substr, int depth) {
    if (!view || depth > 16) return nil;
    NSString *name = ld_className(view);
    if ([name containsString:substr]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = ld_findViewMatching(sub, substr, depth + 1);
        if (found) return found;
    }
    return nil;
}

/* Locate both the clock container (e.g. CSProminentDisplayView / dateView)
 * and the actual time view (e.g. CSProminentTimeView / SBFLockScreenDateView). */
static void ld_locateClockViews(UIView *root, UIView **outContainer, UIView **outTime) {
    if (!root) return;

    UIView *container = nil;
    UIView *timeView = nil;

    @try {
        if (g_coverController && [g_coverController respondsToSelector:@selector(dateViewController)]) {
            UIViewController *dvc = [g_coverController valueForKey:@"dateViewController"];
            if (dvc && dvc.view) {
                container = dvc.view;
            }
        }
    } @catch (NSException *e) {}

    if (!container) {
        @try {
            if ([root respondsToSelector:@selector(dateView)]) {
                container = [root valueForKey:@"dateView"];
            }
        } @catch (NSException *e) {}
    }

    if (!container) {
        container = ld_findViewMatching(root, @"ProminentDisplay", 0);
    }
    if (!container) {
        container = ld_findViewMatching(root, @"LockScreenDateView", 0);
    }

    UIView *searchScope = container ?: root;
    timeView = ld_findViewMatching(searchScope, @"ProminentTime", 0);
    if (!timeView && searchScope != root) {
        timeView = ld_findViewMatching(root, @"ProminentTime", 0);
    }
    if (!timeView) {
        timeView = container;
    }

    if (!container && timeView) {
        if (timeView.superview && timeView.superview != root) {
            container = timeView.superview;
        } else {
            container = timeView;
        }
    }

    if (outContainer) *outContainer = container;
    if (outTime) *outTime = timeView;
}

/* Find the scroll surface that represents the Lock Screen notification list.
 * The class names changed between iOS 15 and 16, so use names only as a
 * positive score and retain a geometry/content fallback. */
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
    if (!root) return nil;
    UIScrollView *best = nil;
    CGFloat bestScore = 0.0;
    ld_findNotificationScroll(root, root, &best, &bestScore, 0);
    return best;
}

static BOOL ld_scrollHasNotifications(UIScrollView *scroll) {
    if (!scroll) return NO;
    if (scroll.contentSize.height > scroll.bounds.size.height + 10.0) return YES;

    NSString *name = [[ld_className(scroll) lowercaseString] copy];
    if ([name containsString:@"notification"] && scroll.subviews.count > 0)
        return YES;
    return NO;
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

    UIView *container = nil;
    UIView *timeView = nil;
    ld_locateClockViews(root, &container, &timeView);
    g_clockContainerView = container;
    g_clockTimeView = timeView;

    if (timeView && root.window) {
        @try {
            CGRect r = [timeView convertRect:timeView.bounds toView:root];
            if (r.size.height > 10.0 && r.origin.y > 0.0) {
                g_baseClockTopInRoot = r.origin.y;
                g_clockBaselineReady = YES;
                g_currentClockTranslateY = 0.0f;
                if (container && container != timeView) {
                    container.transform = CGAffineTransformIdentity;
                }
            }
        } @catch (NSException *e) {}
    }

    ld_log(@"baseline scroll=%@ rect=%@ offsetY=%.2f root=%@ clockTop=%.1f",
           ld_className(scroll), NSStringFromCGRect(g_baseRect),
           g_baseOffsetY, NSStringFromClass([root class]), g_baseClockTopInRoot);
}

/* Put the overlay in the full-screen ancestor immediately below the direct
 * branch containing notifications and clock (CSMainPageView).
 * Leaves notifications and clock fully above the black dimming layer.
 * Does not remove and re-add unnecessarily to prevent vibrancy ghosting. */
static void ld_attachOverlay(UIView *root, UIScrollView *scroll) {
    if (!root || !scroll) return;

    UIView *branch = scroll;
    while (branch.superview && branch.superview != root)
        branch = branch.superview;

    if (!branch.superview && branch != root) return;

    UIView *host = root;

    if (!g_overlay) {
        g_overlay = [[UIView alloc] initWithFrame:host.bounds];
        g_overlay.backgroundColor = [UIColor blackColor];
        g_overlay.userInteractionEnabled = NO;
        g_overlay.accessibilityElementsHidden = YES;
        g_overlay.layer.zPosition = 0.0;
        g_overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight;
    }

    if (g_overlay.superview != host) {
        [g_overlay removeFromSuperview];
        g_overlay.frame = host.bounds;
        [host insertSubview:g_overlay belowSubview:branch];
        g_overlayHost = host;
        return;
    }

    NSUInteger overlayIdx = [host.subviews indexOfObject:g_overlay];
    NSUInteger branchIdx = [host.subviews indexOfObject:branch];
    if (overlayIdx != NSNotFound && branchIdx != NSNotFound && overlayIdx > branchIdx) {
        [host insertSubview:g_overlay belowSubview:branch];
    }
}

static void ld_scanPanProgress(UIView *view, UIView *root, CGFloat *progress,
                               int depth) {
    if (!view || !root || !progress || depth > 14) return;

    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (![gesture isKindOfClass:[UIPanGestureRecognizer class]]) continue;
        if (gesture.state != UIGestureRecognizerStateBegan &&
            gesture.state != UIGestureRecognizerStateChanged) continue;

        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
        CGPoint translation = [pan translationInView:root];
        CGPoint velocity = [pan velocityInView:root];
        if (translation.y < -2.0 || velocity.y < -80.0) {
            CGFloat travel = fmax(80.0, root.bounds.size.height * 0.28);
            CGFloat p = ld_clampf((float)(-translation.y / travel), 0.0f, 1.0f);
            if (p > *progress) *progress = p;
        }
    }

    for (UIView *subview in view.subviews)
        ld_scanPanProgress(subview, root, progress, depth + 1);
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

    CGFloat rootHeight = fmax(1.0, root.bounds.size.height);
    CGFloat upwardMove = g_baseRect.origin.y - currentRect.origin.y;
    CGFloat pFrame = ld_clampf((float)(upwardMove / fmax(80.0, rootHeight * 0.24)),
                                0.0f, 1.0f);

    CGFloat offsetDelta = fabs(scroll.contentOffset.y - g_baseOffsetY);
    CGFloat maxOffset = fmax(0.0, scroll.contentSize.height - scroll.bounds.size.height);
    CGFloat offsetTravel = fmax(80.0, fmin(rootHeight * 0.65, maxOffset));
    CGFloat pOffset = maxOffset > 1.0
        ? ld_clampf((float)(offsetDelta / offsetTravel), 0.0f, 1.0f)
        : 0.0f;

    CGFloat pPan = 0.0f;
    ld_scanPanProgress(root, root, &pPan, 0);

    return fmax(pFrame, fmax(pOffset, pPan));
}

static void ld_setActive(BOOL active) {
    g_active = active;
    if (!active) {
        if (g_clockContainerView) {
            @try {
                g_clockContainerView.transform = CGAffineTransformIdentity;
            } @catch (NSException *e) {}
            g_clockContainerView = nil;
        }
        g_clockTimeView = nil;
        g_clockBaselineReady = NO;
        g_currentClockTranslateY = 0.0f;
        g_baseClockTopInRoot = 0.0f;

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
        g_displayLink.preferredFramesPerSecond = 60;
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

    g_progress += (targetProgress - g_progress) *
                  (1.0f - expf((float)(-dt / 0.045f)));
    g_progress = ld_clampf(g_progress, 0.0f, 1.0f);

    CGFloat targetAlpha = g_maxAlpha * ld_smoothstep(g_progress);
    g_alpha += (targetAlpha - g_alpha) *
               (1.0f - expf((float)(-dt / 0.055f)));
    g_alpha = ld_clampf(g_alpha, 0.0f, g_maxAlpha);

    if (g_overlay) {
        g_overlay.hidden = (g_alpha < 0.001f);
        g_overlay.alpha = g_alpha;
    }

    // Dynamic Sticky Compensation on the clock container
    if (g_stickyClock) {
        UIView *container = g_clockContainerView;
        UIView *timeView = g_clockTimeView;
        if (!container || !timeView || container.window != root.window) {
            ld_locateClockViews(root, &container, &timeView);
            g_clockContainerView = container;
            g_clockTimeView = timeView;
        }

        if (timeView && root.window) {
            if (!g_clockBaselineReady || (g_progress < 0.005f && fabs(g_currentClockTranslateY) < 0.1f)) {
                @try {
                    CGRect r = [timeView convertRect:timeView.bounds toView:root];
                    if (r.size.height > 10.0 && r.origin.y > 0.0) {
                        g_baseClockTopInRoot = r.origin.y;
                        g_clockBaselineReady = YES;
                    }
                } @catch (NSException *e) {}
            }

            // Compensate only on the container view (never touch timeView directly to avoid fighting external scaling tweaks)
            if (g_clockBaselineReady && container && container != timeView) {
                @try {
                    CGRect curRect = [timeView convertRect:timeView.bounds toView:root];
                    CGFloat uncompensatedTop = curRect.origin.y - g_currentClockTranslateY;
                    CGFloat neededCompensation = g_baseClockTopInRoot - uncompensatedTop;

                    if (g_progress < 0.001f && fabs(neededCompensation) < 1.0) {
                        neededCompensation = 0.0f;
                    }

                    if (fabs(neededCompensation - g_currentClockTranslateY) > 0.2f) {
                        g_currentClockTranslateY = neededCompensation;
                        container.transform = CGAffineTransformMakeTranslation(0.0, g_currentClockTranslateY);
                    }
                } @catch (NSException *e) {}
            }
        }
    } else if (g_clockContainerView && fabs(g_currentClockTranslateY) > 0.0) {
        g_clockContainerView.transform = CGAffineTransformIdentity;
        g_currentClockTranslateY = 0.0f;
    }

    if (g_debug && now - g_lastLog > 0.20) {
        ld_log(@"tick progress=%.3f alpha=%.3f scroll=%@ clockTop=%.1f transY=%.1f",
               g_progress, g_alpha, ld_className(scroll),
               g_baseClockTopInRoot, g_currentClockTranslateY);
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
typedef void (*LDLayoutDateViewFn)(id, SEL);
typedef void (*LDCSSetDateViewOffsetFn)(id, SEL, CGPoint);
typedef CGRect (*LDCSDateViewFrameFn)(id, SEL, long long, double, double *);
typedef CGRect (*LDCSDateViewExtentFn)(id, SEL, double);

static IMP g_origCSAppear = NULL;
static IMP g_origCSDisappear = NULL;
static IMP g_origSBAppear = NULL;
static IMP g_origSBDisappear = NULL;
static IMP g_origCSLayoutDateView = NULL;
static IMP g_origCSSetDateViewOffset = NULL;
static IMP g_origCSDateViewFrame = NULL;
static IMP g_origCSDateViewExtent = NULL;

static void ld_csSetDateViewOffset(id self, SEL selector, CGPoint offset) {
    if (g_enabled && g_stickyClock) {
        offset.y = 0.0;
    }
    if (g_origCSSetDateViewOffset) {
        ((LDCSSetDateViewOffsetFn)g_origCSSetDateViewOffset)(self, selector, offset);
    }
}

static CGRect ld_csDateViewFrame(id self, SEL selector, long long align, double scrollOffset, double *outPercent) {
    if (g_enabled && g_stickyClock) {
        scrollOffset = 0.0;
    }
    if (g_origCSDateViewFrame) {
        return ((LDCSDateViewFrameFn)g_origCSDateViewFrame)(self, selector, align, scrollOffset, outPercent);
    }
    return CGRectZero;
}

static CGRect ld_csDateViewExtent(id self, SEL selector, double scrollOffset) {
    if (g_enabled && g_stickyClock) {
        scrollOffset = 0.0;
    }
    if (g_origCSDateViewExtent) {
        return ((LDCSDateViewExtentFn)g_origCSDateViewExtent)(self, selector, scrollOffset);
    }
    return CGRectZero;
}

static void ld_csLayoutDateView(id self, SEL selector) {
    if (g_origCSLayoutDateView) {
        ((LDLayoutDateViewFn)g_origCSLayoutDateView)(self, selector);
    }
    // Clean: do NOT mutate frame here to prevent layout recursion and ghosting
}

static void ld_csViewWillAppear(id self, SEL selector, BOOL animated) {
    if (g_origCSAppear) ((LDViewAppearFn)g_origCSAppear)(self, selector, animated);
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
        Class csView = NSClassFromString(@"CSCoverSheetView");
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
        if (csView) {
            g_origCSLayoutDateView = ld_swizzle(csView, @selector(_layoutDateView),
                                                (IMP)ld_csLayoutDateView);
            g_origCSSetDateViewOffset = ld_swizzle(csView, @selector(setDateViewOffset:),
                                                   (IMP)ld_csSetDateViewOffset);
            g_origCSDateViewFrame = ld_swizzle(csView, @selector(_dateViewFrameForPageAlignment:pageRelativeScrollOffset:outAlignmentPercent:),
                                               (IMP)ld_csDateViewFrame);
            g_origCSDateViewExtent = ld_swizzle(csView, @selector(dateViewPresentationExtentForPageRelativeScrollOffset:),
                                                (IMP)ld_csDateViewExtent);
        }

        ld_log(@"loaded enabled=%d sticky=%d maxAlpha=%.2f CS=%@ SB=%@ CSView=%@",
               g_enabled, g_stickyClock, g_maxAlpha,
               cs ? NSStringFromClass(cs) : @"missing",
               sb ? NSStringFromClass(sb) : @"missing",
               csView ? NSStringFromClass(csView) : @"missing");
    }
}
