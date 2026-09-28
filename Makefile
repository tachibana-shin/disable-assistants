export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

# Rootless (Dopamine / Sileo / roothide)
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard,Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DisableAssistants

DisableAssistants_FILES = Tweak.x DASettings.m DAHiders.m
DisableAssistants_CFLAGS = -fobjc-arc
DisableAssistants_FRAMEWORKS = UIKit Foundation

# PreferenceLoader settings bundle (installed as DisableAssistants.bundle).
# Resources/Root.plist is the panel layout; Theos copies the directory contents
# into the bundle root, which is where PreferenceLoader looks for Root.plist.
DisableAssistants_BUNDLE_INSTALL_PATH = /Library/PreferenceBundles
DisableAssistants_BUNDLE_NAME = DisableAssistants
DisableAssistants_BUNDLE_EXTENSION = bundle
DisableAssistants_BUNDLE_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/tweak.mk
