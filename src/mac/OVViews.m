/*
 * OldDV Rescue - custom views (see OVViews.h)
 */
#import "OVViews.h"
#include <math.h>

@implementation OVGraphView

#define RULER_H 13

- (id)initWithFrame:(NSRect)r
{
    self = [super initWithFrame:r];
    if (self) {
        selected = -1;
        hoverX = -1;
        headTC = -1;
    }
    return self;
}

- (void)dealloc
{
    free(points);
    free(sections);
    [emptyText release];
    [tracking release];
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return NO; }

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (tracking) {
        [self removeTrackingArea:tracking];
        [tracking release];
    }
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
                                                    | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                              owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}

- (void)reserve:(size_t)n
{
    if (n > cap) {
        size_t nc = cap ? cap : 4096;
        OVGraphPoint *np;
        while (nc < n)
            nc *= 2;
        np = (OVGraphPoint *)realloc(points, nc * sizeof(OVGraphPoint));
        if (!np)
            return;
        points = np;
        cap = nc;
    }
}

- (void)setPoints:(const OVGraphPoint *)p count:(size_t)n
{
    count = 0;
    [self appendPoints:p count:n];
}

- (void)appendPoints:(const OVGraphPoint *)p count:(size_t)n
{
    if (!n) {
        [self setNeedsDisplay:YES];
        return;
    }
    [self reserve:count + n];
    if (count + n > cap)
        return;
    memcpy(points + count, p, n * sizeof(OVGraphPoint));
    count += n;
    [self setNeedsDisplay:YES];
}

- (void)clear
{
    count = 0;
    selected = -1;
    nsections = 0;
    passes = 0;
    headMode = 0;
    [self setNeedsDisplay:YES];
}

- (size_t)count { return count; }
- (long)selected { return selected; }
- (void)setSelected:(long)i { selected = i; [self setNeedsDisplay:YES]; }
- (void)setTarget:(id)t action:(SEL)a { target = t; action = a; }
- (void)setEmptyText:(NSString *)s { [emptyText release]; emptyText = [s copy]; [self setNeedsDisplay:YES]; }

- (void)setSections:(const OVRetrySection *)s count:(size_t)n passes:(int)p
{
    OVRetrySection *ns = n ? (OVRetrySection *)malloc(n * sizeof(OVRetrySection)) : NULL;
    if (n && !ns)
        n = 0;
    if (n)
        memcpy(ns, s, n * sizeof(OVRetrySection));
    free(sections);
    sections = ns;
    nsections = n;
    passes = p < 0 ? 0 : (p > 8 ? 8 : p);
    [self setNeedsDisplay:YES];
}

- (void)setHeadMode:(int)mode tc:(int64_t)tc
{
    if (mode == headMode && tc == headTC)
        return;
    headMode = mode;
    headTC = tc;
    [self setNeedsDisplay:YES];
}

- (int)fps { return (count && (points[0].flags & 32)) ? 25 : 30; }

static NSString *tc_text(int64_t k, int fps, BOOL frames)
{
    if (k < 0)
        return frames ? @"--:--:--:--" : @"--:--:--";
    if (frames)
        return [NSString stringWithFormat:@"%02d:%02d:%02d:%02d", (int)(k / fps / 3600), (int)(k / fps / 60 % 60),
                (int)(k / fps % 60), (int)(k % fps)];
    return [NSString stringWithFormat:@"%02d:%02d:%02d", (int)(k / fps / 3600), (int)(k / fps / 60 % 60), (int)(k / fps % 60)];
}

/* the section that is being read or searched now, or NULL */
- (const OVRetrySection *)activeSection
{
    size_t i;
    for (i = 0; i < nsections; i++)
        if (sections[i].state == OVSectionSeeking || sections[i].state == OVSectionReading)
            return &sections[i];
    return NULL;
}

/* Frame of the first pass that has tape time code k (or the nearest one).
 * A time code can be there twice: prefer the place near `hint`. */
- (long)indexForTC:(int64_t)k hint:(long)hint
{
    size_t i;
    long best = -1;
    int64_t bestD = 0, bestH = 0;
    for (i = 0; i < count; i++) {
        int64_t d, h;
        if (points[i].tc < 0)
            continue;
        d = points[i].tc > k ? points[i].tc - k : k - points[i].tc;
        h = hint < 0 ? 0 : ((long)i > hint ? (long)i - hint : hint - (long)i);
        if (best < 0 || d < bestD || (d == bestD && h < bestH)) {
            best = (long)i;
            bestD = d;
            bestH = h;
        }
    }
    return best;
}

