PROJ	:= 5
EMPTY	:=
SPACE	:= $(EMPTY) $(EMPTY)
SLASH	:= /

V       := @

# try to infer the correct GCCPREFX
ifndef GCCPREFIX
GCCPREFIX := $(shell if i386-elf-objdump -i 2>&1 | grep '^elf32-i386$$' >/dev/null 2>&1; \
	then echo 'i386-elf-'; \
	elif objdump -i 2>&1 | grep 'elf32-i386' >/dev/null 2>&1; \
	then echo ''; \
	else echo "***" 1>&2; \
	echo "*** Error: Couldn't find an i386-elf version of GCC/binutils." 1>&2; \
	echo "*** Is the directory with i386-elf-gcc in your PATH?" 1>&2; \
	echo "*** If your i386-elf toolchain is installed with a command" 1>&2; \
	echo "*** prefix other than 'i386-elf-', set your GCCPREFIX" 1>&2; \
	echo "*** environment variable to that prefix and run 'make' again." 1>&2; \
	echo "*** To turn off this error, run 'gmake GCCPREFIX= ...'." 1>&2; \
	echo "***" 1>&2; exit 1; fi)
endif

# try to infer the correct QEMU
ifndef QEMU
QEMU := $(shell if which qemu-system-i386 > /dev/null; \
	then echo 'qemu-system-i386'; exit; \
	elif which i386-elf-qemu > /dev/null; \
	then echo 'i386-elf-qemu'; exit; \
	else \
	echo "***" 1>&2; \
	echo "*** Error: Couldn't find a working QEMU executable." 1>&2; \
	echo "*** Is the directory containing the qemu binary in your PATH" 1>&2; \
	echo "***" 1>&2; exit 1; fi)
endif

# eliminate default suffix rules
.SUFFIXES: .c .S .h

# delete target files if there is an error (or make is interrupted)
.DELETE_ON_ERROR:

# define compiler and flags

HOSTCC		:= gcc
## for mksfs program, -D_FILE_OFFSET_BITS=64 can guarantee sizeof(off_t)==8,  sizeof(ino_t) ==8
## for 64 bit gcc, to build 32-bit mksfs, you can use below line
## HOSTCFLAGS	:= -g -Wall -m32 -O2 -D_FILE_OFFSET_BITS=64
HOSTCFLAGS	:= -g -Wall -O2 -D_FILE_OFFSET_BITS=64

GDB		:= $(GCCPREFIX)gdb

CC		:= $(GCCPREFIX)gcc
CFLAGS	:= -fno-builtin -fno-PIC -Wall -ggdb -m32 -gstabs -nostdinc $(DEFS)
CFLAGS	+= $(shell $(CC) -fno-stack-protector -E -x c /dev/null >/dev/null 2>&1 && echo -fno-stack-protector)
CTYPE	:= c S

LD      := $(GCCPREFIX)ld
LDFLAGS	:= -m $(shell $(LD) -V | grep elf_i386 2>/dev/null | head -n 1)
LDFLAGS	+= -nostdlib

OBJCOPY := $(GCCPREFIX)objcopy
OBJDUMP := $(GCCPREFIX)objdump

COPY	:= cp
MKDIR   := mkdir -p
MV		:= mv
RM		:= rm -f
AWK		:= awk
SED		:= sed
SH		:= sh
TR		:= tr
TOUCH	:= touch -c

OBJDIR	:= obj
BINDIR	:= bin

ALLOBJS	:=
ALLDEPS	:=
TARGETS	:=

USER_PREFIX	:= __user_

ifeq ($(shell uname), Linux)
	M := M
else
	M := m
endif

include tools/function.mk

listf_cc = $(call listf,$(1),$(CTYPE))

# for cc
add_files_cc = $(call add_files,$(1),$(CC),$(CFLAGS) $(3),$(2),$(4))
create_target_cc = $(call create_target,$(1),$(2),$(3),$(CC),$(CFLAGS))

# for hostcc
add_files_host = $(call add_files,$(1),$(HOSTCC),$(HOSTCFLAGS),$(2),$(3))
create_target_host = $(call create_target,$(1),$(2),$(3),$(HOSTCC),$(HOSTCFLAGS))

cgtype = $(patsubst %.$(2),%.$(3),$(1))
objfile = $(call toobj,$(1))
asmfile = $(call cgtype,$(call toobj,$(1)),o,asm)
outfile = $(call cgtype,$(call toobj,$(1)),o,out)
symfile = $(call cgtype,$(call toobj,$(1)),o,sym)
filename = $(basename $(notdir $(1)))
ubinfile = $(call outfile,$(addprefix $(USER_PREFIX),$(call filename,$(1))))

# for match pattern
match = $(shell echo $(2) | $(AWK) '{for(i=1;i<=NF;i++){if(match("$(1)","^"$$(i)"$$")){exit 1;}}}'; echo $$?)

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# include kernel/user

INCLUDE	+= libs/

