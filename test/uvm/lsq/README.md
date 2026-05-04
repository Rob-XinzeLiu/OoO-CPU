# LSQ UVM Testbench Talking Points

This testbench verifies the split load queue and store queue at their real boundary:

- `store_queue` owns store allocation, store address/data readiness, retire-to-cache ordering, and forwarding metadata.
- `load_queue` owns load allocation, load address capture after RS issue, store-to-load forwarding, dcache request issue, dcache return, and CDB broadcast.
- The top-level harness connects SQ outputs directly into LQ forwarding inputs, with a simple cache boundary model driven by UVM.
- Dispatch is 2-wide and can accept any legal load/store combination in the two slots. Load execute, store execute, load issue, store commit, and load/store retire are modeled as one-wide interfaces.

## Interview Narrative

The key design rule is conservative load issue, but in this CPU that policy is enforced by the RS/issue side:

> A load can issue to dcache only after every older store has a known address.

The reason is memory ordering. If an older store has an unknown address, the load cannot prove that it is independent. In the full core, RS uses SQ address-ready metadata to avoid sending `load_execute_pack` for that load. Once RS releases the load, LQ records its address, checks older SQ entries for same-word conflicts, forwards from the youngest matching older store when possible, or sends the load to dcache when it is safe.

## UVM Structure

- `lsq_if.sv`: one-cycle interface for dispatch, execute, retire, cache return, and LQ/SQ observation.
- `lsq_tb_top.sv`: instantiates `store_queue` and `load_queue`, wires forwarding metadata, publishes the virtual interface.
- `lsq_pkg.sv`: package entry point; imports UVM/sys defs and includes the LSQ UVM class files in dependency order.
- `lsq_types.svh`: operation enum, agent config, sequence item, and monitor observation object.
- `lsq_sequences.svh`: base, directed, and smoke sequences.
- `lsq_driver.svh`, `lsq_monitor.svh`, `lsq_agent.svh`: agent internals; `lsq_agent` owns the sequencer, driver, and monitor.
- `lsq_scoreboard.svh`, `lsq_coverage.svh`, `lsq_env.svh`: environment internals; `lsq_env` owns the agent, scoreboard, and coverage collector.
- `lsq_tests.svh`: base, directed, and smoke tests.

## Functional Coverage

The coverage collector samples architectural LSQ events rather than raw signal toggles:

- load/store dispatch, including load/load, store/store, store/load, and load/store same-cycle pairs
- load execute and store execute
- load issue to dcache and dcache return
- load broadcast/forwarding
- one-wide load/store retire and ordered store commit
- visible older-store state during load execution
- same-word SQ match with forwarding data ready
- load/store `funct3` bins for byte, halfword, word, and unsigned loads
- LQ issue slot distribution

The default directed test reports functional coverage in `report_phase`; use `make lsq_uvm.cov` for the VCS coverage database/report flow.

## Directed Scenarios

1. Store dispatch, then younger load waits in LQ while the older store address is unknown.
   The sequence deliberately does not send `load_execute_pack` yet, modeling RS gating.

2. The older store later executes with same word address and ready data, then RS releases the load.
   The LQ should forward instead of issuing the load to dcache.

3. Independent load with no older store conflict.
   The LQ should issue to dcache and accept a cache return.

4. Store/load in the same dispatch group.
   Slot 0 store is older than slot 1 load, so RS waits for the store address before issuing the load.

5. The remaining 2-wide dispatch combinations: load/load, store/store, and load/store.
   These are allocation-only checks in the directed smoke path; execute, issue, and retire remain one-wide.

## Current Result

`make lsq_uvm.pass` compiles and runs the testbench. The scoreboard also contains an environment protocol check:

- `RS_LOAD_PROTOCOL`: the testbench/RS model tried to send `load_execute_pack` while an older store address was still unknown.
- `ONE_WIDE_PIPE_PROTOCOL`: stimulus tried to retire more than one load or store in a cycle.

That check is there to catch bad stimulus. It is not treated as an LSQ DUT failure in legal directed scenarios, because conservative issue is controlled before the LSQ.
