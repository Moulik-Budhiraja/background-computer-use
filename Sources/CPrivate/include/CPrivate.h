// Thin C/ObjC wrappers around private macOS APIs. Everything here is called
// from our own process; nothing is injected into other apps.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Virtual display

/// A software-only display backed by the private CGVirtualDisplay API.
/// The display exists until -invalidate is called or the object is freed.
@interface BCUVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned)width
                               height:(unsigned)height
                                  ppi:(double)ppi
                               serial:(unsigned)serial;
- (void)invalidate;
@end

#pragma mark - SkyLight events

/// True when SLEventPostToPid resolved.
BOOL BCUSkyLightAvailable(void);

/// Post `event` to one process without moving the cursor or activating it.
/// `attachAuthMessage` adds SLSEventAuthenticationMessage, which keyboard
/// input needs for Chromium-based apps on macOS 14+. Leave it off for mouse
/// events and for menu key equivalents (with it, NSMenu never sees the key).
/// Falls back to CGEventPostToPid when SkyLight is unavailable.
void BCUPostEventToPid(pid_t pid, CGEventRef event, BOOL attachAuthMessage);

/// SLEventSetIntegerValueField: raw event field stamping (fields 40, 51, 91, 92...).
void BCUEventSetIntegerField(CGEventRef event, uint32_t field, int64_t value);

/// CGEventSetWindowLocation (private): screen-space point the event targets.
void BCUEventSetWindowLocation(CGEventRef event, CGPoint point);

#pragma mark - In-app key window records (no activation, no raise)

/// Post the 248-byte focus (focus=YES) or defocus record for `windowID` to its
/// owning process. Returns the SLPSPostEventRecordTo status (0 = posted).
int BCUPostFocusRecord(pid_t pid, uint32_t windowID, BOOL focus);

/// Post the make-key record pair for `windowID` to its owning process.
int BCUPostMakeKeyRecords(pid_t pid, uint32_t windowID);

#pragma mark - Processes

/// The pid WindowServer considers frontmost (0 if unknown). Unlike
/// NSWorkspace, this doesn't wait for our run loop to see the change.
pid_t BCUFrontProcessPID(void);

/// SLPSSetFrontProcessWithOptions. Used only to give the front back to the
/// user's app after another app activated itself. 0x200 = user generated.
int BCUSetFrontProcess(pid_t pid, uint32_t windowID, uint32_t options);

#pragma mark - Capture

/// SLSHWCaptureWindowList: one window's backing store as a CGImage (+1, caller
/// releases), or NULL. Reads the window directly: no ScreenCaptureKit session,
/// so macOS shows no screen-sharing indicator.
CGImageRef _Nullable BCUCaptureWindow(uint32_t windowID) CF_RETURNS_RETAINED;
/// Capture part of one window (SLSCaptureWindowsContentsToRectWithOptions).
CGImageRef _Nullable BCUCaptureWindowRect(uint32_t windowID, CGRect rect, uint32_t options) CF_RETURNS_RETAINED;

#pragma mark - Spaces

/// The current Space of a display (SLSManagedDisplayGetCurrentSpace). 0 if unknown.
uint64_t BCUCurrentSpaceForDisplay(CGDirectDisplayID display);

/// SLSProcessAssignToSpace: new windows of `pid` open on Space `sid`, like the
/// Dock's "Assign To Desktop on Display N". Pass 0 to clear. Returns CGError.
int BCUProcessAssignToSpace(pid_t pid, uint64_t sid);

#pragma mark - Accessibility

/// _AXUIElementGetWindow: the CGWindowID behind an AX window element.
BOOL BCUAXGetWindowID(AXUIElementRef element, uint32_t *outWindowID);

NS_ASSUME_NONNULL_END
