/*
 * OldDV Rescue - FireWire AV/C deck control (see OVDeck.h)
 */
#import "OVDeck.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/avc/IOFireWireAVCLib.h>

#define AVC_CTL      0x00
#define AVC_STATUS   0x01
#define AVC_VCR      0x20
#define VCR_PLAY     0xC3
#define VCR_WIND     0xC4
#define VCR_TIMECODE 0x51
#define VCR_TRANSPORT_STATE 0xD0

#define UNIT ((IOFireWireAVCLibUnitInterface **)avcUnit)

static IOFireWireAVCLibUnitInterface **open_unit(io_service_t service)
{
    IOCFPlugInInterface **plugin = NULL;
    IOFireWireAVCLibUnitInterface **unit = NULL;
    SInt32 score = 0;
    IOReturn r = IOCreatePlugInInterfaceForService(service, kIOFireWireAVCLibUnitTypeID,
                                                   kIOCFPlugInInterfaceID, &plugin, &score);
    if (r != kIOReturnSuccess || !plugin)
        return NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOFireWireAVCLibUnitInterfaceID), (LPVOID *)&unit);
    (*plugin)->Release(plugin);
    return unit;
}

static NSString *service_name(io_service_t service)
{
    NSString *vendor = nil, *model = nil;
    CFTypeRef v = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("FireWire Vendor Name"),
                                                  kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
    CFTypeRef m = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("FireWire Product Name"),
                                                  kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        vendor = [NSString stringWithString:(NSString *)v];
    if (m && CFGetTypeID(m) == CFStringGetTypeID())
        model = [NSString stringWithString:(NSString *)m];
    if (v) CFRelease(v);
    if (m) CFRelease(m);
    if (vendor && model)
        return [NSString stringWithFormat:@"%@ %@", vendor, model];
    if (model)
        return model;
    if (vendor)
        return vendor;
    return @"FireWire AV/C device";
}

@implementation OVDeck

+ (NSUInteger)avcUnitCount
{
    io_iterator_t it;
    io_service_t s;
    NSUInteger n = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOFireWireAVCUnit"), &it) != KERN_SUCCESS)
        return 0;
    while ((s = IOIteratorNext(it))) {
        n++;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return n;
}

- (id)initWithService:(io_service_t)service
{
    self = [super init];
    if (self) {
        avcUnit = open_unit(service);
        if (!avcUnit) {
            [self release];
            return nil;
        }
        unitName = [service_name(service) retain];
        lock = [[NSLock alloc] init];
    }
    return self;
}

+ (OVDeck *)deckForDeviceID:(NSString *)guidString
{
    io_service_t service = 0;
    unsigned long long guid = 0;
    if (guidString) {
        NSScanner *sc = [NSScanner scannerWithString:guidString];
        [sc scanHexLongLong:&guid];
    }
    if (guid) {
        CFMutableDictionaryRef match = IOServiceMatching("IOFireWireAVCUnit");
        CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &guid);
        CFDictionarySetValue(match, CFSTR("GUID"), num);
        CFRelease(num);
        service = IOServiceGetMatchingService(kIOMasterPortDefault, match); /* consumes match */
    }
    if (!service) /* fall back to the first AV/C unit (one camcorder connected) */
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOFireWireAVCUnit"));
    if (!service)
        return nil;
    OVDeck *d = [[[OVDeck alloc] initWithService:service] autorelease];
    IOObjectRelease(service);
    return d;
}

- (void)dealloc
{
    if (avcUnit)
        (*UNIT)->Release(UNIT);
    [unitName release];
    [lock release];
    [super dealloc];
}

- (NSString *)name { return unitName; }

/* returns AV/C response code (0x09 accepted, 0x0C stable, ...) or -1 */
- (int)command:(const UInt8 *)cmd length:(UInt32)len response:(UInt8 *)resp responseLength:(UInt32 *)rlen
{
    UInt8 local[64];
    UInt32 llen = sizeof(local);
    IOReturn r;
    if (!avcUnit)
        return -1;
    if (!resp) {
        resp = local;
        rlen = &llen;
    }
    [lock lock];
    r = (*UNIT)->AVCCommand(UNIT, cmd, len, resp, rlen);
    [lock unlock];
    if (r != kIOReturnSuccess || *rlen < 1)
        return -1;
    return resp[0];
}

