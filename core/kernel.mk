#
# Copyright (C) 2009 The Android-x86 Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#

ifneq ($(strip $(TARGET_NO_KERNEL)),true)

# Location of the kernel archive as generated by the build system. Use a stable
# name so it's easy to find in scripts. We'll properly namespace it when we put
# it in out/dist/
INSTALLED_KERNEL_ARCHIVE := $(OUT)/kernel-archive.zip


# Tarball conatining source code of currently used Linux sources for GPL
# license compliance
INSTALLED_KERNEL_SOURCE_TARBALL := $(call intermediates-dir-for,PACKAGING,kernel)/kernelsrc.tar.gz

# use_prebuilt_kernel is the variable used for determining if we will be using
# prebuilt kernel components or build kernel from source, in the code that
# follows below.
use_prebuilt_kernel :=

# Test for the presence of a prebuilt kernel archive. If this variable is set
# in BoardConfig.mk and the file exists, we'll use that instead of building from
# source using the policy in the lines below.
kernel_prebuilt_archive := $(wildcard $(TARGET_PREBUILT_KERNEL_ARCHIVE))

ifneq ($(kernel_prebuilt_archive),)
  $(info KERNEL: Kernel prebuilt archive is available)

  # We have all the ingredients necessary for prebuilt kernels, but we make sure
  # that the user didn't set the BUILD_KERNEL variable, in which case we will be
  # forcing the kernel build from source.
  ifeq ($(BUILD_KERNEL),)
    $(info KERNEL: BUILD_KERNEL is not set, will not force kernel source build)

    # Under this condition, we set use_prebuilt_kernel to true, which means that we
    # will be using prebuilt kernels below.
    use_prebuilt_kernel := true
    $(info KERNEL: Will use prebuilt kernel)
  else # BUILD_KERNEL != null
    # This is the case where users force kernel build from source.
    $(info KERNEL: BUILD_KERNEL is set to a non-null value. Will not use prebuilt kernels)
  endif
else # kernel prebuilt mandatory ingredients are not available
  $(info KERNEL: Kernel prebuilt archive is not available. Will not use prebuilt kernels)
endif

TARGET_KERNEL_SCRIPTS := sign-file $(BOARD_KERNEL_SCRIPTS)

ifneq ($(use_prebuilt_kernel),true)

$(info Building kernel from source)

# Boards will typically need to set the following variables
# TARGET_KERNEL_CONFIG - Name of the base defconfig to use
# TARGET_KERNEL_CONFIG_OVERRIDES - 0 or more 'override' files to modify the
#     base defconfig; for enable, special overrides for user builds to disable
#     debug features, etc.
# TARGET_KERNEL_SOURCE - Location of kernel source directory relative to the
#     top level
# TARGET_KERNEL_EXTRA_CFLAGS - Additional CFLAGS which will be passed to the
#     kernel 'make' invocation as KCFLAGS


ifeq ($(TARGET_ARCH),x86)
  KERNEL_TARGET := bzImage
  TARGET_KERNEL_CONFIG ?= android-x86_defconfig
  ifeq ($(TARGET_KERNEL_ARCH),)
    TARGET_KERNEL_ARCH := i386
  endif
endif

ifeq ($(TARGET_ARCH),arm)
  KERNEL_TARGET := zImage
  TARGET_KERNEL_CONFIG ?= goldfish_defconfig
  ifeq ($(TARGET_KERNEL_ARCH),)
    TARGET_KERNEL_ARCH := arm
  endif
endif

TARGET_KERNEL_SOURCE ?= kernel

kernel_script_deps := $(foreach s,$(TARGET_KERNEL_SCRIPTS),$(TARGET_KERNEL_SOURCE)/scripts/$(s))
script_output := $(CURDIR)/$(TARGET_OUT_INTERMEDIATES)/kscripts
modbuild_output := $(CURDIR)/$(TARGET_OUT_INTERMEDIATES)/kernelmods

# Leading "+" gives child Make access to the jobserver.
# Be sure to have CONFIG_KERNEL_MINIGZIP enabled or your
# incremental OTA binary diffs will be very large.
mk_kernel_base := + $(hide) $(MAKE) ARCH=$(TARGET_KERNEL_ARCH) $(if $(SHOW_COMMANDS),V=1) KCFLAGS="$(TARGET_KERNEL_EXTRA_CFLAGS)"

