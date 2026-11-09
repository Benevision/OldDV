/*
 * OldDV Rescue - custom views (see OVViews.h)
 */
#import "OVViews.h"
#include <math.h>

@implementation OVGraphView

- (id)initWithFrame:(NSRect)r
{
    self = [super initWithFrame:r];
    if (self)
        selected = -1;
    return self;
}

- (void)dealloc
{
    free(points);
    [emptyText release];
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return NO; }

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
    [self setNeedsDisplay:YES];
}

- (size_t)count { return count; }
- (long)selected { return selected; }
- (void)setSelected:(long)i { selected = i; [self setNeedsDisplay:YES]; }
- (void)setTarget:(id)t action:(SEL)a { target = t; action = a; }
- (void)setEmptyText:(NSString *)s { [emptyText release]; emptyText = [s copy]; [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    CGFloat w = b.size.width, h = b.size.height, mid = h * 0.62;
    long x;
    [[NSColor colorWithCalibratedWhite:0.12 alpha:1] set];
    NSRectFill(b);
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1] set];
    NSRectFill(NSMakeRect(0, mid, w, 1));
    if (!count) {
        if (emptyText) {
            NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                               [NSColor colorWithCalibratedWhite:0.6 alpha:1], NSForegroundColorAttributeName,
                               [NSFont systemFontOfSize:11], NSFontAttributeName, nil];
            [emptyText drawAtPoint:NSMakePoint(8, h / 2 - 6) withAttributes:a];
        }
        return;
    }
    for (x = 0; x < (long)w; x++) {
        size_t i0 = (size_t)((double)x / w * count), i1 = (size_t)((double)(x + 1) / w * count), i;
        unsigned vmax = 0, amax = 0, flags = 0;
        if (i1 <= i0)
            i1 = i0 + 1;
        if (i0 >= count)
            break;
        if (i1 > count)
            i1 = count;
        for (i = i0; i < i1; i++) {
            if (points[i].video > vmax) vmax = points[i].video;
            if (points[i].audio > amax) amax = points[i].audio;
            flags |= points[i].flags;
        }
        if (vmax) {
            /* square root scale so that small errors stay visible */
            CGFloat vh = (CGFloat)(sqrt(vmax / 1000.0) * (mid - 2));
            if (vh < 2) vh = 2;
            if (flags & 4)
                [[NSColor colorWithCalibratedRed:1 green:0.2 blue:0.9 alpha:1] set];
            else
                [[NSColor colorWithCalibratedRed:0.95 green:0.2 blue:0.2 alpha:1] set];
            NSRectFill(NSMakeRect(x, 0, 1, vh));
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
    if (selected >= 0 && (size_t)selected < count) {
        CGFloat sx = (CGFloat)((double)selected / count * w);
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(floor(sx), 0, 1, h));
    }
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
