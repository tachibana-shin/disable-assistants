// DASettings.m — preference loading, jailbreak check, Gestures15 detection,
// status text and diagnostic logging.

#import "DATweak.h"

#pragma mark - Configuration

static NSString *const kDomainA = @"DisableAssistants";
static NSString *const kDomainB = @"com.shin.disableassistants";
static NSString *const kLogPath = @"/var/mobile/Library/Logs/DisableAssistants.log";
static const NSTimeInterval kPrefsTTL = 2.0;            // do not re-read more often than this
static const unsigned long long kLogMaxBytes = 512 * 1024;

static BOOL gEnabled = YES;
static BOOL gRequireGestures15 = YES;
static BOOL gVerbose = NO;
static NSString *gMatch = @"gestures15";
static BOOL gJailbroken = NO;
static NSString *gJailbreakStyle = @"not jailbroken";
static BOOL gGesturesFound = NO;
static NSString *gGesturesDetail = @"not found";
static NSDate *gLoadedAt = nil;

#pragma mark - Preferences

static id DAPrefValue(NSString *key) {
    for (NSString *domain in @[kDomainA, kDomainB]) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        CFTypeRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
        if (raw != NULL) {
            return (__bridge_transfer id)raw;
        }
    }
    return nil;
}

static BOOL DABoolPref(NSString *key, BOOL defaultValue) {
    id value = DAPrefValue(key);
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return defaultValue;
}

static NSString *DAStringPref(NSString *key, NSString *defaultValue) {
    id value = DAPrefValue(key);
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return defaultValue;
}

#pragma mark - Jailbreak detection

static void DAReloadJailbreak(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    gJailbroken = NO;
    gJailbreakStyle = @"not jailbroken";

    if ([fm fileExistsAtPath:@"/var/jb"]) {
        gJailbroken = YES;
        gJailbreakStyle = @"yes (rootless)";
        return;
    }
    if ([fm fileExistsAtPath:@"/var/containers/Bundle/tweaksupport"]) {
        gJailbroken = YES;
        gJailbreakStyle = @"yes (roothide)";
        return;
    }
    for (NSString *marker in @[@"/private/var/lib/apt", @"/bin/bash", @"/usr/sbin/sshd", @"/Applications/Cydia.app"]) {
        if ([fm fileExistsAtPath:marker]) {
            gJailbroken = YES;
            gJailbreakStyle = @"yes (rootful)";
            return;
        }
    }
}

#pragma mark - Gestures15 detection

static NSArray<NSString *> *DATweakDirectories(void) {
    return @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/TweakInject",
        @"/var/containers/Bundle/tweaksupport/usr/lib/TweakInject",
        @"/var/containers/Bundle/tweaksupport/Library/MobileSubstrate/DynamicLibraries",
    ];
}

// Read a text file (used to look for a bundle id inside a Substrate filter plist)
static BOOL DAFileContainsString(NSString *path, NSString *needle) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (data.length == 0) {
        return NO;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        return NO;
    }
    return [text rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Cross-check against dpkg. Returns YES when a matching package exists and is
// in the "install ok installed" state.
static BOOL DAPackageInstalled(NSString *needle, BOOL *outFound) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *statusPath in @[@"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status"]) {
        if (![fm fileExistsAtPath:statusPath]) {
            continue;
        }
        NSString *content = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:NULL];
        if (content.length == 0) {
            continue;
        }
        BOOL found = NO;
        BOOL installed = NO;
        for (NSString *paragraph in [content componentsSeparatedByString:@"\n\n"]) {
            NSRange range = [paragraph rangeOfString:@"Package: "];
            if (range.location == NSNotFound) {
                continue;
            }
            NSString *tail = [paragraph substringFromIndex:NSMaxRange(range)];
            NSString *name = [[tail componentsSeparatedByString:@"\n"].firstObject
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([name.lowercaseString rangeOfString:needle].location == NSNotFound) {
                continue;
            }
            found = YES;
            if ([paragraph rangeOfString:@"Status: install ok installed"].location != NSNotFound) {
                installed = YES;
            }
        }
        if (found) {
            if (outFound != NULL) {
                *outFound = YES;
            }
            return installed;
        }
    }
    if (outFound != NULL) {
        *outFound = NO;
    }
    return NO;
}

