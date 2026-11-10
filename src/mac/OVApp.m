/*
 * OldDV Rescue - main window and application.
 *
 * Written for Mac OS X 10.6 Snow Leopard (manual retain/release, no nib,
 * no Auto Layout, no ARC, no Objective-C literals) so that it builds with
 * Xcode 3.2.6 and runs on 10.6 - 10.14.
 */
#import <Cocoa/Cocoa.h>
#import <QTKit/QTKit.h>
#import "OVEngine.h"
#import "OVViews.h"
#include <math.h>
#include <sys/stat.h>

#define OLDDV_VERSION_NS @OLDDV_VERSION

/* ------------------------------------------------------------------ */
/* Small UI helpers                                                    */

static NSTextField *mkLabel(NSView *parent, NSRect r, NSString *text)
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setStringValue:text ? text : @""];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBordered:NO];
    [t setDrawsBackground:NO];
    [t setFont:[NSFont systemFontOfSize:12]];
    [parent addSubview:t];
    return t;
}

static NSTextField *mkField(NSView *parent, NSRect r, NSString *text)
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setStringValue:text ? text : @""];
    [t setFont:[NSFont systemFontOfSize:12]];
    [parent addSubview:t];
    return t;
}

static NSButton *mkButton(NSView *parent, NSRect r, NSString *title, id target, SEL action)
{
    NSButton *b = [[[NSButton alloc] initWithFrame:r] autorelease];
    [b setTitle:title];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setFont:[NSFont systemFontOfSize:12]];
    [b setTarget:target];
    [b setAction:action];
    [parent addSubview:b];
    return b;
}

static NSButton *mkCheck(NSView *parent, NSRect r, NSString *title, BOOL on)
{
    NSButton *b = [[[NSButton alloc] initWithFrame:r] autorelease];
    [b setButtonType:NSSwitchButton];
    [b setTitle:title];
    [b setFont:[NSFont systemFontOfSize:12]];
    [b setState:on ? NSOnState : NSOffState];
    [parent addSubview:b];
    return b;
}

static NSPopUpButton *mkPopup(NSView *parent, NSRect r, NSArray *items)
{
    NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame:r pullsDown:NO] autorelease];
    [p addItemsWithTitles:items];
    [p setFont:[NSFont systemFontOfSize:12]];
    [parent addSubview:p];
    return p;
}

static NSTextView *mkTextView(NSView *parent, NSRect r, NSUInteger mask)
{
    NSScrollView *sv = [[[NSScrollView alloc] initWithFrame:r] autorelease];
    NSTextView *tv;
    NSSize cs;
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSBezelBorder];
    [sv setAutoresizingMask:mask];
    cs = [sv contentSize];
    tv = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)] autorelease];
    [tv setEditable:NO];
    [tv setFont:[NSFont userFixedPitchFontOfSize:11]];
    [tv setMinSize:NSMakeSize(0, cs.height)];
    [tv setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [tv setVerticallyResizable:YES];
    [tv setHorizontallyResizable:NO];
    [tv setAutoresizingMask:NSViewWidthSizable];
    [[tv textContainer] setContainerSize:NSMakeSize(cs.width, FLT_MAX)];
    [[tv textContainer] setWidthTracksTextView:YES];
    [sv setDocumentView:tv];
    [parent addSubview:sv];
    return tv;
}

static void appendText(NSTextView *tv, NSString *line)
{
    NSDictionary *a = [NSDictionary dictionaryWithObject:[NSFont userFixedPitchFontOfSize:11] forKey:NSFontAttributeName];
    NSAttributedString *s = [[[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"] attributes:a] autorelease];
    [[tv textStorage] appendAttributedString:s];
    [tv scrollRangeToVisible:NSMakeRange([[tv string] length], 0)];
}

static NSTableView *mkTable(NSView *parent, NSRect r, NSArray *ids, NSArray *titles, NSArray *widths, id owner)
{
    NSScrollView *sv = [[[NSScrollView alloc] initWithFrame:r] autorelease];
    NSTableView *t = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, r.size.width, r.size.height)] autorelease];
    NSUInteger i;
    for (i = 0; i < [ids count]; i++) {
        NSTableColumn *c = [[[NSTableColumn alloc] initWithIdentifier:[ids objectAtIndex:i]] autorelease];
        [[c headerCell] setStringValue:[titles objectAtIndex:i]];
        [c setWidth:[[widths objectAtIndex:i] floatValue]];
        [[c dataCell] setFont:[NSFont systemFontOfSize:11]];
        [c setEditable:NO];
        [t addTableColumn:c];
    }
    [t setUsesAlternatingRowBackgroundColors:YES];
    [t setRowHeight:15];
    [t setDataSource:owner];
    [t setDelegate:owner];
    [sv setDocumentView:t];
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSBezelBorder];
    [parent addSubview:sv];
    return t;
}

@interface OVBlackView : NSView { NSString *text; }
- (void)setText:(NSString *)t;
@end
@implementation OVBlackView
- (void)dealloc { [text release]; [super dealloc]; }
- (void)setText:(NSString *)t { [text release]; text = [t copy]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r
{
    [[NSColor blackColor] set];
    NSRectFill([self bounds]);
    if (text) {
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSColor colorWithCalibratedWhite:0.6 alpha:1], NSForegroundColorAttributeName,
                           [NSFont systemFontOfSize:12], NSFontAttributeName, nil];
        NSSize s = [text sizeWithAttributes:a];
        [text drawAtPoint:NSMakePoint(([self bounds].size.width - s.width) / 2, [self bounds].size.height / 2) withAttributes:a];
    }
}
@end

static NSString *fmtBytes(int64_t b)
{
    if (b >= 1000000000LL)
        return [NSString stringWithFormat:@"%.2f GB", b / 1e9];
    return [NSString stringWithFormat:@"%.1f MB", b / 1e6];
}

static NSString *fmtDuration(uint64_t frames, int pal)
{
    double s = pal ? frames / 25.0 : frames * 1001.0 / 30000.0;
    int t = (int)s;
    return [NSString stringWithFormat:@"%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60];
}

/* ------------------------------------------------------------------ */

@interface OVAppController : NSObject <OVEngineDelegate> {
    NSWindow *window;
    NSTabView *tabs;
    OVEngine *engine;
    NSTimer *timer;
    NSUserDefaults *defs;

    /* capture tab */
    OVBlackView *previewBox;
    NSPopUpButton *devicePopup, *enginePopup, *retryPopup;
    NSArray *deviceList;
    NSTextField *connLabel, *folderField, *nameField, *timeoutField, *deckLabel, *statsLabel, *statsLabel2;
    NSButton *autoPlayCheck, *previewCheck, *captureButton, *connectButton;
    NSArray *deckButtons;
    OVGraphView *liveGraph;
    NSTextView *captureLog;
    size_t graphCopied;
    NSString *lastCapture;

    /* analyze tab */
    NSTextField *analyzePath;
    NSProgressIndicator *analyzeProgress;
    OVGraphView *analyzeGraph;
    NSTableView *issueTable;
    NSTextView *summaryView;
    OVBlockMapView *blockMap;
    NSImageView *thumb;
    dv_report *analysis;
    uint32_t *rows;
    uint32_t nrows;
    NSString *analysisFile;
    QTMovie *movie;
    BOOL busy;

    /* merge tab */
    NSMutableArray *mergeInputs;
    NSTableView *mergeTable;
    NSTextField *mergeOutField;
    NSProgressIndicator *mergeProgress;
    NSTextView *mergeLog;
    NSButton *mergeButton;

    /* package tab */
    NSTextField *packInField, *packOutField, *packMinField, *ffmpegField;
    NSButton *packSplit, *packRec, *packFormat, *packTC, *packKeepDV, *packMovDV, *packMP4, *packMovH264;
    NSButton *packDeint, *packSquare, *packButton;
    NSPopUpButton *packQuality, *afterPopup;
    BOOL wasRunning;
    NSTextView *packLog;
    NSProgressIndicator *packProgress;
}
@end

static int progress_to_main(void *ctx, double f)
{
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    [(id)ctx performSelectorOnMainThread:@selector(setBusyProgress:) withObject:[NSNumber numberWithDouble:f * 100] waitUntilDone:NO];
    [p release];
    return 0;
}

static void log_to_main(void *ctx, const char *line)
{
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    [(id)ctx performSelectorOnMainThread:@selector(busyLog:) withObject:[NSString stringWithUTF8String:line] waitUntilDone:NO];
    [p release];
}

@implementation OVAppController

- (NSString *)defaultName
{
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"yyyy-MM-dd_HHmm"];
    return [NSString stringWithFormat:@"Tape_%@", [df stringFromDate:[NSDate date]]];
}

