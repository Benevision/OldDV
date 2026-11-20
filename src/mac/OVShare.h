/*
 * OldDV Rescue - mounting an NFS share (Unraid or another NAS).
 *
 * Mac OS X 10.6 only talks to such a server reliably with NFS version 3
 * over TCP from a privileged port, which the Finder's "Connect to Server"
 * does not ask for. This does by itself what otherwise is typed in
 * Terminal:
 *   sudo mkdir -p /Volumes/Unraid
 *   sudo mount -t nfs -o vers=3,tcp,resvport,rw tower.local:/mnt/user/Share /Volumes/Unraid
 */
#import <Cocoa/Cocoa.h>

/* YES when a file system is mounted exactly on `point` */
BOOL OVShareIsMounted(NSString *point);
/* nil when the three values can be used, else what is wrong */
NSString *OVShareCheck(NSString *server, NSString *exportPath, NSString *point);
/* Mounts server:exportPath on point. First without a password; if the
 * system refuses, the system's own dialog asks for an administrator
 * password (this app never sees it). Waits until done: call it from a
 * background thread, or accept that the window waits. Returns nil when the
 * share is mounted, else the reason. */
NSString *OVShareMount(NSString *server, NSString *exportPath, NSString *point);
