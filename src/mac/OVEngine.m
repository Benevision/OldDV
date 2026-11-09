/*
 * OldDV Rescue - capture engine (see OVEngine.h)
 */
#import "OVEngine.h"
#include <sys/time.h>
#include <unistd.h>

static double now_s(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static int64_t tc_key(const dv_frame *f)
{
    int fps = f->dsf ? 25 : 30;
    if (!f->tc_valid)
        return -1;
    return ((int64_t)f->tc_h * 3600 + f->tc_m * 60 + f->tc_s) * fps + f->tc_f;
}

void OVGraphPointFromFrame(const dv_frame *f, OVGraphPoint *p)
{
    uint32_t vb = f->video_blocks ? f->video_blocks : 1350;
    uint32_t v = f->video_errors * 1000 / vb;
    if (f->video_errors && !v)
        v = 1;
    p->video = (uint16_t)(v > 1000 ? 1000 : v);
    p->audio = (uint16_t)f->audio_errors;
    p->flags = (uint8_t)((f->tc_nc ? 1 : 0) | (f->rec_start ? 2 : 0)
                         | ((f->full_conceal_vid && f->full_conceal_aud) ? 4 : 0) | (f->rdt_nc ? 8 : 0));
}

@interface OVEngine (Private)
- (void)frame:(const uint8_t *)data size:(size_t)size pos:(int64_t)pos;
- (void)log:(NSString *)line;
- (void)setState:(OVEngineState)s;
@end

static void frame_cb(void *ctx, const uint8_t *frame, size_t size, int64_t pos)
{
    [(OVEngine *)ctx frame:frame size:size pos:pos];
}

@implementation OVEngine

- (id)initWithDelegate:(id)d
{
    self = [super init];
    if (self) {
        pthread_mutex_init(&mtx, NULL);
        delegate = d;
        dv_splitter_init(&splitter);
        dv_analyzer_init(&liveAnalyzer, 0);
        badKeys = [[NSMutableIndexSet alloc] init];
        takes = [[NSMutableArray alloc] init];
        deckQueue = dispatch_queue_create("org.olddv.deck", NULL);
        noDataTimeout = 5;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    dv_splitter_free(&splitter);
    free(points);
    [badKeys release];
    [takes release];
    dispatch_release(deckQueue);
    pthread_mutex_destroy(&mtx);
    [super dealloc];
}

- (void)log:(NSString *)line
{
    [(NSObject *)delegate performSelectorOnMainThread:@selector(engineLogLine:) withObject:line waitUntilDone:NO];
}

- (void)notifyState
{
    [(NSObject *)delegate performSelectorOnMainThread:@selector(engineStateDidChange:) withObject:self waitUntilDone:NO];
}

- (void)setState:(OVEngineState)s
{
    state = s;
    [self notifyState];
}

- (OVEngineState)state { return state; }
- (OVDeck *)deck { return deck; }
- (NSString *)engineName { return backend ? [backend engineName] : @"-"; }
- (NSString *)currentFile
{
    NSString *r;
    pthread_mutex_lock(&mtx);
    r = [[filePath retain] autorelease];
    pthread_mutex_unlock(&mtx);
    return r;
}

- (BOOL)connectDevice:(NSString *)uid engine:(OVEngineChoice)choice preview:(NSView *)view error:(NSString **)err
{
    [self disconnect];
    backend = [[OVCaptureBackend backendWithChoice:choice] retain];
    if (!backend) {
        if (err) *err = @"No capture engine available (QTKit / AVFoundation missing).";
        return NO;
    }
    pthread_mutex_lock(&mtx);
    dv_splitter_free(&splitter);
    dv_splitter_init(&splitter);
    dv_analyzer_init(&liveAnalyzer, 0);
    haveLast = 0;
    framesSeen = 0;
    lastDataTime = 0;
    pthread_mutex_unlock(&mtx);
    if (![backend startWithDeviceID:uid sink:self preview:view error:err]) {
        [backend release];
        backend = nil;
        return NO;
    }
    deviceID = [uid copy];
    deck = [[OVDeck deckForDeviceID:uid] retain];
    [self log:[NSString stringWithFormat:@"Connected using %@%@", [backend engineName],
               deck ? [NSString stringWithFormat:@", deck control: %@", [deck name]] : @", no AV/C deck control"]];
    [self setState:OVEngineMonitoring];
    return YES;
}

- (void)disconnect
{
    if (state == OVEngineRecording || state == OVEngineRetrying)
        [self stopRecording];
    [backend stop];
    [backend release];
    backend = nil;
    [deck release];
    deck = nil;
    [deviceID release];
    deviceID = nil;
    if (state != OVEngineMerging && state != OVEngineRetrying)
        state = OVEngineIdle;
}

/* ------------------------------------------------------------------ */
/* Data path (capture thread)                                          */

- (void)captureReceivedBytes:(const void *)bytes length:(size_t)length
{
    pthread_mutex_lock(&mtx);
    lastDataTime = now_s();
    if (fp && !retryWindow && state == OVEngineRecording && !writeError) {
        if (fwrite(bytes, 1, length, fp) != length)
            writeError = 1;
        fileBytes += (int64_t)length;
    }
    dv_splitter_push(&splitter, (const uint8_t *)bytes, length, frame_cb, self);
    pthread_mutex_unlock(&mtx);
}

/* called with mtx held */
- (void)frame:(const uint8_t *)data size:(size_t)size pos:(int64_t)pos
{
    dv_frame f;
    framesSeen++;
    if (state == OVEngineRecording && report && fp) {
        dv_report_feed(report, data, size, pos);
        if (!report->count) /* out of memory: frame dropped from the report */
            return;
        f = report->frames[report->count - 1];
        f.sta = NULL;
        if (npoints == cappoints) {
            size_t nc = cappoints ? cappoints * 2 : 4096;
            OVGraphPoint *np = (OVGraphPoint *)realloc(points, nc * sizeof(OVGraphPoint));
            if (np) { points = np; cappoints = nc; }
        }
        if (npoints < cappoints)
            OVGraphPointFromFrame(&f, &points[npoints++]);
        if (dv_frame_error_blocks(&f) && tc_key(&f) >= 0)
            [badKeys addIndex:(NSUInteger)tc_key(&f)];
    } else {
        dv_analyze_frame(&liveAnalyzer, data, size, pos, &f);
        free(f.sta);
        f.sta = NULL;
        if (retryWindow && fp && report && !writeError) {
            int64_t k = tc_key(&f);
            if (k >= winStart && k <= winEnd) {
                if (fwrite(data, 1, size, fp) != size)
                    writeError = 1;
                else {
                    dv_report_feed(report, data, size, fileBytes);
                    fileBytes += (int64_t)size;
                }
            }
        }
    }
    last = f;
    haveLast = 1;
    if (f.tc_valid)
        lastTCTime = now_s();
}

/* ------------------------------------------------------------------ */

- (OVLiveStats)stats
{
    OVLiveStats s;
    memset(&s, 0, sizeof(s));
    pthread_mutex_lock(&mtx);
    s.haveFrame = haveLast;
    s.last = last;
    s.framesSeen = framesSeen;
    if (report) {
        s.framesRecorded = report->count;
        s.framesWithErrors = report->frames_with_errors;
        s.tcBreaks = report->tc_breaks;
        s.recStarts = report->rec_starts;
    }
    s.fileBytes = fileBytes;
    s.secondsSinceData = lastDataTime ? now_s() - lastDataTime : -1;
    pthread_mutex_unlock(&mtx);
    return s;
}

- (size_t)graphPointCount
{
    size_t n;
    pthread_mutex_lock(&mtx);
    n = npoints;
    pthread_mutex_unlock(&mtx);
    return n;
}

- (size_t)copyGraphPointsFrom:(size_t)start into:(OVGraphPoint *)buf max:(size_t)max
{
    size_t n = 0;
    pthread_mutex_lock(&mtx);
    if (start < npoints) {
        n = npoints - start;
        if (n > max)
            n = max;
        memcpy(buf, points + start, n * sizeof(OVGraphPoint));
    }
    pthread_mutex_unlock(&mtx);
    return n;
}

- (OVDeckState)cachedDeckState { return (OVDeckState)deckStateCache; }

/* ------------------------------------------------------------------ */
/* Recording                                                           */

- (BOOL)openFile:(NSString *)path error:(NSString **)err
{
    FILE *f = fopen([path fileSystemRepresentation], "wb");
    if (!f) {
        if (err) *err = [NSString stringWithFormat:@"Cannot create %@", path];
        return NO;
    }
    pthread_mutex_lock(&mtx);
    fp = f;
    [filePath release];
    filePath = [path copy];
    fileBytes = 0;
    writeError = 0;
    report = (dv_report *)calloc(1, sizeof(dv_report));
    dv_report_init(report, [path fileSystemRepresentation]);
    /* restart frame splitting so that frame positions are file offsets */
    dv_splitter_free(&splitter);
    dv_splitter_init(&splitter);
    pthread_mutex_unlock(&mtx);
    return YES;
}

/* closes the current file, writes its XML report; returns the report
 * (caller frees) */
- (dv_report *)closeFile
{
    dv_report *r;
    NSString *path;
    pthread_mutex_lock(&mtx);
    dv_splitter_flush(&splitter, frame_cb, self);
    if (fp) {
        if (fclose(fp))
            writeError = 1;
        fp = NULL;
    }
    retryWindow = 0;
    r = report;
    report = NULL;
    path = [[filePath retain] autorelease];
    if (r)
        r->file_size = fileBytes;
    pthread_mutex_unlock(&mtx);
    if (r && path) {
        NSString *xml = [path stringByAppendingString:@".dvrescue.xml"];
        if (dv_report_save_xml([xml fileSystemRepresentation], r))
            [self log:[NSString stringWithFormat:@"Could not write %@", xml]];
        else
            [self log:[NSString stringWithFormat:@"Saved %@ (%u frames, %u with issues) and its XML report",
                       [path lastPathComponent], r->count, r->frames_with_errors]];
    }
    if (writeError)
        [self log:@"WARNING: write error during capture (disk full?) - the file is incomplete."];
    return r;
}

- (BOOL)startRecordingTo:(NSString *)basePath retries:(int)retries noDataTimeout:(double)seconds
                playDeck:(BOOL)play error:(NSString **)err
{
    NSString *path = [basePath stringByAppendingPathExtension:@"dv"];
    if (!backend) {
        if (err) *err = @"No device connected.";
        return NO;
    }
    if (state == OVEngineRecording || state == OVEngineRetrying || state == OVEngineMerging) {
        if (err) *err = @"A capture is already running.";
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (err) *err = [NSString stringWithFormat:@"%@ already exists, choose another name.", [path lastPathComponent]];
        return NO;
    }
    if (![self openFile:path error:err])
        return NO;
    [baseName release];
    baseName = [basePath copy];
    [takes removeAllObjects];
    [takes addObject:path];
    retryCount = retries;
    noDataTimeout = seconds > 0 ? seconds : 0;
    cancel = NO;
    autoStopDeck = play;
    pthread_mutex_lock(&mtx);
    [badKeys removeAllIndexes];
    npoints = 0;
    lastDataTime = 0;
    /* switch to recording atomically with a splitter restart, so that the
     * bytes written to the file and the frame positions start together */
    dv_splitter_free(&splitter);
    dv_splitter_init(&splitter);
    state = OVEngineRecording;
    pthread_mutex_unlock(&mtx);
    [self notifyState];
    [self log:[NSString stringWithFormat:@"Recording to %@", path]];
    if (play && deck) {
        OVDeck *d = deck;
        dispatch_async(deckQueue, ^{ [d play]; });
    }
    return YES;
}

- (void)finishPass1
{
    dv_report *r = [self closeFile];
    if (r) {
        dv_report_free(r);
        free(r);
    }
    if (!cancel && retryCount > 0 && [badKeys count]) {
        if (!deck) {
            [self log:@"Retry of bad sections skipped: the device has no AV/C deck control."];
        } else {
            [self setState:OVEngineRetrying];
            /* the deck is passed so that NSThread keeps it retained while the
             * worker uses it, even if -disconnect releases the ivar */
            [NSThread detachNewThreadSelector:@selector(retryMain:) toTarget:self withObject:deck];
            return;
        }
    } else if (retryCount > 0 && !cancel)
        [self log:@"No frame with errors: no retry needed."];
    if (autoStopDeck && deck) {
        OVDeck *d = deck;
        dispatch_async(deckQueue, ^{ [d stop]; });
    }
    [self setState:backend ? OVEngineMonitoring : OVEngineIdle];
}

- (void)stopRecording
{
    if (state == OVEngineRecording) {
        cancel = YES;
        [self log:@"Capture stopped by user."];
        [self finishPass1];
    } else if (state == OVEngineRetrying) {
        cancel = YES;
        [self log:@"Stopping retries..."];
    }
}

- (void)tick
{
    double t = now_s();
    if (deck && t - lastDeckPoll > 1.0) {
        OVDeck *d = deck;
        lastDeckPoll = t;
        dispatch_async(deckQueue, ^{ deckStateCache = (int)[d state]; });
    }
    if (state == OVEngineRecording) {
        OVLiveStats s = [self stats];
        if (writeError) {
            [self log:@"Write error (disk full?): capture stopped."];
            cancel = YES;
            [self finishPass1];
        } else if (noDataTimeout > 0 && s.framesRecorded > 0 && s.secondsSinceData > noDataTimeout) {
            [self log:[NSString stringWithFormat:@"No signal for %.0f seconds (end of tape?): capture finished.", noDataTimeout]];
            [self finishPass1];
        }
    }
}

/* ------------------------------------------------------------------ */
/* Rewind and retry (worker thread)                                    */

- (int64_t)liveTC:(double)maxAge
{
    int64_t k = -1;
    pthread_mutex_lock(&mtx);
    if (haveLast && now_s() - lastTCTime <= maxAge)
        k = tc_key(&last);
    pthread_mutex_unlock(&mtx);
    return k;
}

- (int)fps
{
    int r;
    pthread_mutex_lock(&mtx);
    r = (haveLast && last.dsf) ? 25 : 30;
    pthread_mutex_unlock(&mtx);
    return r;
}

- (int64_t)deckTC
{
    int h, m, s, f;
    if ([deck timeCodeHours:&h minutes:&m seconds:&s frames:&f])
        return ((int64_t)h * 3600 + m * 60 + s) * [self fps] + f;
    return [self liveTC:0.5];
}

- (NSString *)tcString:(int64_t)k
{
    int fps = [self fps];
    if (k < 0)
        return @"--:--:--:--";
    return [NSString stringWithFormat:@"%02d:%02d:%02d:%02d", (int)(k / fps / 3600), (int)(k / fps / 60 % 60),
            (int)(k / fps % 60), (int)(k % fps)];
}

- (BOOL)seekTo:(int64_t)target
{
    int64_t pos = [self deckTC];
    int dir;
    double t0;
    BOOL shuttle = NO;
    double lastKnown, lastCmd;
    if (target < 0) /* section at the very start of the tape */
        target = 0;
    if (pos < 0) {
        /* play a moment to learn where we are */
        [deck play];
        for (t0 = now_s(); now_s() - t0 < 4 && pos < 0 && !cancel; usleep(100000))
            pos = [self liveTC:0.5];
        [deck pause];
    }
    if (pos < 0) {
        [self log:@"  Cannot read the tape position (no time code)."];
        return NO;
    }
    if (pos > target)
        dir = -1;
    else if (pos < target - 10 * [self fps])
        dir = 1;
    else
        return YES;
    if (dir < 0) [deck rewind]; else [deck fastForward];
    t0 = now_s();
    lastKnown = lastCmd = t0;
    while (!cancel && now_s() - t0 < 300) {
        usleep(150000);
        if (now_s() - lastCmd > 2 && [deck state] == OVDeckStopped)
            break; /* the deck stopped by itself: beginning / end of the tape */
        pos = [self deckTC];
        if (pos < 0) {
            if (now_s() - lastKnown > 6 && dir < 0 && !shuttle) {
                /* deck does not report time code while winding: shuttle instead */
                [deck stop];
                usleep(500000);
                [deck fastReversePlay];
                shuttle = YES;
                lastKnown = lastCmd = now_s();
            } else if (now_s() - lastKnown > 15) {
                [self log:@"  The deck does not report its position while winding."];
                [deck stop];
                return NO;
            }
            continue;
        }
        lastKnown = now_s();
        if ((dir < 0 && pos <= target) || (dir > 0 && pos >= target - 2 * [self fps]))
            break;
    }
    [deck stop];
    usleep(1000000);
    return !cancel && now_s() - t0 < 300;
}

- (void)retryMain:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int pass;
    int fps = [self fps];
    for (pass = 1; pass <= retryCount && !cancel; pass++) {
        NSMutableArray *ranges = [NSMutableArray array];
        NSString *path;
        NSString *err = nil;
        dv_report *r;
        NSUInteger idx;
        int64_t rs = -1, re = -1;
        /* contiguous bad sections (gaps under 2 s are joined) */
        pthread_mutex_lock(&mtx);
        for (idx = [badKeys firstIndex]; idx != NSNotFound; idx = [badKeys indexGreaterThanIndex:idx]) {
            if (rs < 0) { rs = re = (int64_t)idx; continue; }
            if ((int64_t)idx - re > 2 * fps) {
                [ranges addObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:rs], [NSNumber numberWithLongLong:re], nil]];
                rs = (int64_t)idx;
            }
            re = (int64_t)idx;
        }
        if (rs >= 0)
            [ranges addObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:rs], [NSNumber numberWithLongLong:re], nil]];
        pthread_mutex_unlock(&mtx);
        if (![ranges count]) {
            [self log:@"No bad section left."];
            break;
        }
        path = [NSString stringWithFormat:@"%@.retry%d.dv", baseName, pass];
        [self log:[NSString stringWithFormat:@"Retry pass %d of %d: %lu section(s) to re-read into %@",
                   pass, retryCount, (unsigned long)[ranges count], [path lastPathComponent]]];
        if (![self openFile:path error:&err]) {
            [self log:err];
            break;
        }
        for (NSArray *rg in ranges) {
            int64_t a = [[rg objectAtIndex:0] longLongValue], b = [[rg objectAtIndex:1] longLongValue];
            double t0, lastData;
            if (cancel)
                break;
            [self log:[NSString stringWithFormat:@"  Section %@ - %@: seeking...", [self tcString:a], [self tcString:b]]];
            if (![self seekTo:a - 3 * fps]) {
                [self log:@"  Seek failed, section skipped."];
                continue;
            }
            pthread_mutex_lock(&mtx);
            winStart = a - fps;
            winEnd = b + fps;
            retryWindow = 1;
            pthread_mutex_unlock(&mtx);
            [deck play];
            t0 = lastData = now_s();
            while (!cancel) {
                int64_t k = [self liveTC:0.5];
                usleep(100000);
                if (k >= 0)
                    lastData = now_s();
                if (k > b + fps)
                    break;
                if (now_s() - lastData > 6 || now_s() - t0 > (double)(b - a) / fps + 30) {
                    [self log:@"  Time out while re-reading the section."];
                    break;
                }
            }
            pthread_mutex_lock(&mtx);
            retryWindow = 0;
            pthread_mutex_unlock(&mtx);
            [deck pause];
        }
        [deck stop];
        /* write what we have; keep the good frames as fixed */
        pthread_mutex_lock(&mtx);
        retryWindow = 1; /* keep data path from writing during close */
        pthread_mutex_unlock(&mtx);
        r = [self closeFile];
        if (r) {
            uint32_t i, fixed = 0;
            pthread_mutex_lock(&mtx);
            for (i = 0; i < r->count; i++) {
                int64_t k = tc_key(&r->frames[i]);
                if (k >= 0 && !dv_frame_error_blocks(&r->frames[i]) && [badKeys containsIndex:(NSUInteger)k]) {
                    [badKeys removeIndex:(NSUInteger)k];
                    fixed++;
                }
            }
            pthread_mutex_unlock(&mtx);
            [self log:[NSString stringWithFormat:@"  Pass %d: %u frames re-read, %u now clean, %lu frames still with errors",
                       pass, r->count, fixed, (unsigned long)[badKeys count]]];
            if (r->count)
                [takes addObject:path];
            else
                [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            dv_report_free(r);
            free(r);
        }
    }
    if ([takes count] > 1) {
        NSString *merged = [baseName stringByAppendingString:@".merged.dv"];
        const char *in[64];
        int n = 0;
        dv_merge_stats ms;
        [self setState:OVEngineMerging];
        [self log:[NSString stringWithFormat:@"Merging %lu takes into %@ ...", (unsigned long)[takes count], [merged lastPathComponent]]];
        for (NSString *t in takes)
            if (n < 64)
                in[n++] = [t fileSystemRepresentation];
        if (dv_merge_files(in, n, [merged fileSystemRepresentation], &ms, NULL, NULL, NULL) == 0) {
            dv_report mr;
            dv_report_init(&mr, [merged fileSystemRepresentation]);
            dv_analyze_file([merged fileSystemRepresentation], &mr, NULL, NULL);
            dv_report_save_xml([[merged stringByAppendingString:@".dvrescue.xml"] fileSystemRepresentation], &mr);
            [self log:[NSString stringWithFormat:@"Merged: %u frames, %u repaired from other takes, %u still with errors (%u blocks fixed).",
                       ms.frames_out, ms.frames_repaired, ms.frames_still_bad, ms.blocks_fixed]];
            dv_report_free(&mr);
        } else
            [self log:@"Merge failed."];
    }
    if (autoStopDeck && deck)
        [deck stop];
    [self log:@"Capture finished."];
    [self setState:backend ? OVEngineMonitoring : OVEngineIdle];
    [pool release];
}

@end
