/*
 * OldDV Rescue - AVFoundation capture backend (Mac OS X 10.7 and later).
 * Compiled against a 10.7+ SDK but weak linked, so the same binary still
 * launches on 10.6 where this class is simply never used.
 * Same approach as DVRescue's AvfCtl: AVCaptureVideoDataOutput with empty
 * videoSettings delivers the raw DV stream of muxed FireWire devices.
 */
#import "OVCapture.h"
#ifdef OLDDV_HAVE_AVF
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

/* CoreMedia is loaded at run time (dlopen in OVCapture.m), not linked */
static CMBlockBufferRef (*p_GetDataBuffer)(CMSampleBufferRef);
static size_t (*p_GetDataLength)(CMBlockBufferRef);
static OSStatus (*p_CopyDataBytes)(CMBlockBufferRef, size_t, size_t, void *);

static BOOL load_coremedia(void)
{
    if (!p_GetDataBuffer) {
        p_GetDataBuffer = (CMBlockBufferRef (*)(CMSampleBufferRef))dlsym(RTLD_DEFAULT, "CMSampleBufferGetDataBuffer");
        p_GetDataLength = (size_t (*)(CMBlockBufferRef))dlsym(RTLD_DEFAULT, "CMBlockBufferGetDataLength");
        p_CopyDataBytes = (OSStatus (*)(CMBlockBufferRef, size_t, size_t, void *))dlsym(RTLD_DEFAULT, "CMBlockBufferCopyDataBytes");
    }
    return p_GetDataBuffer && p_GetDataLength && p_CopyDataBytes;
}

@interface OVAVFBackend : OVCaptureBackend {
    id session;              /* AVCaptureSession */
    id input;                /* AVCaptureDeviceInput */
    id output;               /* AVCaptureVideoDataOutput */
    id previewLayer;         /* AVCaptureVideoPreviewLayer */
    NSView *previewView;
    dispatch_queue_t queue;
    void *buffer;
    size_t bufferSize;
}
@end

@implementation OVAVFBackend

- (NSString *)engineName { return @"AVFoundation"; }

- (NSArray *)avDevices
{
    Class dc = NSClassFromString(@"AVCaptureDevice");
    if (!dc)
        return [NSArray array];
    return [dc devicesWithMediaType:@"muxx"]; /* AVMediaTypeMuxed */
}

- (NSArray *)devices
{
    NSMutableArray *r = [NSMutableArray array];
    for (id d in [self avDevices])
        [r addObject:[OVCaptureDeviceInfo infoWithName:[(AVCaptureDevice *)d localizedName] uniqueID:[(AVCaptureDevice *)d uniqueID]]];
    return r;
}

- (BOOL)startWithDeviceID:(NSString *)uid sink:(id<OVCaptureSink>)s preview:(NSView *)container error:(NSString **)err
{
    NSError *e = nil;
    id device = nil;
    [self stop];
    if (!load_coremedia()) {
        if (err) *err = @"CoreMedia is not available.";
        return NO;
    }
    for (id d in [self avDevices])
        if (!uid || [[(AVCaptureDevice *)d uniqueID] isEqualToString:uid]) { device = d; break; }
    if (!device) {
        if (err) *err = @"The DV device is not connected (check the FireWire cable and that the camcorder is in VCR/Play mode).";
        return NO;
    }
    if ([device isInUseByAnotherApplication]) {
        if (err) *err = @"The device is in use by another application (quit iMovie / Final Cut / QuickTime Player).";
        return NO;
    }
    sink = s;
    session = [[NSClassFromString(@"AVCaptureSession") alloc] init];
    input = [[NSClassFromString(@"AVCaptureDeviceInput") deviceInputWithDevice:device error:&e] retain];
    if (!input || ![session canAddInput:input]) {
        if (err) *err = [NSString stringWithFormat:@"Cannot use the device: %@", e ? [e localizedDescription] : @"rejected"];
        [self stop];
        return NO;
    }
    [session addInput:input];
    output = [[NSClassFromString(@"AVCaptureVideoDataOutput") alloc] init];
    [output setVideoSettings:[NSDictionary dictionary]]; /* raw DV */
    [output setAlwaysDiscardsLateVideoFrames:NO];
    queue = dispatch_queue_create("org.olddv.capture", NULL);
    [output setSampleBufferDelegate:(id)self queue:queue];
    if (![session canAddOutput:output]) {
        if (err) *err = @"Cannot capture from the device";
        [self stop];
        return NO;
    }
    [session addOutput:output];
    if (container) {
        previewView = [container retain];
        [container setWantsLayer:YES];
        previewLayer = [[NSClassFromString(@"AVCaptureVideoPreviewLayer") layerWithSession:session] retain];
        [(CALayer *)previewLayer setFrame:[[container layer] bounds]];
        [(CALayer *)previewLayer setAutoresizingMask:kCALayerWidthSizable | kCALayerHeightSizable];
        { CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 1); [(CALayer *)previewLayer setBackgroundColor:black]; CGColorRelease(black); }
        [[container layer] addSublayer:previewLayer];
    }
    [session startRunning];
    return YES;
}

- (void)captureOutput:(id)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(id)connection
{
    CMBlockBufferRef bb = p_GetDataBuffer(sampleBuffer);
    size_t len;
    if (!bb)
        return;
    len = p_GetDataLength(bb);
    if (len > bufferSize) {
        void *nb = realloc(buffer, len);
        if (!nb)
            return;
        buffer = nb;
        bufferSize = len;
    }
    if (p_CopyDataBytes(bb, 0, len, buffer) == 0)
        [self deliver:buffer length:len];
}

- (void)setPreviewHidden:(BOOL)hidden
{
    [(CALayer *)previewLayer setHidden:hidden];
}

- (void)stop
{
    if (session)
        [session stopRunning];
    [output setSampleBufferDelegate:nil queue:NULL];
    if (queue) {
        dispatch_sync(queue, ^{ });
        dispatch_release(queue);
        queue = NULL;
    }
    [previewLayer removeFromSuperlayer];
    [previewLayer release];
    previewLayer = nil;
    [previewView release];
    previewView = nil;
    [output release];
    output = nil;
    [input release];
    input = nil;
    [session release];
    session = nil;
    sink = nil;
}

- (void)dealloc
{
    [self stop];
    free(buffer);
    [super dealloc];
}
@end
#endif
