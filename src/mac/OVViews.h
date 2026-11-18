/*
 * OldDV Rescue - custom views: error timeline and DIF block map.
 */
#import <Cocoa/Cocoa.h>
#import "OVEngine.h"

/* Timeline of a capture, one column per group of frames.
 *   top:     blue marks = recording starts, yellow marks = time code breaks,
 *            orange bars = audio errors
 *   middle:  red bars = video blocks with errors (magenta: nothing readable),
 *            green = repaired by a re-read
 *   lanes:   one row per re-read pass: amber = to be read, white = being
 *            read, green = now clean, blue = read but errors remain,
 *            grey = skipped
 *   bottom:  tape time codes
 * A marker shows where the tape is; the mouse shows the details of a
 * place. Click to select a frame. */
@interface OVGraphView : NSView {
    OVGraphPoint *points;
    size_t count, cap;
    long selected;
    id target;
    SEL action;
    NSString *emptyText;
    OVRetrySection *sections;
    size_t nsections;
    int passes;
    int headMode;
    int64_t headTC;
    CGFloat hoverX;
    NSTrackingArea *tracking;
}
- (void)setPoints:(const OVGraphPoint *)p count:(size_t)n;
- (void)appendPoints:(const OVGraphPoint *)p count:(size_t)n;
- (void)clear;
- (size_t)count;
- (void)setSelected:(long)index;
- (long)selected;
- (void)setTarget:(id)t action:(SEL)a;
- (void)setEmptyText:(NSString *)s;
/* re-read sections of all passes and the number of passes (rows) */
- (void)setSections:(const OVRetrySection *)s count:(size_t)n passes:(int)p;
/* marker: 0 none, 1 at the end of the recording, 2 at tape time code tc */
- (void)setHeadMode:(int)mode tc:(int64_t)tc;
@end

/* One frame: each row is a DIF sequence (track), each cell an 80 byte
 * block: grey = header/subcode/aux, green = video OK, red = concealed
 * video, teal = audio OK, orange = audio error. */
@interface OVBlockMapView : NSView {
    uint8_t *types;
    uint8_t *status;
    size_t nblocks;
    NSString *caption;
}
- (void)setFrameData:(const uint8_t *)data size:(size_t)size bitDepth:(int)bits caption:(NSString *)c;
- (void)clear;
@end

/* One frame as a picture, with the places of its damaged video blocks
 * marked over it (red), like DVRescue's player. */
@interface OVPictureView : NSView {
    NSImage *image;
    uint8_t *rects;      /* x, y, w, h as uint16_t each, in picture pixels */
    size_t nrects;
    int picH;            /* 576 or 480; 0: no frame */
    BOOL wideShape, showErrors;
    unsigned audioErrors;
    NSString *caption;
}
/* image may be nil (the picture cannot be decoded): the marks still show */
- (void)setImage:(NSImage *)img frameData:(const uint8_t *)data size:(size_t)size bitDepth:(int)bits
            wide:(BOOL)w caption:(NSString *)c;
- (void)setShowErrors:(BOOL)on;
- (void)clear;
- (size_t)markCount;
@end
