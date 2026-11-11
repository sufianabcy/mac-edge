// EdgePal media helper.
//
// Since macOS 15.4 only Apple-signed programs may read the system's Now Playing info, so
// EdgePal starts /usr/bin/perl, perl loads this library, and this library asks the private
// MediaRemote framework what's playing.
//
// stdout, one JSON object per line:
//   {"type":"ready"}
//   {"type":"info","title":..,"artist":..,"duration":..,"elapsed":..,"rate":..,"timestamp":..,"playing":..,"pid":..}
//   {"type":"none"}      nothing playing, or a live stream with no end to scrub to
//   {"type":"probe",..}  the answer to "probe"
// stdin, one command per line:
//   get              print the current info now
//   seek <seconds>   jump the current player to that position
//   probe            self-test: shows how odd numbers from MediaRemote are cleaned up
// The helper exits when stdin closes (EdgePal quit).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <unistd.h>

#import "EdgePalMedia.h"

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*SetElapsedFn)(double);
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));

static GetInfoFn epGetInfo;
static RegisterFn epRegister;
static SetElapsedFn epSetElapsed;
static IsPlayingFn epIsPlaying;
static GetPIDFn epGetPID; // Optional: which app is playing, for the icon in EdgePal's scrub panel.
static NSMutableData *epInput;
static BOOL epReportScheduled;
static uint64_t epSeekCount;

static void epEmit(NSDictionary *object) {
    // NSJSONSerialization throws on NaN and infinity, and an exception here would abort the
    // whole helper (it did, for a live stream). Numbers are cleaned up before they get here;
    // this is the last line of defence.
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return;
    }
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    } @catch (NSException *exception) {
        (void)exception;
        json = nil;
    }
    if (json == nil) {
        return;
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, bytes, left);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            exit(0);
        }
        bytes += n;
        left -= (size_t)n;
    }
}

/// A finite number, or `fallback`. Live streams report an endless duration, and a video that
/// is still loading can report NaN.
static double epNumber(id value, double fallback) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return fallback;
    }
    double number = [value doubleValue];
    return isfinite(number) ? number : fallback;
}

static NSString *epString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

/// The line EdgePal gets for one Now Playing state, or nil when there's nothing to scrub
/// (nothing playing, or a live stream).
static NSDictionary *epInfoObject(NSDictionary *info, BOOL playing, int pid) {
    double duration = epNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"], 0);
    if (info == nil || duration <= 0) {
        return nil;
    }
    double elapsed = fmin(fmax(epNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], 0), 0), duration);
    double rate = epNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], playing ? 1 : 0);
    double now = [[NSDate date] timeIntervalSince1970];
    id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    double timestamp = [stamp isKindOfClass:[NSDate class]] ? [stamp timeIntervalSince1970] : now;
    if (!isfinite(timestamp)) {
        timestamp = now;
    }
    return @{
        @"type": @"info",
        @"title": epString(info[@"kMRMediaRemoteNowPlayingInfoTitle"]),
        @"artist": epString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]),
        @"duration": @(duration),
        @"elapsed": @(elapsed),
        @"rate": @(playing ? (rate > 0 ? rate : 1) : 0),
        @"timestamp": @(timestamp),
        @"playing": playing ? @YES : @NO,
        @"pid": @(pid),
    };
}

static void epReport(void) {
    epReportScheduled = NO;
    epGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        epIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            __block BOOL sent = NO;
            void (^send)(int) = ^(int pid) {
                if (sent) {
                    return;
                }
                sent = YES;
                NSDictionary *object = epInfoObject(info, playing ? YES : NO, pid);
                epEmit(object ?: @{@"type": @"none"});
            };
            if (epGetPID == NULL) {
                send(0);
                return;
            }
            epGetPID(dispatch_get_main_queue(), ^(int pid) {
                send(pid);
            });
            // Never let a slow answer about the app hold up the info itself.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                send(0);
            });
        });
    });
}

/// Players send bursts of change notifications (several per seek): answer them once.
static void epScheduleReport(void) {
    if (epReportScheduled) {
        return;
    }
    epReportScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        epReport();
    });
}

static void epProbe(void) {
    NSDictionary *live = epInfoObject(@{
        @"kMRMediaRemoteNowPlayingInfoDuration": @(INFINITY),
        @"kMRMediaRemoteNowPlayingInfoElapsedTime": @(12.0),
    }, YES, 0);
    NSDictionary *loading = epInfoObject(@{
        @"kMRMediaRemoteNowPlayingInfoDuration": @(300.0),
        @"kMRMediaRemoteNowPlayingInfoElapsedTime": @(NAN),
        @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @(NAN),
        @"kMRMediaRemoteNowPlayingInfoTitle": @"probe",
    }, YES, 0);
    epEmit(@{@"type": @"probe", @"live": live ?: @"none", @"loading": loading ?: @"none"});
}

static void epHandle(NSString *line) {
    if ([line isEqualToString:@"get"]) {
        epReport();
    } else if ([line isEqualToString:@"probe"]) {
        epProbe();
    } else if ([line hasPrefix:@"seek "]) {
        double seconds = [[line substringFromIndex:5] doubleValue];
        if (isfinite(seconds) && seconds >= 0) {
            epSetElapsed(seconds);
            // While a finger scrubs, seeks come several times a second: report once they stop.
            uint64_t seek = ++epSeekCount;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (seek == epSeekCount) {
                    epReport();
                }
            });
        }
    }
}

static void epReadInput(void) {
    epInput = [NSMutableData data];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint8_t buffer[1024];
        while (true) {
            ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                exit(0); // EdgePal quit.
            }
            NSData *chunk = [NSData dataWithBytes:buffer length:(NSUInteger)n];
            dispatch_async(dispatch_get_main_queue(), ^{
                [epInput appendData:chunk];
                while (true) {
                    NSRange newline = [epInput rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                                   options:0
                                                     range:NSMakeRange(0, epInput.length)];
                    if (newline.location == NSNotFound) {
                        break;
                    }
                    NSData *lineData = [epInput subdataWithRange:NSMakeRange(0, newline.location)];
                    [epInput replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
                    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                    if (line != nil) {
                        epHandle([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
                    }
                }
            });
        }
    });
}

void edgepal_media_run(void *unused1, void *unused2) {
    (void)unused1;
    (void)unused2;
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        epGetInfo = h ? (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        epRegister = h ? (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
        epSetElapsed = h ? (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime") : NULL;
        epIsPlaying = h ? (IsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
        epGetPID = h ? (GetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
        if (!epGetInfo || !epRegister || !epSetElapsed || !epIsPlaying) {
            epEmit(@{@"type": @"error", @"message": @"MediaRemote is not available"});
            exit(1);
        }
        epRegister(dispatch_get_main_queue());
        for (NSString *name in @[
                 @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
             ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
                                                            (void)note;
                                                            epScheduleReport();
                                                        }];
        }
        epReadInput();
        epEmit(@{@"type": @"ready"});
        epReport();
    }
    CFRunLoopRun();
}
