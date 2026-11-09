/*
 * OldDV Rescue - FireWire AV/C tape deck / camcorder control.
 * Uses IOFireWireAVCLib (available since Mac OS X 10.2), so it works on
 * Snow Leopard without AVFoundation. Same commands DVRescue's AvfCtl sends.
 */
#import <Foundation/Foundation.h>

typedef enum {
    OVDeckUnknown = 0,
    OVDeckStopped,
    OVDeckPlaying,
    OVDeckPaused,
    OVDeckRewinding,
    OVDeckFastForwarding,
    OVDeckReversePlaying,
    OVDeckRecording,
    OVDeckNoTape
} OVDeckState;

@interface OVDeck : NSObject {
    void *avcUnit;          /* IOFireWireAVCLibUnitInterface ** */
    NSString *unitName;
    NSLock *lock;
}
/* guidString: QTKit/AVFoundation device uniqueID ("0x0800460102030405"),
 * may be nil to take the first AV/C unit found. Returns nil if none. */
+ (OVDeck *)deckForDeviceID:(NSString *)guidString;
+ (NSUInteger)avcUnitCount;

- (NSString *)name;
- (BOOL)play;
- (BOOL)stop;
- (BOOL)pause;
- (BOOL)rewind;
- (BOOL)fastForward;
- (BOOL)reversePlay;          /* x1 reverse */
- (BOOL)fastReversePlay;      /* shuttle reverse, picture + time code kept */
- (OVDeckState)state;
/* Deck time code (AV/C TIME CODE status); returns NO if not supported */
- (BOOL)timeCodeHours:(int *)h minutes:(int *)m seconds:(int *)s frames:(int *)f;
+ (NSString *)describeState:(OVDeckState)st;
@end