/* ---------------- capture tab ---------------- */

- (void)buildCaptureTab:(NSView *)v
{
    CGFloat H = [v bounds].size.height, W = [v bounds].size.width, x = 430, y;
    NSView *dk;
    NSArray *titles = [NSArray arrayWithObjects:@"<< Rew", @"< Rev", @"|| Pause", @"Stop", @"Play >", @"FF >>", nil];
    NSMutableArray *btns = [NSMutableArray array];
    NSUInteger i;
    SEL sels[6] = { @selector(deckRewind:), @selector(deckReverse:), @selector(deckPause:), @selector(deckStop:), @selector(deckPlay:), @selector(deckFF:) };

    previewBox = [[OVBlackView alloc] initWithFrame:NSMakeRect(12, H - 312, 400, 300)];
    [previewBox setText:@"No device"];
    [previewBox setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
    [v addSubview:previewBox];
    [previewBox release];
    dk = v;
    for (i = 0; i < 6; i++) {
        NSButton *b = mkButton(dk, NSMakeRect(8 + i * 68, H - 348, 70, 32), [titles objectAtIndex:i], self, sels[i]);
        [b setAutoresizingMask:NSViewMinYMargin];
        [btns addObject:b];
    }
    deckButtons = [btns retain];
    deckLabel = mkLabel(v, NSMakeRect(12, H - 372, 400, 18), @"Deck: -");
    [deckLabel setAutoresizingMask:NSViewMinYMargin];

    y = H - 34;
    mkLabel(v, NSMakeRect(x, y, 90, 18), @"Device:");
    devicePopup = mkPopup(v, NSMakeRect(x + 95, y - 4, 300, 26), [NSArray array]);
    [devicePopup setTarget:self];
    [devicePopup setAction:@selector(deviceChosen:)];
    mkButton(v, NSMakeRect(x + 400, y - 6, 100, 32), @"Refresh", self, @selector(refreshDevices:));
    y -= 30;
    mkLabel(v, NSMakeRect(x, y, 90, 18), @"Engine:");
    enginePopup = mkPopup(v, NSMakeRect(x + 95, y - 4, 200, 26),
                          [NSArray arrayWithObjects:@"Automatic", @"QTKit (10.6)", @"AVFoundation (10.7+)", nil]);
    [enginePopup selectItemAtIndex:[defs integerForKey:@"engine"]];
    [enginePopup setTarget:self];
    [enginePopup setAction:@selector(engineChosen:)];
    connectButton = mkButton(v, NSMakeRect(x + 400, y - 6, 100, 32), @"Connect", self, @selector(connect:));
    y -= 24;
    connLabel = mkLabel(v, NSMakeRect(x, y, W - x - 12, 18), @"Not connected");
    [connLabel setTextColor:[NSColor darkGrayColor]];
    y -= 34;
    mkLabel(v, NSMakeRect(x, y, 90, 18), @"Save to:");
    folderField = mkField(v, NSMakeRect(x + 95, y - 2, 300, 22), [defs stringForKey:@"folder"]);
    mkButton(v, NSMakeRect(x + 400, y - 6, 100, 32), @"Choose...", self, @selector(chooseFolder:));
    y -= 30;
    mkLabel(v, NSMakeRect(x, y, 90, 18), @"File name:");
    nameField = mkField(v, NSMakeRect(x + 95, y - 2, 300, 22), [self defaultName]);
    mkLabel(v, NSMakeRect(x + 400, y, 60, 18), @".dv");
    y -= 30;
    autoPlayCheck = mkCheck(v, NSMakeRect(x, y, 450, 20), @"Rewind not needed - play the tape when capture starts, stop at the end",
                            [defs boolForKey:@"autoplay"]);
    y -= 26;
    mkLabel(v, NSMakeRect(x, y, 260, 18), @"Finish when there is no signal for");
    timeoutField = mkField(v, NSMakeRect(x + 262, y - 2, 40, 22), [defs stringForKey:@"timeout"]);
    mkLabel(v, NSMakeRect(x + 306, y, 220, 18), @"seconds (end of tape)");
    y -= 30;
    mkLabel(v, NSMakeRect(x, y, 260, 18), @"Re-read sections with errors:");
    retryPopup = mkPopup(v, NSMakeRect(x + 195, y - 4, 80, 26),
                         [NSArray arrayWithObjects:@"Off", @"1 time", @"2 times", @"3 times", @"5 times", nil]);
    [retryPopup selectItemAtIndex:[defs integerForKey:@"retries"]];
    mkLabel(v, NSMakeRect(x + 280, y, 260, 18), @"(rewinds the deck, then merges)");
    y -= 26;
    previewCheck = mkCheck(v, NSMakeRect(x, y, 160, 20), @"Live picture preview", ![defs boolForKey:@"nopreview"]);
    [previewCheck setTarget:self];
    [previewCheck setAction:@selector(previewToggled:)];
    mkLabel(v, NSMakeRect(x + 175, y, 90, 18), @"Then create:");
    afterPopup = mkPopup(v, NSMakeRect(x + 262, y - 4, 245, 26), [NSArray arrayWithObjects:
                         @"nothing more", @".mov (DV, lossless)", @".mp4 (H.264)", @".mov (DV) + .mp4 (H.264)", nil]);
    [afterPopup selectItemAtIndex:[defs integerForKey:@"after"]];
    [afterPopup setTarget:self];
    [afterPopup setAction:@selector(afterChosen:)];
    y -= 48;
    captureButton = mkButton(v, NSMakeRect(x, y, 200, 40), @"Start Capture", self, @selector(toggleCapture:));
    [captureButton setKeyEquivalent:@"\r"];
    mkButton(v, NSMakeRect(x + 210, y + 4, 150, 32), @"Show in Finder", self, @selector(revealCapture:));
    mkButton(v, NSMakeRect(x + 365, y + 4, 140, 32), @"Analyze Capture", self, @selector(analyzeLastCapture:));
    y -= 6;
    statsLabel = mkLabel(v, NSMakeRect(x, y - 92, 260, 92), @"");
    [statsLabel setFont:[NSFont userFixedPitchFontOfSize:11]];
    statsLabel2 = mkLabel(v, NSMakeRect(x + 262, y - 92, W - x - 274, 92), @"");
    [statsLabel2 setFont:[NSFont userFixedPitchFontOfSize:11]];

    liveGraph = [[OVGraphView alloc] initWithFrame:NSMakeRect(12, 146, W - 24, 92)];
    [liveGraph setAutoresizingMask:NSViewWidthSizable];
    [liveGraph setEmptyText:@"Errors of the capture appear here: red = video blocks concealed, orange = audio errors, blue = new recording, yellow = time code break"];
    [v addSubview:liveGraph];
    [liveGraph release];
    captureLog = mkTextView(v, NSMakeRect(12, 12, W - 24, 128), NSViewWidthSizable | NSViewHeightSizable);
}

- (OVEngineChoice)engineChoice { return (OVEngineChoice)[enginePopup indexOfSelectedItem]; }

- (void)refreshDevices:(id)sender
{
    OVCaptureBackend *b = [OVCaptureBackend backendWithChoice:[self engineChoice]];
    NSString *current = [devicePopup indexOfSelectedItem] >= 0 && [deviceList count] > (NSUInteger)[devicePopup indexOfSelectedItem]
        ? [(OVCaptureDeviceInfo *)[deviceList objectAtIndex:[devicePopup indexOfSelectedItem]] uniqueID] : nil;
    NSUInteger i;
    [deviceList release];
    deviceList = [[b devices] retain];
    [devicePopup removeAllItems];
    for (i = 0; i < [deviceList count]; i++) {
        [devicePopup addItemWithTitle:[NSString stringWithFormat:@"%@", [(OVCaptureDeviceInfo *)[deviceList objectAtIndex:i] name]]];
        if (current && [[(OVCaptureDeviceInfo *)[deviceList objectAtIndex:i] uniqueID] isEqualToString:current])
            [devicePopup selectItemAtIndex:i];
    }
    if (![deviceList count]) {
        [devicePopup addItemWithTitle:@"No FireWire DV device found"];
        [devicePopup setEnabled:NO];
    } else
        [devicePopup setEnabled:YES];
    if (sender && sender != self)
        appendText(captureLog, [NSString stringWithFormat:@"%lu DV device(s) found (%@).", (unsigned long)[deviceList count],
                                b ? [b engineName] : @"no engine"]);
}

- (void)connect:(id)sender
{
    NSString *err = nil;
    NSInteger i = [devicePopup indexOfSelectedItem];
    if ([engine state] == OVEngineRecording || [engine state] == OVEngineRetrying || [engine state] == OVEngineMerging)
        return;
    [self refreshDevices:nil];
    i = [devicePopup indexOfSelectedItem];
    if (![deviceList count] || i < 0) {
        [connLabel setStringValue:@"No DV device: connect the camcorder with FireWire, set it to VCR/Play mode"];
        [previewBox setText:@"No device"];
        return;
    }
    [previewBox setText:@""];
    if (![engine connectDevice:[(OVCaptureDeviceInfo *)[deviceList objectAtIndex:i] uniqueID] engine:[self engineChoice]
                       preview:([previewCheck state] == NSOnState ? previewBox : nil) error:&err]) {
        [connLabel setStringValue:err ? err : @"Cannot connect"];
        [previewBox setText:@"Not connected"];
        return;
    }
    [connLabel setStringValue:[NSString stringWithFormat:@"Connected (%@)%@", [engine engineName],
                               [engine deck] ? @" - deck control OK" : @" - no deck control"]];
}

- (void)deviceChosen:(id)s { [self connect:s]; }
- (void)engineChosen:(id)s
{
    [defs setInteger:[enginePopup indexOfSelectedItem] forKey:@"engine"];
    [self refreshDevices:nil];
    [self connect:s];
}
- (void)previewToggled:(id)s
{
    [defs setBool:[previewCheck state] != NSOnState forKey:@"nopreview"];
    if ([engine state] == OVEngineMonitoring)
        [self connect:s]; /* reconnect with/without preview */
}

- (void)deviceNotification:(NSNotification *)n
{
    if (![NSThread isMainThread]) { /* not guaranteed to be posted on the main thread */
        [self performSelectorOnMainThread:@selector(deviceNotification:) withObject:n waitUntilDone:NO];
        return;
    }
    [self refreshDevices:nil];
    if ([engine state] == OVEngineIdle)
        [self connect:nil];
}

- (void)chooseFolder:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseDirectories:YES];
    [p setCanChooseFiles:NO];
    [p setCanCreateDirectories:YES];
    [p setPrompt:@"Choose"];
    if ([p runModal] == NSFileHandlingPanelOKButton) {
        [folderField setStringValue:[[[p URLs] objectAtIndex:0] path]];
        [defs setObject:[folderField stringValue] forKey:@"folder"];
    }
}

