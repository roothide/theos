ifneq ($(call __theos_bool,$(_LOCAL_USE_MODULES)),$(_THEOS_TRUE))
$(warning "*** You have disabled clang modules. To use the roothide api, please add `-lroothide` to LDFLAGS ***")
endif