ifneq ($(TARGET_KERNEL_CROSS_COMPILE),false)
  ifneq ($(TARGET_KERNEL_TOOLS_PREFIX),)
    ifneq ($(USE_CCACHE),)
      mk_kernel += CROSS_COMPILE="$(CURDIR)/$(CCACHE_BIN) $(CURDIR)/$(TARGET_KERNEL_TOOLS_PREFIX)"
    else
       mk_kernel += CROSS_COMPILE=$(CURDIR)/$(TARGET_KERNEL_TOOLS_PREFIX)
    endif
  endif
endif

mk_kernel = $(mk_kernel_base) -C $(TARGET_KERNEL_SOURCE)  O=$(PRODUCT_KERNEL_OUTPUT)

# If there's a file in the arch-specific configs directory that matches
# what's in $(TARGET_KERNEL_CONFIG), use that. Otherwise, use $(TARGET_KERNEL_CONFIG)
# verbatim
ifneq ($(wildcard $(TARGET_KERNEL_SOURCE)/arch/$(TARGET_ARCH)/configs/$(TARGET_KERNEL_CONFIG)),)
  kernel_config_file := $(TARGET_KERNEL_SOURCE)/arch/$(TARGET_ARCH)/configs/$(TARGET_KERNEL_CONFIG)
else
  kernel_config_file := $(TARGET_KERNEL_CONFIG)
endif

# FIXME: doesn't check overrides, only the base configuration file
kernel_mod_enabled = $(shell grep ^CONFIG_MODULES=y $(kernel_config_file))
kernel_fw_enabled = $(shell grep ^CONFIG_FIRMWARE_IN_KERNEL=y $(kernel_config_file))

# signed kernel modules
kernel_signed_mod_enabled = $(shell grep ^CONFIG_MODULE_SIG=y $(kernel_config_file))
kernel_genkey := $(PRODUCT_KERNEL_OUTPUT)/x509.genkey
kernel_private_key := $(PRODUCT_KERNEL_OUTPUT)/signing_key.priv
kernel_public_key := $(PRODUCT_KERNEL_OUTPUT)/signing_key.x509
kernel_key_deps := $(if kernel_signed_mod_enabled,$(kernel_private_key) $(kernel_public_key))

$(kernel_public_key): $(TARGET_MODULE_KEY_PAIR).x509.pem $(kernel_genkey)
	$(hide) openssl x509 -inform PEM -outform DER -in $(TARGET_MODULE_KEY_PAIR).x509.pem -out $@

$(kernel_private_key): $(TARGET_MODULE_KEY_PAIR).pk8 $(kernel_genkey)
	$(hide) openssl pkcs8 -nocrypt -inform DER -outform PEM -in $(TARGET_MODULE_KEY_PAIR).pk8 -out $@

$(kernel_genkey): $(TARGET_MODULE_GENKEY) | $(ACP)
	$(copy-file-to-target)

# The actual .config that is in use during the build is derived from
# a base $kernel_config_file, plus a a list of config overrides which
# are processed in order.
kernel_dotconfig_file := $(PRODUCT_KERNEL_OUTPUT)/.config
$(kernel_dotconfig_file): $(kernel_config_file) $(TARGET_KERNEL_CONFIG_OVERRIDES) | $(ACP)
	$(hide) mkdir -p $(dir $@)
	build/tools/build-defconfig.py $^ > $@
	$(mk_kernel) oldnoconfig
	$(hide) rm -f $@.old

built_kernel_target := $(PRODUCT_KERNEL_OUTPUT)/arch/$(TARGET_ARCH)/boot/$(KERNEL_TARGET)

# Declared .PHONY to force a rebuild each time. We can't tell if the kernel
# sources have changed from this context
.PHONY : $(INSTALLED_KERNEL_TARGET)

$(INSTALLED_KERNEL_TARGET): $(kernel_dotconfig_file) $(kernel_key_deps) $(MINIGZIP) | $(ACP)
	$(mk_kernel) $(KERNEL_TARGET) $(if $(kernel_mod_enabled),modules)
	$(hide) $(ACP) -fp $(built_kernel_target) $@

$(INSTALLED_SYSTEM_MAP): $(INSTALLED_KERNEL_TARGET) | $(ACP)
	$(hide) $(ACP) $(PRODUCT_KERNEL_OUTPUT)/System.map $@

