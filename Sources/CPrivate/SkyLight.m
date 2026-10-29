// Background input through SkyLight, called from our own process.
// The recipes (per-pid posting with the authentication message, the 248-byte
// focus/make-key records) follow trycua/cua's cua-driver (MIT), which in turn
// credits yabai (MIT) for the focus record layout.
#import "CPrivate.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void (*PostToPidFn)(pid_t, CGEventRef);
typedef void (*SetAuthMessageFn)(CGEventRef, id);
typedef void (*SetWindowLocationFn)(CGEventRef, CGPoint);
typedef void (*SetIntegerFieldFn)(CGEventRef, uint32_t, int64_t);
typedef uint32_t (*MainConnectionIDFn)(void);
typedef int32_t (*PostEventRecordToFn)(const void *psn, const uint8_t *bytes);
typedef int32_t (*GetFrontProcessFn)(void *psn);
typedef int32_t (*GetWindowOwnerFn)(uint32_t cid, uint32_t wid, uint32_t *outCid);
typedef int32_t (*GetConnectionPSNFn)(uint32_t cid, void *psn);
typedef int32_t (*GetProcessForPIDFn)(pid_t pid, void *psn);
typedef int32_t (*GetProcessPIDFn)(const void *psn, pid_t *pid);
typedef int32_t (*SetFrontProcessFn)(const void *psn, uint32_t wid, uint32_t options);
typedef AXError (*AXGetWindowFn)(AXUIElementRef, uint32_t *);

static void *Sym(const char *name) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
    return dlsym(RTLD_DEFAULT, name);
}

BOOL BCUSkyLightAvailable(void) {
    return Sym("SLEventPostToPid") != NULL;
}

// The SLSEventRecord pointer inside a CGEvent: {CFRuntimeBase, uint32_t, SLSEventRecord *}.
// Probe a few offsets in case the layout shifts between releases.
static void *EventRecord(CGEventRef event) {
    const size_t offsets[] = {24, 32, 16};
    for (size_t i = 0; i < 3; i++) {
        void *p = NULL;
        memcpy(&p, (const uint8_t *)event + offsets[i], sizeof(p));
        if (p) return p;
    }
    return NULL;
}

void BCUPostEventToPid(pid_t pid, CGEventRef event, BOOL attachAuthMessage) {
    PostToPidFn post = (PostToPidFn)Sym("SLEventPostToPid");
    if (!post) {
        CGEventPostToPid(pid, event);
        return;
    }
    if (attachAuthMessage) {
        Class cls = objc_getClass("SLSEventAuthenticationMessage");
        SEL sel = sel_registerName("messageWithEventRecord:pid:version:");
        SetAuthMessageFn setAuth = (SetAuthMessageFn)Sym("SLEventSetAuthenticationMessage");
        // The factory exists from macOS 15. On 14 the event goes without it.
        if (cls && setAuth && [(id)cls respondsToSelector:sel]) {
            void *record = EventRecord(event);
            if (record) {
                id message = ((id (*)(Class, SEL, void *, int32_t, uint32_t))objc_msgSend)(cls, sel, record, pid, 0);
                if (message) setAuth(event, message);
            }
        }
    }
    post(pid, event);
}

void BCUEventSetIntegerField(CGEventRef event, uint32_t field, int64_t value) {
    SetIntegerFieldFn f = (SetIntegerFieldFn)Sym("SLEventSetIntegerValueField");
    if (f) f(event, field, value);
    else CGEventSetIntegerValueField(event, (CGEventField)field, value);
}

void BCUEventSetWindowLocation(CGEventRef event, CGPoint point) {
    SetWindowLocationFn f = (SetWindowLocationFn)Sym("CGEventSetWindowLocation");
    if (f) f(event, point);
}

static BOOL PSNForWindow(uint32_t wid, pid_t pid, uint8_t psn[8]) {
    MainConnectionIDFn cid = (MainConnectionIDFn)Sym("CGSMainConnectionID");
    GetWindowOwnerFn owner = (GetWindowOwnerFn)Sym("SLSGetWindowOwner");
    GetConnectionPSNFn connectionPSN = (GetConnectionPSNFn)Sym("SLSGetConnectionPSN");
    if (wid && cid && owner && connectionPSN) {
        uint32_t ownerCid = 0;
        if (owner(cid(), wid, &ownerCid) == 0 && ownerCid != 0 && connectionPSN(ownerCid, psn) == 0) return YES;
    }
    GetProcessForPIDFn forPid = (GetProcessForPIDFn)Sym("GetProcessForPID");
    return forPid && forPid(pid, psn) == 0;
}

