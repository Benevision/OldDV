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
                         | ((f->full_conceal_vid && f->full_conceal_aud) ? 4 : 0) | (f->rdt_nc ? 8 : 0)
                         | (f->dsf ? 32 : 0));
    p->tc = (int32_t)tc_key(f);
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
        logQueue = dispatch_queue_create("org.olddv.log", NULL);
        noDataTimeout = 5;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    dv_splitter_free(&splitter);
    free(points);
    free(sections);
    [badKeys release];
    [takes release];
    dispatch_release(deckQueue);
    dispatch_release(logQueue);
    [logPath release];
    [destFolder release];
    [resultFolder release];
    dv_mirror_free(mirror);
    pthread_mutex_destroy(&mtx);
    [super dealloc];
}

/* Every log line also goes to ~/Library/Logs/OldDV Rescue.log and, during
 * a capture, to <capture name>.log next to the capture file, so that a
 * session can be looked at afterwards. Written on a queue of its own: a
 * stalled network share must not block the caller. */
static void append_line(NSString *path, NSString *text)
{
    FILE *f = fopen([path fileSystemRepresentation], "a");
    if (f) {
        fputs([text UTF8String], f);
        fclose(f);
    }
}

- (void)setLogPath:(NSString *)path
{
    NSString *p = [path copy];
    dispatch_async(logQueue, ^{
        [logPath release];
        logPath = p;
    });
}

