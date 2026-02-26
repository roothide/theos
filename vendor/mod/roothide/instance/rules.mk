ifneq ($(call __theos_bool,$(_LOCAL_USE_MODULES)),$(_THEOS_TRUE))
ifeq ($(filter -lroothide, $(ALL_LDFLAGS)),)
$(warning "*** You have disabled clang modules. To use the roothide api, please add `-lroothide` to LDFLAGS ***")
endif
endif
