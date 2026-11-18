/*
 * OldDV Rescue - player: plays a DV file (picture and, on 10.6 - 10.14,
 * sound: see OVMovie.h) and shows the damaged blocks of each frame over the picture,
 * with the error timeline under it.
 */
#import <Cocoa/Cocoa.h>
#include "dvcore.h"

@class OVMovie, OVGraphView, OVPictureView;

@interface OVPlayer : NSObject {
    NSWindow *window;
    OVPictureView *picture;
    OVGraphView *graph;
    NSButton *playButton, *errCheck;
    NSTextField *info;
    OVMovie *movie;
    NSString *path;
    dv_frame *frames;       /* copy of the report's frames, sta not kept */
    uint32_t count;
    double fps;
    FILE *fp;
    uint8_t *buf;
    NSTimer *timer;
    long shown;
    BOOL wasPlaying;
}
/* report: the analysis of the file; its frames are copied */
- (id)initWithFile:(NSString *)file report:(const dv_report *)report;
- (void)showAtFrame:(uint32_t)index;
- (void)close;
@end
