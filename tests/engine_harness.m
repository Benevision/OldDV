/*
 * Drives the capture engine without a camcorder: a stub backend feeds a DV
 * file to the engine. Used to test recording on this Mac with a background
 * copy to a destination folder that may fail.
 *
 *   engine_harness INPUT.dv LOCALDIR DESTDIR|- NAME [stop-copy-after-seconds]
 */
#import <Cocoa/Cocoa.h>
#import "OVEngine.h"
#import "OVViews.h"

@implementation OVCaptureBackend
+ (OVCaptureBackend *)backendWithChoice:(OVEngineChoice)choice { return [[[OVCaptureBackend alloc] init] autorelease]; }
+ (BOOL)avFoundationAvailable { return NO; }
+ (BOOL)qtKitAvailable { return NO; }
- (NSString *)engineName { return @"test feed"; }
- (NSArray *)devices { return [NSArray array]; }
- (BOOL)startWithDeviceID:(NSString *)uid sink:(id<OVCaptureSink>)s preview:(NSView *)c error:(NSString **)err { sink = s; return YES; }
- (void)setPreviewHidden:(BOOL)hidden {}
- (void)stop {}
- (int64_t)bytesReceived { return bytesReceived; }
- (void)deliver:(const void *)bytes length:(size_t)len { [sink captureReceivedBytes:bytes length:len]; }
@end

/* A simulated tape deck for --sim: a position on a tape (frames) and a
 * transport state; the main loop "plays" the tape into the engine. */
static BOOL simDeck;
static volatile int simState = OVDeckStopped;
static volatile long simPos, simLen;

@implementation OVDeck
+ (OVDeck *)deckForDeviceID:(NSString *)g { return simDeck ? [[[OVDeck alloc] init] autorelease] : nil; }
+ (NSUInteger)avcUnitCount { return simDeck ? 1 : 0; }
- (NSString *)name { return simDeck ? @"simulated deck" : @"none"; }
- (BOOL)play { simState = OVDeckPlaying; return YES; }
- (BOOL)stop { simState = OVDeckStopped; return YES; }
- (BOOL)pause { simState = OVDeckPaused; return YES; }
- (BOOL)rewind { simState = OVDeckRewinding; return YES; }
- (BOOL)fastForward { simState = OVDeckFastForwarding; return YES; }
- (BOOL)reversePlay { return NO; }
- (BOOL)fastReversePlay { simState = OVDeckRewinding; return YES; }
- (OVDeckState)state { return (OVDeckState)simState; }
- (BOOL)timeCodeHours:(int *)h minutes:(int *)m seconds:(int *)s frames:(int *)f
{
    long p = simPos;
    if (!simDeck)
        return NO;
    *h = (int)(p / 30 / 3600); *m = (int)(p / 30 / 60 % 60); *s = (int)(p / 30 % 60); *f = (int)(p % 30);
    return YES;
}
+ (NSString *)describeState:(OVDeckState)st
{
    static NSString *n[] = { @"unknown", @"stopped", @"playing", @"paused", @"rewinding", @"fast forward", @"reverse", @"recording", @"no tape" };
    return n[st];
}
@end

@interface Del : NSObject <OVEngineDelegate>
@end
@implementation Del
- (void)engineLogLine:(NSString *)line { printf("LOG %s\n", [line UTF8String]); fflush(stdout); }
- (void)engineStateDidChange:(OVEngine *)e {}
@end

static void spin(double s)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]];
}

/* what the app does 4 times a second for its timeline, then a picture of it */
static void snapshot(OVEngine *e, OVGraphView *g, NSString *dir, int n)
{
    OVRetryStatus rs = [e retryStatus];
    OVEngineState st = [e state];
    size_t np = [e graphPointCount], ns = 4096;
    OVGraphPoint *all = (OVGraphPoint *)malloc((np + 1) * sizeof(OVGraphPoint));
    OVRetrySection *sec = (OVRetrySection *)malloc(ns * sizeof(OVRetrySection));
    NSBitmapImageRep *rep;
    np = [e copyGraphPointsFrom:0 into:all max:np];
    [g setPoints:all count:np];
    ns = [e copyRetrySections:sec max:ns];
    [g setSections:sec count:ns passes:rs.planned];
    [g setHeadMode:st == OVEngineRecording ? 1 : (st == OVEngineRetrying ? 2 : 0) tc:rs.headTC];
    rep = [g bitmapImageRepForCachingDisplayInRect:[g bounds]];
    [g cacheDisplayInRect:[g bounds] toBitmapImageRep:rep];
    [[rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
        writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"t%03d.png", n]] atomically:YES];
    printf("SNAP %d state %d pass %d/%d section %d/%d head %lld sections %lu:", n, (int)st, rs.pass, rs.planned,
           rs.section, rs.sections, (long long)rs.headTC, (unsigned long)ns);
    for (np = 0; np < ns; np++)
        printf(" p%d[%u-%u]=%d", sec[np].pass, sec[np].first, sec[np].last, sec[np].state);
    printf("\n");
    fflush(stdout);
    free(all);
    free(sec);
}

/* engine_harness --sim FIRST.dv PASS1.dv PASS2.dv PASS3.dv LOCALDIR NAME SNAPDIR
 * The tape reads as FIRST.dv on the first pass and as PASSn.dv on re-read
 * pass n (NTSC, time code from 00:00:00:00). Runs 10 times faster than a deck. */
