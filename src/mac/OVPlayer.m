/*
 * OldDV Rescue - player (see OVPlayer.h)
 */
#import "OVPlayer.h"
#import <QTKit/QTKit.h>
#import "OVEngine.h"
#import "OVViews.h"

@implementation OVPlayer

static NSButton *btn(NSView *v, NSRect r, NSString *title, id target, SEL action, NSString *key)
{
    NSButton *b = [[[NSButton alloc] initWithFrame:r] autorelease];
    [b setTitle:title];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setTarget:target];
    [b setAction:action];
    [b setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
    if (key)
        [b setKeyEquivalent:key];
    [v addSubview:b];
    return b;
}

- (id)initWithFile:(NSString *)file report:(const dv_report *)report
{
    NSView *v;
    CGFloat W = 860, H = 700;
    OVGraphPoint *pts;
    uint32_t i;
    unichar left = NSLeftArrowFunctionKey, right = NSRightArrowFunctionKey;
    self = [super init];
    if (!self)
        return nil;
    path = [file copy];
    count = report->count;
    frames = (dv_frame *)malloc((count ? count : 1) * sizeof(dv_frame));
    buf = (uint8_t *)malloc(DV_MAX_FRAME * 4);
    fp = fopen([file fileSystemRepresentation], "rb");
    if (!frames || !buf || !fp || !count) {
        [self release];
        return nil;
    }
    memcpy(frames, report->frames, count * sizeof(dv_frame));
    for (i = 0; i < count; i++)
        frames[i].sta = NULL;
    fps = frames[0].dsf ? 25.0 : 30000.0 / 1001.0;
    shown = -1;
    movie = [[QTMovie movieWithFile:file error:NULL] retain];

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                         styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
                                           backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    [window setTitle:[NSString stringWithFormat:@"%@ - player", [file lastPathComponent]]];
    [window setContentMinSize:NSMakeSize(700, 480)];
    [window setDelegate:(id)self];
    v = [window contentView];

    picture = [[OVPictureView alloc] initWithFrame:NSMakeRect(0, 190, W, H - 190)];
    [picture setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [v addSubview:picture];
    [picture release];

    info = [[[NSTextField alloc] initWithFrame:NSMakeRect(12, 164, W - 24, 18)] autorelease];
    [info setBezeled:NO];
    [info setDrawsBackground:NO];
    [info setEditable:NO];
    [info setSelectable:YES];
    [info setFont:[NSFont userFixedPitchFontOfSize:11]];
    [info setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [[info cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [v addSubview:info];

    graph = [[OVGraphView alloc] initWithFrame:NSMakeRect(12, 56, W - 24, 104)];
    [graph setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [graph setTarget:self action:@selector(graphClicked:)];
    [v addSubview:graph];
    [graph release];
    pts = (OVGraphPoint *)malloc(count * sizeof(OVGraphPoint));
    if (pts) {
        for (i = 0; i < count; i++)
            OVGraphPointFromFrame(&frames[i], &pts[i]);
        [graph setPoints:pts count:count];
        free(pts);
    }

    btn(v, NSMakeRect(8, 12, 110, 32), @"|< Error", self, @selector(prevError:), nil);
    btn(v, NSMakeRect(118, 12, 80, 32), @"< Frame", self, @selector(stepBack:), [NSString stringWithCharacters:&left length:1]);
    playButton = btn(v, NSMakeRect(198, 12, 100, 32), @"Play", self, @selector(togglePlay:), @" ");
    btn(v, NSMakeRect(298, 12, 80, 32), @"Frame >", self, @selector(stepForward:), [NSString stringWithCharacters:&right length:1]);
    btn(v, NSMakeRect(378, 12, 110, 32), @"Error >|", self, @selector(nextError:), nil);
    errCheck = [[[NSButton alloc] initWithFrame:NSMakeRect(500, 18, 200, 20)] autorelease];
    [errCheck setButtonType:NSSwitchButton];
    [errCheck setTitle:@"Mark damaged blocks"];
    [errCheck setState:NSOnState];
    [errCheck setTarget:self];
    [errCheck setAction:@selector(errToggled:)];
    [v addSubview:errCheck];
    if (!movie) {
        NSTextField *w = [[[NSTextField alloc] initWithFrame:NSMakeRect(700, 18, W - 712, 18)] autorelease];
        [w setBezeled:NO];
        [w setDrawsBackground:NO];
        [w setEditable:NO];
        [w setStringValue:@"QuickTime cannot open this file: no picture, no sound."];
        [w setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [v addSubview:w];
        [playButton setEnabled:NO];
    }
    timer = [[NSTimer timerWithTimeInterval:0.04 target:self selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [window center];
    return self;
}

- (void)dealloc
{
    [self close];
    [window setDelegate:nil];
    [window release];
    [movie release];
    [path release];
    free(frames);
    free(buf);
    if (fp)
        fclose(fp);
    [super dealloc];
}

- (void)close
{
    /* the timer retains the player: without this it would never go away */
    [timer invalidate];
    [timer release];
    timer = nil;
    [movie stop];
    [window orderOut:nil];
}

- (void)windowWillClose:(NSNotification *)n
{
    [timer invalidate];
    [timer release];
    timer = nil;
    [movie stop];
    [playButton setTitle:@"Play"];
}

- (BOOL)playing { return movie && [movie rate] != 0; }

- (long)movieFrame
{
    NSTimeInterval t = 0;
    long i;
    if (!movie || !QTGetTimeInterval([movie currentTime], &t))
        return shown < 0 ? 0 : shown;
    i = (long)floor(t * fps + 0.05);
    if (i < 0)
        i = 0;
    if (i >= (long)count)
        i = (long)count - 1;
    return i;
}

- (void)display:(long)idx
{
    const dv_frame *f;
    char tc[16], rd[48];
    size_t got = 0, size;
    NSMutableString *s;
    if (idx < 0 || idx >= (long)count)
        return;
    f = &frames[idx];
    shown = idx;
    size = f->size > DV_MAX_FRAME * 4 ? DV_MAX_FRAME * 4 : f->size;
    if (fseeko(fp, f->pos, SEEK_SET) == 0)
        got = fread(buf, 1, size, fp);
    dv_format_tc(tc, f);
    dv_format_rdt(rd, f);
    [picture setImage:movie ? [movie currentFrameImage] : nil frameData:got == size ? buf : NULL size:got == size ? size : 0
             bitDepth:f->bitdepth wide:f->aspect_n == 16 caption:[NSString stringWithFormat:@"%s", tc[0] ? tc : "--:--:--:--"]];
    s = [NSMutableString stringWithFormat:@"Frame %ld of %u   %s   %s   ", idx + 1, count, tc[0] ? tc : "--:--:--:--", rd];
    if (f->video_errors || f->audio_errors)
        [s appendFormat:@"video %.1f%% (%u blocks)  audio %u blocks", f->video_blocks ? 100.0 * f->video_errors / f->video_blocks : 0.0,
            f->video_errors, f->audio_errors];
    else
        [s appendString:@"no error"];
    if (f->rec_start) [s appendString:@"   new recording"];
    if (f->tc_nc) [s appendString:@"   time code break"];
    [info setStringValue:s];
    [graph setSelected:idx];
}

- (void)seek:(long)idx
{
    if (idx < 0)
        idx = 0;
    if (idx >= (long)count)
        idx = (long)count - 1;
    if (movie)
        [movie setCurrentTime:QTMakeTimeWithTimeInterval((idx + 0.25) / fps)];
    [self display:idx];
}

- (void)tick:(NSTimer *)t
{
    BOOL p = [self playing];
    long idx;
    if (p != wasPlaying) {
        wasPlaying = p;
        [playButton setTitle:p ? @"Pause" : @"Play"];
    }
    if (!p && shown >= 0)
        return;
    idx = [self movieFrame];
    if (idx != shown)
        [self display:idx];
}

- (void)showAtFrame:(uint32_t)index
{
    [window makeKeyAndOrderFront:nil];
    if (!timer) {
        timer = [[NSTimer timerWithTimeInterval:0.04 target:self selector:@selector(tick:) userInfo:nil repeats:YES] retain];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    [self seek:(long)index];
}

- (void)togglePlay:(id)s
{
    if (!movie)
        return;
    if ([self playing])
        [movie stop];
    else {
        if (shown >= (long)count - 1)
            [self seek:0];
        [movie play];
    }
}

- (void)stepBack:(id)s { [movie stop]; [self seek:(shown < 0 ? 0 : shown) - 1]; }
- (void)stepForward:(id)s { [movie stop]; [self seek:(shown < 0 ? 0 : shown) + 1]; }

/* the start of the next / the previous run of frames with errors */
- (void)nextError:(id)s
{
    long i = shown < 0 ? 0 : shown;
    while (i < (long)count && dv_frame_has_errors(&frames[i]))
        i++;
    while (i < (long)count && !dv_frame_has_errors(&frames[i]))
        i++;
    if (i >= (long)count) {
        NSBeep();
        return;
    }
    [movie stop];
    [self seek:i];
}

- (void)prevError:(id)s
{
    long i = (shown < 0 ? 0 : shown) - 1;
    while (i >= 0 && dv_frame_has_errors(&frames[i]))
        i--;
    while (i >= 0 && !dv_frame_has_errors(&frames[i]))
        i--;
    if (i < 0) {
        NSBeep();
        return;
    }
    while (i > 0 && dv_frame_has_errors(&frames[i - 1]))
        i--;
    [movie stop];
    [self seek:i];
}

- (void)graphClicked:(OVGraphView *)g
{
    long sel = [g selected];
    if (sel >= 0)
        [self seek:sel];
}

- (void)errToggled:(id)s { [picture setShowErrors:[errCheck state] == NSOnState]; }

@end