- (void)deckDo:(SEL)sel
{
    OVDeck *d = [engine deck];
    if (!d) {
        NSBeep();
        appendText(captureLog, @"No AV/C deck control for this device.");
        return;
    }
    if (![d performSelector:sel])
        appendText(captureLog, @"The deck did not accept the command.");
}
- (void)deckRewind:(id)s { [self deckDo:@selector(rewind)]; }
- (void)deckReverse:(id)s { [self deckDo:@selector(reversePlay)]; }
- (void)deckPause:(id)s { [self deckDo:@selector(pause)]; }
- (void)deckStop:(id)s { [self deckDo:@selector(stop)]; }
- (void)deckPlay:(id)s { [self deckDo:@selector(play)]; }
- (void)deckFF:(id)s { [self deckDo:@selector(fastForward)]; }

- (void)toggleCapture:(id)s
{
    OVEngineState st = [engine state];
    NSString *folder, *name, *err = nil;
    int retries[5] = { 0, 1, 2, 3, 5 };
    if (st == OVEngineRecording || st == OVEngineRetrying) {
        [engine stopRecording];
        return;
    }
    if (st == OVEngineMerging)
        return;
    if (st == OVEngineIdle)
        [self connect:nil];
    if ([engine state] != OVEngineMonitoring) {
        NSRunAlertPanel(@"No device", @"Connect the camcorder or deck with a FireWire cable, switch it to VCR / Play mode, then click Connect.", @"OK", nil, nil);
        return;
    }
    folder = [[folderField stringValue] stringByExpandingTildeInPath];
    name = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![name length])
        name = [self defaultName];
    if ([[name pathExtension] isEqualToString:@"dv"])
        name = [name stringByDeletingPathExtension];
    if (![folder length] || ![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]) {
        NSRunAlertPanel(@"Folder", @"Choose a folder to save the capture.", @"OK", nil, nil);
        return;
    }
    [defs setObject:folder forKey:@"folder"];
    [defs setObject:[timeoutField stringValue] forKey:@"timeout"];
    [defs setInteger:[retryPopup indexOfSelectedItem] forKey:@"retries"];
    [defs setBool:[autoPlayCheck state] == NSOnState forKey:@"autoplay"];
    {
        NSDictionary *fsa = [[NSFileManager defaultManager] attributesOfFileSystemForPath:folder error:NULL];
        long long freeb = [[fsa objectForKey:NSFileSystemFreeSize] longLongValue];
        if (fsa && freeb < 15000000000LL &&
            NSRunAlertPanel(@"Low disk space", @"Only %@ free. One hour of DV needs about 13 GB.", @"Capture anyway", @"Cancel", nil,
                            fmtBytes(freeb)) != NSAlertDefaultReturn)
            return;
    }
    if (![engine startRecordingTo:[folder stringByAppendingPathComponent:name]
                          retries:retries[[retryPopup indexOfSelectedItem] < 5 ? [retryPopup indexOfSelectedItem] : 0]
                    noDataTimeout:[timeoutField doubleValue]
                         playDeck:[autoPlayCheck state] == NSOnState error:&err]) {
        NSRunAlertPanel(@"Cannot capture", @"%@", @"OK", nil, nil, err ? err : @"Unknown error");
        return;
    }
    [lastCapture release];
    lastCapture = [[[folder stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"dv"] retain];
    [liveGraph clear];
    graphCopied = 0;
}

- (void)revealCapture:(id)s
{
    NSString *f = lastCapture ? lastCapture : [[folderField stringValue] stringByExpandingTildeInPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:f])
        [[NSWorkspace sharedWorkspace] selectFile:f inFileViewerRootedAtPath:@""];
    else
        [[NSWorkspace sharedWorkspace] openFile:[[folderField stringValue] stringByExpandingTildeInPath]];
}

- (void)analyzeLastCapture:(id)s
{
    NSString *merged = [[lastCapture stringByDeletingPathExtension] stringByAppendingString:@".merged.dv"];
    if (!lastCapture) { NSBeep(); return; }
    [tabs selectTabViewItemAtIndex:1];
    [self analyzeFile:[[NSFileManager defaultManager] fileExistsAtPath:merged] ? merged : lastCapture];
}

- (void)engineLogLine:(NSString *)line { appendText(captureLog, line); }

- (void)afterChosen:(id)s { [defs setInteger:[afterPopup indexOfSelectedItem] forKey:@"after"]; }

- (void)engineStateDidChange:(OVEngine *)e
{
    OVEngineState st = [engine state];
    BOOL running = st == OVEngineRecording || st == OVEngineRetrying || st == OVEngineMerging;
    [captureButton setTitle:running ? (st == OVEngineMerging ? @"Merging..." : @"Stop Capture") : @"Start Capture"];
    [captureButton setEnabled:st != OVEngineMerging];
    [devicePopup setEnabled:!running && [deviceList count]];
    [enginePopup setEnabled:!running];
    [connectButton setEnabled:!running];
    [nameField setEnabled:!running];
    if (!running && lastCapture && [[NSFileManager defaultManager] fileExistsAtPath:lastCapture])
        [nameField setStringValue:[self defaultName]];
    if (wasRunning && !running)
        [self exportAfterCapture];
    wasRunning = running;
}

