/*
 * OldDV Rescue - custom views: error timeline and DIF block map.
 */
#import <Cocoa/Cocoa.h>
#import "OVEngine.h"

/* Timeline of errors per frame: red bars (from bottom) = video blocks with
 * errors, orange bars (from top) = audio errors, blue marks = recording
 * starts, yellow marks = time code breaks. Click to select a frame. */
@interface OVGraphView : NSView {
    OVGraphPoint *points;
    size_t count, cap;
    long selected;
    id target;
    SEL action;
    NSString *emptyText;
}
- (void)setPoints:(const OVGraphPoint *)p count:(size_t)n;
- (void)appendPoints:(const OVGraphPoint *)p count:(size_t)n;
- (void)clear;
- (size_t)count;
- (void)setSelected:(long)index;
- (long)selected;
- (void)setTarget:(id)t action:(SEL)a;
- (void)setEmptyText:(NSString *)s;
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
