##########################
# ---- Introduction ---- #
##########################
# Welcome to Final Processor makefile!
# this file will build and run a fully synthesizable RISC-V verilog processor
# and is an extended version of the EECS 472 standard makefile

# This file is reuses the majority of the p2 makefile

# reference table of all make targets:

# make  <- runs the default target, set explicitly below as 'make no_hazard.out'
.DEFAULT_GOAL = mult.pass
# ^ this overrides using the first listed target as the default
.SECONDEXPANSION:
# ^ needed to correctly run $$(call tb_path,%) dependency fetch

# ---- Module Testbenches ---- #
# NOTE: these require files like: 'verilog/src/rob.sv' and 'test/testbenches/rob_test.sv'
#       which implement and test the module: 'rob'

# make <module>.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
# make <module>.out    <- run the testbench (via build/<module>.simv)
# make <module>.verdi  <- run in verdi (via <module>.simv)
# make build/<module>.simv  <- compile the testbench executable

# make <module>.syn.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
# make <module>.syn.out    <- run the synthesized module on the testbench
# make <module>.syn.verdi  <- run in verdi (via <module>.syn.simv)
# make synth/<module>.vg        <- synthesize the module
# make build/<module>.syn.simv  <- compile the synthesized module with the testbench

# make slack     <- grep the slack status of any synthesized modules

# ---- module testbench coverage ---- #
# make <module>.cov        <- print the coverage hierarchy report to the terminal
# make <module>.cov.verdi  <- open the coverage report in verdi
# make build/<module>.cov.simv  <- compiles a coverage executable for the testbench
# make build/<module>.cov.vdb   <- runs the executable and makes a coverage output dir
# make cov_report_<module>      <- run urg to create human readable coverage reports

# ---- Program Execution ---- #
# These are your main commands for running programs and generating output
# make <my_program>.out      <- run a program on build/cpu.simv and output *.out, *.cpi, and *.wb files
# make <my_program>.syn.out  <- run a program on build/cpu.syn.simv and do the same
# make simulate_all          <- run every program on simv at once (in parallel with -j)
# make simulate_all_syn      <- run every program on syn_simv at once (in parallel with -j)

# ---- Executable Compilation ---- #
# make simv      <- compiles build/cpu.simv from the CPU_TESTBENCH and CPU_SOURCES
# make syn_simv  <- compiles syn_simv from CPU_TESTBENCH and CPU_SYNTH
# make synth/cpu.vg  <- synthesize modules in CPU_SOURCES for use in syn_simv

# ---- Program Memory Compilation ---- #
# Programs to run are in the programs/ directory
# make programs/<my_program>.mem  <- compile a program to a RISC-V memory file
# make compile_all                <- compile every program at once (in parallel with -j)

# ---- Dump Files ---- #
# make <my_program>.dump  <- disassembles compiled memory into RISC-V assembly dump files
# make *.debug.dump       <- for a .c program, creates dump files with a debug flag
# make programs/<my_program>.dump_x    <- numeric dump files use x0-x31 as register names
# make programs/<my_program>.dump_abi  <- abi dump files use the abi register names (sp, a0, etc.)
# make dump_all  <- create all dump files at once (in parallel with -j)

# ---- Verdi ---- #
# make <my_program>.verdi     <- run a program in verdi via build/cpu.simv
# make <my_program>.syn.verdi <- run a program in verdi via build/cpu.syn.simv

# ---- Cleanup ---- #
# make clean            <- remove per-run files and compiled executable files
# make nuke             <- remove all files created from make rules
# make clean_run_files  <- remove per-run output files
# make clean_exe        <- remove compiled executable files
# make clean_synth      <- remove generated synthesis files
# make clean_output     <- remove the entire output/ directory
# make clean_programs   <- remove program memory and dump files
# make clean_coverage   <- remove coverage file directories

# Credits:
# VeriSimpleV was adapted by Jielun Tan for RISC-V from the original 470 VeriSimple Alpha language processor
# however I cannot find the original authors or the major editors of the project :/
# so to everyone I can't credit: thank you!
# the current layout of the Makefile was made by Ian Wrzesinski in 2023
# VeriSimpleV has also been edited by at least:
# Nevil Pooniwala, Xueyang Liu, Cassie Jones, James Connolly