- (void)updateLive
{
    OVLiveStats s = [engine stats];
    OVEngineState st = [engine state];
    char tc[16] = "", rd[48] = "";
    NSString *status;
    OVGraphPoint buf[2048];
    size_t n;
    if (s.haveFrame) {
        dv_format_tc(tc, &s.last);
        dv_format_rdt(rd, &s.last);
    }
    switch (st) {
    case OVEngineMonitoring: status = s.secondsSinceData >= 0 && s.secondsSinceData < 1 ? @"Receiving (not recording)" : @"Connected, no signal"; break;
    case OVEngineRecording: status = s.secondsSinceData >= 0 && s.secondsSinceData < 1 ? @"RECORDING" : @"RECORDING (waiting for signal)"; break;
    case OVEngineRetrying: status = @"Re-reading bad sections"; break;
    case OVEngineMerging: status = @"Merging takes"; break;
    default: status = @"Not connected";
    }
    [statsLabel setStringValue:[NSString stringWithFormat:
        @"Status:    %@\nTime code: %s\nRecorded:  %s\nFrames:    %u\nDuration:  %@\nFile size: %@%@",
        status, tc[0] ? tc : "--", rd[0] ? rd : "--", s.framesRecorded,
        fmtDuration(s.framesRecorded, s.haveFrame && s.last.dsf), fmtBytes(s.fileBytes),
        s.droppedBytes ? [NSString stringWithFormat:@"\nDROPPED:   %@ (disk too slow)", fmtBytes((int64_t)s.droppedBytes)]
        : (s.bufferedBytes > 4000000 ? [NSString stringWithFormat:@"\nBuffered:  %@ (disk/share slow)", fmtBytes(s.bufferedBytes)] : @"")]];
    [statsLabel2 setStringValue:[NSString stringWithFormat:
        @"Frames with issues: %u\nTime code breaks:   %u\nNew recordings:     %u\nThis frame: %@%@",
        s.framesWithErrors, s.tcBreaks, s.recStarts,
        !s.haveFrame ? @"-" : (dv_frame_error_blocks(&s.last) ?
            [NSString stringWithFormat:@"%.1f%% video, %u audio blocks bad",
             s.last.video_blocks ? 100.0 * s.last.video_errors / s.last.video_blocks : 0.0, s.last.audio_errors] : @"OK"),
        s.haveFrame ? [NSString stringWithFormat:@"\nFormat: %s %s", s.last.dsf ? "PAL" : "NTSC",
                       s.last.aspect_n == 16 ? "16:9" : "4:3"] : @""]];
    if ([engine deck])
        [deckLabel setStringValue:[NSString stringWithFormat:@"Deck: %@ - %@", [[engine deck] name],
                                   [OVDeck describeState:[engine cachedDeckState]]]];
    else
        [deckLabel setStringValue:@"Deck: no AV/C control"];
    if (st == OVEngineRecording)
        while ((n = [engine copyGraphPointsFrom:graphCopied into:buf max:2048]) > 0) {
            [liveGraph appendPoints:buf count:n];
            graphCopied += n;
        }
}

- (void)tick:(NSTimer *)t
{
    [engine tick];
    [self updateLive];
}

/* ---------------- analyze tab ---------------- */

