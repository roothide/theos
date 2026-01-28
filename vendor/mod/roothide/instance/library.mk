ifneq ($(_LOCAL_LINKAGE_TYPE),static)
_THEOS_INTERNAL_LDFLAGS += -install_name "@loader_path/.jbroot$(LOCAL_INSTALL_PATH)/$(THEOS_CURRENT_INSTANCE)$(TARGET_LIB_EXT)"
endif
