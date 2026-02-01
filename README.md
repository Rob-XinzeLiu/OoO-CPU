
# EECS 472 Final Project

Welcome to the EECS 472 Final Project!

This is the repository for your implementation of an out-of-order,
synthesizable, RISC-V processor with advanced features.

This repository has multiple changes from Project 2. So please read the
following sections to get up-to-date! In particular, the Makefile has
been improved to make it easy to add individual module testbenches.

The [Project Specification](https://drive.google.com/file/d/1NnuJebAk416Z50KM0qWXN4E4uJEBZwAI/view?usp=sharing)
has more details on the overall structure of the project and deadlines.

To summarize the deadlines:
- PDR           is due by 2/11 @ 11:59p (ROB/RS + tb; high-level diagram; 3 interfaces)
- Milestone     is due by 3/12 @ 11:59p (mult_no_lsq functional without memory impl.)
- CDR           is due by 4/2  @ 11:59p (fully functional processor + RTL freeze)
- Report Draft  is due by 4/10 @ 11:59p
- Final Code    is due by 4/18 @ 11:59p (justify any updates since RTL freeze)
- Final Report  is due by 4/21 @ 11:59p 
- Oral Pres.    is during lecture, 4/21

## Autograder Submission

For autograder submissions, we have these requirements:

1.  Running `make simv` will compile a simulation executable for your
    processor

2.  Running `make syn_simv` will compile a synthesis executable for your
    processor

3.  Running `make my_program.out` and `make my_program.syn.out` will run
    a program by loading a memory file in `programs/my_program.mem` (as
    in project 2)

4.  This must write the correct memory output (lines starting with @@@)
    to stdout when it runs, and you must generate the same
    `output/my_program.out` file exactly as in project 2.

One note on memory ouput: when you start implementing your data cache,
you will need to ensure that any dirty cache values get written in the
memory output instead of the value from memory. This will require
exposing your cache at the top level and editing the
`show_final_mem_and_status` task in `test/testbenches/given/cpu_test.sv`.

### Submission Script

The script has two submission options for the final project:
- Simulation Only
- Simulation & Synthesis
Run `./submit.py` with one of the following options:
```text
  -h, --help   show the help message
  -y, --yes    Assume yes, you have pushed your main branch to github
  -s, --sim    Submit simulation only
```
- Running `./submit.py` alone will prompt you if you've pushed to github
- Running `./submit.py` without `-s` or `--sim` will additionally run synthesis

Remember, your design __must__ be synthesizable by the 4/18 deadline.

## Getting Started

Start the project by working on your first module, either the ReOrder
Buffer (ROB) or the Reservation Station (RS). Implement the modules in
files in the `verilog/src/` folder, and write testbenches for them in the
`test/testbenches/` folder. If you're writing the ROB, name these like:
`verilog/src/rob.sv` and `test/testbenches/rob_test.sv` which implement 
and test the module named `rob`.

Once you have something written, try running the new Makefile targets.
Add `rob` to the MODULES variable in the Makefile, then run
`make rob.out` to compile, run, and check the testbench. Do the same for
synthesis with `make rob.syn.out`. And finally, check your testbench's
coverage with `make rob.cov`

If you have your testbench output "@@@ Passed" and "@@@ Failed", then
you can use `make rob.pass rob.syn.pass` targets to print these in green
and red!

After you have the first module written and tested, keep going and work
towards a full processor. Try to pass the `mult_no_lsq` program for
milestone 2 -- you can verify this using the .wb file from project 2!

## Changes from Project 2

Many of the files from project 2 are still present or kept the same, but
there are a number of notable changes:

### New File Structure

#### The verilog directory is split into `inc/` and `src/`, which should contain your header and source files respectively.

- The `inc/` directory should have ALL if your __header__ files, and this folder 
CANNOT have subfolders of headers.
- The `src/` directory should have ALL of your __source__ files, and this folder
CAN have any depth of subfolders for organization. An example `combinational/`
subfolder is given, but you can reorganize however you desire.
- For testing individual modules, declare the dependency file paths as explained
in the Makefile. This can be done with the provided recursive glob function, 
by normal wildcard globbing, or by manually specifying the source file locations.
Headers do not need to be added here as they are automatically found in the `inc/`
directory by the script.

#### The `test/` directory now includes a `testbenches/` subfolder:

- You should add all of your testbenches here.
- You can create any depth of subfolders in the `testbenches/` directory for 
organization.
- You do not need to specify the file path for the testbench. If you follow
the naming criteria specified, the Makefile will automatically find it.
- Testbench names must be unique in the entire `testbenches/` hierarchy. Meaning, 
you cannot have two `rob_test.sv` testbenches in different subfolders. If you 
have multiple homonymous testbenches for experimentation, rename all but the 
target to something that does not meet the testbench name criteria specified.

#### Example file structure the Makefile can parse

```text
test/
└── testbenches/
    ├── <subfolder1>/
    │   ├── <file_tb1>.sv
    │   └── <file_tb2>.sv
    ├── <subfolder2>/
    │   └── <sub_subfolder1>/
    │       └── <file_tb3>.sv
    └── <file_tb4>.sv
verilog/
├── inc/
│   ├── <file_inc1>.sv
│   └── <file_inc2>.sv
└── src/
    ├── <subfolder1>/
    │   ├── <file1>.sv
    │   └── <file2>.sv
    ├── <subfolder2>/
    │   └── <sub_subfolder1>/
    │       └── <file1>.sv
    └── <file1>.sv
```

#### Testing the CPU

- The Makefile is currently setup to read in every source file in the `src/`
directory. If you have any source files that should __not__ be included, you can 
either rename them with any suffix extension (e.g. `file.sv.ignore`), or append 
the file to the `IGNORE` variable in the Makefile.

### The Makefile

The final project requires writing many modules, so we've added a new
section to the Makefile to compile arbitrary modules and testbenches.

To make it work for a module `mod`, create the files `verilog/src/mod.sv`
and `test/testbenches/mod_test.sv` which implement and test the module. If you
update the `MODULES` variable in the Makefile, then it will be able to
link the new targets below.

You do not need to have the module name match the file or testbench names,
but the `mod_name` listed for `MODULES` must match the `build/mod_name` and
the testbench must be named as `mod_name_test.sv`. While this flexibility
is given, be consistent and organized.

## How to use the Makefile

The most straightforward targets are `make mod.out`, `make mod.syn.out`
and `make mod.cov`, which run the module on its testbench in simulation,
run the module in synthesis, and print the coverage results for the
testbench.

We also now put the VCS compilation results in a `build/` folder so the
top level folder doesn't get too messy!

``` make
# ---- Module Testbenches ---- #
# NOTE: these require files like: 'verilog/src/rob.sv' and 'test/testbenches/rob_test.sv'
#       which implement and test the module: 'rob'
make <module>.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
make <module>.out    <- run the testbench (via build/<module>.simv)
make <module>.verdi  <- run in verdi (via build/<module>.simv)
make build/<module>.simv  <- compile the testbench executable

make <module>.syn.pass   <- greps for "@@@ Passed" or "@@@ Failed" in the output
make <module>.syn.out    <- run the synthesized module on the testbench
make <module>.syn.verdi  <- run in verdi (via <module>.syn.simv)
make synth/<module>.vg        <- synthesize the module
make build/<module>.syn.simv  <- compile the synthesized module with the testbench

# ---- module testbench coverage ---- #
make <module>.cov        <- print the coverage hierarchy report to the terminal
make <module>.cov.verdi  <- open the coverage report in verdi
make cov_report_<module>      <- run urg to create human readable coverage reports
make build/<module>.cov.vdb   <- runs the executable and makes a coverage output dir
make build/<module>.cov.simv  <- compiles a coverage executable for the testbench
```

#### `verilog/inc/sys_defs.svh`

`sys_defs` has received a few changes to prepare the final project:

1.  We've defined `CACHE_MODE`, affecting `test/mem.sv` and changing
    the way the processor interacts with memory.

2.  We've added a memory latency of 100ns, so memory is now much
    slower, and handling it with caching is necessary.

3.  There is a new 'Parameters' section giving you a starting point
    for some common macros that will likely need to be decided on like
    the size of the ROB, the number of functional units, etc.

3.  The ALU functions have separated the multiplier operations out

### CPU Files

The two files `verilog/src/cpu.sv` and `test/testbenches/given/cpu_test.sv` 
have been edited to comment-out or remove project 2 specific code, so you 
should be able to re-use them when you want to start integrating your 
modules into a full processor again.

## New Files

We've added an `icache` module in `verilog/src/icache.sv`. That file has
more comments explaining how it works, but the idea is it stores
memory's response tag until memory returns that tag with the data.

The file `verilog/src/combinational/psel_gen.sv` implements an incredibly 
efficient parameterized priority selector. Many tasks in superscalar 
processors come down to priority selection, so instead of writing manual 
for-loops, try to use this module. It is faster than any priority selector 
instructors are aware of (as far as my last conversation about it with Brehob).

As promised, we've also copied the multiplier from project 1 and moved
the `STAGES` definition to `sys_defs.svh` as `MULT_STAGES`.
This is set to 4 to start, but you can change it to 2 or 8 depending on
your processor's clock period.

## Running Programs
To run a program on the processor, run `make <my_program>.out`. This
will assemble a RISC-V `*.mem` file which will be loaded into `mem.sv`
by the testbench, and will also compile the processor and run the
program.

All of the "`<my_program>.abc`" targets are linked to do both the
executable compilation step and the `.mem` compilation steps if
necessary, so you can run each without needing to run anything else
first.

`make <my_program>.out` should be your main command for running
programs: it creates the `<my_program>.out`, `<my_program>.cpi`,
`<my_program>.wb`, and `<my_program>.ppln` output, CPI, writeback, and
pipeline output files in the `output/` directory. The output file
includes the processor status and the final state of memory, the CPI
file contains the total runtime and CPI calculation, the writeback file
is the list of writes to registers done by the program, and the pipeline
file is the state of each of the pipeline stages as the program is run.

The following Makefile rules are available to run programs on the
processor:

``` make
# ---- Program Execution ---- #
# These are your main commands for running programs and generating output
make <my_program>.out      <- run a program on build/cpu.simv and output *.out, *.cpi, and *.wb files
make <my_program>.syn.out  <- run a program on build/cpu.syn.simv and do the same
make simulate_all          <- run every program on simv at once (in parallel with -j)
make simulate_all_syn      <- run every program on syn_simv at once (in parallel with -j)

# ---- Executable Compilation ---- #
make simv      <- compiles build/cpu.simv from the CPU_TESTBENCH and CPU_SOURCES
make syn_simv  <- compiles syn_simv from CPU_TESTBENCH and CPU_SYNTH
make synth/cpu.vg  <- synthesize modules in CPU_SOURCES for use in syn_simv

# ---- Program Memory Compilation ---- #
# Programs to run are in the programs/ directory
make programs/<my_program>.mem  <- compile a program to a RISC-V memory file
make compile_all                <- compile every program at once (in parallel with -j)

# ---- Dump Files ---- #
make <my_program>.dump  <- disassembles compiled memory into RISC-V assembly dump files
make *.debug.dump       <- for a .c program, creates dump files with a debug flag
make programs/<my_program>.dump_x    <- numeric dump files use x0-x31 as register names
make programs/<my_program>.dump_abi  <- abi dump files use the abi register names (sp, a0, etc.)
make dump_all  <- create all dump files at once (in parallel with -j)

# ---- Verdi ---- #
make <my_program>.verdi     <- run a program in verdi via build/cpu.simv
make <my_program>.syn.verdi <- run a program in verdi via build/cpu.syn.simv

# ---- Cleanup ---- #
make clean            <- remove per-run files and compiled executable files
make nuke             <- remove all files created from make rules
make clean_run_files  <- remove per-run output files
make clean_exe        <- remove compiled executable files
make clean_synth      <- remove generated synthesis files
make clean_output     <- remove the entire output/ directory
make clean_programs   <- remove program memory and dump files
make clean_coverage   <- remove coverage file directories
```