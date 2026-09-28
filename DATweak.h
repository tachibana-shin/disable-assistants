// DATweak.h — shared declarations for the "Disable Assistants" tweak.
// The tweak does exactly one job: hide the Siri/Assistants UI while the device
// is jailbroken and the Gestures15 tweak is installed and enabled.

#import <Foundation/Foundation.h>

// Prefix used to recognise the live status row in the Settings panel.
#define DA_STATUS_PREFIX   @"Status:"
// Prefix used to recognise the respring row in the Settings panel.
#define DA_RESPRING_PREFIX @"Respring"
// Darwin notification posted when the user changes a preference in Settings.
#define DA_NOTIFY_PREFS_CHANGED "com.shin.disableassistants/PrefsChanged"

// --- Conditions / state ----------------------------------------------------
BOOL DAIsJailbroken(void);
NSString *DAJailbreakStyle(void);
BOOL DAGestures15Found(NSString **outDetail);
BOOL DAEnabled(void);
BOOL DARequireGestures15(void);
BOOL DAVerbose(void);
NSString *DAGestures15MatchString(void);
BOOL DAShouldHide(void);
void DAReloadPrefs(void);
void DAReloadPrefsIfNeeded(void);
NSString *DAStatusShortText(void);
NSString *DAStatusReportText(void);
NSString *DALogFilePath(void);
void DALog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// --- UI hiding -------------------------------------------------------------
void DAInstallHider(void);
void DAApplyHiderNow(void);

// --- Shared hooking helpers ------------------------------------------------
IMP DAOriginalIMPForObject(id object, SEL selector);
BOOL DAHookMethodOnce(Class cls, SEL selector, IMP replacement);
Class DAFindClassDeclaringSelector(Class cls, SEL selector);