- (CGFloat)laneHeight { return passes ? passes * (passes <= 3 ? 6 : 4) + 3 : 0; }

static void draw_tag(NSString *s, CGFloat x, CGFloat y, CGFloat w, BOOL leftOf, NSColor *color)
{
    NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                       color, NSForegroundColorAttributeName,
                       [NSFont userFixedPitchFontOfSize:10], NSFontAttributeName, nil];
    NSSize sz = [s sizeWithAttributes:a];
    if (leftOf)
        x -= sz.width + 8;
    if (x + sz.width + 6 > w)
        x = w - sz.width - 6;
    if (x < 0)
        x = 0;
    [[NSColor colorWithCalibratedWhite:0 alpha:0.8] set];
    NSRectFillUsingOperation(NSMakeRect(x, y, sz.width + 6, sz.height), NSCompositeSourceOver);
    [s drawAtPoint:NSMakePoint(x + 3, y) withAttributes:a];
}

- (NSString *)hoverTextAt:(CGFloat)hx width:(CGFloat)w
{
    size_t i0 = (size_t)((double)hx / w * count), i1 = (size_t)((double)(hx + 1) / w * count), i, worst, k;
    unsigned bad = 0, fixed = 0, reads = 0, waiting = 0, started = 0;
    NSMutableString *s;
    if (i0 >= count)
        i0 = count - 1;
    if (i1 <= i0)
        i1 = i0 + 1;
    if (i1 > count)
        i1 = count;
    worst = i0;
    for (i = i0; i < i1; i++) {
        if ((unsigned)points[i].video + points[i].audio > (unsigned)points[worst].video + points[worst].audio)
            worst = i;
        if (points[i].video || points[i].audio) {
            bad++;
            if (points[i].flags & 16)
                fixed++;
        }
    }
    s = [NSMutableString stringWithFormat:@"%@  frame %lu", tc_text(points[worst].tc, [self fps], YES), (unsigned long)worst + 1];
    if (points[worst].video || points[worst].audio)
        [s appendFormat:@"  video %.1f%%  audio %u blocks", points[worst].video / 10.0, (unsigned)points[worst].audio];
    else
        [s appendString:@"  no error"];
    for (k = 0; k < nsections; k++) {
        const OVRetrySection *sc = &sections[k];
        if (sc->pass > started)
            started = sc->pass;
        if (sc->first > sc->last || sc->last < i0 || sc->first >= i1)
            continue;
        if (sc->state == OVSectionRead || sc->state == OVSectionClean || sc->state == OVSectionPartial)
            reads++;
        else if (sc->state != OVSectionSkipped)
            waiting++;
    }
    if (reads)
        [s appendFormat:@"  re-read %u time%s", reads, reads > 1 ? "s" : ""];
    if (bad && fixed == bad)
        [s appendString:@": repaired"];
    else if (reads && bad)
        [s appendString:@": errors remain"];
    if (waiting)
        [s appendString:@"  being re-read"];
    else if (bad > fixed && (unsigned)passes > started && points[worst].tc >= 0)
        [s appendString:@"  to be re-read"];
    return s;
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    CGFloat w = b.size.width, h = b.size.height, lane = [self laneHeight], base = RULER_H + lane;
    CGFloat mid = base + (h - base) * 0.58;
    int fps = [self fps];
    long x, wi = (long)w;
    uint8_t *todo;
    NSDictionary *small = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSColor colorWithCalibratedWhite:0.7 alpha:1], NSForegroundColorAttributeName,
                           [NSFont systemFontOfSize:9], NSFontAttributeName, nil];
    [[NSColor colorWithCalibratedWhite:0.12 alpha:1] set];
    NSRectFill(b);
    if (!count) {
        if (emptyText) {
            NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                               [NSColor colorWithCalibratedWhite:0.6 alpha:1], NSForegroundColorAttributeName,
                               [NSFont systemFontOfSize:11], NSFontAttributeName, nil];
            [emptyText drawAtPoint:NSMakePoint(8, h / 2 - 6) withAttributes:a];
        }
        return;
    }
    /* time ruler: a label every so many seconds of the recording, with the
     * tape time code found there */
    {
        static const int steps[] = { 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600 };
        double pps = w / ((double)count / fps);
        int step = 3600;
        size_t si, i;
        for (si = 0; si < sizeof(steps) / sizeof(steps[0]); si++)
            if (steps[si] * pps >= 84) {
                step = steps[si];
                break;
            }
        [[NSColor colorWithCalibratedWhite:0.17 alpha:1] set];
        NSRectFill(NSMakeRect(0, 0, w, RULER_H));
        for (i = 0; i < count; i += (size_t)step * fps) {
            CGFloat tx = (CGFloat)floor((double)i / count * w);
            size_t j = i;
            while (j < count && j < i + (size_t)fps && points[j].tc < 0)
                j++;
            [[NSColor colorWithCalibratedWhite:0.2 alpha:1] set];
            NSRectFill(NSMakeRect(tx, RULER_H, 1, h - RULER_H));
            [[NSColor colorWithCalibratedWhite:0.5 alpha:1] set];
            NSRectFill(NSMakeRect(tx, 0, 1, RULER_H));
            if (tx + 46 < w)
                [tc_text(j < count ? points[j].tc : -1, fps, NO) drawAtPoint:NSMakePoint(tx + 3, 1) withAttributes:small];
        }
    }
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1] set];
    NSRectFill(NSMakeRect(0, mid, w, 1));
    NSRectFill(NSMakeRect(0, base, w, 1));

    todo = (uint8_t *)calloc((size_t)(wi > 0 ? wi : 1), 1);
    for (x = 0; x < wi; x++) {
        size_t i0 = (size_t)((double)x / w * count), i1 = (size_t)((double)(x + 1) / w * count), i;
        unsigned vmax = 0, amax = 0, vfix = 0, afix = 0, flags = 0;
        if (i1 <= i0)
            i1 = i0 + 1;
        if (i0 >= count)
            break;
        if (i1 > count)
            i1 = count;
        for (i = i0; i < i1; i++) {
            if (points[i].flags & 16) {
                if (points[i].video > vfix) vfix = points[i].video;
                if (points[i].audio > afix) afix = points[i].audio;
            } else {
                if (points[i].video > vmax) vmax = points[i].video;
                if (points[i].audio > amax) amax = points[i].audio;
                if (todo && (points[i].flags & 64))
                    todo[x] = 1;
            }
            flags |= points[i].flags;
        }
        /* repaired errors first, what is left over them */
        if (vfix > vmax) {
            CGFloat vh = (CGFloat)(sqrt(vfix / 1000.0) * (mid - base - 2));
            if (vh < 2) vh = 2;
            [[NSColor colorWithCalibratedRed:0.2 green:0.62 blue:0.3 alpha:1] set];
            NSRectFill(NSMakeRect(x, base + 1, 1, vh));
        }
        if (vmax) {
            /* square root scale so that small errors stay visible */
            CGFloat vh = (CGFloat)(sqrt(vmax / 1000.0) * (mid - base - 2));
            if (vh < 2) vh = 2;
            if (flags & 4)
                [[NSColor colorWithCalibratedRed:1 green:0.2 blue:0.9 alpha:1] set];
            else
                [[NSColor colorWithCalibratedRed:0.95 green:0.2 blue:0.2 alpha:1] set];
            NSRectFill(NSMakeRect(x, base + 1, 1, vh));
        }
        if (afix > amax) {
            CGFloat ah = (CGFloat)(sqrt(afix > 108 ? 1.0 : afix / 108.0) * (h - mid - 14));
            if (ah < 2) ah = 2;
            [[NSColor colorWithCalibratedRed:0.2 green:0.62 blue:0.3 alpha:1] set];
            NSRectFill(NSMakeRect(x, h - 12 - ah, 1, ah));
        }
        if (amax) {
            CGFloat ah = (CGFloat)(sqrt(amax > 108 ? 1.0 : amax / 108.0) * (h - mid - 14));
            if (ah < 2) ah = 2;
            [[NSColor colorWithCalibratedRed:1 green:0.6 blue:0.1 alpha:1] set];
            NSRectFill(NSMakeRect(x, h - 12 - ah, 1, ah));
        }
        if (flags & 2) {
            [[NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1 alpha:1] set];
            NSRectFill(NSMakeRect(x, h - 10, 1, 10));
        } else if (flags & 9) {
            [[NSColor colorWithCalibratedRed:1 green:0.95 blue:0.2 alpha:1] set];
            NSRectFill(NSMakeRect(x, h - 6, 1, 6));
        }
    }
    /* re-read lanes: pass 1 is the top row */
    if (passes) {
        CGFloat rh = passes <= 3 ? 6 : 4;
        int p;
        for (p = 1; p <= passes; p++) {
            CGFloat ry = base - 1 - p * rh;
            BOOL started = NO;
            size_t k;
            [[NSColor colorWithCalibratedWhite:0.16 alpha:1] set];
            NSRectFill(NSMakeRect(0, ry, w, rh - 1));
            for (k = 0; k < nsections; k++) {
                const OVRetrySection *sc = &sections[k];
                CGFloat x0, x1;
                NSColor *c;
                if (sc->pass != p)
                    continue;
                started = YES;
                if (sc->first > sc->last)
                    continue;
                x0 = (CGFloat)floor((double)sc->first / count * w);
                x1 = (CGFloat)ceil((double)(sc->last + 1) / count * w);
                if (x1 - x0 < 2)
                    x1 = x0 + 2;
                switch (sc->state) {
                case OVSectionSeeking: c = [NSColor colorWithCalibratedWhite:0.7 alpha:1]; break;
                case OVSectionReading: c = [NSColor whiteColor]; break;
                case OVSectionRead:
                case OVSectionPartial: c = [NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1 alpha:1]; break;
                case OVSectionClean: c = [NSColor colorWithCalibratedRed:0.25 green:0.8 blue:0.35 alpha:1]; break;
                case OVSectionSkipped: c = [NSColor colorWithCalibratedWhite:0.42 alpha:1]; break;
                default: c = [NSColor colorWithCalibratedRed:0.95 green:0.68 blue:0.1 alpha:1];
                }
                [c set];
                NSRectFill(NSMakeRect(x0, ry, x1 - x0, rh - 1));
            }
            if (!started && todo) {
                /* not planned in detail yet: wherever errors are left */
                [[NSColor colorWithCalibratedRed:0.5 green:0.36 blue:0.08 alpha:1] set];
                for (x = 0; x < wi; x++)
                    if (todo[x])
                        NSRectFill(NSMakeRect(x, ry, 1, rh - 1));
            }
        }
    }
    free(todo);
    if (selected >= 0 && (size_t)selected < count) {
        CGFloat sx = (CGFloat)((double)selected / count * w);
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(floor(sx), 0, 1, h));
    }
    /* where the tape is */
    if (headMode) {
        long idx = -1;
        int64_t k = -1;
        if (headMode == 1) {
            idx = (long)count - 1;
            k = points[idx].tc;
        } else if (headTC >= 0) {
            const OVRetrySection *as = [self activeSection];
            idx = [self indexForTC:headTC hint:(as && as->first <= as->last) ? (long)as->first : -1];
            k = headTC;
        }
        if (idx >= 0) {
            CGFloat hx = (CGFloat)floor((double)(idx + 1) / count * w);
            NSBezierPath *tri = [NSBezierPath bezierPath];
            NSColor *c = [NSColor colorWithCalibratedRed:0.45 green:0.95 blue:1 alpha:1];
            if (hx > w - 1)
                hx = w - 1;
            [c set];
            NSRectFill(NSMakeRect(hx, 0, 1, h));
            [tri moveToPoint:NSMakePoint(hx - 4, h)];
            [tri lineToPoint:NSMakePoint(hx + 5, h)];
            [tri lineToPoint:NSMakePoint(hx + 0.5, h - 6)];
            [tri closePath];
            [tri fill];
            draw_tag(tc_text(k, fps, YES), hx + 4, h - 27, w, hx > w * 0.6, c);
        }
    }
    if (hoverX >= 0 && hoverX < w) {
        [[NSColor colorWithCalibratedWhite:0.6 alpha:1] set];
        NSRectFill(NSMakeRect(floor(hoverX), RULER_H, 1, h - RULER_H));
        draw_tag([self hoverTextAt:(CGFloat)floor(hoverX) width:w], 2, h - 13, w, NO, [NSColor whiteColor]);
    }
}