######################################################
# ---- Compilation Commands and Other Variables ---- #
######################################################

# recursive globbing function (https://stackoverflow.com/questions/4036191/sources-from-subdirectories-in-makefile)
rwildcard=$(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
# usage: $(call rwildcard,<folder>/,<mask>*<mask>) (spaces must be consistent as example shows)

# these are various build flags for different parts of the makefile, VCS and LIB should be
# familiar, but there are new variables for supporting the compilation of assembly and C
# source programs into riscv machine code files to be loaded into the processor's memory

# don't be afraid to change these, but be diligent about testing changes and using git commits
# there should be no need to change anything for the final project

# this is a global clock period variable used in the tcl script and referenced in testbenches
export CLOCK_PERIOD = 30

# verilog file paths
export INC = verilog/inc/   # tcl script also uses inc
SRC        = verilog/src/
TSB        = test/testbenches/

#	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#	% ---- Ignore Source Files ---- %
#	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# list source files that should be ignored in sim or synth. This is useful since CPU_SOURCES
# 	globs every .sv file in src/, and you might be testing different versions of the same module

#  	e.g. IGNORE = $(SRC)combinational/psel_gen.sv \
		 		  $(SRC)icache.sv

# or: you can rename the file to-be-ignored by appending anything after .sv (will fail glob mask)
#	e.g. psel_gen.sv.ignore
IGNORE = 

# the Verilog Compiler command and arguments
VCS = module load vcs/2023.12-SP2-1 && \
	  vcs -sverilog -xprop=tmerge +vc -Mupdate -Mdir=build/csrc -line -full64 -kdb -lca -nc \
      -debug_access+all+reverse $(VCS_BAD_WARNINGS) +define+CLOCK_PERIOD=$(CLOCK_PERIOD) +incdir+$(INC)
# a SYNTH define is added when compiling for synthesis that can be used in testbenches

RUN_VERDI = -gui=verdi -verdi_opts "-ultra"

# remove certain warnings that generate MB of text but can be safely ignored
VCS_BAD_WARNINGS = +warn=noTFIPC +warn=noDEBUG_DEP +warn=noENUMASSIGN +warn=noLCA_FEATURES_ENABLED

# a reference library of standard structural cells that we link against when synthesizing
LIB = /usr/caen/misc/class/eecs470/lib/verilog/lec25dscc25.v

# the EECS 472 synthesis script
TCL_SCRIPT = synth/472synth.tcl

# Set the shell's pipefail option: causes return values through pipes to match the last non-zero value
# (useful for, i.e. piping to `tee`)
SHELL := $(SHELL) -o pipefail

# The following are new in project 2:

# you might need to update these build flags for the final project, but make sure you know what they do:
# https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Options.html
CFLAGS     = -mno-relax -march=rv32im -mabi=ilp32 -nostartfiles -std=gnu11 -mstrict-align -mno-div
# adjust the optimization if you want programs to run faster; this may obfuscate/change their instructions
OFLAGS     = -O0
ASFLAGS    = -mno-relax -march=rv32im -mabi=ilp32 -nostartfiles -Wno-main -mstrict-align
OBJFLAGS   = -SD -M no-aliases
OBJCFLAGS  = --set-section-flags .bss=contents,alloc,readonly
OBJDFLAGS  = -SD -M numeric,no-aliases
DEBUG_FLAG = -g

# this is our RISC-V compiler toolchain
# NOTE: you can use a local riscv install to compile programs by setting CAEN to 0
CAEN = 1
ifeq (1, $(CAEN))
    GCC     = riscv gcc
    OBJCOPY = riscv objcopy
    OBJDUMP = riscv objdump
    AS      = riscv as
    ELF2HEX = riscv elf2hex
else
    GCC     = riscv64-unknown-elf-gcc
    OBJCOPY = riscv64-unknown-elf-objcopy
    OBJDUMP = riscv64-unknown-elf-objdump
    AS      = riscv64-unknown-elf-as
    ELF2HEX = elf2hex
endif

GREP = grep -E --color=auto

################################
# ---- Module Testbenches ---- #
################################

# This section adds Make targets for running individual module testbenches
# It requires using the following naming convention:
# 1. the source file: 'verilog/src/<subfolder>/<file>.sv'
# 2. the source file contains your module of interest for testing
# 3. with a testbench file: 'test/rob_test.sv'
# 4. and added to the MODULES variable as: 'rob' (your module declaration in your source file does not need to be the same name)
# 5. with extra sources specified for: 'build/rob.simv', 'build/rob.cov.simv', and 'synth/rob.vg'


# This allows you to use the following make targets:

# Simulation
# make <module>.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
# make <module>.out    <- run the testbench (via build/<module>.simv)
# make <module>.verdi  <- run in verdi (via <module>.simv)
# make build/<module>.simv  <- compile the testbench executable

# Synthesis
# make <module>.syn.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
# make <module>.syn.out    <- run the synthesized module on the testbench
# make <module>.syn.verdi  <- run in verdi (via <module>.syn.simv)
# make synth/<module>.vg        <- synthesize the module
# make build/<module>.syn.simv  <- compile the synthesized module with the testbench

# We have also added targets for checking testbench coverage:

# make <module>.cov        <- print the coverage hierarchy report to the terminal
# make <module>.cov.verdi  <- open the coverage report in verdi (need to make the report first with .cov or .vdb)
# make build/<module>.cov.simv  <- compiles a coverage executable for the testbench
# make build/<module>.cov.vdb   <- runs the executable and makes a coverage output dir
# make cov_report_<module>      <- run urg to create human readable coverage reports

# This is only here so the Makefile can track header changes.
# inc/ CANNOT have subfolders.
ALL_HEADERS = $(INC)*.svh
#CPU_HEADERS = $(INC)sys_defs.svh \
              $(INC)ISA.svh
# or add individually ^ (you shouldn't need to; headers are only parsed if explicitly included in a source file)

# ---- Modules to Test ---- #

# Setup:
# files = $(SRC)<file1>.sv \
		  $(SRC)<file2>.sv \
		  $(SRC)<subfolder>/<file3>.sv \
		  ...
# build/<name>.simv: 	  $(files)
# build/<name>.cov.simv:  $(files)
# synth/<name>.vg:        $(files)

# <name> must match the name listed in MODULES, as well as testbench name in the format: 
# 		 <name>_test.sv 		(these live in your test/testbenches directory)
# <name> does not have to match the target source file, i.e. mult does not need a 'mult'.sv or a 'mult' module.
#		 - For clarity, we recommend you stay consistent and organized. This flexibility in naming is given
#		     to make organization and testing simpler. 
#		 - Reference the IGNORE variable for adapting your CPU source files.

# you could also do:
# files = $(call rwildcard,$(SRC)<subfolder>,*.sv) \
		  $(SRC)/<other_file>.sv
# for <subfolder> and child folder sources.
# or..
# files = $(SRC)<subfolder>/*.sv \
		  $(SRC)<other_file>.sv
# for only the subfolder contents (does not recurse into children directories)
#
# If you organize your files in such chunks, this could be easier to use.

# src/ directory can have any depth of subfolders for organization.
# inc/ CANNOT have ANY subfolders. VCS and dc_shell will not recursively search inc/ for header matches.
# 	All headers must be in inc/ directly.

# TODO: add more modules here, or rename the given ones
MODULES = cpu mult rob rs psel_gen freelist victim_cache mshr dcache miss_path

MULT_FILES =		 $(SRC)mult.sv
build/mult.simv:	 $(MULT_FILES)
build/mult.cov.simv: $(MULT_FILES)
synth/mult.vg:		 $(MULT_FILES)

RS_FILES =		   	 $(SRC)rs.sv $(SRC)combinational/psel_gen.sv
build/rs.simv:     	 $(RS_FILES)
build/rs.cov.simv: 	 $(RS_FILES)
synth/rs.vg:       	 $(RS_FILES)

ROB_FILES =      	 $(SRC)rob.sv
build/rob.simv:  	 $(ROB_FILES)
build/rob.cov.simv:	 $(ROB_FILES)
synth/rob.vg:    	 $(ROB_FILES)

FREELIST_FILES =       $(SRC)freelist.sv
build/freelist.simv:   $(FREELIST_FILES)
build/freelist.cov.simv: $(FREELIST_FILES)
synth/freelist.vg:     $(FREELIST_FILES)

VICTIM_CACHE_FILES = $(SRC)victim_cache.sv
build/victim_cache.simv:      $(VICTIM_CACHE_FILES)
build/victim_cache.cov.simv:  $(VICTIM_CACHE_FILES)
synth/victim_cache.vg:        $(VICTIM_CACHE_FILES)

MSHR_FILES = $(SRC)mshr.sv
build/mshr.simv:      $(MSHR_FILES)
build/mshr.cov.simv:  $(MSHR_FILES)
synth/mshr.vg:        $(MSHR_FILES)

DCACHE_FILES = \
	$(SRC)dcache.sv \
	$(SRC)memDP.sv \
	$(SRC)victim_cache.sv \
	$(SRC)write_buf.sv
build/dcache.simv:      $(DCACHE_FILES)
build/dcache.cov.simv:  $(DCACHE_FILES)
synth/dcache.vg:        $(DCACHE_FILES)

MISS_PATH_FILES = \
	$(SRC)dcache.sv \
	$(SRC)memDP.sv \
	$(SRC)victim_cache.sv \
	$(SRC)write_buff.sv \
	$(SRC)mshr.sv \
	test/testbenches/miss_path_test.sv
build/miss_path.simv:      $(MISS_PATH_FILES)
build/miss_path.cov.simv:  $(MISS_PATH_FILES)
synth/miss_path.vg:        $(MISS_PATH_FILES)
#################################
# ---- Main CPU Definition ---- #
#################################

# We also reuse this section to compile the cpu, but not to run it
# You should still run programs in the same way as project 2

# test/cpu_test.sv is implicit. You shouldn't need to update this
CPU_TESTBENCH = test/pipeline_print.c \
			    test/decode_inst.c \
                test/mem.sv 
# NOTE: you CANNOT alter the given memory module

# TODO: add your source files here
# syntax for src/ directory: You can organize however you wish!
# $(SRC)<subfolder>/<file>.sv
CPU_SOURCES = $(call rwildcard,$(SRC),*.sv) # recursive glob of src/ directory
# CPU_SOURCES = $(SRC)cpu.sv \
			  $(SRC)regfile.sv \
              $(SRC)icache.sv \
              $(SRC)memDP.sv \
			  $(SRC)mult.sv \
			  $(SRC)combinational/decoder.sv \
			  $(SRC)combinational/psel_gen.sv
# or add individually ^

build/cpu.simv: $(CPU_SOURCES) $(CPU_HEADERS) $(CPU_TESTBENCH)
synth/cpu.vg: $(CPU_SOURCES) $(CPU_HEADERS)
build/cpu.syn.simv: $(CPU_TESTBENCH)
# Don't need coverage for the CPU

# Connect the simv and syn_simv targets for the autograder
simv: build/cpu.simv ;
syn_simv: build/cpu.syn.simv ;

# You shouldn't need to change things below here

#####################
# ---- Running ---- #
#####################

# The following Makefile targets heavily use pattern substitution and static pattern rules
# See these links if you want to hack on them and understand how they work:
# - https://www.gnu.org/software/make/manual/html_node/Text-Functions.html
# - https://www.gnu.org/software/make/manual/html_node/Static-Usage.html
# - https://www.gnu.org/software/make/manual/html_node/Automatic-Variables.html

# run compiled executables ('make %.out' is linked to 'make output/%.out' further below)
# using this syntax avoids overlapping with the 'make <my_program>.out' targets
$(MODULES:%=build/%.out) $(MODULES:%=build/%.syn.out): build/%.out: build/%.simv
	@$(call PRINT_COLOR, 5, running $<)
	cd build && ./$(<F) | tee $(@F)

# Connect 'make build/mod.out' to 'make mod.out'
$(MODULES:%=./%.out) $(MODULES:%=./%.syn.out): ./%.out: build/%.out
	@$(call PRINT_COLOR, 2, Finished $* testbench output is in: $<)

# Print in green or red the pass/fail status (must $display() "@@@ Passed" or "@@@ Failed")
%.pass: build/%.out
	@$(call PRINT_COLOR, 6, Grepping for pass/fail in $<:)
	@GREP_COLOR="01;31" $(GREP) -i '@@@ ?Failed' $< || \
	GREP_COLOR="01;32" $(GREP) -i '@@@ ?Passed' $<
.PHONY: %.pass

# run the module in verdi
./%.verdi: build/%.simv
	@$(call PRINT_COLOR, 5, running $< with verdi )
	cd build && ./$(<F) $(RUN_VERDI)
.PHONY: %.verdi

###############################
# ---- Compiling Verilog ---- #
###############################

# Testbench dependency search
# find all <module>_test.sv files in tb and child directories. If there is more than one, raise error
tb_path=$(eval _matches=$(call rwildcard,$(TSB),$1_test.sv)) \
        $(if $(filter 1, $(words $(_matches))),$(_matches),\
		ERROR:multiple-matching-tb-found-in::<$(subst $(empty) $(empty),><,$(strip $(dir $(_matches))))>)


# The normal simulation executable will run your testbench on simulated modules
$(MODULES:%=build/%.simv): build/%.simv: $$(call tb_path,%) | build
	@$(call PRINT_COLOR, 5, compiling the simulation executable $@)
	$(VCS) $(filter-out $(ALL_HEADERS) $(IGNORE),$^) -o $@
	@$(call PRINT_COLOR, 6, finished compiling $@)

# This also generates many other files, see the tcl script's introduction for info on each of them
synth/%.vg: $(TCL_SCRIPT) | synth
	@$(call PRINT_COLOR, 5, synthesizing the $* module)
	@$(call PRINT_COLOR, 3, this might take a while...)
	cd synth && \
	MODULE=$* SOURCES="$(filter-out $(TCL_SCRIPT) $(ALL_HEADERS) $(IGNORE),$^)" \
	dc_shell-t -f $(notdir $(TCL_SCRIPT)) | tee $*_synth.out
	@$(call PRINT_COLOR, 6, finished synthesizing $@)
	make slack

# A phony target to view the slack in all the *.rep synthesis reports
slack:
	$(GREP) "slack" synth/*.rep
.PHONY: slack

# The synthesis executable runs your testbench on the synthesized versions of your modules
$(MODULES:%=build/%.syn.simv): build/%.syn.simv: $$(call tb_path,%) synth/%.vg | build
	@$(call PRINT_COLOR, 5, compiling the synthesis executable $@)
	$(VCS) +define+SYNTH $(filter-out $(ALL_HEADERS) $(IGNORE),$^) $(LIB) -o $@
	@$(call PRINT_COLOR, 6, finished compiling $@)

##############################
# ---- Coverage targets ---- #
##############################

# This section adds targets to run module testbenches with coverage output

# Additional VCS argument for both building and running with coverage output
VCS_COVG = -cm line+tgl+cond+branch

$(MODULES:%=build/%.cov.simv): build/%.cov.simv: $$(call tb_path,%) | build
	@$(call PRINT_COLOR, 5, compiling the coverage executable $@)
	@$(call PRINT_COLOR, 3, NOTE: if this is slow to startup: run '"module load vcs verdi synopsys-synth"')
	$(VCS) $(VCS_COVG) $(filter-out $(ALL_HEADERS) $(IGNORE),$^) -o $@
	@$(call PRINT_COLOR, 6, finished compiling $@)

# Run the testbench to produce a *.vdb directory with coverage info
$(MODULES:%=build/%.cov.simv.out): %.cov.simv.out: %.cov.simv | build
	@$(call PRINT_COLOR, 5, running $<)
	cd build && ./$(<F) $(VCS_COVG) | tee $(@F)
	@$(call PRINT_COLOR, 2, created coverage dir $<.vdb and saved output to $@)

# A layer of indirection for the coverage output dir
build/%.cov.simv.vdb: build/%.cov.simv.out ;

# Use urg to generate human-readable reports in text mode (alternative is html)
$(MODULES:%=cov_report_%): cov_report_%: build/%.cov.simv.vdb
	@$(call PRINT_COLOR, 5, outputting coverage report in $@)
	module load vcs/2023.12-SP2-1 && cd build && urg -format text -dir $*.cov.simv.vdb -report ../$@
	@$(call PRINT_COLOR, 2, coverage report is in $@)

# view the coverage hierarchy report
$(MODULES:=.cov): %.cov: cov_report_%
	@$(call PRINT_COLOR, 2, printing coverage hierarchy - open '$<' for more)
	cat $</hierarchy.txt

# open the coverage info in verdi
$(MODULES:=.cov.verdi): %.cov.verdi: build/%.cov.simv
	@$(call PRINT_COLOR, 5, running verdi for $* coverage)
	cd build && ./$(<F) $(RUN_VERDI) -cov -covdir $(<F).vdb
# 	./$< $(RUN_VERDI) -cov -covdir $<.vdb

.PHONY: %.cov %.cov.verdi

#############################
# ---- Visual Debugger ---- #
#############################

# Add your own GUI debugger here!

VTUBER = test/vtuber_test.sv \
         test/vtuber.cpp \
		 test/mem.sv

VISFLAGS = -lncurses

build/vis.simv: $(CPU_HEADERS) $(VTUBER) $(CPU_SOURCES) | build
	@$(call PRINT_COLOR, 5, compiling visual debugger testbench)
	$(VCS) $(VISFLAGS) $^ -o $@
	@$(call PRINT_COLOR, 6, finished compiling visual debugger testbench)

%.vis: programs/mem/%.mem build/vis.simv
	cd build && ./vis.simv +MEMORY=../$<
	@$(call PRINT_COLOR, 6, Fullscreen your terminal for the best VTUBER experience!)
.PHONY: %.vis

####################################
# ---- Executable Compilation ---- #
####################################

########################################
# ---- Program Memory Compilation ---- #
########################################

# this section will compile programs into .mem files to be loaded into memory
# you start with either an assembly or C program in the programs/ directory
# those compile into a .elf link file via the riscv assembler or compiler
# then that link file is converted to a .mem hex file

# find the test program files and separate them based on suffix of .s or .c
# filter out files that aren't themselves programs
NON_PROGRAMS = $(CRT)
ASSEMBLY = $(filter-out $(NON_PROGRAMS),$(wildcard programs/*.s))
C_CODE   = $(filter-out $(NON_PROGRAMS),$(wildcard programs/*.c))

# concatenate ASSEMBLY and C_CODE to list every program
PROGRAMS = $(ASSEMBLY:%.s=%) $(C_CODE:%.c=%)

# NOTE: this is Make's pattern substitution syntax
# see: https://www.gnu.org/software/make/manual/html_node/Text-Functions.html#Text-Functions
# this reads as: $(var:pattern=replacement)
# a percent sign '%' in pattern is as a wildcard, and can be reused in the replacement
# if you don't include the percent it automatically attempts to replace just the suffix of the input

# C and assembly compilation files. These link and setup the runtime for the programs
CRT        = programs/crt.s
LINKERS    = programs/linker.lds
ASLINKERS  = programs/aslinker.lds

# make elf files from assembly code
programs/mem/%.elf: programs/%.s $(ASLINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling assembly file $<)
	$(GCC) $(ASFLAGS) $< -T $(ASLINKERS) -o $@

# make elf files from C source code
programs/mem/%.elf: programs/%.c $(CRT) $(LINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling C code file $<)
	$(GCC) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@

# C programs can also be compiled in debug mode, this is solely meant for use in the .dump files below
programs/mem/%.debug.elf: %.c $(CRT) $(LINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling debug C code file $<)
	$(GCC) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@
	$(GCC) $(DEBUG_FLAG) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@

# declare the .elf files as intermediate files.
# Make will automatically rm intermediate files after they're used in a recipe
# and it won't remake them until their sources are updated or they're needed again
.INTERMEDIATE: programs/mem/%.elf

# turn any elf file into a hex memory file ready for the testbench
programs/mem/%.mem: programs/mem/%.elf
	$(ELF2HEX) 8 8192 $< > $@
	@$(call PRINT_COLOR, 6, created memory file $@)
	@$(call PRINT_COLOR, 3, NOTE: to see RISC-V assembly run: '"make $*.dump"')
	@$(call PRINT_COLOR, 3, for \*.c sources also try: '"make $*.debug.dump"')

# compile all programs in one command (use 'make -j' to run multithreaded)
compile_all: $(PROGRAMS:programs/%=programs/mem/%=.mem)
.PHONY: compile_all

########################
# ---- Dump Files ---- #
########################

# when debugging a program, the dump files will show you the disassembled RISC-V
# assembly code that your processor is actually running

# this creates the <my_program>.debug.elf targets, which can be used in: 'make <my_program>.debug.dump_*'
# these are useful for the C sources because the debug flag makes the assembly more understandable
# because it includes some of the original C operations and function/variable names

DUMP_PROGRAMS = $(ASSEMBLY:.s=) $(C_CODE:.c=)

# 'make <my_program>.dump' will create both files at once!
./%.dump: programs/%.dump_x programs/%.dump_abi ;
.PHONY: ./%.dump
# Tell Make to treat the .dump_* files as "precious" and not to rm them as intermediaries to %.dump
.PRECIOUS: %.dump_x %.dump_abi

# use the numberic x0-x31 register names
programs/%.dump_x: programs/mem/%.elf
	@$(call PRINT_COLOR, 5, disassembling $<)
	$(OBJDUMP) $(OBJDFLAGS) $< > $@
	@$(call PRINT_COLOR, 6, created numeric dump file $@)

# use the Application Binary Interface register names (sp, a0, etc.)
programs/%.dump_abi: programs/mem/%.elf
	@$(call PRINT_COLOR, 5, disassembling $<)
	$(OBJDUMP) $(OBJFLAGS) $< > $@
	@$(call PRINT_COLOR, 6, created abi dump file $@)

# create all dump files in one command (use 'make -j' to run multithreaded)
dump_all: $(DUMP_PROGRAMS:=.dump_x) $(DUMP_PROGRAMS:=.dump_abi)
.PHONY: dump_all

###############################
# ---- Program Execution ---- #
###############################

# run one of the executables (simv/syn_simv) using the chosen program
# e.g. 'make sampler.out' does the following from a clean directory:
#   1. compiles simv
#   2. compiles programs/sampler.s into its .elf and then .mem files (in programs/)
#   3. runs ./simv +MEMORY=programs/sampler.mem +OUTPUT=output/sampler > output/sampler.out
#   4. which creates the sampler.out, sampler.cpi, sampler.wb, and files in output/
# the same can be done for synthesis by doing 'make sampler.syn.out'
# which will also create .syn.cpi, .syn.wb, and files in output/

# run a program and produce output files
output/%.out: programs/mem/%.mem build/cpu.simv | output
	@$(call PRINT_COLOR, 5, running simv on $<)
	./build/cpu.simv +MEMORY=$< +OUTPUT=output/$* > output/$*.log
	@$(call PRINT_COLOR, 6, finished running simv on $<)
	@$(call PRINT_COLOR, 2, output is in output/$*.{out cpi wb log})
# NOTE: this uses a 'static pattern rule' to match a list of known targets to a pattern
# and then generates the correct rule based on the pattern, where % and $* match
# so for the target 'output/sampler.out' the % matches 'sampler' and depends on programs/sampler.mem
# see: https://www.gnu.org/software/make/manual/html_node/Static-Usage.html
# $(@D) is an automatic variable for the directory of the target, in this case, 'output'

# this does the same as simv, but adds .syn to the output files and compiles syn_simv instead
# run synthesis with: 'make <my_program>.syn.out'
output/%.syn.out: programs/mem/%.mem build/cpu.syn.simv | output
	@$(call PRINT_COLOR, 5, running syn_simv on $<)
	@$(call PRINT_COLOR, 3, this might take a while...)
	./build/cpu.syn.simv +MEMORY=$< +OUTPUT=output/$*.syn > output/$*.syn.log
	@$(call PRINT_COLOR, 6, finished running syn_simv on $<)
	@$(call PRINT_COLOR, 2, output is in output/$*.syn.{out cpi wb})

# Allow us to type 'make <my_program>.out' instead of 'make output/<my_program>.out'
./%.out: output/%.out ;
.PHONY: ./%.out

# Declare that creating a %.out file also creates both %.cpi, %.wb, and files
%.cpi %.wb : %.out ;

.PRECIOUS: %.out %.cpi %.wb

# run all programs in one command (use 'make -j' to run multithreaded)
simulate_all: build/cpu.simv compile_all $(PROGRAMS:programs/%=output/%.out)
simulate_all_syn: build/cpu.syn.simv compile_all $(PROGRAMS:programs/%=output/%.syn.out)
.PHONY: simulate_all simulate_all_syn

###################
# ---- Verdi ---- #
###################

# run verdi on a program with: 'make <my_program>.verdi' or 'make <my_program>.syn.verdi'

# this creates a directory verdi will use if it doesn't exist yet
verdi_dir:
	mkdir -p /tmp/$${USER}470
.PHONY: verdi_dir

novas.rc: initialnovas.rc
	sed s/UNIQNAME/$$USER/ initialnovas.rc > novas.rc

%.verdi: programs/mem/%.mem build/cpu.simv novas.rc verdi_dir | output
	./build/cpu.simv $(RUN_VERDI) +MEMORY=$< +OUTPUT=output/verdi_output

%.syn.verdi: programs/mem/%.mem build/cpu.syn.simv novas.rc verdi_dir | output
	./build/cpu.syn.simv $(RUN_VERDI) +MEMORY=$< +OUTPUT=output/syn_verdi_output

.PHONY: %.verdi

################################
# ---- Output Directories ---- #
################################

# Directories for holding build files or run outputs
# Targets that need these directories should add them after a pipe.
# ex: "target: dep1 dep2 ... | build"
build synth output programs/mem:
	mkdir -p $@
# Don't leave any files in these, they will be deleted by clean commands

#####################
# ---- Cleanup ---- #
#####################

# You should only clean your directory if you think something has built incorrectly
# or you want to prepare a clean directory for e.g. git (first check your .gitignore).
# Please avoid cleaning before every build. The point of a makefile is to
# automatically determine which targets have dependencies that are modified,
# and to re-build only those as needed; avoiding re-building everything everytime.

# 'make clean' removes build/output files, 'make nuke' removes all generated files
# 'make clean' does not remove .mem or .dump files
# clean_* commands remove certain groups of files

clean: clean_exe clean_run_files
	@$(call PRINT_COLOR, 6, note: clean is split into multiple commands you can call separately: $^)

# removes all extra synthesis files and the entire output directory
# use cautiously, this can cause hours of recompiling in the final project
nuke: clean clean_output clean_synth clean_programs clean_coverage
	@$(call PRINT_COLOR, 6, note: nuke is split into multiple commands you can call separately: $^)

clean_exe:
	@$(call PRINT_COLOR, 3, removing compiled executable files)
	rm -rf build/                         # remove the entire 'build' folder
	rm -rf *simv *.daidir csrc *.key      # created by simv/syn_simv/vis_simv
	rm -rf vcdplus.vpd vc_hdrs.h          # created by simv/syn_simv/vis_simv
	rm -rf unifiedInference.log xprop.log # created by simv/syn_simv/vis_simv
	rm -rf *.cov cov_report_* cm.log      # coverage files
	rm -rf verdi* novas* *fsdb*           # verdi files
	rm -rf dve* inter.vpd DVEfiles        # old DVE debugger

clean_run_files:
	@$(call PRINT_COLOR, 3, removing per-run outputs)
	rm -rf output/*.out output/*.cpi output/*.wb output/*.log

clean_synth:
	@$(call PRINT_COLOR, 1, removing synthesis files)
	cd synth && rm -rf *.vg *_svsim.sv *.res *.rep *.ddc *.chk *.syn *.out *.db *.svf *.mr *.pvl command.log cksum_dir/

clean_output:
	@$(call PRINT_COLOR, 1, removing entire output directory)
	rm -rf output/

clean_programs:
	@$(call PRINT_COLOR, 3, removing program memory files)
	rm -rf programs/*.mem
	@$(call PRINT_COLOR, 3, removing dump files)
	rm -rf programs/*.dump*

clean_coverage:
	@$(call PRINT_COLOR, 3, removing coverage files)
	rm -rf vdCovLog/

.PHONY: clean nuke clean_%

######################
# ---- Printing ---- #
######################

# this is a GNU Make function with two arguments: PRINT_COLOR(color: number, msg: string)
# it does all the color printing throughout the makefile
PRINT_COLOR = if [ -t 0 ]; then tput setaf $(1) ; fi; echo $(2); if [ -t 0 ]; then tput sgr0; fi
# colors: 0:black, 1:red, 2:green, 3:yellow, 4:blue, 5:magenta, 6:cyan, 7:white
# other numbers are valid, but aren't specified in the tput man page

# Make functions are called like this:
# $(call PRINT_COLOR,3,Hello World!)
# NOTE: adding '@' to the start of a line avoids printing the command itself, only the output