- (void)buildAnalyzeTab:(NSView *)v
{
    CGFloat H = [v bounds].size.height, W = [v bounds].size.width;
    NSArray *ids = [NSArray arrayWithObjects:@"n", @"tc", @"rdt", @"video", @"audio", @"flags", nil];
    NSArray *titles = [NSArray arrayWithObjects:@"Frame", @"Time code", @"Recorded", @"Video err.", @"Audio err.", @"Notes", nil];
    NSArray *widths = [NSArray arrayWithObjects:@"60", @"80", @"130", @"70", @"70", @"190", nil];
    NSButton *b;
    b = mkButton(v, NSMakeRect(8, H - 40, 120, 32), @"Open DV...", self, @selector(openForAnalysis:));
    b = mkButton(v, NSMakeRect(128, H - 40, 130, 32), @"Save XML...", self, @selector(saveXML:));
    b = mkButton(v, NSMakeRect(258, H - 40, 120, 32), @"Save CSV...", self, @selector(saveCSV:));
    b = mkButton(v, NSMakeRect(378, H - 40, 120, 32), @"Play in QuickTime", self, @selector(playFile:));
    (void)b;
    analyzeProgress = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(508, H - 32, 160, 16)] autorelease];
    [analyzeProgress setIndeterminate:NO];
    [analyzeProgress setHidden:YES];
    [v addSubview:analyzeProgress];
    analyzePath = mkLabel(v, NSMakeRect(676, H - 32, W - 688, 18), @"Open a .dv file to see its errors");
    [[analyzePath cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];

    analyzeGraph = [[OVGraphView alloc] initWithFrame:NSMakeRect(12, H - 150, W - 24, 100)];
    [analyzeGraph setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [analyzeGraph setTarget:self action:@selector(graphClicked:)];
    [analyzeGraph setEmptyText:@"Error timeline - click to inspect a frame"];
    [v addSubview:analyzeGraph];
    [analyzeGraph release];

    issueTable = mkTable(v, NSMakeRect(12, 12, W - 380, H - 170), ids, titles, widths, self);
    [[issueTable enclosingScrollView] setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    thumb = [[[NSImageView alloc] initWithFrame:NSMakeRect(W - 358, H - 170 - 240 + 12, 346, 240)] autorelease];
    [thumb setImageFrameStyle:NSImageFrameGrayBezel];
    [thumb setImageScaling:NSImageScaleProportionallyUpOrDown];
    [thumb setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [v addSubview:thumb];
    blockMap = [[OVBlockMapView alloc] initWithFrame:NSMakeRect(W - 358, H - 170 - 240 - 120, 346, 124)];
    [blockMap setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [v addSubview:blockMap];
    [blockMap release];
    summaryView = mkTextView(v, NSMakeRect(W - 358, 12, 346, H - 170 - 240 - 120 - 18), NSViewMinXMargin | NSViewHeightSizable);
}

- (void)setBusyProgress:(NSNumber *)n
{
    [analyzeProgress setDoubleValue:[n doubleValue]];
    [mergeProgress setDoubleValue:[n doubleValue]];
    [packProgress setDoubleValue:[n doubleValue]];
}

- (void)busyLog:(NSString *)line
{
    if ([[[tabs selectedTabViewItem] identifier] isEqual:@"merge"])
        appendText(mergeLog, line);
    else
        appendText(packLog, line);
}

- (void)openForAnalysis:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setAllowedFileTypes:[NSArray arrayWithObjects:@"dv", @"dif", @"DV", nil]];
    if ([p runModal] == NSFileHandlingPanelOKButton)
        [self analyzeFile:[[[p URLs] objectAtIndex:0] path]];
}

- (void)analyzeFile:(NSString *)path
{
    if (busy) { NSBeep(); return; }
    busy = YES;
    [analyzePath setStringValue:[NSString stringWithFormat:@"Analyzing %@ ...", [path lastPathComponent]]];
    [analyzeProgress setDoubleValue:0];
    [analyzeProgress setHidden:NO];
    [NSThread detachNewThreadSelector:@selector(analyzeThread:) toTarget:self withObject:path];
}

- (void)analyzeThread:(NSString *)path
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    dv_report *r = (dv_report *)calloc(1, sizeof(dv_report));
    dv_report_init(r, [path fileSystemRepresentation]);
    if (dv_analyze_file([path fileSystemRepresentation], r, progress_to_main, self) < 0) {
        dv_report_free(r);
        free(r);
        r = NULL;
    }
    [self performSelectorOnMainThread:@selector(analysisDone:)
                           withObject:[NSArray arrayWithObjects:path, [NSValue valueWithPointer:r], nil] waitUntilDone:NO];
    [pool release];
}

- (void)analysisDone:(NSArray *)res
{
    NSString *path = [res objectAtIndex:0];
    dv_report *r = (dv_report *)[[res objectAtIndex:1] pointerValue];
    uint32_t i;
    OVGraphPoint *pts;
    busy = NO;
    [analyzeProgress setHidden:YES];
    if (!r) {
        [analyzePath setStringValue:[NSString stringWithFormat:@"Cannot read %@", path]];
        return;
    }
    if (analysis) {
        dv_report_free(analysis);
        free(analysis);
    }
    analysis = r;
    [analysisFile release];
    analysisFile = [path copy];
    [movie release];
    movie = nil;
    free(rows);
    rows = (uint32_t *)malloc((r->count + 1) * sizeof(uint32_t));
    nrows = 0;
    pts = (OVGraphPoint *)malloc((r->count + 1) * sizeof(OVGraphPoint));
    for (i = 0; i < r->count; i++) {
        const dv_frame *f = &r->frames[i];
        if (rows && (dv_frame_has_errors(f) || f->rec_start || i == 0))
            rows[nrows++] = i;
        if (pts)
            OVGraphPointFromFrame(f, &pts[i]);
    }
    [analyzeGraph setPoints:pts count:pts ? r->count : 0];
    [analyzeGraph setSelected:-1];
    free(pts);
    [issueTable reloadData];
    [analyzePath setStringValue:path];
    {
        /* open_memstream() does not exist on 10.6: go through tmpfile() */
        FILE *mf = tmpfile();
        if (mf) {
            char buf[8192];
            size_t len;
            dv_report_write_summary(mf, r);
            rewind(mf);
            len = fread(buf, 1, sizeof(buf) - 1, mf);
            buf[len] = 0;
            fclose(mf);
            [summaryView setString:[NSString stringWithUTF8String:buf]];
        }
    }
    [blockMap clear];
    [thumb setImage:nil];
    if (nrows > 1)
        [issueTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t
{
    if (t == mergeTable)
        return [mergeInputs count];
    return analysis ? nrows : 0;
}

- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)row
{
    NSString *idf = [c identifier];
    const dv_frame *f;
    char buf[64];
    if (t == mergeTable)
        return [[mergeInputs objectAtIndex:row] lastPathComponent];
    if (!analysis || row < 0 || (uint32_t)row >= nrows)
        return @"";
    f = &analysis->frames[rows[row]];
    if ([idf isEqualToString:@"n"])
        return [NSString stringWithFormat:@"%u", f->index];
    if ([idf isEqualToString:@"tc"]) {
        dv_format_tc(buf, f);
        return [NSString stringWithUTF8String:buf];
    }
    if ([idf isEqualToString:@"rdt"]) {
        dv_format_rdt(buf, f);
        return [NSString stringWithUTF8String:buf];
    }
    if ([idf isEqualToString:@"video"])
        return f->video_errors ? [NSString stringWithFormat:@"%.1f%%", f->video_blocks ? 100.0 * f->video_errors / f->video_blocks : 0.0] : @"";
    if ([idf isEqualToString:@"audio"])
        return f->audio_errors ? [NSString stringWithFormat:@"%u blk", f->audio_errors] : @"";
    if ([idf isEqualToString:@"flags"]) {
        NSMutableArray *a = [NSMutableArray array];
        if (f->index == 0) [a addObject:@"start"];
        if (f->rec_start) [a addObject:@"new recording"];
        if (f->full_conceal_vid && f->full_conceal_aud) [a addObject:@"fully concealed"];
        else if (f->full_conceal_vid) [a addObject:@"video concealed"];
        if (f->tc_nc) [a addObject:f->tc_nc == 2 ? @"TC back" : @"TC jump"];
        if (f->tc_r) [a addObject:@"TC repeat"];
        if (f->rdt_nc) [a addObject:@"date jump"];
        if (f->abst_nc) [a addObject:@"track jump"];
        if (f->seqn_nc) [a addObject:@"seq. jump"];
        return [a componentsJoinedByString:@", "];
    }
    return @"";
}

- (void)showFrame:(uint32_t)idx
{
    const dv_frame *f;
    FILE *fp;
    uint8_t *buf;
    char tc[16];
    if (!analysis || idx >= analysis->count)
        return;
    f = &analysis->frames[idx];
    [analyzeGraph setSelected:idx];
    fp = fopen([analysisFile fileSystemRepresentation], "rb");
    buf = (uint8_t *)malloc(f->size);
    if (fp && buf && fseeko(fp, f->pos, SEEK_SET) == 0 && fread(buf, 1, f->size, fp) == f->size) {
        dv_format_tc(tc, f);
        [blockMap setFrameData:buf size:f->size bitDepth:f->bitdepth
                       caption:[NSString stringWithFormat:@"Frame %u %s - blocks per DIF sequence (red: concealed video, orange: audio error)", f->index, tc]];
    } else
        [blockMap clear];
    free(buf);
    if (fp)
        fclose(fp);
    if (!movie)
        movie = [[QTMovie movieWithFile:analysisFile error:NULL] retain];
    if (movie) {
        NSImage *img = [movie frameImageAtTime:QTMakeTimeWithTimeInterval(f->pts_ns / 1e9 + 0.001)];
        [thumb setImage:img];
    }
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    NSInteger r = [issueTable selectedRow];
    if ([n object] != issueTable || r < 0 || (uint32_t)r >= nrows)
        return;
    [self showFrame:rows[r]];
}

- (void)graphClicked:(OVGraphView *)g
{
    long sel = [g selected];
    uint32_t i, best = 0;
    if (!analysis || sel < 0)
        return;
    for (i = 0; i < nrows; i++)
        if (rows[i] <= (uint32_t)sel)
            best = i;
    if (nrows && rows[best] == (uint32_t)sel)
        [issueTable selectRowIndexes:[NSIndexSet indexSetWithIndex:best] byExtendingSelection:NO];
    else
        [issueTable deselectAll:nil];
    if (nrows)
        [issueTable scrollRowToVisible:best];
    [self showFrame:(uint32_t)sel];
}

- (void)saveXML:(id)s
{
    NSSavePanel *p;
    if (!analysis) { NSBeep(); return; }
    p = [NSSavePanel savePanel];
    [p setNameFieldStringValue:[[analysisFile lastPathComponent] stringByAppendingString:@".dvrescue.xml"]];
    [p setDirectoryURL:[NSURL fileURLWithPath:[analysisFile stringByDeletingLastPathComponent]]];
    if ([p runModal] == NSFileHandlingPanelOKButton)
        if (dv_report_save_xml([[[p URL] path] fileSystemRepresentation], analysis))
            NSRunAlertPanel(@"Error", @"Cannot write the file.", @"OK", nil, nil);
}

- (void)saveCSV:(id)s
{
    NSSavePanel *p;
    FILE *fp;
    if (!analysis) { NSBeep(); return; }
    p = [NSSavePanel savePanel];
    [p setNameFieldStringValue:[[analysisFile lastPathComponent] stringByAppendingString:@".csv"]];
    [p setDirectoryURL:[NSURL fileURLWithPath:[analysisFile stringByDeletingLastPathComponent]]];
    if ([p runModal] == NSFileHandlingPanelOKButton) {
        fp = fopen([[[p URL] path] fileSystemRepresentation], "w");
        if (!fp) { NSRunAlertPanel(@"Error", @"Cannot write the file.", @"OK", nil, nil); return; }
        dv_report_write_csv(fp, analysis);
        fclose(fp);
    }
}

- (void)playFile:(id)s
{
    if (analysisFile)
        [[NSWorkspace sharedWorkspace] openFile:analysisFile];
    else
        NSBeep();
}

/* ---------------- merge tab ---------------- */

- (void)buildMergeTab:(NSView *)v
{
    CGFloat H = [v bounds].size.height, W = [v bounds].size.width;
    mkLabel(v, NSMakeRect(12, H - 52, W - 24, 40),
            @"Merge several captures (takes) of the same tape: each frame is taken from the best take and its damaged "
            @"DIF blocks are replaced with good blocks from the other takes. Takes are lined up by absolute track number or time code.");
    mergeTable = mkTable(v, NSMakeRect(12, H - 250, W - 160, 190), [NSArray arrayWithObject:@"f"],
                         [NSArray arrayWithObject:@"Takes (first = reference)"], [NSArray arrayWithObject:@"700"], self);
    mkButton(v, NSMakeRect(W - 144, H - 92, 130, 32), @"Add Takes...", self, @selector(mergeAdd:));
    mkButton(v, NSMakeRect(W - 144, H - 124, 130, 32), @"Remove", self, @selector(mergeRemove:));
    mkLabel(v, NSMakeRect(12, H - 284, 90, 18), @"Output file:");
    mergeOutField = mkField(v, NSMakeRect(100, H - 286, W - 260, 22), @"");
    mkButton(v, NSMakeRect(W - 154, H - 292, 140, 32), @"Choose...", self, @selector(mergeChooseOut:));
    mergeButton = mkButton(v, NSMakeRect(8, H - 334, 130, 36), @"Merge", self, @selector(mergeRun:));
    mergeProgress = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(150, H - 324, 300, 16)] autorelease];
    [mergeProgress setIndeterminate:NO];
    [v addSubview:mergeProgress];
    mergeLog = mkTextView(v, NSMakeRect(12, 12, W - 24, H - 352), NSViewWidthSizable | NSViewHeightSizable);
}

- (void)mergeAdd:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setAllowsMultipleSelection:YES];
    [p setAllowedFileTypes:[NSArray arrayWithObjects:@"dv", @"dif", @"DV", nil]];
    if ([p runModal] == NSFileHandlingPanelOKButton) {
        for (NSURL *u in [p URLs])
            [mergeInputs addObject:[u path]];
        [mergeTable reloadData];
        if (![[mergeOutField stringValue] length] && [mergeInputs count])
            [mergeOutField setStringValue:[[[mergeInputs objectAtIndex:0] stringByDeletingPathExtension] stringByAppendingString:@".merged.dv"]];
    }
}