- (void)mouseMoved:(NSEvent *)e
{
    hoverX = [self convertPoint:[e locationInWindow] fromView:nil].x;
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)e { [self mouseMoved:e]; }

- (void)mouseExited:(NSEvent *)e
{
    hoverX = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    if (!count)
        return;
    selected = (long)(p.x / [self bounds].size.width * count);
    if (selected < 0) selected = 0;
    if ((size_t)selected >= count) selected = (long)count - 1;
    [self setNeedsDisplay:YES];
    if (target && action)
        [target performSelector:action withObject:self];
}

- (void)mouseDragged:(NSEvent *)e { [self mouseDown:e]; }
@end

/* ------------------------------------------------------------------ */

@implementation OVBlockMapView

- (void)dealloc
{
    free(types);
    free(status);
    [caption release];
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)clear
{
    nblocks = 0;
    [caption release];
    caption = nil;
    [self setNeedsDisplay:YES];
}

- (void)setFrameData:(const uint8_t *)data size:(size_t)size bitDepth:(int)bits caption:(NSString *)c
{
    size_t i;
    free(types);
    free(status);
    nblocks = size / DV_BLOCK_SIZE;
    types = (uint8_t *)malloc(nblocks ? nblocks : 1);
    status = (uint8_t *)malloc(nblocks ? nblocks : 1);
    if (!types || !status) {
        nblocks = 0;
        return;
    }
    dv_block_status(data, size, bits == 12 ? 1 : (bits == 16 ? 0 : -1), status);
    for (i = 0; i < nblocks; i++)
        types[i] = data[i * DV_BLOCK_SIZE] >> 5;
    [caption release];
    caption = [c copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    size_t rows, r, col;
    CGFloat top = 18, cw, ch;
    [[NSColor colorWithCalibratedWhite:0.12 alpha:1] set];
    NSRectFill(b);
    if (caption) {
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSColor colorWithCalibratedWhite:0.85 alpha:1], NSForegroundColorAttributeName,
                           [NSFont systemFontOfSize:10], NSFontAttributeName, nil];
        [caption drawAtPoint:NSMakePoint(4, 2) withAttributes:a];
    }
    if (!nblocks)
        return;
    rows = (nblocks + 149) / 150;
    cw = b.size.width / 150.0;
    ch = (b.size.height - top) / (CGFloat)rows;
    for (r = 0; r < rows; r++)
        for (col = 0; col < 150; col++) {
            size_t i = r * 150 + col;
            NSColor *c;
            if (i >= nblocks)
                break;
            switch (types[i]) {
            case 4: /* video */
                c = status[i] == DV_BS_NOK ? [NSColor colorWithCalibratedRed:0.95 green:0.15 blue:0.15 alpha:1]
                                           : [NSColor colorWithCalibratedRed:0.15 green:0.55 blue:0.25 alpha:1];
                break;
            case 3: /* audio */
                c = status[i] == DV_BS_NOK ? [NSColor colorWithCalibratedRed:1 green:0.6 blue:0.1 alpha:1]
                                           : [NSColor colorWithCalibratedRed:0.15 green:0.5 blue:0.6 alpha:1];
                break;
            default:
                c = [NSColor colorWithCalibratedWhite:0.45 alpha:1];
            }
            [c set];
            NSRectFill(NSMakeRect(col * cw, top + r * ch, cw > 2 ? cw - 1 : cw, ch > 2 ? ch - 1 : ch));
        }
}
@end

