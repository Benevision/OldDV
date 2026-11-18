/*
 * OldDV Rescue - the picture (and sound) of a DV file.
 *
 * Mac OS X 10.6 - 10.14: QuickTime through QTKit, with sound.
 * Later systems have no QTKit (build with -DOLDDV_MODERN): AVFoundation
 * decodes the picture; it does not see the sound of a raw DV stream, so
 * the player is silent there.
 */
#import <Cocoa/Cocoa.h>

@interface OVMovie : NSObject {
    id movie;        /* QTMovie, or AVURLAsset */
    id generator;    /* AVAssetImageGenerator */
    double duration;
    double position; /* modern: where the player is when it does not play */
    double startWall;
    BOOL running;
}
+ (OVMovie *)movieWithFile:(NSString *)path;   /* nil when the file cannot be opened */
+ (BOOL)hasSound;
- (NSImage *)imageAtTime:(double)seconds;
- (NSImage *)currentImage;
- (BOOL)getCurrentTime:(double *)seconds;
- (void)setCurrentTime:(double)seconds;
- (void)play;
- (void)stop;
- (BOOL)playing;
@end