CFLAGS	+= $(addprefix -I,$(INCLUDE))

LIBDIR	+= libs

$(call add_files_cc,$(call listf_cc,$(LIBDIR)),libs,)

# -------------------------------------------------------------------
# user programs

UINCLUDE	+= user/include/ \
			   user/libs/

USRCDIR		+= user

ULIBDIR		+= user/libs

UCFLAGS		+= $(addprefix -I,$(UINCLUDE))
USER_BINS	:=

$(call add_files_cc,$(call listf_cc,$(ULIBDIR)),ulibs,$(UCFLAGS))
$(call add_files_cc,$(call listf_cc,$(USRCDIR)),uprog,$(UCFLAGS))

UOBJS	:= $(call read_packet,ulibs libs)

define uprog_ld
__user_bin__ := $$(call ubinfile,$(1))
USER_BINS += $$(__user_bin__)
$$(__user_bin__): tools/user.ld
$$(__user_bin__): $$(UOBJS)
$$(__user_bin__): $(1) | $$$$(dir $$$$@)
	$(V)$(LD) $(LDFLAGS) -T tools/user.ld -o $$@ $$(UOBJS) $(1)
	@$(OBJDUMP) -S $$@ > $$(call cgtype,$$<,o,asm)
	@$(OBJDUMP) -t $$@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$$$/d' > $$(call cgtype,$$<,o,sym)
endef

$(foreach p,$(call read_packet,uprog),$(eval $(call uprog_ld,$(p))))

# -------------------------------------------------------------------
# kernel

KINCLUDE	+= kern/debug/ \
			   kern/driver/ \
			   kern/trap/ \
			   kern/mm/ \
			   kern/libs/ \
			   kern/sync/ \
			   kern/fs/    \
			   kern/process/ \
			   kern/schedule/ \
			   kern/syscall/  \
			   kern/fs/swap/ \
			   kern/fs/vfs/ \
			   kern/fs/devs/ \
			   kern/fs/sfs/ 


KSRCDIR		+= kern/init \
			   kern/libs \
			   kern/debug \
			   kern/driver \
			   kern/trap \
			   kern/mm \
			   kern/sync \
			   kern/fs    \
			   kern/process \
			   kern/schedule \
			   kern/syscall  \
			   kern/fs/swap \
			   kern/fs/vfs \
			   kern/fs/devs \
			   kern/fs/sfs

KCFLAGS		+= $(addprefix -I,$(KINCLUDE))

$(call add_files_cc,$(call listf_cc,$(KSRCDIR)),kernel,$(KCFLAGS))

KOBJS	= $(call read_packet,kernel libs)

# create kernel target
kernel = $(call totarget,kernel)

$(kernel): tools/kernel.ld

$(kernel): $(KOBJS)
	@echo + ld $@
	$(V)$(LD) $(LDFLAGS) -T tools/kernel.ld -o $@ $(KOBJS)
	@$(OBJDUMP) -S $@ > $(call asmfile,kernel)
	@$(OBJDUMP) -t $@ | $(SED) '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $(call symfile,kernel)

$(call create_target,kernel)

# -------------------------------------------------------------------

# create bootblock
bootfiles = $(call listf_cc,boot)
$(foreach f,$(bootfiles),$(call cc_compile,$(f),$(CC),$(CFLAGS) -Os -nostdinc))

bootblock = $(call totarget,bootblock)

$(bootblock): $(call toobj,boot/bootasm.S) $(call toobj,$(bootfiles)) | $(call totarget,sign)
	@echo + ld $@
	$(V)$(LD) $(LDFLAGS) -N -T tools/boot.ld $^ -o $(call toobj,bootblock)
	@$(OBJDUMP) -S $(call objfile,bootblock) > $(call asmfile,bootblock)
	@$(OBJCOPY) -S -O binary $(call objfile,bootblock) $(call outfile,bootblock)
	@$(call totarget,sign) $(call outfile,bootblock) $(bootblock)

$(call create_target,bootblock)

# -------------------------------------------------------------------

# create 'sign' tools
$(call add_files_host,tools/sign.c,sign,sign)
$(call create_target_host,sign,sign)

# -------------------------------------------------------------------
# create 'mksfs' tools
$(call add_files_host,tools/mksfs.c,mksfs,mksfs)
$(call create_target_host,mksfs,mksfs)

# -------------------------------------------------------------------
# create ucore.img
UCOREIMG	:= $(call totarget,ucore.img)

$(UCOREIMG): $(kernel) $(bootblock)
	$(V)dd if=/dev/zero of=$@ count=10000
	$(V)dd if=$(bootblock) of=$@ conv=notrunc
	$(V)dd if=$(kernel) of=$@ seek=1 conv=notrunc

$(call create_target,ucore.img)

# -------------------------------------------------------------------

# create swap.img
SWAPIMG		:= $(call totarget,swap.img)

$(SWAPIMG):
	$(V)dd if=/dev/zero of=$@ bs=1$(M) count=128

$(call create_target,swap.img)