- (BOOL)send:(UInt8)opcode operand:(UInt8)operand
{
    UInt8 cmd[4] = { AVC_CTL, AVC_VCR, opcode, operand };
    int rc = [self command:cmd length:4 response:NULL responseLength:NULL];
    return rc == 0x09 || rc == 0x0F || rc == 0x0C;
}

- (BOOL)play { return [self send:VCR_PLAY operand:0x75]; }
- (BOOL)pause { return [self send:VCR_PLAY operand:0x7D]; }
- (BOOL)reversePlay { return [self send:VCR_PLAY operand:0x65]; }
- (BOOL)fastReversePlay
{
    /* FAST REVERSE 4; some units only know the fastest one */
    if ([self send:VCR_PLAY operand:0x4C])
        return YES;
    return [self send:VCR_PLAY operand:0x4F];
}
- (BOOL)stop { return [self send:VCR_WIND operand:0x60]; }
- (BOOL)rewind { return [self send:VCR_WIND operand:0x65]; }
- (BOOL)fastForward { return [self send:VCR_WIND operand:0x75]; }

- (OVDeckState)state
{
    UInt8 cmd[4] = { AVC_STATUS, AVC_VCR, VCR_TRANSPORT_STATE, 0x7F };
    UInt8 resp[16];
    UInt32 rlen = sizeof(resp);
    int rc = [self command:cmd length:4 response:resp responseLength:&rlen];
    if (rc != 0x0C || rlen < 4)
        return OVDeckUnknown;
    switch (resp[2]) {
    case 0xC1: return OVDeckNoTape;          /* LOAD MEDIUM */
    case 0xC2: return OVDeckRecording;
    case 0xC3:
        if (resp[3] == 0x7D || resp[3] == 0x6D)
            return OVDeckPaused;
        if ((resp[3] >= 0x40 && resp[3] <= 0x4F) || resp[3] == 0x65)
            return OVDeckReversePlaying;
        return OVDeckPlaying;
    case 0xC4:
        if (resp[3] == 0x65 || resp[3] == 0x45)
            return OVDeckRewinding;
        if (resp[3] == 0x75 || resp[3] == 0x55)
            return OVDeckFastForwarding;
        return OVDeckStopped;
    }
    return OVDeckUnknown;
}

static int bcd(UInt8 b) { return ((b >> 4) & 0x0F) * 10 + (b & 0x0F); }

- (BOOL)timeCodeHours:(int *)h minutes:(int *)m seconds:(int *)s frames:(int *)f
{
    UInt8 cmd[8] = { AVC_STATUS, AVC_VCR, VCR_TIMECODE, 0x71, 0xFF, 0xFF, 0xFF, 0xFF };
    UInt8 resp[16];
    UInt32 rlen = sizeof(resp);
    int rc = [self command:cmd length:8 response:resp responseLength:&rlen];
    if (rc != 0x0C || rlen < 8 || resp[4] == 0xFF)
        return NO;
    *f = bcd(resp[4] & 0x3F);
    *s = bcd(resp[5] & 0x7F);
    *m = bcd(resp[6] & 0x7F);
    *h = bcd(resp[7] & 0x3F);
    return *s < 60 && *m < 60 && *h < 24;
}

+ (NSString *)describeState:(OVDeckState)st
{
    switch (st) {
    case OVDeckStopped: return @"Stopped";
    case OVDeckPlaying: return @"Playing";
    case OVDeckPaused: return @"Paused";
    case OVDeckRewinding: return @"Rewinding";
    case OVDeckFastForwarding: return @"Fast forwarding";
    case OVDeckReversePlaying: return @"Reverse play";
    case OVDeckRecording: return @"Recording";
    case OVDeckNoTape: return @"No tape";
    default: return @"Unknown";
    }
}
@end
