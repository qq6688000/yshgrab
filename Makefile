TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YSHGrab

YSHGrab_FILES = Tweak.x
YSHGrab_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
YSHGrab_FRAMEWORKS = UIKit Foundation WebKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