# Extra newline intentional to prevent calling foreach from concatenating
# into a single line
# FIXME: Need to extend this so that all external modules are not built by
# default, need to define them each as an Android module and include them as
# needed in PRODUCT_PACKAGES
define make-ext-module
	$(mk_kernel) M=$(1) INSTALL_MOD_PATH=$(2) modules_install

endef

# $1: module name
# $2: module install directory; common to all modules
define install-compat-module
	@echo Installing kernel compat module $(1) in $(2)/
	$(hide) $(call COMPAT_PRIVATE_$(1)_PREINSTALL,$(2),$(COMPAT_PRIVATE_$(1)_SRC_PATH))
	$(mk_kernel) M=$(COMPAT_PRIVATE_$(1)_SRC_PATH) INSTALL_MOD_PATH=$(2) INSTALL_MOD_DIR=updates modules_install
	$(hide) $(call COMPAT_PRIVATE_$(1)_POSTINSTALL,$(2),$(COMPAT_PRIVATE_$(1)_SRC_PATH))

endef

define make-modules
	$(mk_kernel) INSTALL_MOD_PATH=$(1) modules_install
	$(foreach item,$(dir $(EXTERNAL_KERNEL_MODULES_TO_INSTALL)),$(call make-ext-module,$(item),$(1)))
	$(foreach item,$(EXTERNAL_KERNEL_COMPAT_MODULES_TO_INSTALL),$(call install-compat-module,$(item),$(1)))
	$(hide) rm -f $(1)/lib/modules/*/{build,source}
	$(hide) cd $(1)/lib/modules && find -type f -print0 | xargs -t -0 -I{} mv {} .
endef

# Testing a few parallel builds indicate that the kernel needs to be built before building
# compat modules.
$(foreach m,$(EXTERNAL_KERNEL_COMPAT_MODULES_TO_INSTALL),$(COMPAT_PRIVATE_$(m)_SRC_PATH)/.sentinel): $(INSTALLED_KERNEL_TARGET)

ifneq ($(kernel_mod_enabled),)
$(INSTALLED_MODULES_TARGET): $(EXTERNAL_KERNEL_MODULES_TO_INSTALL) 
$(INSTALLED_MODULES_TARGET): $(foreach m,$(EXTERNAL_KERNEL_COMPAT_MODULES_TO_INSTALL),$(COMPAT_PRIVATE_$(m)_SRC_PATH)/.sentinel)
endif

$(INSTALLED_MODULES_TARGET): $(INSTALLED_KERNEL_TARGET) $(MINIGZIP) | $(ACP)
	$(hide) rm -rf $(modbuild_output)/lib/modules
	$(hide) mkdir -p $(modbuild_output)/lib/modules
	$(if $(kernel_mod_enabled),$(call make-modules,$(modbuild_output)))
	$(hide) tar -cz -C $(modbuild_output)/lib/ -f $(CURDIR)/$@ modules

$(INSTALLED_KERNELFW_TARGET): $(INSTALLED_KERNEL_TARGET) $(INSTALLED_MODULES_TARGET) $(MINIGZIP)
	$(hide) rm -rf $(modbuild_output)/lib/firmware
	$(hide) mkdir -p $(modbuild_output)/lib/firmware
	$(if $(kernel_fw_enabled),$(mk_kernel) INSTALL_MOD_PATH=$(modbuild_output) firmware_install)
	$(hide) tar -cz -C $(modbuild_output)/lib/ -f $(CURDIR)/$@ firmware

$(INSTALLED_KERNEL_SCRIPTS): $(kernel_script_deps) | $(ACP)
	$(hide) rm -rf $(script_output)
	$(hide) mkdir -p $(script_output)
	$(hide) $(ACP) -p $(kernel_script_deps) $(script_output)
	$(hide) tar -cz -C $(script_output) -f $(CURDIR)/$@ $(foreach item,$(kernel_script_deps),$(notdir $(item)))

PREBUILT-PROJECT-linux: \
		$(INSTALLED_KERNEL_TARGET) \
		$(INSTALLED_SYSTEM_MAP) \
		$(INSTALLED_MODULES_TARGET) \
		$(INSTALLED_KERNELFW_TARGET) \
		$(INSTALLED_KERNEL_SCRIPTS) \

	$(hide) rm -rf out/prebuilt/linux/$(TARGET_PREBUILT_TAG)/kernel/$(TARGET_PRODUCT)-$(TARGET_BUILD_VARIANT)
	$(hide) mkdir -p out/prebuilt/linux/$(TARGET_PREBUILT_TAG)/kernel/$(TARGET_PRODUCT)-$(TARGET_BUILD_VARIANT)
	$(hide) $(ACP) -fp $^ out/prebuilt/linux/$(TARGET_PREBUILT_TAG)/kernel/$(TARGET_PRODUCT)-$(TARGET_BUILD_VARIANT)

# Declared .PHONY to force a rebuild each time. We can't tell if the kernel
# sources have changed from this context. So we do this in 2 stages; the second
# stage doesn't actually touch anything unless there was a real change in the
# archive; although we have to build the tarball every time, this prevents rules
# that depend on this from being needlessly rebuilt
.PHONY: $(INSTALLED_KERNEL_SOURCE_TARBALL).temp

# minigzip used to compute efficient OTA diffs, dd zeroes out the gzip MTIME
# field.
$(INSTALLED_KERNEL_SOURCE_TARBALL).temp: $(MINIGZIP)
	$(hide) mkdir -p $(dir $@)
	$(hide) tar -c --exclude ".git*" $(TARGET_KERNEL_SOURCE) \
				         $(TARGET_EXTRA_KERNEL_SOURCE) \
					 $(foreach item,$(ALL_GPL_KERNEL_MODULE_LICENSE_FILES),$(dir $(item))) \
				| $(MINIGZIP) -c > $@
	$(hide) dd if=/dev/zero of=$@ bs=4 count=1 conv=notrunc seek=1 status=noxfer

$(INSTALLED_KERNEL_SOURCE_TARBALL): $(INSTALLED_KERNEL_SOURCE_TARBALL).temp | $(ACP)
	$(hide) mkdir -p $(dir $@)
	$(hide) cmp --quiet $< $@ || { $(ACP) -f $< $@ && echo "Source code changed, updating $@"; }

$(INSTALLED_KERNEL_ARCHIVE):  \
			$(INSTALLED_KERNEL_TARGET) \
			$(INSTALLED_SYSTEM_MAP) \
			$(INSTALLED_MODULES_TARGET) \
			$(INSTALLED_KERNELFW_TARGET) \
			$(INSTALLED_KERNEL_SCRIPTS) \
			$(INSTALLED_KERNEL_SOURCE_TARBALL)
	$(hide) zip -qj $@ $^

else # use_prebuilt_kernel = true

define extract-from-zip
@echo "Unzip $(dir $@) <- $<"
$(hide) mkdir -p $(dir $@)
$(hide) unzip -qo $< -d $(dir $@) $(notdir $@)
endef

$(info Using prebuilt kernel components)
$(INSTALLED_KERNEL_TARGET): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_SYSTEM_MAP): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_KERNEL_SCRIPTS): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_MODULES_TARGET): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_KERNELFW_TARGET): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_KERNEL_SOURCE_TARBALL): $(kernel_prebuilt_archive)
	$(extract-from-zip)

$(INSTALLED_KERNEL_ARCHIVE): $(kernel_prebuilt_archive) | $(ACP)
	$(copy-file-to-new-target)

# It makes no sense to use the automatic prebuilts machinery target, if we have
# used the prebuilt kernel. It would mean re-copying the same files in the
# upstream repository, from where they came initially. So, we return an error
# if anyone is trying a "make PREBUILT-*" target.
PREBUILT-PROJECT-linux:
	$(error Automatic prebuilts for kernel are available only when building kernel from source)

endif # use_prebuilt_kernel

use_prebuilt_kernel :=
host_scripts := $(foreach item,$(TARGET_KERNEL_SCRIPTS),$(HOST_OUT_EXECUTABLES)/$(notdir $(item)))
$(host_scripts): $(INSTALLED_KERNEL_SCRIPTS)
	$(hide) mkdir -p $(HOST_OUT_EXECUTABLES)
	$(hide) tar -C $(HOST_OUT_EXECUTABLES) -xzvf $(INSTALLED_KERNEL_SCRIPTS) $(notdir $@)

.PHONY: kernel
kernel: $(INSTALLED_KERNEL_ARCHIVE)

$(call dist-for-goals,droidcore,$(INSTALLED_KERNEL_ARCHIVE):$(TARGET_PRODUCT)-kernel-archive-$(FILE_NAME_TAG).zip)

# For including sources in gpl_source_tgz
ALL_EXTRA_SOURCE_TARBALLS += $(INSTALLED_KERNEL_SOURCE_TARBALL)

endif # TARGET_NO_KERNEL
