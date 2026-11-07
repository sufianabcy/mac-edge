// EdgePal: a tiny C bridge to MultitouchSupport, the private framework that reports
// where each finger is on a Mac trackpad and drives its Taptic Engine.
#ifndef EDGE_TOUCH_H
#define EDGE_TOUCH_H

#include <stdbool.h>
#include <stdint.h>

/// MultitouchSupport touch states.
typedef enum {
    ETStateNotTracking = 0,
    ETStateStartInRange = 1,
    ETStateHoverInRange = 2,
    ETStateMakeTouch = 3,
    ETStateTouching = 4,
    ETStateBreakTouch = 5,
    ETStateLingerInRange = 6,
    ETStateOutOfRange = 7,
} ETTouchState;

typedef struct {
    int32_t identifier;
    int32_t state;   // ETTouchState
    float x;         // 0...1, left to right
    float y;         // 0...1, bottom to top
    float size;      // contact size, palms are big
} ETTouch;

/// Called on MultitouchSupport's own thread for every frame of every trackpad.
typedef void (*ETFrameCallback)(uintptr_t device, const ETTouch *touches, int32_t count, double timestamp);

/// Loads the framework. False if it isn't there (should never happen on a Mac with a trackpad).
bool ETLoad(void);
/// Starts every trackpad and sends its frames to `callback`. Returns how many were started.
int32_t ETStart(ETFrameCallback callback);
/// Stops every trackpad that ETStart started.
void ETStop(void);
/// How many trackpads are attached right now (cheap enough to poll every few seconds).
int32_t ETAttachedCount(void);
/// Physical surface size in millimetres.
bool ETDeviceSize(uintptr_t device, double *widthMM, double *heightMM);
/// True for the MacBook's own trackpad.
bool ETDeviceIsBuiltIn(uintptr_t device);
/// A Taptic Engine click on that trackpad. strength: 1 light, 2 medium, 3 strong.
bool ETActuate(uintptr_t device, int32_t strength);

#endif