- (void)mergeRemove:(id)s
{
    NSInteger r = [mergeTable selectedRow];
    if (r >= 0 && (NSUInteger)r < [mergeInputs count]) {
        [mergeInputs removeObjectAtIndex:r];
        [mergeTable reloadData];
    }
}

- (void)mergeChooseOut:(id)s
{
    NSSavePanel *p = [NSSavePanel savePanel];
    [p setAllowedFileTypes:[NSArray arrayWithObject:@"dv"]];
    [p setNameFieldStringValue:@"merged.dv"];
    if ([p runModal] == NSFileHandlingPanelOKButton)
        [mergeOutField setStringValue:[[p URL] path]];
}

- (void)mergeRun:(id)s
{
    NSString *out = [mergeOutField stringValue];
    if (busy) { NSBeep(); return; }
    if ([mergeInputs count] < 2) {
        NSRunAlertPanel(@"Merge", @"Add at least two takes of the same tape.", @"OK", nil, nil);
        return;
    }
    if (![out length] || [mergeInputs containsObject:out]) {
        NSRunAlertPanel(@"Merge", @"Choose an output file that is not one of the takes.", @"OK", nil, nil);
        return;
    }
    busy = YES;
    [mergeButton setEnabled:NO];
    [mergeProgress setDoubleValue:0];
    [NSThread detachNewThreadSelector:@selector(mergeThread:) toTarget:self
                           withObject:[NSArray arrayWithObjects:[[mergeInputs copy] autorelease], out, nil]];
}

- (void)mergeThread:(NSArray *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *in = [args objectAtIndex:0];
    NSString *out = [args objectAtIndex:1];
    const char *paths[64];
    int n = 0;
    dv_merge_stats st;
    for (NSString *p in in)
        if (n < 64) paths[n++] = [p fileSystemRepresentation];
    if (dv_merge_files(paths, n, [out fileSystemRepresentation], &st, log_to_main, progress_to_main, self) == 0) {
        dv_report r;
        dv_report_init(&r, [out fileSystemRepresentation]);
        dv_analyze_file([out fileSystemRepresentation], &r, NULL, NULL);
        dv_report_save_xml([[out stringByAppendingString:@".dvrescue.xml"] fileSystemRepresentation], &r);
        dv_report_free(&r);
        log_to_main(self, "Merged file and its XML report written.");
    } else
        log_to_main(self, "Merge failed.");
    [self performSelectorOnMainThread:@selector(jobDone:) withObject:nil waitUntilDone:NO];
    [pool release];
}

- (void)jobDone:(id)x
{
    busy = NO;
    [mergeButton setEnabled:YES];
    [packButton setEnabled:YES];
}

/* ---------------- package & export tab ---------------- */

- (void)buildPackageTab:(NSView *)v
{
    CGFloat H = [v bounds].size.height, W = [v bounds].size.width, y = H - 40;
    NSString *ff = [defs stringForKey:@"ffmpeg"];
    mkLabel(v, NSMakeRect(12, y, 95, 18), @"DV file:");
    packInField = mkField(v, NSMakeRect(110, y - 2, W - 270, 22), @"");
    mkButton(v, NSMakeRect(W - 154, y - 8, 140, 32), @"Choose...", self, @selector(packChooseIn:));
    y -= 30;
    mkLabel(v, NSMakeRect(12, y, 95, 18), @"Output folder:");
    packOutField = mkField(v, NSMakeRect(110, y - 2, W - 270, 22), @"");
    mkButton(v, NSMakeRect(W - 154, y - 8, 140, 32), @"Choose...", self, @selector(packChooseOut:));
    y -= 34;
    packSplit = mkCheck(v, NSMakeRect(12, y, 140, 20), @"Split at:", YES);
    packRec = mkCheck(v, NSMakeRect(150, y, 170, 20), @"each new recording", YES);
    packFormat = mkCheck(v, NSMakeRect(320, y, 240, 20), @"format changes (4:3/16:9, audio)", YES);
    packTC = mkCheck(v, NSMakeRect(560, y, 160, 20), @"time code breaks", NO);
    mkLabel(v, NSMakeRect(720, y, 90, 18), @"min. frames:");
    packMinField = mkField(v, NSMakeRect(810, y - 2, 50, 22), @"25");
    y -= 34;
    mkLabel(v, NSMakeRect(12, y, 95, 18), @"Create:");
    packKeepDV = mkCheck(v, NSMakeRect(110, y, 200, 20), @".dv (raw, archival)", YES);
    packMovDV = mkCheck(v, NSMakeRect(320, y, 330, 20), @".mov - DV + PCM, lossless (built in)", [defs boolForKey:@"exp_movdv"]);
    y -= 24;
    packMP4 = mkCheck(v, NSMakeRect(110, y, 200, 20), @".mp4 - H.264 + AAC", [defs boolForKey:@"exp_mp4"]);
    packMovH264 = mkCheck(v, NSMakeRect(320, y, 330, 20), @".mov - H.264 + AAC", [defs boolForKey:@"exp_movh264"]);
    y -= 30;
    mkLabel(v, NSMakeRect(12, y, 95, 18), @"H.264:");
    packQuality = mkPopup(v, NSMakeRect(106, y - 4, 210, 26), [NSArray arrayWithObjects:
                          @"Best quality (CRF 18)", @"High quality (CRF 20)", @"Good, smaller (CRF 23)", @"Small (CRF 26)", nil]);
    [packQuality selectItemAtIndex:[defs objectForKey:@"exp_quality"] ? [defs integerForKey:@"exp_quality"] : 1];
    packDeint = mkCheck(v, NSMakeRect(330, y, 150, 20), @"Deinterlace", ![defs boolForKey:@"exp_nodeint"]);
    packSquare = mkCheck(v, NSMakeRect(480, y, 330, 20), @"Square pixels (640x480 / 854x480 ...)", ![defs boolForKey:@"exp_anamorphic"]);
    y -= 30;
    mkLabel(v, NSMakeRect(12, y, 95, 18), @"Encoder:");
    ffmpegField = mkField(v, NSMakeRect(110, y - 2, W - 270, 22), ff ? ff : @"");
    [[ffmpegField cell] setPlaceholderString:@"ffmpeg (bundled, or e.g. /opt/local/bin/ffmpeg from MacPorts)"];
    mkButton(v, NSMakeRect(W - 154, y - 8, 140, 32), @"Choose...", self, @selector(packChooseFFmpeg:));
    y -= 46;
    packButton = mkButton(v, NSMakeRect(8, y, 130, 36), @"Start", self, @selector(packRun:));
    packProgress = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(150, y + 10, 300, 16)] autorelease];
    [packProgress setIndeterminate:NO];
    [v addSubview:packProgress];
    packLog = mkTextView(v, NSMakeRect(12, 12, W - 24, y - 24), NSViewWidthSizable | NSViewHeightSizable);
    appendText(packLog, @"Split a capture into one file per recording and/or convert it.");
    appendText(packLog, @"  .dv         raw DV, keep it as the archival master");
    appendText(packLog, @"  .mov (DV)   same DV video untouched + PCM audio, plays everywhere QuickTime does (13 GB/hour)");
    appendText(packLog, @"  .mp4/.mov H.264   small files for sharing / Plex (about 1-1.5 GB/hour), needs the ffmpeg encoder");
    {
        NSString *enc = [self ffmpegPath];
        appendText(packLog, enc ? [NSString stringWithFormat:@"H.264 encoder: %@", enc]
                                : @"H.264 encoder: not found (see README: bundled ffmpeg or MacPorts).");
    }
}

/* bundled encoder first, then the configured one, then usual places */
- (NSString *)ffmpegPath
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"ffmpeg"];
    NSString *user = [[ffmpegField stringValue] stringByExpandingTildeInPath];
    NSArray *places = [NSArray arrayWithObjects:@"/opt/local/bin/ffmpeg", @"/usr/local/bin/ffmpeg", @"/sw/bin/ffmpeg", nil];
    if ([user length] && [fm isExecutableFileAtPath:user])
        return user;
    if ([fm isExecutableFileAtPath:bundled])
        return bundled;
    for (NSString *p in places)
        if ([fm isExecutableFileAtPath:p])
            return p;
    return nil;
}

- (void)packChooseIn:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setAllowedFileTypes:[NSArray arrayWithObjects:@"dv", @"dif", @"DV", nil]];
    if ([p runModal] == NSFileHandlingPanelOKButton) {
        NSString *f = [[[p URLs] objectAtIndex:0] path];
        [packInField setStringValue:f];
        if (![[packOutField stringValue] length])
            [packOutField setStringValue:[f stringByDeletingLastPathComponent]];
    }
}

