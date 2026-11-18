/*
 * OldDV Rescue - the picture (and sound) of a DV file. See OVMovie.h.
 */
#import "OVMovie.h"

#ifndef OLDDV_MODERN
#import <QTKit/QTKit.h>

@implementation OVMovie

+ (OVMovie *)movieWithFile:(NSString *)path
{
    OVMovie *m = [[[OVMovie alloc] init] autorelease];
    m->movie = [[QTMovie movieWithFile:path error:NULL] retain];
    return m->movie ? m : nil;
}

+ (BOOL)hasSound { return YES; }

- (void)dealloc
{
    [(QTMovie *)movie stop];
    [movie release];
    [super dealloc];
}

- (NSImage *)imageAtTime:(double)seconds { return [(QTMovie *)movie frameImageAtTime:QTMakeTimeWithTimeInterval(seconds)]; }
- (NSImage *)currentImage { return [(QTMovie *)movie currentFrameImage]; }

- (BOOL)getCurrentTime:(double *)seconds
{
    NSTimeInterval t = 0;
    if (!QTGetTimeInterval([(QTMovie *)movie currentTime], &t))
        return NO;
    *seconds = t;
    return YES;
}

- (void)setCurrentTime:(double)seconds { [(QTMovie *)movie setCurrentTime:QTMakeTimeWithTimeInterval(seconds)]; }
- (void)play { [(QTMovie *)movie play]; }
- (void)stop { [(QTMovie *)movie stop]; }
- (BOOL)playing { return [(QTMovie *)movie rate] != 0; }
@end

#else
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@implementation OVMovie

+ (OVMovie *)movieWithFile:(NSString *)path
{
    OVMovie *m = [[[OVMovie alloc] init] autorelease];
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetImageGenerator *g;
    if (!a || ![[a tracksWithMediaType:AVMediaTypeVideo] count])
        return nil;
    g = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
    [g setRequestedTimeToleranceBefore:kCMTimeZero];
    [g setRequestedTimeToleranceAfter:kCMTimeZero];
    m->movie = [a retain];
    m->generator = [g retain];
    m->duration = CMTimeGetSeconds([a duration]);
    return m;
}

+ (BOOL)hasSound { return NO; }

- (void)dealloc
{
    [generator release];
    [movie release];
    [super dealloc];
}

static double wall(void) { return [NSDate timeIntervalSinceReferenceDate]; }

- (NSImage *)imageAtTime:(double)seconds
{
    CGImageRef im;
    NSImage *img;
    if (seconds < 0)
        seconds = 0;
    im = [(AVAssetImageGenerator *)generator copyCGImageAtTime:CMTimeMakeWithSeconds(seconds, 30000) actualTime:NULL error:NULL];
    if (!im)
        return nil;
    img = [[[NSImage alloc] initWithCGImage:im size:NSMakeSize(CGImageGetWidth(im), CGImageGetHeight(im))] autorelease];
    CGImageRelease(im);
    return img;
}

- (BOOL)getCurrentTime:(double *)seconds
{
    if (running) {
        double t = position + wall() - startWall;
        if (duration > 0 && t >= duration) {
            /* the end: stop there */
            running = NO;
            position = t = duration;
        }
        *seconds = t;
    } else
        *seconds = position;
    return YES;
}

- (NSImage *)currentImage
{
    double t = 0;
    [self getCurrentTime:&t];
    return [self imageAtTime:t];
}

- (void)setCurrentTime:(double)seconds
{
    position = seconds < 0 ? 0 : seconds;
    startWall = wall();
}

- (void)play
{
    if (!running) {
        startWall = wall();
        running = YES;
    }
}

- (void)stop
{
    double t = 0;
    if (running) {
        [self getCurrentTime:&t];
        running = NO;
        position = t;
    }
}

- (BOOL)playing
{
    double t;
    [self getCurrentTime:&t]; /* notices the end */
    return running;
}
@end
#endif
