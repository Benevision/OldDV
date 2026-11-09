/*
 * OldDV Rescue - capture backend base class + QTKit backend.
 */
#import "OVCapture.h"
#import <QTKit/QTKit.h>
#include <libkern/OSAtomic.h>
#include <dlfcn.h>

@implementation OVCaptureDeviceInfo
+ (OVCaptureDeviceInfo *)infoWithName:(NSString *)n uniqueID:(NSString *)u
{
    OVCaptureDeviceInfo *i = [[[OVCaptureDeviceInfo alloc] init] autorelease];
    i->name = [n copy];
    i->uniqueID = [u copy];
    return i;
}
- (void)dealloc
{
    [name release];
    [uniqueID release];
    [super dealloc];
}
- (NSString *)name { return name; }
- (NSString *)uniqueID { return uniqueID; }
@end

/* ------------------------------------------------------------------ */

@interface OVQTKitBackend : OVCaptureBackend {
    QTCaptureSession *session;
    QTCaptureDevice *device;
    QTCaptureDeviceInput *input;
    QTCaptureMovieFileOutput *output;
    QTCaptureView *preview;
    QTCaptureConnection *dvConnection;
    NSTimer *fallbackTimer;
    NSString *fallbackPath;
}
@end

@implementation OVCaptureBackend

+ (BOOL)avFoundationAvailable
{
    SInt32 major = 10, minor = 0;
    Gestalt(gestaltSystemVersionMajor, &major);
    Gestalt(gestaltSystemVersionMinor, &minor);
    if (major == 10 && minor < 7)
        return NO;
    /* not linked (so that the app starts on 10.6): load it now */
    if (!NSClassFromString(@"AVCaptureVideoDataOutput")) {
        dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY | RTLD_GLOBAL);
    }
    return NSClassFromString(@"OVAVFBackend") != nil
        && NSClassFromString(@"AVCaptureVideoDataOutput") != nil;
}

+ (BOOL)qtKitAvailable
{
    return NSClassFromString(@"QTCaptureSession") != nil;
}

+ (OVCaptureBackend *)backendWithChoice:(OVEngineChoice)choice
{
    BOOL avf = [self avFoundationAvailable], qt = [self qtKitAvailable];
    Class c = Nil;
    if (choice == OVEngineQTKit && qt)
        c = [OVQTKitBackend class];
    else if (choice == OVEngineAVFoundation && avf)
        c = NSClassFromString(@"OVAVFBackend");
    else if (avf)
        c = NSClassFromString(@"OVAVFBackend");
    else if (qt)
        c = [OVQTKitBackend class];
    if (!c)
        return nil;
    return [[[c alloc] init] autorelease];
}

- (NSString *)engineName { return @"none"; }
- (NSArray *)devices { return [NSArray array]; }
- (BOOL)startWithDeviceID:(NSString *)uid sink:(id<OVCaptureSink>)s preview:(NSView *)container error:(NSString **)err
{
    if (err) *err = @"No capture engine";
    return NO;
}
- (void)setPreviewHidden:(BOOL)hidden {}
- (void)stop {}
- (int64_t)bytesReceived { return bytesReceived; }

/* used by subclasses */
- (void)deliver:(const void *)bytes length:(size_t)len
{
    if (!len)
        return;
    OSAtomicAdd64((int64_t)len, (int64_t *)&bytesReceived);
    [sink captureReceivedBytes:bytes length:len];
}
@end

/* ------------------------------------------------------------------ */

@implementation OVQTKitBackend

- (NSString *)engineName { return @"QTKit"; }

- (NSArray *)qtDevices
{
    NSMutableArray *all = [NSMutableArray array];
    NSArray *muxed = [QTCaptureDevice inputDevicesWithMediaType:QTMediaTypeMuxed];
    [all addObjectsFromArray:muxed];
    return all;
}

- (NSArray *)devices
{
    NSMutableArray *r = [NSMutableArray array];
    for (QTCaptureDevice *d in [self qtDevices])
        [r addObject:[OVCaptureDeviceInfo infoWithName:[d localizedDisplayName] uniqueID:[d uniqueID]]];
    return r;
}