int BCUPostFocusRecord(pid_t pid, uint32_t windowID, BOOL focus) {
    PostEventRecordToFn post = (PostEventRecordToFn)Sym("SLPSPostEventRecordTo");
    if (!post) return -1;
    uint8_t psn[8] = {0};
    if (!PSNForWindow(windowID, pid, psn)) return -2;
    uint8_t record[0xF8] = {0};
    record[0x04] = 0xF8;
    record[0x08] = 0x0D;
    memcpy(&record[0x3C], &windowID, 4);  // little-endian on Apple silicon and Intel
    record[0x8A] = focus ? 0x01 : 0x02;
    return post(psn, record);
}

int BCUPostMakeKeyRecords(pid_t pid, uint32_t windowID) {
    PostEventRecordToFn post = (PostEventRecordToFn)Sym("SLPSPostEventRecordTo");
    if (!post) return -1;
    uint8_t psn[8] = {0};
    if (!PSNForWindow(windowID, pid, psn)) return -2;
    int status = 0;
    for (uint8_t kind = 0x01; kind <= 0x02; kind++) {
        uint8_t record[0xF8] = {0};
        record[0x04] = 0xF8;
        record[0x08] = kind;
        record[0x3A] = 0x10;
        memcpy(&record[0x3C], &windowID, 4);
        memset(&record[0x20], 0xFF, 0x10);
        int s = post(psn, record);
        if (s) status = s;
    }
    return status;
}

pid_t BCUFrontProcessPID(void) {
    GetFrontProcessFn front = (GetFrontProcessFn)Sym("_SLPSGetFrontProcess");
    GetProcessPIDFn toPid = (GetProcessPIDFn)Sym("GetProcessPID");
    if (!front || !toPid) return 0;
    uint8_t psn[8] = {0};
    if (front(psn) != 0) return 0;
    pid_t pid = 0;
    return toPid(psn, &pid) == 0 ? pid : 0;
}

int BCUSetFrontProcess(pid_t pid, uint32_t windowID, uint32_t options) {
    SetFrontProcessFn setFront = (SetFrontProcessFn)Sym("SLPSSetFrontProcessWithOptions");
    if (!setFront) return -1;
    uint8_t psn[8] = {0};
    if (!PSNForWindow(windowID, pid, psn)) return -2;
    return setFront(psn, windowID, options);
}

typedef CFArrayRef (*HWCaptureWindowListFn)(int32_t cid, uint32_t *windows, int32_t count, uint32_t options);

CGImageRef BCUCaptureWindow(uint32_t windowID) {
    MainConnectionIDFn cid = (MainConnectionIDFn)Sym("CGSMainConnectionID");
    HWCaptureWindowListFn capture = (HWCaptureWindowListFn)Sym("SLSHWCaptureWindowList");
    if (!capture) capture = (HWCaptureWindowListFn)Sym("CGSHWCaptureWindowList");
    if (!cid || !capture) return NULL;
    uint32_t wid = windowID;
    // 1<<11 ignore the global clip shape, 1<<8 best (backing store) resolution.
    CFArrayRef images = capture((int32_t)cid(), &wid, 1, (1u << 11) | (1u << 8));
    if (!images) return NULL;
    CGImageRef image = NULL;
    if (CFArrayGetCount(images) > 0) {
        CFTypeRef first = CFArrayGetValueAtIndex(images, 0);
        if (first && CFGetTypeID(first) == CGImageGetTypeID()) image = (CGImageRef)CFRetain(first);
    }
    CFRelease(images);
    return image;
}

typedef uint64_t (*ManagedDisplayGetCurrentSpaceFn)(uint32_t cid, CFStringRef displayUUID);
typedef int32_t (*ProcessAssignToSpaceFn)(uint32_t cid, pid_t pid, uint64_t sid);

uint64_t BCUCurrentSpaceForDisplay(CGDirectDisplayID display) {
    MainConnectionIDFn cid = (MainConnectionIDFn)Sym("CGSMainConnectionID");
    ManagedDisplayGetCurrentSpaceFn current = (ManagedDisplayGetCurrentSpaceFn)Sym("SLSManagedDisplayGetCurrentSpace");
    if (!cid || !current) return 0;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return 0;
    CFStringRef str = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    if (!str) return 0;
    uint64_t sid = current(cid(), str);
    CFRelease(str);
    return sid;
}

int BCUProcessAssignToSpace(pid_t pid, uint64_t sid) {
    MainConnectionIDFn cid = (MainConnectionIDFn)Sym("CGSMainConnectionID");
    ProcessAssignToSpaceFn assign = (ProcessAssignToSpaceFn)Sym("SLSProcessAssignToSpace");
    if (!cid || !assign) return -1;
    return assign(cid(), pid, sid);
}

BOOL BCUAXGetWindowID(AXUIElementRef element, uint32_t *outWindowID) {
    AXGetWindowFn f = (AXGetWindowFn)Sym("_AXUIElementGetWindow");
    if (!f) return NO;
    return f(element, outWindowID) == kAXErrorSuccess && *outWindowID != 0;
}