- (void)log:(NSString *)line
{
    time_t t = time(NULL);
    struct tm tmv;
    char stamp[32];
    NSString *text;
    localtime_r(&t, &tmv);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tmv);
    text = [NSString stringWithFormat:@"%s  %@\n", stamp, line];
    dispatch_async(logQueue, ^{
        append_line([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/OldDV Rescue.log"], text);
        if (logPath)
            append_line(logPath, text);
    });
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
    if (state != OVEngineMerging && state != OVEngineRetrying && state != OVEngineCopying)
        state = OVEngineIdle;
}

/* ------------------------------------------------------------------ */
/* Data path (capture thread)                                          */

- (void)captureReceivedBytes:(const void *)bytes length:(size_t)length
{
    pthread_mutex_lock(&mtx);
    lastDataTime = now_s();
    if (fp && !retryWindow && state == OVEngineRecording && !writeError) {
        int w = dv_writer_write(fp, bytes, length);
        if (w < 0)
            writeError = 1;
        else if (w == 0)
            fileBytes += (int64_t)length;
        else
            droppedBytes += length; /* buffer full: whole sample dropped */
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
        if (dv_frame_error_blocks(&f) && tc_key(&f) >= 0) {
            [badKeys addIndex:(NSUInteger)tc_key(&f)];
            if (npoints)
                points[npoints - 1].flags |= 64;
        }
    } else {
        dv_analyze_frame(&liveAnalyzer, data, size, pos, &f);
        free(f.sta);
        f.sta = NULL;
        if (retryWindow && fp && report && !writeError) {
            int64_t k = tc_key(&f);
            if (k >= winStart && k <= winEnd) {
                int w = dv_writer_write(fp, data, size);
                if (w < 0)
                    writeError = 1;
                else if (w > 0)
                    droppedBytes += size;
                else {
                    dv_report_feed(report, data, size, fileBytes);
                    fileBytes += (int64_t)size;
                }
            }
        }
    }
    /* A deck that has stopped (end of the tape) or plays blank tape keeps
     * sending frames: every video block flagged as concealed, or the same
     * tape position again and again. Such frames are "dead". */
    {
        int dead = f.full_conceal_vid
            || (haveLast && f.tc_valid && last.tc_valid && f.abst_valid && last.abst_valid
                && f.abst == last.abst && tc_key(&f) == tc_key(&last));
        if (!dead) {
            lastSignalTime = now_s();
            deadFrames = 0;
            if (state == OVEngineRecording && fp)
                signalSeen = 1;
        } else if (state == OVEngineRecording && fp)
            deadFrames++;
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
    s.bufferedBytes = fp ? (int64_t)dv_writer_pending(fp) : 0;
    s.droppedBytes = droppedBytes;
    s.deadFrames = deadFrames;
    s.secondsSinceData = lastDataTime ? now_s() - lastDataTime : -1;
    if (mirror) {
        dv_mirror_info mi;
        dv_mirror_status(mirror, &mi);
        s.copying = 1;
        s.copyBehind = fileBytes > mi.copied ? fileBytes - mi.copied : 0;
        s.copyFailing = mi.failing || mi.seconds_idle > 20;
    }
    s.secondsSinceSignal = (signalSeen && lastSignalTime) ? now_s() - lastSignalTime : -1;
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

- (OVRetryStatus)retryStatus
{
    OVRetryStatus r;
    pthread_mutex_lock(&mtx);
    r.planned = plannedRetries;
    r.pass = curPass;
    r.section = curSection;
    r.sections = passSections;
    r.headTC = headTC;
    r.revision = graphRev;
    pthread_mutex_unlock(&mtx);
    return r;
}

- (size_t)copyRetrySections:(OVRetrySection *)buf max:(size_t)max
{
    size_t n;
    pthread_mutex_lock(&mtx);
    n = nsections < max ? nsections : max;
    if (n)
        memcpy(buf, sections, n * sizeof(OVRetrySection));
    pthread_mutex_unlock(&mtx);
    return n;
}

- (OVDeckState)cachedDeckState { return (OVDeckState)deckStateCache; }

/* ------------------------------------------------------------------ */
/* Recording                                                           */

- (BOOL)openFile:(NSString *)path error:(NSString **)err
{
    dv_writer *f = dv_writer_open([path fileSystemRepresentation], 256u << 20);
    if (!f) {
        if (err) *err = [NSString stringWithFormat:@"Cannot create %@ (is the disk / network share mounted and writable?)", path];
        return NO;
    }
    pthread_mutex_lock(&mtx);
    fp = f;
    [filePath release];
    filePath = [path copy];
    fileBytes = 0;
    writeError = 0;
    droppedBytes = 0;
    signalSeen = 0;
    deadFrames = 0;
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
    dv_writer *w;
    pthread_mutex_lock(&mtx);
    dv_splitter_flush(&splitter, frame_cb, self);
    w = fp;
    fp = NULL;
    retryWindow = 0;
    r = report;
    report = NULL;
    path = [[filePath retain] autorelease];
    if (r)
        r->file_size = fileBytes;
    pthread_mutex_unlock(&mtx);
    /* drain the buffer outside the lock (can take a while on a share) */
    if (w) {
        if (dv_writer_pending(w) > (8u << 20))
            [self log:[NSString stringWithFormat:@"Writing the last %.0f MB to disk...", dv_writer_pending(w) / 1e6]];
        if (dv_writer_close(w) < 0)
            writeError = 1;
    }
    if (droppedBytes)
        [self log:[NSString stringWithFormat:@"WARNING: the destination was too slow, %.1f MB (about %llu frames) were dropped. "
                   @"Capture to the internal disk, or check the network.", droppedBytes / 1e6,
                   (unsigned long long)(droppedBytes / 120000)]];
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
    if (state == OVEngineRecording || state == OVEngineRetrying || state == OVEngineMerging || state == OVEngineCopying) {
        if (err) *err = @"A capture is already running.";
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (err) *err = [NSString stringWithFormat:@"%@ already exists, choose another name.", [path lastPathComponent]];
        return NO;
    }
    [resultFolder release];
    resultFolder = nil;
    if (destFolder) {
        NSString *dst = [destFolder stringByAppendingPathComponent:[path lastPathComponent]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dst]) {
            if (err) *err = [NSString stringWithFormat:@"%@ already exists in %@, choose another name.", [path lastPathComponent], destFolder];
            return NO;
        }
    }
    if (![self openFile:path error:err])
        return NO;
    dv_mirror_free(mirror);
    mirror = NULL;
    mirrorFailing = NO;
    cancelCopy = NO;
    if (destFolder) {
        mirror = dv_mirror_start([path fileSystemRepresentation],
                                 [[destFolder stringByAppendingPathComponent:[path lastPathComponent]] fileSystemRepresentation]);
        resultFolder = [[path stringByDeletingLastPathComponent] copy];
    } else
        resultFolder = [[path stringByDeletingLastPathComponent] copy];
    [baseName release];
    baseName = [basePath copy];
    [takes removeAllObjects];
    [takes addObject:path];
    retryCount = retries;
    noDataTimeout = seconds > 0 ? seconds : 0;
    blankLogged = NO;
    lastProgressLog = now_s();
    cancel = NO;
    autoStopDeck = play;
    pthread_mutex_lock(&mtx);
    [badKeys removeAllIndexes];
    npoints = 0;
    nsections = 0;
    plannedRetries = deck ? retries : 0;
    curPass = curSection = passSections = 0;
    headTC = -1;
    graphRev++;
    lastDataTime = 0;
    /* switch to recording atomically with a splitter restart, so that the
     * bytes written to the file and the frame positions start together */
    dv_splitter_free(&splitter);
    dv_splitter_init(&splitter);
    state = OVEngineRecording;
    pthread_mutex_unlock(&mtx);
    [self notifyState];
    [self setLogPath:[basePath stringByAppendingPathExtension:@"log"]];
    [self log:[NSString stringWithFormat:@"OldDV Rescue %s on %@, capture engine: %@, deck control: %@",
               OLDDV_VERSION, [[NSProcessInfo processInfo] operatingSystemVersionString], [self engineName],
               deck ? [deck name] : @"none"]];
    [self log:[NSString stringWithFormat:@"Recording to %@ (finish after %.0f s without signal, %d retry pass(es), %@)",
               path, noDataTimeout, retryCount, play ? @"deck started by the app" : @"deck not started by the app"]];
    if (destFolder)
        [self log:[NSString stringWithFormat:@"The capture is recorded on this Mac and copied to %@ in the background. "
                   @"If that folder stops answering, the capture goes on.", destFolder]];
    if (play && deck) {
        OVDeck *d = deck;
        dispatch_async(deckQueue, ^{ [d play]; });
    }
    return YES;
}

- (void)finishPass1
{
    dv_report *r = [self closeFile];
    uint32_t recorded = 0;
    NSUInteger bad;
    if (r) {
        recorded = r->count;
        [self log:[NSString stringWithFormat:@"First pass: %u frames, %u with issues, %u time code break(s), %u recording start(s)",
                   r->count, r->frames_with_errors, r->tc_breaks, r->rec_starts]];
        dv_report_free(r);
        free(r);
        r = NULL;
    }
    pthread_mutex_lock(&mtx);
    bad = [badKeys count];
    pthread_mutex_unlock(&mtx);
    if (!cancel && retryCount > 0 && bad && recorded && bad > (NSUInteger)recorded * 3 / 10) {
        /* errors all over the tape (dirty heads, tape recorded on another
         * camcorder, LP mode...): winding to hundreds of sections wears the
         * tape and brings nothing a second complete capture does not */
        [self log:[NSString stringWithFormat:@"%lu of %u frames have errors: too many to re-read section by section. "
                   @"Clean the heads or try another camcorder, capture the whole tape again under another name, "
                   @"then use Merge Takes.", (unsigned long)bad, recorded]];
    } else if (!cancel && retryCount > 0 && bad) {
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
    pthread_mutex_lock(&mtx);
    plannedRetries = 0; /* no section will be read again */
    graphRev++;
    pthread_mutex_unlock(&mtx);
    if (autoStopDeck && deck) {
        OVDeck *d = deck;
        dispatch_async(deckQueue, ^{ [d stop]; });
    }
    [self finishSession];
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
    } else if (state == OVEngineCopying) {
        cancelCopy = YES;
        [self log:@"Stopping the copy..."];
    }
}

/* ------------------------------------------------------------------ */
/* Local recording, copy to the destination                            */

- (void)setCopyDestination:(NSString *)folder
{
    [destFolder release];
    destFolder = [folder copy];
}

- (NSString *)resultPath
{
    if (!resultFolder || !baseName)
        return nil;
    return [resultFolder stringByAppendingPathComponent:
            [[baseName lastPathComponent] stringByAppendingPathExtension:@"dv"]];
}

static int copy_cancel_cb(void *ctx, double f)
{
    (void)f;
    return ((OVEngine *)ctx)->cancelCopy ? 1 : 0;
}

/* waits for one background copy, then compares both files; YES when the
 * destination holds an identical copy */
- (BOOL)finishCopy:(dv_mirror *)m from:(NSString *)src to:(NSString *)dst
{
    dv_mirror_info mi;
    double lastLog = now_s();
    BOOL failing = mirrorFailing;
    int st, cmp;
    dv_mirror_complete(m);
    while ((st = dv_mirror_status(m, &mi)) == DV_MIRROR_RUNNING && !cancelCopy) {
        BOOL f = mi.failing || mi.seconds_idle > 20;
        if (f != failing) {
            failing = f;
            [self log:f ? [NSString stringWithFormat:@"%@ does not answer: waiting. Click Stop to leave the capture on this Mac.", destFolder]
                        : [NSString stringWithFormat:@"%@ answers again: the copy continues.", destFolder]];
        }
        if (now_s() - lastLog > 60) {
            lastLog = now_s();
            [self log:[NSString stringWithFormat:@"  %@: %.0f of %.0f MB copied", [src lastPathComponent],
                       mi.copied / 1048576.0, mi.source_size / 1048576.0]];
        }
        usleep(200000);
    }
    mirrorFailing = failing;
    if (st != DV_MIRROR_DONE)
        return NO;
    cmp = dv_files_identical([src fileSystemRepresentation], [dst fileSystemRepresentation], copy_cancel_cb, self);
    if (cmp == 1)
        [self log:[NSString stringWithFormat:@"WARNING: the copy of %@ is not identical to the recording.", [src lastPathComponent]]];
    return cmp == 0;
}

- (void)copyMain:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *localDir = [baseName stringByDeletingLastPathComponent];
    NSString *prefix = [[baseName lastPathComponent] stringByAppendingString:@"."];
    NSString *mainName = [prefix stringByAppendingString:@"dv"], *logName = [prefix stringByAppendingString:@"log"];
    NSMutableArray *names = [NSMutableArray array], *done = [NSMutableArray array];
    BOOL ok = YES;
    dv_mirror *m;

    /* the main file first (its copy is already under way), the log last */
    [names addObject:mainName];
    for (NSString *n in [[fm contentsOfDirectoryAtPath:localDir error:NULL] sortedArrayUsingSelector:@selector(compare:)])
        if ([n hasPrefix:prefix] && ![n isEqualToString:mainName] && ![n isEqualToString:logName])
            [names addObject:n];
    [names addObject:logName];
    [self log:[NSString stringWithFormat:@"Copying the capture to %@ and checking the copy...", destFolder]];
    pthread_mutex_lock(&mtx);
    m = mirror;
    mirror = NULL;
    pthread_mutex_unlock(&mtx);
    for (NSString *n in names) {
        NSString *src = [localDir stringByAppendingPathComponent:n], *dst = [destFolder stringByAppendingPathComponent:n];
        if (n == logName) {
            /* everything said so far must be in the file that is copied */
            [self log:[NSString stringWithFormat:@"The capture files are in %@ and identical to the recording.", destFolder]];
            dispatch_sync(logQueue, ^{ [logPath release]; logPath = nil; });
        }
        if (![fm fileExistsAtPath:src]) {
            if (n == mainName) ok = NO;
            dv_mirror_free(m);
            m = NULL;
            if (!ok) break;
            continue;
        }
        if (!m)
            m = dv_mirror_start([src fileSystemRepresentation], [dst fileSystemRepresentation]);
        ok = m && [self finishCopy:m from:src to:dst];
        dv_mirror_free(m);
        m = NULL;
        if (!ok)
            break;
        [done addObject:n];
    }
    dv_mirror_free(m);
    if (ok) {
        /* the copies are verified: the recordings on this Mac can go */
        for (NSString *n in done)
            [fm removeItemAtPath:[localDir stringByAppendingPathComponent:n] error:NULL];
        [resultFolder release];
        resultFolder = [destFolder copy];
        [self setLogPath:[destFolder stringByAppendingPathComponent:logName]];
        [self log:@"The recording on this Mac was removed after the check."];
    } else {
        [self setLogPath:[localDir stringByAppendingPathComponent:logName]];
        [self log:[NSString stringWithFormat:@"The capture was NOT copied completely to %@ (%@). It is complete and safe on this Mac in %@. "
                   @"Copy the files named %@* from there when the folder works again.",
                   destFolder, cancelCopy ? @"stopped" : @"the folder failed", localDir, prefix]];
    }
    [self log:@"Capture finished."];
    [self setState:backend ? OVEngineMonitoring : OVEngineIdle];
    [pool release];
}

/* end of a capture session (any thread) */
- (void)finishSession
{
    if (destFolder && baseName) {
        [self setState:OVEngineCopying];
        [NSThread detachNewThreadSelector:@selector(copyMain:) toTarget:self withObject:nil];
        return;
    }
    [self log:@"Capture finished."];
    [self setState:backend ? OVEngineMonitoring : OVEngineIdle];
}

/* Seconds without a picture after which a capture ends although the deck
 * still plays (blank tape); 0 when the automatic finish is off. */
- (double)blankLimit
{
    if (noDataTimeout <= 0)
        return 0;
    return noDataTimeout * 6 > 90 ? noDataTimeout * 6 : 90;
}

- (void)tick
{
    double t = now_s();
    if (deck && t - lastDeckPoll > 1.0) {
        OVDeck *d = deck;
        lastDeckPoll = t;
        dispatch_async(deckQueue, ^{
            int st = (int)[d state];
            if (st != deckStateCache && state != OVEngineIdle && state != OVEngineMonitoring)
                [self log:[NSString stringWithFormat:@"Deck: %@", [OVDeck describeState:(OVDeckState)st]]];
            deckStateCache = st;
        });
    }
    if (state == OVEngineRecording) {
        OVLiveStats s = [self stats];
        /* Blank sections and a progress line every 5 minutes go to the log:
         * after a crash or a power cut the log shows how far the capture got. */
        if (!blankLogged && s.secondsSinceSignal > 10) {
            blankLogged = YES;
            [self log:[NSString stringWithFormat:@"Blank or frozen picture since about frame %u.",
                       s.framesRecorded > s.deadFrames ? s.framesRecorded - s.deadFrames : 0]];
        } else if (blankLogged && s.secondsSinceSignal >= 0 && s.secondsSinceSignal < 2) {
            blankLogged = NO;
            [self log:[NSString stringWithFormat:@"Picture is back at frame %u.", s.framesRecorded]];
        }
        if (s.copying && (BOOL)s.copyFailing != mirrorFailing) {
            mirrorFailing = (BOOL)s.copyFailing;
            [self log:mirrorFailing
                ? [NSString stringWithFormat:@"%@ does not answer. The capture goes on, on this Mac; the copy continues when the folder is back.", destFolder]
                : [NSString stringWithFormat:@"%@ answers again: the copy continues.", destFolder]];
        }
        if (t - lastProgressLog > 300) {
            lastProgressLog = t;
            [self log:[NSString stringWithFormat:@"Progress: %u frames, %u with issues, %.1f MB waiting to be written%@, deck %@",
                       s.framesRecorded, s.framesWithErrors, s.bufferedBytes / 1048576.0,
                       s.copying ? [NSString stringWithFormat:@", %.1f MB not yet copied", s.copyBehind / 1048576.0] : @"",
                       deck ? [OVDeck describeState:(OVDeckState)deckStateCache] : @"not controlled"]];
        }
        if (writeError) {
            [self log:@"Write error (disk full, or network share disconnected?): capture stopped."];
            cancel = YES;
            [self finishPass1];
        } else if (noDataTimeout > 0 && s.framesRecorded > 0 && s.secondsSinceData > noDataTimeout) {
            [self log:[NSString stringWithFormat:@"No data from the device for %.0f seconds (end of tape?): finishing.", noDataTimeout]];
            [self finishPass1];
        } else if (noDataTimeout > 0 && s.secondsSinceSignal > noDataTimeout) {
            /* Frames still arrive but carry no picture. If the deck says it
             * has stopped, this is the end. If it still plays, it may be a
             * blank section between two recordings: wait much longer. */
            BOOL stopped = deck && (deckStateCache == OVDeckStopped || deckStateCache == OVDeckNoTape);
            double limit = [self blankLimit];
            if (stopped || s.secondsSinceSignal > limit) {
                [self log:[NSString stringWithFormat:@"No picture for %.0f seconds (%@): finishing. "
                           @"The last %u frames of the file are blank or repeated.", s.secondsSinceSignal,
                           stopped ? @"the deck has stopped, end of the tape" : @"blank tape", s.deadFrames]];
                [self finishPass1];
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Rewind and retry (worker thread)                                    */

/* The sections of a retry pass, for the timeline. ranges: (first, last)
 * time codes, sorted. Returns the index of the first one, -1 without
 * memory. Called with mtx held. */
- (long)addSections:(NSArray *)ranges pass:(int)pass fps:(int)fps
{
    size_t n = [ranges count], base = nsections, i, j;
    if (nsections + n > capsections) {
        size_t nc = nsections + n + 64;
        OVRetrySection *ns = (OVRetrySection *)realloc(sections, nc * sizeof(OVRetrySection));
        if (!ns)
            return -1;
        sections = ns;
        capsections = nc;
    }
    for (i = 0; i < n; i++) {
        OVRetrySection *s = &sections[base + i];
        NSArray *rg = [ranges objectAtIndex:i];
        s->tcStart = [[rg objectAtIndex:0] longLongValue];
        s->tcEnd = [[rg objectAtIndex:1] longLongValue];
        s->first = 1;
        s->last = 0;
        s->pass = (uint8_t)pass;
        s->state = OVSectionPending;
    }
    /* where each section is in the first pass. A tape whose time code
     * starts again has the same time codes twice: keep the first place. */
    for (j = 0; j < npoints && n; j++) {
        int64_t k = points[j].tc;
        size_t lo = 0, hi = n;
        OVRetrySection *s;
        if (k < 0)
            continue;
        while (hi - lo > 1) {
            size_t mid = (lo + hi) / 2;
            if (sections[base + mid].tcStart <= k) lo = mid; else hi = mid;
        }
        s = &sections[base + lo];
        if (k < s->tcStart || k > s->tcEnd)
            continue;
        if (s->first > s->last)
            s->first = s->last = (uint32_t)j;
        else if (j - s->last <= (size_t)(3 * fps))
            s->last = (uint32_t)j;
    }
    nsections += n;
    graphRev++;
    return (long)base;
}

- (void)setSection:(long)i state:(int)st
{
    pthread_mutex_lock(&mtx);
    if (i >= 0 && (size_t)i < nsections) {
        sections[i].state = (uint8_t)st;
        graphRev++;
    }
    pthread_mutex_unlock(&mtx);
}

- (void)setHeadTC:(int64_t)k
{
    pthread_mutex_lock(&mtx);
    headTC = k;
    pthread_mutex_unlock(&mtx);
}

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

/* one winding towards target: 0 failed, 1 already there, 2 wound */
- (int)windTo:(int64_t)target
{
    int64_t pos = [self deckTC];
    int dir;
    double t0;
    BOOL shuttle = NO;
    double lastKnown, lastCmd;
    if (pos < 0) {
        /* play a moment to learn where we are */
        [deck play];
        for (t0 = now_s(); now_s() - t0 < 4 && pos < 0 && !cancel; usleep(100000))
            pos = [self liveTC:0.5];
        [deck pause];
    }
    if (pos < 0) {
        [self log:@"  Cannot read the tape position (no time code)."];
        return 0;
    }
    [self setHeadTC:pos];
    if (pos > target)
        dir = -1;
    else if (pos < target - 10 * [self fps])
        dir = 1;
    else
        return 1;
    if (dir < 0) [deck rewind]; else [deck fastForward];
    t0 = now_s();
    lastKnown = lastCmd = t0;
    while (!cancel && now_s() - t0 < 300) {
        usleep(150000);
        if (now_s() - lastCmd > 2 && [deck state] == OVDeckStopped)
            break; /* the deck stopped by itself: beginning / end of the tape */
        pos = [self deckTC];
        if (pos >= 0)
            [self setHeadTC:pos];
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
                return 0;
            }
            continue;
        }
        lastKnown = now_s();
        if ((dir < 0 && pos <= target) || (dir > 0 && pos >= target - 2 * [self fps]))
            break;
    }
    [deck stop];
    usleep(1000000);
    return (!cancel && now_s() - t0 < 300) ? 2 : 0;
}

/* Winds to just before target. A deck that winds forward stops late, past
 * the place: wind again (backwards) until the tape is before it. */
- (BOOL)seekTo:(int64_t)target
{
    int attempt;
    if (target < 0) /* section at the very start of the tape */
        target = 0;
    for (attempt = 0; attempt < 6 && !cancel; attempt++) {
        int r = [self windTo:target];
        if (r == 1)
            return YES;
        if (r == 0)
            return NO;
    }
    return NO;
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
        long secBase, secIdx = 0;
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
        secBase = [ranges count] ? [self addSections:ranges pass:pass fps:fps] : -1;
        if ([ranges count]) {
            curPass = pass;
            curSection = 0;
            passSections = (int)[ranges count];
        }
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
            long sec = secBase >= 0 ? secBase + secIdx : -1;
            secIdx++;
            if (cancel)
                break;
            pthread_mutex_lock(&mtx);
            curSection = (int)secIdx;
            pthread_mutex_unlock(&mtx);
            [self setSection:sec state:OVSectionSeeking];
            [self log:[NSString stringWithFormat:@"  Section %ld of %lu, %@ - %@: seeking...", secIdx,
                       (unsigned long)[ranges count], [self tcString:a], [self tcString:b]]];
            if (![self seekTo:a - 3 * fps]) {
                [self log:@"  Seek failed, section skipped."];
                [self setSection:sec state:OVSectionSkipped];
                continue;
            }
            [self setSection:sec state:OVSectionReading];
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
                if (k >= 0) {
                    lastData = now_s();
                    [self setHeadTC:k];
                }
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
            [self setSection:sec state:OVSectionRead];
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
            /* the timeline: what this pass repaired */
            {
                size_t j;
                for (j = 0; j < npoints; j++)
                    if ((points[j].flags & 64) && !(points[j].flags & 16) && points[j].tc >= 0
                        && ![badKeys containsIndex:(NSUInteger)points[j].tc])
                        points[j].flags |= 16;
                for (j = 0; j < nsections; j++)
                    if (sections[j].pass == pass && sections[j].state == OVSectionRead)
                        sections[j].state = [badKeys countOfIndexesInRange:
                                             NSMakeRange((NSUInteger)sections[j].tcStart,
                                                         (NSUInteger)(sections[j].tcEnd - sections[j].tcStart + 1))]
                            ? OVSectionPartial : OVSectionClean;
                graphRev++;
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
    /* whatever was not read (stopped, or the file could not be made) */
    pthread_mutex_lock(&mtx);
    {
        size_t j;
        for (j = 0; j < nsections; j++)
            if (sections[j].state < OVSectionRead)
                sections[j].state = OVSectionSkipped;
            else if (sections[j].state == OVSectionRead)
                sections[j].state = OVSectionPartial;
        curSection = 0;
        headTC = -1;
        graphRev++;
    }
    pthread_mutex_unlock(&mtx);
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
            [self log:[NSString stringWithFormat:@"Merged: %u frames: %u without errors in one of the takes, %u repaired by mixing "
                       @"blocks of several takes (%u blocks), %u still with errors.",
                       ms.frames_out, ms.frames_ok, ms.frames_repaired, ms.blocks_fixed, ms.frames_still_bad]];
            dv_report_free(&mr);
        } else
            [self log:@"Merge failed."];
    }
    if (autoStopDeck && deck)
        [deck stop];
    [self finishSession];
    [pool release];
}

@end