- (BOOL)startWithDeviceID:(NSString *)uid sink:(id<OVCaptureSink>)s preview:(NSView *)container error:(NSString **)err
{
    NSError *e = nil;
    [self stop];
    for (QTCaptureDevice *d in [self qtDevices])
        if (!uid || [[d uniqueID] isEqualToString:uid]) {
            device = [d retain];
            break;
        }
    if (!device) {
        if (err) *err = @"The DV device is not connected (check the FireWire cable and that the camcorder is in VCR/Play mode).";
        return NO;
    }
    if (![device open:&e]) {
        if (err) *err = [NSString stringWithFormat:@"Cannot open the device: %@", [e localizedDescription]];
        [self stop];
        return NO;
    }
    sink = s;
    session = [[QTCaptureSession alloc] init];
    input = [[QTCaptureDeviceInput alloc] initWithDevice:device];
    if (![session addInput:input error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"Cannot use the device: %@", [e localizedDescription]];
        [self stop];
        return NO;
    }
    /* Keep only the muxed (DV) connection, else the video one */
    for (QTCaptureConnection *c in [input connections])
        if ([[c mediaType] isEqualToString:QTMediaTypeMuxed]) { dvConnection = [c retain]; break; }
    if (!dvConnection)
        for (QTCaptureConnection *c in [input connections])
            if ([[c mediaType] isEqualToString:QTMediaTypeVideo]) { dvConnection = [c retain]; break; }

    output = [[QTCaptureMovieFileOutput alloc] init];
    [output setDelegate:self];
    if (![session addOutput:output error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"Cannot capture from the device: %@", [e localizedDescription]];
        [self stop];
        return NO;
    }
    for (QTCaptureConnection *c in [output connections])
        [output setCompressionOptions:nil forConnection:c]; /* native DV, no transcoding */

    if (container) {
        preview = [[QTCaptureView alloc] initWithFrame:[container bounds]];
        [preview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [preview setPreservesAspectRatio:YES];
        [preview setFillColor:[NSColor blackColor]];
        [preview setCaptureSession:session];
        [container addSubview:preview];
    }
    [session startRunning];
    /* If QTKit does not deliver sample buffers without an output file,
     * record to a scratch file to get them flowing (deleted on stop). */
    fallbackTimer = [[NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(checkFlow:)
                                                    userInfo:nil repeats:NO] retain];
    return YES;
}

- (void)checkFlow:(NSTimer *)t
{
    if (bytesReceived || !output || fallbackPath)
        return;
    fallbackPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"olddv-qtkit-%d.mov", (int)getpid()]] retain];
    [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:NULL];
    [output recordToOutputFileURL:[NSURL fileURLWithPath:fallbackPath]];
}

/* The scratch file only exists to get sample buffers flowing: pause it
 * right away so that it does not grow by 13 GB per hour of tape on the
 * boot disk (buffers still reach the delegate while paused, 10.6+). */
- (void)captureOutput:(QTCaptureFileOutput *)o didStartRecordingToOutputFileAtURL:(NSURL *)u forConnections:(NSArray *)c
{
    if ([o respondsToSelector:@selector(pauseRecording)])
        [o pauseRecording];
}

- (void)captureOutput:(QTCaptureFileOutput *)o didOutputSampleBuffer:(QTSampleBuffer *)sb fromConnection:(QTCaptureConnection *)c
{
    /* QTKit capture thread: drain per frame */
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *type = [[sb formatDescription] mediaType];
    if ((!dvConnection || c == dvConnection || [[c mediaType] isEqualToString:[dvConnection mediaType]])
        && !(type && [type isEqualToString:QTMediaTypeSound]))
        [self deliver:[sb bytesForAllSamples] length:[sb lengthForAllSamples]];
    [pool release];
}

- (void)setPreviewHidden:(BOOL)hidden
{
    [preview setHidden:hidden];
    [preview setCaptureSession:hidden ? nil : session];
}

- (void)stop
{
    [fallbackTimer invalidate];
    [fallbackTimer release];
    fallbackTimer = nil;
    if (session) {
        if (fallbackPath)
            [output recordToOutputFileURL:nil];
        [session stopRunning];
    }
    [preview setCaptureSession:nil];
    [preview removeFromSuperview];
    [preview release];
    preview = nil;
    [output setDelegate:nil];
    [output release];
    output = nil;
    [input release];
    input = nil;
    [session release];
    session = nil;
    if (device && [device isOpen])
        [device close];
    [device release];
    device = nil;
    [dvConnection release];
    dvConnection = nil;
    if (fallbackPath) {
        [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:NULL];
        [fallbackPath release];
        fallbackPath = nil;
    }
    sink = nil;
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}
@end
