export TARGET = iphone:clang:latest:14.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AHA
AHA_FILES = AHA.x
AHA_FRAMEWORKS = UIKit Foundation
AHA_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@echo "== AHA dylib built =="
