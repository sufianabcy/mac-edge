// EdgePal: MultitouchSupport bridge. See include/EdgeTouch.h.
#include "EdgeTouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>

// Layout of one contact as MultitouchSupport reports it (96 bytes, stable for many macOS versions).
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, fingerID, handID;
    MTVector normalized;
    float size;
    int32_t zero1;
    float angle, majorAxis, minorAxis;
    MTVector millimeters;
    int32_t zero2[2];
    float density;
} MTContact;

typedef void *MTDeviceRef;
typedef void *MTActuatorRef;
typedef int (*MTContactCallback)(MTDeviceRef device, MTContact *contacts, int32_t count, double timestamp, int32_t frame);

static CFMutableArrayRef (*pCreateList)(void);
static void (*pRegister)(MTDeviceRef, MTContactCallback);
static void (*pUnregister)(MTDeviceRef, MTContactCallback);
static int32_t (*pStart)(MTDeviceRef, int32_t);
static int32_t (*pStop)(MTDeviceRef);
static int32_t (*pDimensions)(MTDeviceRef, int32_t *, int32_t *);
static bool (*pIsBuiltIn)(MTDeviceRef);
static bool (*pIsOpaque)(MTDeviceRef);
static int32_t (*pGetDeviceID)(MTDeviceRef, uint64_t *);
static MTActuatorRef (*pActuatorCreate)(uint64_t);
static int32_t (*pActuatorOpen)(MTActuatorRef);
static int32_t (*pActuatorActuate)(MTActuatorRef, int32_t, uint32_t, float, float);

#define ET_MAX_DEVICES 8
#define ET_MAX_TOUCHES 16

static CFMutableArrayRef gList;
static MTDeviceRef gDevices[ET_MAX_DEVICES];
static MTActuatorRef gActuators[ET_MAX_DEVICES];
static int32_t gDeviceCount;
static ETFrameCallback gCallback;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

bool ETLoad(void) {
    static bool loaded = false;
    if (loaded) {
        return true;
    }
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (h == NULL) {
        return false;
    }
    pCreateList = dlsym(h, "MTDeviceCreateList");
    pRegister = dlsym(h, "MTRegisterContactFrameCallback");
    pUnregister = dlsym(h, "MTUnregisterContactFrameCallback");
    pStart = dlsym(h, "MTDeviceStart");
    pStop = dlsym(h, "MTDeviceStop");
    pDimensions = dlsym(h, "MTDeviceGetSensorSurfaceDimensions");
    pIsBuiltIn = dlsym(h, "MTDeviceIsBuiltIn");
    pIsOpaque = dlsym(h, "MTDeviceIsOpaqueSurface");
    pGetDeviceID = dlsym(h, "MTDeviceGetDeviceID");
    pActuatorCreate = dlsym(h, "MTActuatorCreateFromDeviceID");
    pActuatorOpen = dlsym(h, "MTActuatorOpen");
    pActuatorActuate = dlsym(h, "MTActuatorActuate");
    loaded = pCreateList && pRegister && pStart && pStop;
    return loaded;
}

static int contactCallback(MTDeviceRef device, MTContact *contacts, int32_t count, double timestamp, int32_t frame) {
    (void)frame;
    ETFrameCallback callback = gCallback;
    if (callback == NULL) {
        return 0;
    }
    ETTouch touches[ET_MAX_TOUCHES];
    int32_t n = count < ET_MAX_TOUCHES ? count : ET_MAX_TOUCHES;
    for (int32_t i = 0; i < n; i++) {
        touches[i].identifier = contacts[i].identifier;
        touches[i].state = contacts[i].state;
        touches[i].x = contacts[i].normalized.position.x;
        touches[i].y = contacts[i].normalized.position.y;
        touches[i].size = contacts[i].size;
    }
    callback((uintptr_t)device, touches, n, timestamp);
    return 0;
}

int32_t ETStart(ETFrameCallback callback) {
    if (!ETLoad()) {
        return 0;
    }
    ETStop();
    pthread_mutex_lock(&gLock);
    gCallback = callback;
    gList = pCreateList();
    CFIndex total = gList ? CFArrayGetCount(gList) : 0;
    for (CFIndex i = 0; i < total && gDeviceCount < ET_MAX_DEVICES; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gList, i);
        if (pIsOpaque && pIsOpaque(device)) {
            continue; // A Magic Mouse, not a trackpad.
        }
        pRegister(device, contactCallback);
        pStart(device, 0);
        gActuators[gDeviceCount] = NULL;
        gDevices[gDeviceCount++] = device;
    }
    int32_t started = gDeviceCount;
    pthread_mutex_unlock(&gLock);
    return started;
}

void ETStop(void) {
    pthread_mutex_lock(&gLock);
    for (int32_t i = 0; i < gDeviceCount; i++) {
        if (pUnregister) {
            pUnregister(gDevices[i], contactCallback);
        }
        pStop(gDevices[i]);
        gDevices[i] = NULL;
        gActuators[i] = NULL; // Tiny leak by design: closing actuators mid-click can crash.
    }
    gDeviceCount = 0;
    if (gList) {
        CFRelease(gList);
        gList = NULL;
    }
    pthread_mutex_unlock(&gLock);
}

int32_t ETAttachedCount(void) {
    if (!ETLoad()) {
        return 0;
    }
    CFMutableArrayRef list = pCreateList();
    if (list == NULL) {
        return 0;
    }
    int32_t count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (!(pIsOpaque && pIsOpaque(device))) {
            count++;
        }
    }
    CFRelease(list);
    return count;
}

bool ETDeviceSize(uintptr_t device, double *widthMM, double *heightMM) {
    if (pDimensions == NULL || device == 0) {
        return false;
    }
    int32_t w = 0, h = 0;
    pDimensions((MTDeviceRef)device, &w, &h); // hundredths of a millimetre
    if (w <= 0 || h <= 0) {
        return false;
    }
    *widthMM = w / 100.0;
    *heightMM = h / 100.0;
    return true;
}

bool ETDeviceIsBuiltIn(uintptr_t device) {
    return pIsBuiltIn && device != 0 && pIsBuiltIn((MTDeviceRef)device);
}

bool ETActuate(uintptr_t device, int32_t strength) {
    if (!pGetDeviceID || !pActuatorCreate || !pActuatorOpen || !pActuatorActuate) {
        return false;
    }
    pthread_mutex_lock(&gLock);
    MTActuatorRef actuator = NULL;
    for (int32_t i = 0; i < gDeviceCount; i++) {
        if ((uintptr_t)gDevices[i] != device) {
            continue;
        }
        if (gActuators[i] == NULL) {
            uint64_t deviceID = 0;
            if (pGetDeviceID(gDevices[i], &deviceID) == 0 && deviceID != 0) {
                MTActuatorRef created = pActuatorCreate(deviceID);
                if (created && pActuatorOpen(created) == 0) {
                    gActuators[i] = created;
                }
            }
        }
        actuator = gActuators[i];
        break;
    }
    pthread_mutex_unlock(&gLock);
    if (actuator == NULL) {
        return false;
    }
    // Actuation patterns: 3 is a faint tick, 4 a firmer one, 6 a full click.
    int32_t pattern = strength <= 1 ? 3 : (strength == 2 ? 4 : 6);
    return pActuatorActuate(actuator, pattern, 0, 0.0f, 0.0f) == 0;
}
