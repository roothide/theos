ifeq ($(_THEOS_RULES_LOADED),$(_THEOS_FALSE))
include $(THEOS_MAKE_PATH)/rules.mk
endif

.PHONY: internal-library-all_ internal-library-stage_ internal-library-compile

LOCAL_INSTALL_PATH ?= $(strip $($(THEOS_CURRENT_INSTANCE)_INSTALL_PATH))
ifeq ($(LOCAL_INSTALL_PATH),)
	LOCAL_INSTALL_PATH = /usr/lib
endif

_LOCAL_LIBRARY_EXTENSION = $(or $($(THEOS_CURRENT_INSTANCE)_LIBRARY_EXTENSION),$(TARGET_LIB_EXT))
ifeq ($(_LOCAL_LIBRARY_EXTENSION),-)
	_LOCAL_LIBRARY_EXTENSION =
endif

_LOCAL_ARCHIVE_EXTENSION = $(or $($(THEOS_CURRENT_INSTANCE)_ARCHIVE_EXTENSION),$(TARGET_AR_EXT))
ifeq ($(_LOCAL_ARCHIVE_EXTENSION),-)
	_LOCAL_ARCHIVE_EXTENSION =
endif

_LOCAL_LINKAGE_TYPE = $(or $($(THEOS_CURRENT_INSTANCE)_LINKAGE_TYPE),$(THEOS_LINKAGE_TYPE))

_THEOS_INTERNAL_LDFLAGS += $(call TARGET_LDFLAGS_DYNAMICLIB,$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION))
_THEOS_INTERNAL_CFLAGS += $(TARGET_CFLAGS_DYNAMICLIB)

ifeq ($(_THEOS_MAKE_PARALLEL_BUILDING), no)
ifeq ($(_LOCAL_LINKAGE_TYPE),static)
internal-library-all_:: $(_OBJ_DIR_STAMPS) $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)
else ifeq ($(_LOCAL_LINKAGE_TYPE),both)
internal-library-all_:: $(_OBJ_DIR_STAMPS) $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION) $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)
else
internal-library-all_:: $(_OBJ_DIR_STAMPS) $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION)
endif
else
internal-library-all_:: $(_OBJ_DIR_STAMPS)
	$(ECHO_MAKE)$(MAKE) -f $(_THEOS_PROJECT_MAKEFILE_NAME) $(_THEOS_MAKEFLAGS) \
		internal-library-compile \
		_THEOS_CURRENT_TYPE=$(_THEOS_CURRENT_TYPE) THEOS_CURRENT_INSTANCE=$(THEOS_CURRENT_INSTANCE) _THEOS_CURRENT_OPERATION=compile \
		THEOS_BUILD_DIR="$(THEOS_BUILD_DIR)" _THEOS_MAKE_PARALLEL=yes

ifeq ($(_LOCAL_LINKAGE_TYPE),static)
internal-library-compile: $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)
else ifeq ($(_LOCAL_LINKAGE_TYPE),both)
internal-library-compile: $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION) $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)
else
internal-library-compile: $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION)
endif
endif

$(eval $(call _THEOS_TEMPLATE_DEFAULT_LINKING_RULE,$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION)))
$(eval $(call _THEOS_TEMPLATE_ARCHIVE_LINKING_RULE,$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)))

ifneq ($($(THEOS_CURRENT_INSTANCE)_INSTALL),0)
internal-library-stage_::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(LOCAL_INSTALL_PATH)/"$(ECHO_END)
ifneq (static,$(_LOCAL_LINKAGE_TYPE))
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION) "$(THEOS_STAGING_DIR)$(LOCAL_INSTALL_PATH)/"$(ECHO_END)
ifeq ($(_THEOS_CURRENT_TYPE),library)
ifeq ($(THEOS_PACKAGE_SCHEME),)
	$(ECHO_COPYING_LIBRARY)rsync -ra "$(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION)" "$(THEOS_LIBRARY_PATH)"$(ECHO_END)
else
	$(ECHO_NOTHING)mkdir -p "$(THEOS_LIBRARY_PATH)/$(THEOS_TARGET_NAME)/$(THEOS_PACKAGE_SCHEME)/"$(ECHO_END)
	$(ECHO_COPYING_LIBRARY)rsync -ra "$(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_LIBRARY_EXTENSION)" "$(THEOS_LIBRARY_PATH)/$(THEOS_TARGET_NAME)/$(or $(THEOS_PACKAGE_SCHEME),rootful)"$(ECHO_END)
endif
endif
endif
ifneq (,$(filter static both,$(_LOCAL_LINKAGE_TYPE)))
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION) "$(THEOS_STAGING_DIR)$(LOCAL_INSTALL_PATH)/"$(ECHO_END)
ifeq ($(_THEOS_CURRENT_TYPE),library)
ifeq ($(THEOS_PACKAGE_SCHEME),)
	$(ECHO_COPYING_LIBRARY)rsync -ra "$(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)" "$(THEOS_LIBRARY_PATH)"$(ECHO_END)
else
	$(ECHO_NOTHING)mkdir -p "$(THEOS_LIBRARY_PATH)/$(THEOS_TARGET_NAME)/$(THEOS_PACKAGE_SCHEME)/"$(ECHO_END)
	$(ECHO_COPYING_LIBRARY)rsync -ra "$(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(_LOCAL_ARCHIVE_EXTENSION)" "$(THEOS_LIBRARY_PATH)/$(THEOS_TARGET_NAME)/$(or $(THEOS_PACKAGE_SCHEME),rootful)"$(ECHO_END)
endif
endif
endif
endif

$(eval $(call __mod,instance/library.mk))
