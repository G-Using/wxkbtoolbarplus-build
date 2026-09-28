THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXKeyboardToolbarPlus
WXKeyboardToolbarPlus_FILES = Tweak.xm
WXKeyboardToolbarPlus_CFLAGS = -fobjc-arc -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@install -D -m 644 layout/Library/PreferenceLoader/Preferences/WXKeyboardToolbarPlus.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/WXKeyboardToolbarPlus.plist

include $(THEOS_MAKE_PATH)/aggregate.mk