- (void)packChooseOut:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseDirectories:YES];
    [p setCanChooseFiles:NO];
    [p setCanCreateDirectories:YES];
    if ([p runModal] == NSFileHandlingPanelOKButton)
        [packOutField setStringValue:[[[p URLs] objectAtIndex:0] path]];
}

- (void)packChooseFFmpeg:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseFiles:YES];
    [p setTreatsFilePackagesAsDirectories:YES];
    if ([p runModal] == NSFileHandlingPanelOKButton) {
        [ffmpegField setStringValue:[[[p URLs] objectAtIndex:0] path]];
        [defs setObject:[ffmpegField stringValue] forKey:@"ffmpeg"];
    }
}

/* Export options from the Package tab controls */
- (NSMutableDictionary *)exportOptions
{
    static const int crf[4] = { 18, 20, 23, 26 };
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    NSString *ff = [self ffmpegPath];
    int q = (int)[packQuality indexOfSelectedItem];
    [defs setInteger:q forKey:@"exp_quality"];
    [defs setBool:[packDeint state] != NSOnState forKey:@"exp_nodeint"];
    [defs setBool:[packSquare state] != NSOnState forKey:@"exp_anamorphic"];
    [o setObject:[NSNumber numberWithInt:crf[q >= 0 && q < 4 ? q : 1]] forKey:@"crf"];
    [o setObject:[NSNumber numberWithBool:[packDeint state] == NSOnState] forKey:@"deint"];
    [o setObject:[NSNumber numberWithBool:[packSquare state] == NSOnState] forKey:@"square"];
    if (ff)
        [o setObject:ff forKey:@"ffmpeg"];
    return o;
}

- (void)startExport:(NSDictionary *)opts
{
    busy = YES;
    [packButton setEnabled:NO];
    [packProgress setDoubleValue:0];
    [NSThread detachNewThreadSelector:@selector(exportThread:) toTarget:self withObject:opts];
}

- (void)packRun:(id)s
{
    NSString *in = [packInField stringValue], *outDir = [packOutField stringValue];
    NSMutableDictionary *o;
    int flags = 0;
    BOOL h264;
    if (busy) { NSBeep(); return; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:in]) {
        NSRunAlertPanel(@"Package & Export", @"Choose a DV file.", @"OK", nil, nil);
        return;
    }
    if (![outDir length])
        outDir = [in stringByDeletingLastPathComponent];
    if ([packRec state] == NSOnState) flags |= DV_SPLIT_REC_START;
    if ([packFormat state] == NSOnState) flags |= DV_SPLIT_FORMAT;
    if ([packTC state] == NSOnState) flags |= DV_SPLIT_TC_BREAK;
    [defs setBool:[packMovDV state] == NSOnState forKey:@"exp_movdv"];
    [defs setBool:[packMP4 state] == NSOnState forKey:@"exp_mp4"];
    [defs setBool:[packMovH264 state] == NSOnState forKey:@"exp_movh264"];
    if ([[ffmpegField stringValue] length])
        [defs setObject:[ffmpegField stringValue] forKey:@"ffmpeg"];
    o = [self exportOptions];
    h264 = [packMP4 state] == NSOnState || [packMovH264 state] == NSOnState;
    if (h264 && ![o objectForKey:@"ffmpeg"]) {
        NSRunAlertPanel(@"H.264 encoder missing",
                        @"MP4 / H.264 export needs ffmpeg. Use a build of OldDV Rescue that includes it, "
                        @"install it with MacPorts (sudo port install ffmpeg +gpl2), or choose an ffmpeg binary.", @"OK", nil, nil);
        return;
    }
    if ([packSplit state] != NSOnState && [packKeepDV state] == NSOnState && !h264 && [packMovDV state] != NSOnState) {
        NSRunAlertPanel(@"Package & Export", @"Nothing to do: tick Split or choose an output format.", @"OK", nil, nil);
        return;
    }
    [o setObject:in forKey:@"in"];
    [o setObject:outDir forKey:@"dir"];
    [o setObject:[NSNumber numberWithBool:[packSplit state] == NSOnState] forKey:@"split"];
    [o setObject:[NSNumber numberWithInt:flags] forKey:@"flags"];
    [o setObject:[NSNumber numberWithInt:[packMinField intValue]] forKey:@"min"];
    [o setObject:[NSNumber numberWithBool:[packKeepDV state] == NSOnState] forKey:@"keepdv"];
    [o setObject:[NSNumber numberWithBool:[packMovDV state] == NSOnState] forKey:@"movdv"];
    [o setObject:[NSNumber numberWithBool:[packMP4 state] == NSOnState] forKey:@"mp4"];
    [o setObject:[NSNumber numberWithBool:[packMovH264 state] == NSOnState] forKey:@"movh264"];
    [self startExport:o];
}