/* ------------------------------------------------------------------ */

@implementation OVPictureView

- (id)initWithFrame:(NSRect)r
{
    self = [super initWithFrame:r];
    if (self)
        showErrors = YES;
    return self;
}

- (void)dealloc
{
    [image release];
    [caption release];
    free(rects);
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return NO; }
- (size_t)markCount { return nrects; }

- (void)setShowErrors:(BOOL)on
{
    showErrors = on;
    [self setNeedsDisplay:YES];
}

- (void)clear
{
    [image release];
    image = nil;
    [caption release];
    caption = nil;
    nrects = 0;
    picH = 0;
    [self setNeedsDisplay:YES];
}

- (void)setImage:(NSImage *)img frameData:(const uint8_t *)data size:(size_t)size bitDepth:(int)bits
            wide:(BOOL)w caption:(NSString *)c
{
    size_t nb = size / DV_BLOCK_SIZE, nseq = size / 12000, seq, b;
    uint8_t *st = (uint8_t *)malloc(nb ? nb : 1);
    uint16_t *r;
    int dsf = size >= 144000;
    [img retain];
    [image release];
    image = img;
    [caption release];
    caption = [c copy];
    wideShape = w;
    picH = data && nseq ? (dsf ? 576 : 480) : 0;
    nrects = 0;
    audioErrors = 0;
    free(rects);
    rects = (uint8_t *)malloc((nseq * 135 + 1) * 4 * sizeof(uint16_t));
    r = (uint16_t *)rects;
    if (st && rects && data && nseq) {
        dv_block_status(data, size, bits == 12 ? 1 : (bits == 16 ? 0 : -1), st);
        for (seq = 0; seq < nseq; seq++) {
            int v = 0;
            for (b = 0; b < 150; b++) {
                size_t i = seq * 150 + b;
                int type = data[i * DV_BLOCK_SIZE] >> 5;
                if (type == 3 && st[i] == DV_BS_NOK)
                    audioErrors++;
                if (type != 4)
                    continue;
                if (st[i] == DV_BS_NOK && v < 135) {
                    int x, y, bw, bh;
                    dv_video_block_rect(dsf, (int)seq, v, &x, &y, &bw, &bh);
                    r[nrects * 4] = (uint16_t)x;
                    r[nrects * 4 + 1] = (uint16_t)y;
                    r[nrects * 4 + 2] = (uint16_t)bw;
                    r[nrects * 4 + 3] = (uint16_t)bh;
                    nrects++;
                }
                v++;
            }
        }
    }
    free(st);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds], p;
    CGFloat ar = wideShape ? 16.0 / 9.0 : 4.0 / 3.0;
    [[NSColor blackColor] set];
    NSRectFill(b);
    if (!picH && !image)
        return;
    /* the picture, as large as fits, in its display shape */
    p.size.width = b.size.width;
    p.size.height = (CGFloat)floor(b.size.width / ar);
    if (p.size.height > b.size.height) {
        p.size.height = b.size.height;
        p.size.width = (CGFloat)floor(b.size.height * ar);
    }
    p.origin.x = (CGFloat)floor((b.size.width - p.size.width) / 2);
    p.origin.y = (CGFloat)floor((b.size.height - p.size.height) / 2);
    if (image)
        [image drawInRect:p fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0];
    else {
        [[NSColor colorWithCalibratedWhite:0.18 alpha:1] set];
        NSRectFill(p);
    }
    if (showErrors && picH && nrects) {
        const uint16_t *r = (const uint16_t *)rects;
        CGFloat sx = p.size.width / 720.0, sy = p.size.height / (CGFloat)picH;
        size_t i;
        [[NSColor colorWithCalibratedRed:1 green:0.1 blue:0.1 alpha:0.5] set];
        for (i = 0; i < nrects; i++) {
            NSRect q = NSMakeRect(p.origin.x + r[i * 4] * sx,
                                  p.origin.y + p.size.height - (r[i * 4 + 1] + r[i * 4 + 3]) * sy,
                                  r[i * 4 + 2] * sx, r[i * 4 + 3] * sy);
            NSRectFillUsingOperation(q, NSCompositeSourceOver);
        }
    }
    if (showErrors && audioErrors) {
        /* audio errors have no place in the picture: a bar along the bottom */
        [[NSColor colorWithCalibratedRed:1 green:0.6 blue:0.1 alpha:0.9] set];
        NSRectFillUsingOperation(NSMakeRect(p.origin.x, p.origin.y, p.size.width, 4), NSCompositeSourceOver);
    }
    if (caption) {
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSColor whiteColor], NSForegroundColorAttributeName,
                           [NSFont userFixedPitchFontOfSize:11], NSFontAttributeName, nil];
        NSSize sz = [caption sizeWithAttributes:a];
        [[NSColor colorWithCalibratedWhite:0 alpha:0.65] set];
        NSRectFillUsingOperation(NSMakeRect(p.origin.x, p.origin.y + p.size.height - sz.height - 2, sz.width + 8, sz.height + 2),
                                 NSCompositeSourceOver);
        [caption drawAtPoint:NSMakePoint(p.origin.x + 4, p.origin.y + p.size.height - sz.height - 1) withAttributes:a];
    }
}
@end
