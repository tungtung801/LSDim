export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e
# RootHide is the target jailbreak. Override on a developer machine with
# THEOS_PACKAGE_SCHEME=rootless only when building a non-RootHide package.
export THEOS_PACKAGE_SCHEME ?= roothide

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 26LockDim

26LockDim_FILES = Tweak.xm
26LockDim_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
26LockDim_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
