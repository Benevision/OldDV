/*
 * OldDV Rescue - FireWire DV capture backends.
 *
 *  - QTKit (Mac OS X 10.5 - 10.14): QTCaptureMovieFileOutput's sample buffer
 *    delegate receives the device's native DV frames (no transcoding).
 *  - AVFoundation (10.7+): AVCaptureVideoDataOutput with empty video
 *    settings gives raw DV, exactly like DVRescue's AvfCtl.
 * Both deliver raw DIF bytes to an OVCaptureSink on a background thread.
 */
#import <Cocoa/Cocoa.h>

@protocol OVCaptureSink
/* Called on a capture thread, must be fast. */
- (void)captureReceivedBytes:(const void *)bytes length:(size_t)length;
@end

typedef enum {
    OVEngineAutomatic = 0,
    OVEngineQTKit = 1,
    OVEngineAVFoundation = 2
} OVEngineChoice;

@interface OVCaptureDeviceInfo : NSObject {
    NSString *name;
    NSString *uniqueID;
}
+ (OVCaptureDeviceInfo *)infoWithName:(NSString *)n uniqueID:(NSString *)u;
- (NSString *)name;
- (NSString *)uniqueID;
@end

@interface OVCaptureBackend : NSObject {
    id<OVCaptureSink> sink;      /* not retained */
    volatile int64_t bytesReceived;
}
/* Backend for the requested engine (automatic: AVFoundation on 10.7+,
 * QTKit otherwise). */
+ (OVCaptureBackend *)backendWithChoice:(OVEngineChoice)choice;
+ (BOOL)avFoundationAvailable;
+ (BOOL)qtKitAvailable;

- (NSString *)engineName;
- (NSArray *)devices;                 /* of OVCaptureDeviceInfo */
- (BOOL)startWithDeviceID:(NSString *)uid sink:(id<OVCaptureSink>)s preview:(NSView *)container error:(NSString **)err;
- (void)setPreviewHidden:(BOOL)hidden;
- (void)stop;
- (int64_t)bytesReceived;
/* for subclasses: hand raw DV bytes to the sink */
- (void)deliver:(const void *)bytes length:(size_t)len;
@end