/* Encode one DV file to H.264 with ffmpeg. Returns YES on success. */
- (BOOL)encode:(NSString *)dv to:(NSString *)out options:(NSDictionary *)o
{
    NSMutableArray *args = [NSMutableArray array];
    NSMutableArray *vf = [NSMutableArray array];
    NSTask *t = [[[NSTask alloc] init] autorelease];
    NSPipe *errPipe = [NSPipe pipe];
    NSString *errText;
    BOOL mp4 = [[[out pathExtension] lowercaseString] isEqualToString:@"mp4"];
    if ([[o objectForKey:@"deint"] boolValue])
        [vf addObject:@"yadif=0:-1:0"];
    if ([[o objectForKey:@"square"] boolValue])
        [vf addObject:@"scale=trunc(ih*dar/2)*2:ih"];
    [vf addObject:@"setsar=1"];
    if (![[o objectForKey:@"square"] boolValue])
        [vf removeLastObject];
    [args addObjectsFromArray:[NSArray arrayWithObjects:@"-y", @"-nostdin", @"-v", @"error", @"-i", dv,
                               @"-map", @"0:v:0", @"-map", @"0:a:0?", nil]];
    if ([vf count])
        [args addObjectsFromArray:[NSArray arrayWithObjects:@"-vf", [vf componentsJoinedByString:@","], nil]];
    [args addObjectsFromArray:[NSArray arrayWithObjects:
        @"-c:v", @"libx264", @"-preset", @"medium", @"-crf", [[o objectForKey:@"crf"] stringValue],
        @"-pix_fmt", @"yuv420p", @"-c:a", @"aac", @"-b:a", @"192k", @"-ac", @"2", @"-strict", @"-2", nil]];
    if (mp4)
        [args addObjectsFromArray:[NSArray arrayWithObjects:@"-movflags", @"+faststart", nil]];
    [args addObject:out];
    [t setLaunchPath:[o objectForKey:@"ffmpeg"]];
    [t setArguments:args];
    [t setStandardError:errPipe];
    [t setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [t launch];
    } @catch (NSException *e) {
        log_to_main(self, "  ffmpeg could not be started (check the encoder path).");
        return NO;
    }
    errText = [[[NSString alloc] initWithData:[[errPipe fileHandleForReading] readDataToEndOfFile]
                                     encoding:NSUTF8StringEncoding] autorelease];
    [t waitUntilExit];
    if ([t terminationStatus]) {
        log_to_main(self, [[NSString stringWithFormat:@"  %@ FAILED: %@", [out lastPathComponent],
                            errText ? [errText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @""] UTF8String]);
        [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
        return NO;
    }
    return YES;
}

- (void)exportThread:(NSDictionary *)o
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *in = [o objectForKey:@"in"], *dir = [o objectForKey:@"dir"];
    NSString *base = [dir stringByAppendingPathComponent:[[in lastPathComponent] stringByDeletingPathExtension]];
    NSMutableArray *parts = [NSMutableArray array];
    BOOL split = [[o objectForKey:@"split"] boolValue];
    BOOL keepdv = [[o objectForKey:@"keepdv"] boolValue];
    BOOL movdv = [[o objectForKey:@"movdv"] boolValue], mp4 = [[o objectForKey:@"mp4"] boolValue];
    BOOL movh = [[o objectForKey:@"movh264"] boolValue];
    NSUInteger i;
    int ok = 0, failed = 0;

    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    if (split) {
        char *names[2000];
        int n = dv_split_file([in fileSystemRepresentation], [base fileSystemRepresentation],
                              [[o objectForKey:@"flags"] intValue], (uint32_t)[[o objectForKey:@"min"] intValue],
                              names, 2000, log_to_main, progress_to_main, self), k;
        if (n < 0)
            log_to_main(self, "Split failed (no DV frames or write error).");
        for (k = 0; k < n && k < 2000; k++) {
            [parts addObject:[NSString stringWithUTF8String:names[k]]];
            free(names[k]);
        }
    } else
        [parts addObject:in];

    for (i = 0; i < [parts count]; i++) {
        NSString *dv = [parts objectAtIndex:i];
        NSString *b = [dir stringByAppendingPathComponent:[[dv lastPathComponent] stringByDeletingPathExtension]];
        progress_to_main(self, (double)i / [parts count]);
        if (movdv) {
            NSString *mov = [b stringByAppendingString:movh ? @"_dv.mov" : @".mov"];
            if (dv_write_mov([dv fileSystemRepresentation], 0, 0, [mov fileSystemRepresentation], log_to_main, NULL, self) == 0)
                ok++;
            else {
                failed++;
                log_to_main(self, [[NSString stringWithFormat:@"  %@ FAILED", [mov lastPathComponent]] UTF8String]);
            }
        }
        if (mp4) {
            NSString *out = [b stringByAppendingPathExtension:@"mp4"];
            log_to_main(self, [[NSString stringWithFormat:@"Encoding %@ ...", [out lastPathComponent]] UTF8String]);
            if ([self encode:dv to:out options:o]) { ok++; log_to_main(self, "  done"); } else failed++;
        }
        if (movh) {
            NSString *out = [b stringByAppendingString:movdv ? @"_h264.mov" : @".mov"];
            log_to_main(self, [[NSString stringWithFormat:@"Encoding %@ ...", [out lastPathComponent]] UTF8String]);
            if ([self encode:dv to:out options:o]) { ok++; log_to_main(self, "  done"); } else failed++;
        }
        if (split && !keepdv && ![dv isEqualToString:in])
            [[NSFileManager defaultManager] removeItemAtPath:dv error:NULL];
    }
    progress_to_main(self, 1.0);
    log_to_main(self, [[NSString stringWithFormat:@"Finished: %lu part(s), %d file(s) created%@.", (unsigned long)[parts count], ok,
                        failed ? [NSString stringWithFormat:@", %d FAILED", failed] : @""] UTF8String]);
    [self performSelectorOnMainThread:@selector(jobDone:) withObject:nil waitUntilDone:NO];
    [pool release];
}

/* Capture tab: convert the finished capture automatically */
- (void)exportAfterCapture
{
    NSInteger what = [afterPopup indexOfSelectedItem];
    NSString *merged = [[lastCapture stringByDeletingPathExtension] stringByAppendingString:@".merged.dv"];
    NSString *src = [[NSFileManager defaultManager] fileExistsAtPath:merged] ? merged : lastCapture;
    NSMutableDictionary *o;
    if (what <= 0 || !src || ![[NSFileManager defaultManager] fileExistsAtPath:src])
        return;
    if (busy) {
        appendText(captureLog, @"Another job is running: convert the capture later in the Package & Export tab.");
        return;
    }
    o = [self exportOptions];
    if ((what == 2 || what == 3) && ![o objectForKey:@"ffmpeg"]) {
        appendText(captureLog, @"MP4 not created: no ffmpeg encoder found (see Package & Export tab).");
        if (what == 2)
            return;
        what = 1;
    }
    [o setObject:src forKey:@"in"];
    [o setObject:[src stringByDeletingLastPathComponent] forKey:@"dir"];
    [o setObject:[NSNumber numberWithBool:NO] forKey:@"split"];
    [o setObject:[NSNumber numberWithBool:what == 1 || what == 3] forKey:@"movdv"];
    [o setObject:[NSNumber numberWithBool:what == 2 || what == 3] forKey:@"mp4"];
    [o setObject:[NSNumber numberWithBool:NO] forKey:@"movh264"];
    [packInField setStringValue:src];
    appendText(captureLog, @"Converting the capture (progress in the Package & Export tab)...");
    [self startExport:o];
}

/* ---------------- application ---------------- */

- (void)buildMenu
{
    NSMenu *bar = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *appItem = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *appMenu = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *editItem = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    NSMenuItem *winItem = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [bar addItem:appItem];
    [bar addItem:editItem];
    [bar addItem:winItem];
    [appMenu addItemWithTitle:@"About OldDV Rescue" action:@selector(about:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide OldDV Rescue" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit OldDV Rescue" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:edit];
    [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winItem setSubmenu:win];
    [NSApp setMainMenu:bar];
    [NSApp setWindowsMenu:win];
}

- (void)about:(id)s
{
    NSRunAlertPanel(@"OldDV Rescue " OLDDV_VERSION_NS,
                    @"DV tape capture and analysis for Mac OS X 10.6 Snow Leopard and later.\n\n"
                    @"Re-implementation of DVRescue (MIPoPS, BSD-3-Clause) and of the DV analysis of "
                    @"MediaInfoLib (MediaArea, BSD-2-Clause). Reports use the DVRescue XML format.\n\nFor personal use.",
                    @"OK", nil, nil);
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    NSRect frame = NSMakeRect(0, 0, 1000, 720);
    NSArray *names = [NSArray arrayWithObjects:@"Capture", @"Analyze", @"Merge Takes", @"Package & Export", nil];
    NSArray *ids = [NSArray arrayWithObjects:@"capture", @"analyze", @"merge", @"package", nil];
    NSUInteger i;
    NSDictionary *def = [NSDictionary dictionaryWithObjectsAndKeys:
                         [@"~/Movies/DV Captures" stringByExpandingTildeInPath], @"folder",
                         @"5", @"timeout", [NSNumber numberWithBool:YES], @"autoplay", nil];
    defs = [NSUserDefaults standardUserDefaults];
    [defs registerDefaults:def];
    mergeInputs = [[NSMutableArray alloc] init];
    [self buildMenu];
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
                                           backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"OldDV Rescue"];
    [window setContentMinSize:NSMakeSize(1000, 720)];
    [window setDelegate:(id)self];
    tabs = [[[NSTabView alloc] initWithFrame:[[window contentView] bounds]] autorelease];
    [tabs setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [[window contentView] addSubview:tabs];
    for (i = 0; i < [names count]; i++) {
        NSTabViewItem *it = [[[NSTabViewItem alloc] initWithIdentifier:[ids objectAtIndex:i]] autorelease];
        [it setLabel:[names objectAtIndex:i]];
        [tabs addTabViewItem:it];
    }
    engine = [[OVEngine alloc] initWithDelegate:self];
    for (i = 0; i < [names count]; i++) {
        NSTabViewItem *it = [tabs tabViewItemAtIndex:i];
        NSView *v = [[[NSView alloc] initWithFrame:[tabs contentRect]] autorelease];
        [it setView:v];
        switch (i) {
        case 0: [self buildCaptureTab:v]; break;
        case 1: [self buildAnalyzeTab:v]; break;
        case 2: [self buildMergeTab:v]; break;
        case 3: [self buildPackageTab:v]; break;
        }
    }
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    appendText(captureLog, [NSString stringWithFormat:@"OldDV Rescue %@ - capture engines: %@%@", OLDDV_VERSION_NS,
                            [OVCaptureBackend qtKitAvailable] ? @"QTKit " : @"",
                            [OVCaptureBackend avFoundationAvailable] ? @"AVFoundation" : @""]);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceNotification:) name:QTCaptureDeviceWasConnectedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceNotification:) name:QTCaptureDeviceWasDisconnectedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceNotification:) name:@"AVCaptureDeviceWasConnectedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceNotification:) name:@"AVCaptureDeviceWasDisconnectedNotification" object:nil];
    [self refreshDevices:self];
    if ([deviceList count])
        [self connect:nil];
    timer = [[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)a
{
    OVEngineState st = [engine state];
    if (st == OVEngineRecording || st == OVEngineRetrying || st == OVEngineMerging) {
        if (NSRunAlertPanel(@"Capture running", @"Stop the capture and quit?", @"Stop and Quit", @"Cancel", nil) != NSAlertDefaultReturn)
            return NSTerminateCancel;
        [engine stopRecording];
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    [timer invalidate];
    [engine disconnect];
    [defs synchronize];
}
@end

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    OVAppController *c;
    [NSApplication sharedApplication];
    c = [[OVAppController alloc] init];
    [NSApp setDelegate:(id)c];
    [NSApp run];
    [c release];
    [pool release];
    return 0;
}
