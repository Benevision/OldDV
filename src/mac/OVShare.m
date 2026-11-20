/*
 * OldDV Rescue - mounting an NFS share. See OVShare.h.
 */
#import "OVShare.h"
#include <sys/param.h>
#include <sys/mount.h>

BOOL OVShareIsMounted(NSString *point)
{
    struct statfs sf;
    NSString *p = [point stringByStandardizingPath];
    if (![p length] || statfs([p fileSystemRepresentation], &sf))
        return NO;
    return !strcmp(sf.f_mntonname, [p fileSystemRepresentation]);
}

NSString *OVShareCheck(NSString *server, NSString *exportPath, NSString *point)
{
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    if (![server length] || [server rangeOfCharacterFromSet:bad].location != NSNotFound)
        return @"The server must be a name or an address, such as tower.local or 192.168.1.10.";
    if (![exportPath hasPrefix:@"/"] || [exportPath length] < 2)
        return @"The share must be its path on the server, such as /mnt/user/New Share (capitals matter).";
    if (![point hasPrefix:@"/"] || [point length] < 2 || [point isEqualToString:@"/Volumes"])
        return @"The place on this Mac must be a folder path, such as /Volumes/Unraid.";
    if ([exportPath rangeOfString:@"\n"].location != NSNotFound || [point rangeOfString:@"\n"].location != NSNotFound)
        return @"The paths must not contain line breaks.";
    return nil;
}

/* one word for /bin/sh, whatever it contains */
static NSString *sh_quote(NSString *s)
{
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *first_line(NSString *s)
{
    NSRange r = [s rangeOfString:@"\n"];
    return r.location == NSNotFound ? s : [s substringToIndex:r.location];
}

/* runs a program, waits at most `timeout` seconds; returns its exit
 * status (-1: timed out) and what it wrote */
static int run_tool(NSString *path, NSArray *args, double timeout, NSString **output)
{
    NSTask *t = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSData *d;
    int st;
    [t setLaunchPath:path];
    [t setArguments:args];
    [t setStandardOutput:pipe];
    [t setStandardError:pipe];
    [t setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [t launch];
    } @catch (NSException *e) {
        if (output) *output = [NSString stringWithFormat:@"cannot run %@", path];
        return -1;
    }
    while ([t isRunning] && [until timeIntervalSinceNow] > 0)
        usleep(100000);
    if ([t isRunning]) {
        [t terminate];
        if (output) *output = @"no answer (is the server on, and its name right?)";
        return -1;
    }
    st = [t terminationStatus];
    d = [[pipe fileHandleForReading] readDataToEndOfFile];
    if (output)
        *output = [[[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return st;
}

NSString *OVShareMount(NSString *server, NSString *exportPath, NSString *point)
{
    NSString *bad = OVShareCheck(server, exportPath, point);
    NSString *cmd, *script, *out = nil, *out2 = nil;
    int st;
    if (bad)
        return bad;
    point = [point stringByStandardizingPath];
    if (OVShareIsMounted(point))
        return nil;
    cmd = [NSString stringWithFormat:@"/bin/mkdir -p %@ && /sbin/mount -t nfs -o vers=3,tcp,resvport,rw %@ %@",
           sh_quote(point), sh_quote([NSString stringWithFormat:@"%@:%@", server, exportPath]), sh_quote(point)];
    /* as the user: enough where the system lets users mount */
    st = run_tool(@"/bin/sh", [NSArray arrayWithObjects:@"-c", cmd, nil], 45, &out);
    if (st == 0 && OVShareIsMounted(point))
        return nil;
    if (st == -1 && [out hasPrefix:@"no answer"])
        return [NSString stringWithFormat:@"%@ did not answer: %@", server, out];
    /* a password only helps when the system refused for lack of rights */
    if ([out rangeOfString:@"ermission denied"].location == NSNotFound && [out rangeOfString:@"not permitted"].location == NSNotFound
        && [out rangeOfString:@"root"].location == NSNotFound && [out rangeOfString:@"rivileged"].location == NSNotFound)
        return [NSString stringWithFormat:@"The share could not be mounted: %@", [out length] ? first_line(out) : @"unknown reason"];
    /* as administrator: the system asks for the password in its own dialog */
    script = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",
              [[cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
               stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    st = run_tool(@"/usr/bin/osascript", [NSArray arrayWithObjects:@"-e", script, nil], 300, &out2);
    if (st == 0 && OVShareIsMounted(point))
        return nil;
    if ([out2 rangeOfString:@"-128"].location != NSNotFound || [out2 rangeOfString:@"anceled"].location != NSNotFound)
        return @"The password dialog was cancelled.";
    return [NSString stringWithFormat:@"The share could not be mounted: %@", [out2 length] ? first_line(out2) : ([out length] ? first_line(out) : @"unknown reason")];
}
