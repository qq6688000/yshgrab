TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YSHGrab

YSHGrab_FILES = Tweak.x
YSHGrab_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
YSHGrab_FRAMEWORKS = UIKit Foundation WebKit QuartzCore
# rootless LC_RPATH（对齐 XLHVideoGrab 1.4.0，让 @rpath 依赖能解析到 /var/jb/）
YSHGrab_LDFLAGS = -rpath /var/jb/Library/Frameworks -rpath /var/jb/usr/lib -rpath @loader_path/.jbroot/Library/Frameworks -rpath @loader_path/.jbroot/usr/lib

include $(THEOS_MAKE_PATH)/tweak.mk