# -------------------------------------------------------------------
# create sfs.img
SFSIMG		:= $(call totarget,sfs.img)
SFSBINS		:=
SFSROOT		:= disk0

define fscopy
__fs_bin__ := $(2)$(SLASH)$(patsubst $(USER_PREFIX)%,%,$(basename $(notdir $(1))))
SFSBINS += $$(__fs_bin__)
$$(__fs_bin__): $(1) | $$$$(dir $@)
	@$(COPY) $$< $$@
endef

$(foreach p,$(USER_BINS),$(eval $(call fscopy,$(p),$(SFSROOT)$(SLASH))))

$(SFSROOT):
	$(V)$(MKDIR) $@

$(SFSIMG): $(SFSROOT) $(SFSBINS) | $(call totarget,mksfs)
	$(V)dd if=/dev/zero of=$@ bs=1$(M) count=128
	@$(call totarget,mksfs) $@ $(SFSROOT)

$(call create_target,sfs.img)


# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

$(call finish_all)

IGNORE_ALLDEPS	= clean \
				  dist-clean \
				  grade \
				  touch \
				  print-.+ \
				  run-.+ \
				  build-.+ \
				  sh-.+ \
				  script-.+ \
				  handin

ifeq ($(call match,$(MAKECMDGOALS),$(IGNORE_ALLDEPS)),0)
-include $(ALLDEPS)
endif

# files for grade script

TARGETS: $(TARGETS)

.DEFAULT_GOAL := TARGETS

QEMUOPTS = -hda $(UCOREIMG) -drive file=$(SWAPIMG),media=disk,cache=writeback -drive file=$(SFSIMG),media=disk,cache=writeback 

.PHONY: qemu qemu-nox debug debug-nox monitor
qemu-mon: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -monitor stdio $(QEMUOPTS) -serial null
qemu: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -serial stdio $(QEMUOPTS) -parallel null
#	$(V)$(QEMU) -parallel stdio $(QEMUOPTS) -serial null

qemu-nox: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -serial mon:stdio $(QEMUOPTS) -nographic

monitor: $(UCOREIMG) $(SWAPING) $(SFSIMG)
	$(V)$(QEMU) -monitor stdio $(QEMUOPTS) -serial null

TERMINAL := gnome-terminal

dbg4ec: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -S -s -parallel stdio $(QEMUOPTS) -serial null

debug: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -S -s -parallel stdio $(QEMUOPTS) -serial null &
	$(V)sleep 2
	$(V)$(TERMINAL) -e "$(GDB) -q -x tools/gdbinit"

debug-nox: $(UCOREIMG) $(SWAPIMG) $(SFSIMG)
	$(V)$(QEMU) -S -s -serial mon:stdio $(QEMUOPTS) -nographic &
	$(V)sleep 2
	$(V)$(TERMINAL) -e "$(GDB) -q -x tools/gdbinit"

RUN_PREFIX	:= _binary_$(OBJDIR)_$(USER_PREFIX)
MAKEOPTS	:= --quiet --no-print-directory

run-%: build-%
	$(V)$(QEMU) -parallel stdio $(QEMUOPTS) -serial null

sh-%: script-%
	$(V)$(QEMU) -parallel stdio $(QEMUOPTS) -serial null

run-nox-%: build-%
	$(V)$(QEMU) -serial mon:stdio $(QEMUOPTS) -nographic

build-%: touch
	$(V)$(MAKE) $(MAKEOPTS) "DEFS+=-DTEST=$*" 

script-%: touch
	$(V)$(MAKE) $(MAKEOPTS) "DEFS+=-DTEST=sh -DTESTSCRIPT=/script/$*"

.PHONY: grade touch buildfs

GRADE_GDB_IN	:= .gdb.in
GRADE_QEMU_OUT	:= .qemu.out
HANDIN			:= proj$(PROJ)-handin.tar.gz

TOUCH_FILES		:= kern/process/proc.c

MAKEOPTS		:= --quiet --no-print-directory

grade:
	$(V)$(MAKE) $(MAKEOPTS) clean
	$(V)$(SH) tools/grade.sh

touch:
	$(V)$(foreach f,$(TOUCH_FILES),$(TOUCH) $(f))

print-%:
	@echo $($(shell echo $(patsubst print-%,%,$@) | $(TR) [a-z] [A-Z]))

.PHONY: clean dist-clean handin packall
clean:
	$(V)$(RM) $(GRADE_GDB_IN) $(GRADE_QEMU_OUT)  $(SFSBINS)
	-$(RM) -r $(OBJDIR) $(BINDIR)

dist-clean: clean
	-$(RM) $(HANDIN)

handin: packall
	@echo Please visit http://learn.tsinghua.edu.cn and upload $(HANDIN). Thanks!

packall: clean
	@$(RM) -f $(HANDIN)
	@tar -czf $(HANDIN) `find . -type f -o -type d | grep -v '^\.*$$' | grep -vF '$(HANDIN)'`

