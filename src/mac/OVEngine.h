/*
 * OldDV Rescue - capture engine: receives the DV stream, writes the raw
 * capture file, analyzes every frame live, auto-stops at the end of the
 * tape and can re-read sections with errors ("rewind and retry",
 * DVRescue's --rewind-count) before merging all takes.
 */
#import <Cocoa/Cocoa.h>
#import "OVCapture.h"
#import "OVDeck.h"
#include <pthread.h>
#include "dvcore.h"

typedef struct OVGraphPoint {
    uint16_t video;   /* per mille of video blocks with errors */
    uint16_t audio;   /* audio blocks with errors */
    uint8_t  flags;   /* 1 time code break, 2 recording start, 4 fully concealed, 8 rec date jump */
} OVGraphPoint;

void OVGraphPointFromFrame(const dv_frame *f, OVGraphPoint *p);

typedef enum {
    OVEngineIdle = 0,
    OVEngineMonitoring,
    OVEngineRecording,
    OVEngineRetrying,
    OVEngineMerging,
    OVEngineCopying     /* moving the finished capture from this Mac to its destination */
} OVEngineState;

@class OVEngine;
@protocol OVEngineDelegate
- (void)engineLogLine:(NSString *)line;                       /* main thread */
- (void)engineStateDidChange:(OVEngine *)engine;              /* main thread */
@end

typedef struct OVLiveStats {
    int      haveFrame;
    dv_frame last;           /* sta pointer always NULL */
    uint64_t framesSeen;     /* frames received since connect */
    uint32_t framesRecorded; /* frames in current file */
    uint32_t framesWithErrors;
    uint32_t tcBreaks, recStarts;
    int64_t  fileBytes;
    int64_t  bufferedBytes;  /* waiting to be written (slow disk / share) */
    uint64_t droppedBytes;   /* lost because the destination was too slow */
    double   secondsSinceData;
    uint32_t deadFrames;     /* blank / repeated frames at the end of the file */
    int      copying;        /* 1: recorded on this Mac and copied to the destination in the background */
    int64_t  copyBehind;     /* bytes not yet at the destination */
    int      copyFailing;    /* the destination does not answer right now */
    double   secondsSinceSignal; /* since the last frame with a moving, readable picture; -1: none yet */
} OVLiveStats;

@interface OVEngine : NSObject <OVCaptureSink> {
    pthread_mutex_t mtx;
    id delegate;
    OVCaptureBackend *backend;
    OVDeck *deck;
    NSString *deviceID;
    OVEngineState state;

    dv_splitter splitter;
    dv_analyzer liveAnalyzer;
    dv_frame last;
    int haveLast;
    uint64_t framesSeen;
    double lastDataTime;
    double lastTCTime;
    double lastSignalTime;  /* last frame that was not dead (see -frame:size:pos:) */
    int signalSeen;         /* a live frame was recorded in this file */
    uint32_t deadFrames;    /* dead frames at the end of the current file */
    NSString *logPath;      /* capture log next to the capture file */
    dispatch_queue_t logQueue;

    dv_writer *fp;          /* buffered writer (network shares can stall) */
    uint64_t droppedBytes;
    NSString *filePath;
    int64_t fileBytes;
    int writeError;
    dv_report *report;
    int retryWindow;
    int64_t winStart, winEnd;

    OVGraphPoint *points;
    size_t npoints, cappoints;

    NSMutableIndexSet *badKeys;
    NSMutableArray *takes;
    NSString *baseName;     /* full path without .dv */
    int retryCount;
    double noDataTimeout;
    BOOL blankLogged;
    NSString *destFolder;   /* nil: record straight into the chosen folder */
    NSString *resultFolder; /* where the files of the last capture ended up */
    dv_mirror *mirror;      /* background copy of the main capture file */
    BOOL mirrorFailing;
    BOOL cancelCopy;
    double lastProgressLog;
    BOOL cancel;
    BOOL autoStopDeck;
    int deckStateCache;
    dispatch_queue_t deckQueue;
    double lastDeckPoll;
}
- (id)initWithDelegate:(id)d;
- (BOOL)connectDevice:(NSString *)uid engine:(OVEngineChoice)choice preview:(NSView *)view error:(NSString **)err;
- (void)disconnect;
- (NSString *)engineName;
- (OVDeck *)deck;
- (OVEngineState)state;

/* basePath: folder/name without extension. retries: extra passes over bad sections */
- (double)blankLimit;
/* Record on this Mac (the folder of basePath) and copy everything to
 * `folder` in the background; nil records straight to basePath. Call
 * before -startRecordingTo:. */
- (void)setCopyDestination:(NSString *)folder;
/* the main capture file where it ended up (destination, or this Mac if
 * the copy did not succeed); nil before the first capture */
- (NSString *)resultPath;
- (BOOL)startRecordingTo:(NSString *)basePath retries:(int)retries noDataTimeout:(double)seconds
                playDeck:(BOOL)play error:(NSString **)err;
- (void)stopRecording;          /* user stop (also cancels retries) */
- (void)tick;                   /* call from a main thread timer (4 times a second) */
- (OVLiveStats)stats;
- (OVDeckState)cachedDeckState;
- (size_t)copyGraphPointsFrom:(size_t)start into:(OVGraphPoint *)buf max:(size_t)max;
- (size_t)graphPointCount;
- (NSString *)currentFile;
@end
