// EdgePal media helper.
//
// Since macOS 15.4 only Apple-signed programs may read the system's Now Playing info, so
// EdgePal starts /usr/bin/perl, perl loads this library, and this library asks the private
// MediaRemote framework what's playing.
//
// stdout, one JSON object per line:
//   {"type":"ready"}
//   {"type":"info","title":..,"artist":..,"duration":..,"elapsed":..,"rate":..,"timestamp":..,"playing":..}
//   {"type":"none"}
// stdin, one command per line:
//   get              print the current info now
//   seek <seconds>   jump the current player to that position
// The helper exits when stdin closes (EdgePal quit).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <unistd.h>

#import "EdgePalMedia.h"

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*SetElapsedFn)(double);
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));

static GetInfoFn epGetInfo;
static RegisterFn epRegister;
static SetElapsedFn epSetElapsed;
static IsPlayingFn epIsPlaying;
static NSMutableData *epInput;

static void epEmit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
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

static double epNumber(id value, double fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static NSString *epString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void epReport(void) {
    epGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        double duration = epNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"], 0);
        if (info == nil || duration <= 0) {
            epEmit(@{@"type": @"none"});
            return;
        }
        epIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            double rate = epNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], playing ? 1 : 0);
            id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            double timestamp = [stamp isKindOfClass:[NSDate class]] ? [stamp timeIntervalSince1970]
                                                                     : [[NSDate date] timeIntervalSince1970];
            epEmit(@{
                @"type": @"info",
                @"title": epString(info[@"kMRMediaRemoteNowPlayingInfoTitle"]),
                @"artist": epString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]),
                @"duration": @(duration),
                @"elapsed": @(epNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], 0)),
                @"rate": @(playing ? (rate > 0 ? rate : 1) : 0),
                @"timestamp": @(timestamp),
                @"playing": @(playing ? YES : NO),
            });
        });
    });
}

static void epHandle(NSString *line) {
    if ([line isEqualToString:@"get"]) {
        epReport();
    } else if ([line hasPrefix:@"seek "]) {
        double seconds = [[line substringFromIndex:5] doubleValue];
        if (seconds >= 0) {
            epSetElapsed(seconds);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                epReport();
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
                    epHandle([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
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
                                                            epReport();
                                                        }];
        }
        epReadInput();
        epEmit(@{@"type": @"ready"});
        epReport();
    }
    CFRunLoopRun();
}
