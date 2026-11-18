/*
 * Drives the capture engine without a camcorder: a stub backend feeds a DV
 * file to the engine. Used to test recording on this Mac with a background
 * copy to a destination folder that may fail.
 *
 *   engine_harness INPUT.dv LOCALDIR DESTDIR|- NAME [stop-copy-after-seconds]
 */
#import <Cocoa/Cocoa.h>
#import "OVEngine.h"

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

@implementation OVDeck
+ (OVDeck *)deckForDeviceID:(NSString *)g { return nil; }
+ (NSUInteger)avcUnitCount { return 0; }
- (NSString *)name { return @"none"; }
- (BOOL)play { return NO; }
- (BOOL)stop { return NO; }
- (BOOL)pause { return NO; }
- (BOOL)rewind { return NO; }
- (BOOL)fastForward { return NO; }
- (BOOL)reversePlay { return NO; }
- (BOOL)fastReversePlay { return NO; }
- (OVDeckState)state { return OVDeckUnknown; }
- (BOOL)timeCodeHours:(int *)h minutes:(int *)m seconds:(int *)s frames:(int *)f { return NO; }
+ (NSString *)describeState:(OVDeckState)st { return @"?"; }
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

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    Del *d = [[Del alloc] init];
    OVEngine *e = [[OVEngine alloc] initWithDelegate:d];
    NSString *err = nil, *base;
    NSData *in;
    size_t off = 0, step = 144000 * 5;
    double stopCopyAfter = argc > 5 ? atof(argv[5]) : 0, t0;
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