static int sim_main(char **argv)
{
    Del *d = [[Del alloc] init];
    OVEngine *e = [[OVEngine alloc] initWithDelegate:d];
    OVGraphView *g = [[OVGraphView alloc] initWithFrame:NSMakeRect(0, 0, 976, 122)];
    NSData *tape[4];
    NSString *err = nil, *snapDir = [NSString stringWithUTF8String:argv[8]];
    NSString *base = [[NSString stringWithUTF8String:argv[6]] stringByAppendingPathComponent:[NSString stringWithUTF8String:argv[7]]];
    int i, it = 0, snap = 0;
    BOOL started = NO;
    [NSApplication sharedApplication];
    simDeck = YES;
    for (i = 0; i < 4; i++)
        tape[i] = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2 + i]] options:NSDataReadingMapped error:NULL];
    simLen = (long)([tape[0] length] / 120000);
    if (![e connectDevice:@"x" engine:OVEngineAutomatic preview:nil error:&err]) { printf("connect: %s\n", [err UTF8String]); return 1; }
    if (getenv("OV_MERGE_LATER")) /* leave the takes unmerged */
        [e setMergeLater:YES];
    if (getenv("OV_COPY_TO"))     /* record in LOCALDIR, copy to this folder */
        [e setCopyDestination:[NSString stringWithUTF8String:getenv("OV_COPY_TO")]];
    if (![e startRecordingTo:base retries:3 noDataTimeout:2 playDeck:YES error:&err]) { printf("start: %s\n", [err UTF8String]); return 1; }
    for (;;) {
        OVEngineState st = [e state];
        int pass = [e retryStatus].pass;
        if (st == OVEngineRecording || st == OVEngineRetrying || st == OVEngineMerging)
            started = YES;
        else if (started)
            break;
        if (simState == OVDeckPlaying) {
            long n = simLen - simPos < 15 ? simLen - simPos : 15;
            NSData *t = tape[st == OVEngineRecording ? 0 : (pass > 3 ? 3 : pass)];
            if (n > 0) {
                [e captureReceivedBytes:(const uint8_t *)[t bytes] + simPos * 120000 length:(size_t)n * 120000];
                simPos += n;
            } else
                simState = OVDeckStopped;
        } else if (simState == OVDeckRewinding) {
            simPos = simPos > 60 ? simPos - 60 : 0;
            if (!simPos) simState = OVDeckStopped;
        } else if (simState == OVDeckFastForwarding) {
            simPos = simPos + 60 < simLen ? simPos + 60 : simLen;
            if (simPos == simLen) simState = OVDeckStopped;
        }
        [e tick];
        spin(0.05);
        if (++it % 12 == 0)
            snapshot(e, g, snapDir, snap++);
    }
    while ([e state] == OVEngineCopying) /* the copy to OV_COPY_TO */
        spin(0.1);
    snapshot(e, g, snapDir, snap);
    /* the same with the mouse over it */
    [g setValue:[NSNumber numberWithDouble:222] forKey:@"hoverX"];
    snapshot(e, g, snapDir, 900);
    [g setValue:[NSNumber numberWithDouble:762] forKey:@"hoverX"];
    snapshot(e, g, snapDir, 901);
    spin(0.3);
    return 0;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    Del *d = [[Del alloc] init];
    OVEngine *e = [[OVEngine alloc] initWithDelegate:d];
    NSString *err = nil, *base;
    NSData *in;
    size_t off = 0, step = 144000 * 5;
    double stopCopyAfter = argc > 5 ? atof(argv[5]) : 0, t0;
    if (argc == 5 && !strcmp(argv[1], "--picture")) {
        /* engine_harness --picture FRAME.dv PICTURE.png OUT.png: the player's
         * picture view with the damaged blocks of the first frame marked */
        NSData *fr = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        NSImage *img = [[[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]] autorelease];
        size_t fs = [fr length] >= 144000 && (((const uint8_t *)[fr bytes])[3] & 0x80) ? 144000 : 120000;
        OVPictureView *pv = [[OVPictureView alloc] initWithFrame:NSMakeRect(0, 0, 860, 510)];
        NSBitmapImageRep *rep;
        [NSApplication sharedApplication];
        [pv setImage:img frameData:[fr bytes] size:fs bitDepth:16 wide:NO caption:@"00:00:00:00"];
        rep = [pv bitmapImageRepForCachingDisplayInRect:[pv bounds]];
        [pv cacheDisplayInRect:[pv bounds] toBitmapImageRep:rep];
        [[rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
            writeToFile:[NSString stringWithUTF8String:argv[4]] atomically:YES];
        printf("marks %lu\n", (unsigned long)[pv markCount]);
        return 0;
    }
    if (argc == 9 && !strcmp(argv[1], "--sim"))
        return sim_main(argv);
    if (argc < 5)
        return 2;
    in = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    base = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:[NSString stringWithUTF8String:argv[4]]];
    if (![e connectDevice:@"x" engine:OVEngineAutomatic preview:nil error:&err]) { printf("connect: %s\n", [err UTF8String]); return 1; }
    if (strcmp(argv[3], "-"))
        [e setCopyDestination:[NSString stringWithUTF8String:argv[3]]];
    if (![e startRecordingTo:base retries:0 noDataTimeout:0 playDeck:NO error:&err]) { printf("start: %s\n", [err UTF8String]); return 1; }
    while (off < [in length]) {
        size_t n = [in length] - off < step ? [in length] - off : step;
        [e captureReceivedBytes:(const uint8_t *)[in bytes] + off length:n];
        off += n;
        [e tick];
        spin(0.05);
    }
    [e stopRecording];
    t0 = [NSDate timeIntervalSinceReferenceDate];
    while ([e state] != OVEngineMonitoring) {
        [e tick];
        spin(0.1);
        if (stopCopyAfter > 0 && [NSDate timeIntervalSinceReferenceDate] - t0 > stopCopyAfter) {
            stopCopyAfter = 0;
            [e stopRecording];
        }
    }
    spin(0.5);
    printf("RESULT %s\n", [[e resultPath] UTF8String]);
    [pool release];
    return 0;
}