static void DAReloadGestures15(void) {
    gGesturesFound = NO;
    gGesturesDetail = @"not found";

    NSString *match = [gMatch lowercaseString];
    if (match.length == 0) {
        gGesturesDetail = @"not configured";
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL looksLikeBundleID = [match hasPrefix:@"com."] || [match hasPrefix:@"org."] || [match hasPrefix:@"net."];
    NSString *bundleNeedle = [NSString stringWithFormat:@"<string>%@</string>", gMatch];

    for (NSString *directory in DATweakDirectories()) {
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:directory error:NULL];
        for (NSString *file in files) {
            NSString *lower = file.lowercaseString;
            if ([lower rangeOfString:match].location == NSNotFound) {
                continue;
            }
            NSString *path = [directory stringByAppendingPathComponent:file];

            if ([lower hasSuffix:@".dylib"]) {
                if ([fm fileExistsAtPath:[path stringByAppendingString:@".disabled"]]) {
                    gGesturesDetail = @"dylib is disabled";
                    continue;   // tweak was turned off
                }
                gGesturesFound = YES;
                gGesturesDetail = path;
                break;
            }
            if (looksLikeBundleID && [lower hasSuffix:@".plist"] && DAFileContainsString(path, bundleNeedle)) {
                NSString *dylib = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"dylib"];
                if ([fm fileExistsAtPath:dylib]) {
                    gGesturesFound = YES;
                    gGesturesDetail = dylib;
                    break;
                }
            }
        }
        if (gGesturesFound) {
            break;
        }
    }

    // Reject leftovers from a removed package
    BOOL packageFound = NO;
    BOOL packageInstalled = DAPackageInstalled(match, &packageFound);
    if (packageFound && !packageInstalled) {
        gGesturesFound = NO;
        gGesturesDetail = @"package was removed";
        return;
    }
    if (!gGesturesFound) {
        if (packageInstalled) {
            gGesturesDetail = @"package installed, no dylib found";
        } else if (!packageFound && !looksLikeBundleID) {
            gGesturesDetail = [NSString stringWithFormat:@"no match for \"%@\"", gMatch];
        }
    }
}

#pragma mark - Reload everything

void DAReloadPrefs(void) {
    gEnabled = DABoolPref(@"enabled", YES);
    gRequireGestures15 = DABoolPref(@"requireGestures15", YES);
    gVerbose = DABoolPref(@"verbose", NO);
    gMatch = [DAStringPref(@"gesturesMatch", @"gestures15") copy];

    DAReloadJailbreak();
    DAReloadGestures15();
    gLoadedAt = [NSDate date];

    DALog(@"Reload: enabled=%d requireGestures15=%d verbose=%d match=\"%@\" | jailbreak=%@ | gestures15=%d (%@)",
          gEnabled, gRequireGestures15, gVerbose, gMatch,
          gJailbreakStyle, gGesturesFound, gGesturesDetail);
}

void DAReloadPrefsIfNeeded(void) {
    if (gLoadedAt != nil && [[NSDate date] timeIntervalSinceDate:gLoadedAt] < kPrefsTTL) {
        return;
    }
    DAReloadPrefs();
}

#pragma mark - Queries

BOOL DAIsJailbroken(void) { return gJailbroken; }
NSString *DAJailbreakStyle(void) { return gJailbreakStyle; }
BOOL DAEnabled(void) { return gEnabled; }
BOOL DARequireGestures15(void) { return gRequireGestures15; }
BOOL DAVerbose(void) { return gVerbose; }
NSString *DAGestures15MatchString(void) { return gMatch; }

BOOL DAGestures15Found(NSString **outDetail) {
    if (outDetail != NULL) {
        *outDetail = gGesturesDetail;
    }
    return gGesturesFound;
}

BOOL DAShouldHide(void) {
    if (!gEnabled) { return NO; }                                  // master switch off
    if (!gJailbroken) { return NO; }                               // not jailbroken
    if (gRequireGestures15 && !gGesturesFound) { return NO; }       // Gestures15 is not enabled
    return YES;
}

#pragma mark - Status text

NSString *DAStatusShortText(void) {
    NSString *state;
    if (!gEnabled) {
        state = @"OFF (master switch)";
    } else if (!gJailbroken) {
        state = @"OFF (no jailbreak)";
    } else if (gRequireGestures15 && !gGesturesFound) {
        state = @"waiting for Gestures15";
    } else {
        state = @"HIDING";
    }
    return [NSString stringWithFormat:@"%@ %@ | Jailbreak: %@ | Gestures15: %@",
            DA_STATUS_PREFIX, state, gJailbreakStyle, gGesturesFound ? @"found" : @"not found"];
}

NSString *DAStatusReportText(void) {
    return [NSString stringWithFormat:
            @"Hide Assistants: %@\n"
            @"Jailbreak: %@\n"
            @"Gestures15 match string: %@\n"
            @"Gestures15: %@\n\n"
            @"Log: %@",
            DAShouldHide() ? @"ACTIVE" : @"inactive",
            gJailbreakStyle,
            gMatch,
            gGesturesDetail,
            kLogPath];
}

#pragma mark - Logging

NSString *DALogFilePath(void) { return kLogPath; }

void DALog(NSString *format, ...) {
    if (!gVerbose) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *directory = [kLogPath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directory]) {
        return;
    }

    // Keep the log small
    NSDictionary *attributes = [fm attributesOfItemAtPath:kLogPath error:NULL];
    if ([attributes[NSFileSize] unsignedLongLongValue] > kLogMaxBytes) {
        [[NSString string] writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (handle == nil) {
        [[NSString string] writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        handle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    }
    if (handle == nil) {
        return;
    }

    NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
                      [NSDate date], [[NSProcessInfo processInfo] processName], message];
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}
