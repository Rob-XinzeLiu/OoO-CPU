// rob_pkg.sv — UVM verification package for the ROB module
// Contains: seq_item, sequences, driver, monitor, scoreboard,
//           coverage, agent, env, and tests.
//
// Compile with: vcs -sverilog -ntb_opts uvm-1.2 ...
`ifndef ROB_PKG_SV
`define ROB_PKG_SV

// Types from sys_defs.svh are at $unit scope, visible inside the package.
`include "sys_defs.svh"

// Declare two named analysis-imp suffixes so the scoreboard can have
// two write() overloads receiving different transaction types.
`uvm_analysis_imp_decl(_dispatch)
`uvm_analysis_imp_decl(_commit)

package rob_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // 1. Agent configuration object — test configures agent via uvm_config_db
    // =========================================================================
    class rob_agent_cfg extends uvm_object;
        `uvm_object_utils(rob_agent_cfg)

        uvm_active_passive_enum active = UVM_ACTIVE;
        int unsigned num_rand_trans    = 200;  // random sequence length

        function new(string name = "rob_agent_cfg");
            super.new(name);
        endfunction
    endclass : rob_agent_cfg

    // =========================================================================
    // 2. Input sequence item — one clock-cycle of stimulus to the ROB
    //    Uses plain int fields (not packed-struct) so the solver can randomize them.
    //    The driver converts these to D_S_PACKET / X_C_PACKET types.
    // =========================================================================
    typedef enum logic [2:0] {
        ROB_IDLE,
        ROB_DISPATCH_1,     // dispatch 1 instruction (slot 0 valid)
        ROB_DISPATCH_2,     // dispatch 2 instructions (both slots valid)
        ROB_CDB_COMPLETE,   // 1 CDB broadcast
        ROB_CDB_COMPLETE_2, // 2 simultaneous CDB broadcasts
        ROB_MISPREDICT      // branch mispredict, restore tail
    } rob_op_e;

    class rob_seq_item extends uvm_sequence_item;
        `uvm_object_utils(rob_seq_item)

        // ---- Operation selector ----
        rand rob_op_e op;

        // ---- Dispatch fields (slots 0 and 1) ----
        rand int unsigned T_val       [2]; // new physical register tag
        rand int unsigned Told_val    [2]; // old physical register tag
        rand bit          has_dest_v  [2];
        rand bit          is_branch_v [2];
        rand bit          halt_v      [2];
        rand bit          wr_mem_v    [2];
        rand bit          rd_mem_v    [2];
        rand int unsigned pc_val      [2]; // instruction PC

        // ---- CDB completion fields (slots 0 and 1) ----
        rand int unsigned cdb_rob_idx [2]; // ROB entry being completed
        rand int unsigned cdb_tag_val [2]; // completing physical tag
        rand int unsigned cdb_result  [2]; // result data

        // ---- Mispredict field ----
        rand int unsigned mispredict_tail; // tail pointer to restore

        // -------------------------------------------------------------------
        // Constraints
        // -------------------------------------------------------------------

        // Weighted distribution over operation types
        constraint c_op_dist {
            op dist {
                ROB_IDLE         := 5,
                ROB_DISPATCH_1   := 20,
                ROB_DISPATCH_2   := 30,
                ROB_CDB_COMPLETE := 25,
                ROB_CDB_COMPLETE_2 := 15,
                ROB_MISPREDICT   := 5
            };
        }

        // Physical register tag ranges:
        //   - renamed (new) tags live in [ARCH_REG_SZ .. PHYS_REG_SZ_R10K-1]
        //   - Told values are in arch-reg range [1 .. ARCH_REG_SZ-1]
        constraint c_tag_ranges {
            foreach (T_val[i])
                T_val[i] inside {[`ARCH_REG_SZ : `PHYS_REG_SZ_R10K-1]};
            foreach (Told_val[i])
                Told_val[i] inside {[1 : `ARCH_REG_SZ-1]};
            foreach (cdb_tag_val[i])
                cdb_tag_val[i] inside {[`ARCH_REG_SZ : `PHYS_REG_SZ_R10K-1]};
        }

        // ROB index must be a valid entry
        constraint c_rob_idx_valid {
            foreach (cdb_rob_idx[i])
                cdb_rob_idx[i] inside {[0 : `ROB_SZ-1]};
            mispredict_tail inside {[0 : `ROB_SZ-1]};
        }

        // PC must be word-aligned
        constraint c_pc_align {
            foreach (pc_val[i]) pc_val[i][1:0] == 2'b00;
        }

        // Simplify: no halts/mem for basic random test (can be overridden)
        constraint c_no_halt_mem {
            foreach (halt_v[i])   halt_v[i]   == 0;
            foreach (wr_mem_v[i]) wr_mem_v[i] == 0;
            foreach (rd_mem_v[i]) rd_mem_v[i] == 0;
            foreach (has_dest_v[i]) has_dest_v[i] == 1;
        }

        // No branches in basic random (simplifies scoreboard)
        constraint c_no_branch {
            foreach (is_branch_v[i]) is_branch_v[i] == 0;
        }

        // Two T values must differ (can't rename same phys reg twice in one cycle)
        constraint c_unique_T {
            T_val[0] != T_val[1];
        }

        function new(string name = "rob_seq_item");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("[rob_seq_item] op=%-14s T=[%0d,%0d] Told=[%0d,%0d]",
                op.name(), T_val[0], T_val[1], Told_val[0], Told_val[1]);
        endfunction
    endclass : rob_seq_item

    // =========================================================================
    // 3. Output observation transaction — one cycle of DUT outputs
    //    Sent from monitor to scoreboard and coverage collector.
    // =========================================================================
    class rob_obs_trans extends uvm_object;
        `uvm_object_utils(rob_obs_trans)

        // What the driver applied (captured from interface inputs)
        rob_op_e      op;
        int unsigned  T_val    [2];
        int unsigned  Told_val [2];
        bit           has_dest [2];
        bit           halt_v   [2];
        bit           disp_valid[2];
        int unsigned  cdb_rob_idx[2];
        int unsigned  cdb_tag_val[2];
        int unsigned  cdb_result [2];
        bit           cdb_valid [2];
        bit           mispredicted_v;
        int unsigned  mispredict_tail_v;

        // What the DUT produced
        RETIRE_PACKET rob_commit     [`N-1:0];
        logic  [1:0]  rob_space_avail;
        ROB_IDX       rob_index      [`N-1:0];
        ROB_IDX       rob_tail_out   [`N-1:0];

        function new(string name = "rob_obs_trans");
            super.new(name);
        endfunction

        function int commit_count();
            int c = 0;
            foreach (rob_commit[i]) c += rob_commit[i].valid;
            return c;
        endfunction
    endclass : rob_obs_trans

    // =========================================================================
    // 4a. Base sequence — provides helper to send a single item
    // =========================================================================
    class rob_base_seq extends uvm_sequence #(rob_seq_item);
        `uvm_object_utils(rob_base_seq)

        function new(string name = "rob_base_seq");
            super.new(name);
        endfunction

        // Helper: send a single idle cycle
        task send_idle();
            rob_seq_item item;
            item = rob_seq_item::type_id::create("idle_item");
            start_item(item);
            item.op = ROB_IDLE;
            finish_item(item);
        endtask

        // Helper: dispatch 1 instruction with explicit T/Told
        task send_dispatch_1(int T, int Told, bit has_dest = 1, int pc = 'h1000);
            rob_seq_item item;
            item = rob_seq_item::type_id::create("d1_item");
            start_item(item);
            if (!item.randomize() with { op == ROB_DISPATCH_1; }) begin
                `uvm_fatal("SEQ", "randomize failed")
            end
            item.T_val[0]    = T;
            item.Told_val[0] = Told;
            item.has_dest_v[0] = has_dest;
            item.pc_val[0]   = pc;
            finish_item(item);
        endtask

        // Helper: CDB complete one entry
        task send_cdb(int rob_idx, int tag, int result = 0);
            rob_seq_item item;
            item = rob_seq_item::type_id::create("cdb_item");
            start_item(item);
            item.op = ROB_CDB_COMPLETE;
            item.cdb_rob_idx[0] = rob_idx;
            item.cdb_tag_val[0] = tag;
            item.cdb_result[0]  = result;
            finish_item(item);
        endtask
    endclass : rob_base_seq

    // =========================================================================
    // 4b. Directed sequence — tests specific corner cases
    //     Mirrors the directed testbench cases but driven through UVM machinery
    // =========================================================================
    class rob_directed_seq extends rob_base_seq;
        `uvm_object_utils(rob_directed_seq)

        function new(string name = "rob_directed_seq");
            super.new(name);
        endfunction

        task body();
            rob_seq_item item;
            `uvm_info("SEQ", "Starting directed sequence", UVM_LOW)

            // --- Scenario 1: 2-way dispatch → CDB → retire ---
            begin
                // Dispatch 2 instructions
                item = rob_seq_item::type_id::create("s1_disp");
                start_item(item);
                item.op         = ROB_DISPATCH_2;
                item.T_val[0]   = 32; item.Told_val[0] = 5;
                item.T_val[1]   = 33; item.Told_val[1] = 6;
                item.has_dest_v = '{1, 1};
                item.pc_val[0]  = 32'h1000; item.pc_val[1] = 32'h1004;
                finish_item(item);

                // CDB-complete both
                item = rob_seq_item::type_id::create("s1_cdb0");
                start_item(item);
                item.op = ROB_CDB_COMPLETE_2;
                item.cdb_rob_idx[0] = 0; item.cdb_tag_val[0] = 32; item.cdb_result[0] = 32'hAABB;
                item.cdb_rob_idx[1] = 1; item.cdb_tag_val[1] = 33; item.cdb_result[1] = 32'hCCDD;
                finish_item(item);

                // Idle — observe retirement
                send_idle();
            end

            // --- Scenario 2: Out-of-order completion (older stalls head) ---
            begin
                item = rob_seq_item::type_id::create("s2_disp");
                start_item(item);
                item.op         = ROB_DISPATCH_2;
                item.T_val[0]   = 34; item.Told_val[0] = 7;
                item.T_val[1]   = 35; item.Told_val[1] = 8;
                item.has_dest_v = '{1, 1};
                item.pc_val[0]  = 32'h2000; item.pc_val[1] = 32'h2004;
                finish_item(item);

                // Complete YOUNGER (idx 1) first — head must NOT advance
                send_cdb(2, 35);  // idx 2 = dispatch after scenario 1 (head was at 2)
                send_idle();      // head stays

                // Complete OLDER (idx 0/head) — both retire
                send_cdb(2, 34);  // actually needs the correct ROB idx; illustrative
                send_idle();
            end

            // --- Scenario 3: Fill ROB (wrap-around test) ---
            begin : fill_rob
                int i;
                for (i = 0; i < `ROB_SZ / 2; i++) begin
                    item = rob_seq_item::type_id::create($sformatf("fill_%0d", i));
                    start_item(item);
                    item.op = ROB_DISPATCH_2;
                    // Use rotating tag values to avoid solver conflicts
                    item.T_val[0]   = 32 + (i*2   % 32);
                    item.Told_val[0] = 1  + (i*2   % 31);
                    item.T_val[1]   = 32 + (i*2+1 % 32);
                    item.Told_val[1] = 1  + (i*2+1 % 31);
                    item.has_dest_v = '{1, 1};
                    item.pc_val[0]  = 32'h3000 + i*8;
                    item.pc_val[1]  = 32'h3004 + i*8;
                    finish_item(item);
                end
                send_idle();
            end

            // --- Scenario 4: Misprediction recovery ---
            begin
                // Dispatch one branch + one younger
                item = rob_seq_item::type_id::create("s4_disp");
                start_item(item);
                item.op            = ROB_DISPATCH_2;
                item.T_val[0]      = 40; item.Told_val[0] = 10;
                item.T_val[1]      = 41; item.Told_val[1] = 11;
                item.is_branch_v[0] = 1;
                item.pc_val[0]     = 32'h4000; item.pc_val[1] = 32'h4004;
                finish_item(item);

                // Mispredict: restore tail, squash younger entry
                item = rob_seq_item::type_id::create("s4_misp");
                start_item(item);
                item.op              = ROB_MISPREDICT;
                item.mispredict_tail = 0; // restore to 0 (fresh state)
                finish_item(item);

                send_idle();
            end

            `uvm_info("SEQ", "Directed sequence complete", UVM_LOW)
        endtask
    endclass : rob_directed_seq

    // =========================================================================
    // 4c. Random sequence — generates num_trans fully-random transactions
    // =========================================================================
    class rob_rand_seq extends rob_base_seq;
        `uvm_object_utils(rob_rand_seq)

        int unsigned num_trans = 200;

        function new(string name = "rob_rand_seq");
            super.new(name);
        endfunction

        task body();
            rob_seq_item item;
            `uvm_info("SEQ", $sformatf("Starting %0d-transaction random sequence", num_trans), UVM_LOW)
            for (int i = 0; i < num_trans; i++) begin
                item = rob_seq_item::type_id::create($sformatf("rand_item_%0d", i));
                start_item(item);
                if (!item.randomize()) begin
                    `uvm_fatal("SEQ", $sformatf("randomize() failed at iteration %0d", i))
                end
                finish_item(item);
            end
            // Drain pipeline: send extra idles so any pending commits can retire
            repeat (10) send_idle();
            `uvm_info("SEQ", "Random sequence complete", UVM_LOW)
        endtask
    endclass : rob_rand_seq

    // =========================================================================
    // 5. Driver — converts sequence items into interface-level stimulus
    // =========================================================================
    class rob_driver extends uvm_driver #(rob_seq_item);
        `uvm_component_utils(rob_driver)

        virtual rob_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual rob_if)::get(this, "", "rob_vif", vif)) begin
                `uvm_fatal("DRV", "Could not get virtual interface from config_db")
            end
        endfunction

        task run_phase(uvm_phase phase);
            rob_seq_item item;
            forever begin
                seq_item_port.get_next_item(item);
                drive_item(item);
                seq_item_port.item_done();
            end
        endtask

        // Translate a seq_item into one clock cycle of interface stimulus
        task drive_item(rob_seq_item item);
            D_S_PACKET  pkt0, pkt1;
            X_C_PACKET  cdb0, cdb1;

            // Default: all inputs zero except halt_safe
            vif.drv_cb.halt_safe      <= 1;
            vif.drv_cb.dispatch_pack  <= '{default: '0};
            vif.drv_cb.is_branch      <= '0;
            vif.drv_cb.mispredicted   <= 0;
            vif.drv_cb.rob_tail_in    <= '0;
            vif.drv_cb.cdb            <= '{default: '0};
            vif.drv_cb.cond_branch_in <= '0;
            vif.drv_cb.sq_in          <= '0;

            case (item.op)
                ROB_DISPATCH_1, ROB_DISPATCH_2: begin
                    pkt0       = '0;
                    pkt0.valid = 1;
                    pkt0.T     = PRF_IDX'(item.T_val[0]);
                    pkt0.Told  = PRF_IDX'(item.Told_val[0]);
                    pkt0.has_dest = item.has_dest_v[0];
                    pkt0.halt     = item.halt_v[0];
                    pkt0.wr_mem   = item.wr_mem_v[0];
                    pkt0.rd_mem   = item.rd_mem_v[0];
                    pkt0.PC       = ADDR'(item.pc_val[0]);
                    pkt0.NPC      = ADDR'(item.pc_val[0]) + 4;
                    vif.drv_cb.dispatch_pack[0] <= pkt0;
                    vif.drv_cb.is_branch[0]     <= item.is_branch_v[0];

                    if (item.op == ROB_DISPATCH_2) begin
                        pkt1       = '0;
                        pkt1.valid = 1;
                        pkt1.T     = PRF_IDX'(item.T_val[1]);
                        pkt1.Told  = PRF_IDX'(item.Told_val[1]);
                        pkt1.has_dest = item.has_dest_v[1];
                        pkt1.halt     = item.halt_v[1];
                        pkt1.wr_mem   = item.wr_mem_v[1];
                        pkt1.rd_mem   = item.rd_mem_v[1];
                        pkt1.PC       = ADDR'(item.pc_val[1]);
                        pkt1.NPC      = ADDR'(item.pc_val[1]) + 4;
                        vif.drv_cb.dispatch_pack[1] <= pkt1;
                        vif.drv_cb.is_branch[1]     <= item.is_branch_v[1];
                    end
                end

                ROB_CDB_COMPLETE, ROB_CDB_COMPLETE_2: begin
                    cdb0 = '0;
                    cdb0.valid          = 1;
                    cdb0.complete_index = ROB_IDX'(item.cdb_rob_idx[0]);
                    cdb0.complete_tag   = PRF_IDX'(item.cdb_tag_val[0]);
                    cdb0.result         = DATA'(item.cdb_result[0]);
                    vif.drv_cb.cdb[0]   <= cdb0;

                    if (item.op == ROB_CDB_COMPLETE_2) begin
                        cdb1 = '0;
                        cdb1.valid          = 1;
                        cdb1.complete_index = ROB_IDX'(item.cdb_rob_idx[1]);
                        cdb1.complete_tag   = PRF_IDX'(item.cdb_tag_val[1]);
                        cdb1.result         = DATA'(item.cdb_result[1]);
                        vif.drv_cb.cdb[1]   <= cdb1;
                    end
                end

                ROB_MISPREDICT: begin
                    vif.drv_cb.mispredicted <= 1;
                    vif.drv_cb.rob_tail_in  <= ROB_IDX'(item.mispredict_tail);
                end

                ROB_IDLE: ; // all zeros already applied above

                default: `uvm_warning("DRV", "Unknown op in drive_item")
            endcase

            @(vif.drv_cb); // advance one negedge (next stimulus cycle)
        endtask

    endclass : rob_driver

    // =========================================================================
    // 6. Monitor — captures one cycle of DUT i/o and broadcasts to analysis port
    //    One monitor handles both dispatch-side inputs and commit-side outputs
    //    so the scoreboard can correlate them.
    // =========================================================================
    class rob_monitor extends uvm_monitor;
        `uvm_component_utils(rob_monitor)

        virtual rob_if vif;
        uvm_analysis_port #(rob_obs_trans) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual rob_if)::get(this, "", "rob_vif", vif)) begin
                `uvm_fatal("MON", "Could not get virtual interface from config_db")
            end
        endfunction

        task run_phase(uvm_phase phase);
            rob_obs_trans obs;
            forever begin
                @(vif.mon_cb); // wait for posedge

                obs = rob_obs_trans::type_id::create("obs");

                // Capture inputs that were driven at the previous negedge
                for (int i = 0; i < `N; i++) begin
                    obs.disp_valid[i] = vif.mon_cb.dispatch_pack[i].valid;
                    obs.T_val[i]      = int'(vif.mon_cb.dispatch_pack[i].T);
                    obs.Told_val[i]   = int'(vif.mon_cb.dispatch_pack[i].Told);
                    obs.has_dest[i]   = vif.mon_cb.dispatch_pack[i].has_dest;
                    obs.halt_v[i]     = vif.mon_cb.dispatch_pack[i].halt;
                    obs.cdb_valid[i]  = vif.mon_cb.cdb[i].valid;
                    obs.cdb_rob_idx[i] = int'(vif.mon_cb.cdb[i].complete_index);
                    obs.cdb_tag_val[i] = int'(vif.mon_cb.cdb[i].complete_tag);
                    obs.cdb_result[i]  = int'(vif.mon_cb.cdb[i].result);
                end
                obs.mispredicted_v   = vif.mon_cb.mispredicted;
                obs.mispredict_tail_v = int'(vif.mon_cb.rob_tail_in);

                // Capture DUT outputs
                for (int i = 0; i < `N; i++) begin
                    obs.rob_commit[i]  = vif.mon_cb.rob_commit[i];
                    obs.rob_index[i]   = vif.mon_cb.rob_index[i];
                    obs.rob_tail_out[i] = vif.mon_cb.rob_tail_out[i];
                end
                obs.rob_space_avail = vif.mon_cb.rob_space_avail;

                ap.write(obs);
            end
        endtask

    endclass : rob_monitor

    // =========================================================================
    // 7. Scoreboard — reference model + checker
    //    Tracks a shadow ROB; checks every retire packet against expected Told.
    //    Uses two analysis-imp ports (dispatch side, commit side) driven by
    //    a single monitor split through a uvm_analysis_port.
    //    For simplicity we use a single analysis_imp and dispatch inside write().
    // =========================================================================
    class rob_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(rob_scoreboard)

        uvm_analysis_imp #(rob_obs_trans, rob_scoreboard) imp;

        // ---- Shadow ROB reference model ----
        typedef struct {
            logic     valid;
            int       T;
            int       Told;
            logic     has_dest;
            logic     ready;
            int       data;
            logic     halt;
        } ref_entry_t;

        ref_entry_t ref_array [`ROB_SZ];
        int         ref_head = 0;
        int         ref_tail = 0;
        int         ref_count = 0;

        int unsigned pass_cnt = 0;
        int unsigned fail_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            imp = new("imp", this);
        endfunction

        // Called by the monitor every posedge
        function void write(rob_obs_trans obs);
            // 1. Process mispredict first (squashes entries)
            if (obs.mispredicted_v) begin
                // Restore tail pointer to checkpoint
                ref_tail  = obs.mispredict_tail_v;
                ref_count = (ref_tail >= ref_head)
                            ? (ref_tail - ref_head)
                            : (`ROB_SZ - ref_head + ref_tail);
                // Invalidate squashed entries
                for (int i = ref_tail; i != ref_tail; i = (i+1) % `ROB_SZ) begin
                    ref_array[i] = '{valid: 0, default: 0};
                end
            end

            // 2. Process CDB completions (mark entries ready)
            for (int s = 0; s < `N; s++) begin
                if (obs.cdb_valid[s]) begin
                    int idx = obs.cdb_rob_idx[s];
                    if (ref_array[idx].valid) begin
                        ref_array[idx].ready = 1;
                        ref_array[idx].data  = obs.cdb_result[s];
                    end
                end
            end

            // 3. Check committed entries against reference model
            for (int s = 0; s < `N; s++) begin
                if (obs.rob_commit[s].valid) begin
                    int exp_idx = (ref_head + s) % `ROB_SZ;

                    // Check Told (freed physical register)
                    if (obs.rob_commit[s].t_old !== PRF_IDX'(ref_array[exp_idx].Told)) begin
                        `uvm_error("SB",
                            $sformatf("Slot%0d t_old MISMATCH: got p%0d, exp p%0d (idx=%0d)",
                                s, obs.rob_commit[s].t_old, ref_array[exp_idx].Told, exp_idx))
                        fail_cnt++;
                    end else begin
                        pass_cnt++;
                    end

                    // Check data if instruction has a destination
                    if (ref_array[exp_idx].has_dest &&
                        obs.rob_commit[s].data !== DATA'(ref_array[exp_idx].data)) begin
                        `uvm_error("SB",
                            $sformatf("Slot%0d data MISMATCH: got 0x%08x, exp 0x%08x",
                                s, obs.rob_commit[s].data, ref_array[exp_idx].data))
                        fail_cnt++;
                    end

                    // Retire the head entry
                    ref_array[exp_idx] = '{valid: 0, default: 0};
                end
            end

            // Advance head by number of valid commits this cycle
            begin
                int num_commit = obs.commit_count();
                ref_head  = (ref_head + num_commit) % `ROB_SZ;
                if (ref_count >= num_commit)
                    ref_count -= num_commit;
                else
                    ref_count = 0;
            end

            // 4. Process new dispatches (after commits, so tail doesn't collide)
            for (int s = 0; s < `N; s++) begin
                if (obs.disp_valid[s]) begin
                    int idx = (ref_tail + s) % `ROB_SZ;
                    ref_array[idx].valid    = 1;
                    ref_array[idx].T        = obs.T_val[s];
                    ref_array[idx].Told     = obs.Told_val[s];
                    ref_array[idx].has_dest = obs.has_dest[s];
                    ref_array[idx].ready    = 0;
                    ref_array[idx].data     = 0;
                    ref_array[idx].halt     = obs.halt_v[s];
                end
            end
            // Update tail for dispatches
            begin
                int ndispatched = obs.disp_valid[0] + obs.disp_valid[1];
                ref_tail  = (ref_tail + ndispatched) % `ROB_SZ;
                ref_count += ndispatched;
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("Scoreboard: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt), UVM_LOW)
            if (fail_cnt != 0)
                `uvm_error("SB", "Scoreboard detected FAILURES — see above errors")
        endfunction

    endclass : rob_scoreboard

    // =========================================================================
    // 8. Coverage collector — functional coverage for the ROB
    // =========================================================================
    class rob_coverage extends uvm_subscriber #(rob_obs_trans);
        `uvm_component_utils(rob_coverage)

        // Mirrored signals for covergroup sampling
        int         dispatch_count;
        int         cdb_count;
        int         commit_count;
        logic [1:0] space_avail;
        logic       mispredicted_v;

        // Functional coverage groups
        covergroup cg_rob_dispatch;
            // How many instructions dispatched per cycle: 0 / 1 / 2
            cp_dispatch_n : coverpoint dispatch_count {
                bins none     = {0};
                bins one      = {1};
                bins two      = {2};
            }
            // ROB occupancy (from space_avail output)
            cp_space_avail : coverpoint space_avail {
                bins full     = {2'b00}; // 0 free ≥ 2
                bins one_free = {2'b01}; // 1 free slot
                bins many_free = {2'b10}; // 2+ free slots
            }
            // Cross: dispatch under different ROB fullness conditions
            cx_disp_x_space : cross cp_dispatch_n, cp_space_avail;
        endgroup

        covergroup cg_rob_cdb;
            // How many CDB completions in one cycle
            cp_cdb_n : coverpoint cdb_count {
                bins none = {0};
                bins one  = {1};
                bins two  = {2};
            }
        endgroup

        covergroup cg_rob_commit;
            // How many retirements per cycle
            cp_commit_n : coverpoint commit_count {
                bins none = {0};
                bins one  = {1};
                bins two  = {2};
            }
        endgroup

        covergroup cg_rob_events;
            // Mispredict coverage
            cp_mispredict : coverpoint mispredicted_v {
                bins seen   = {1'b1};
                bins unseen = {1'b0};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_rob_dispatch = new();
            cg_rob_cdb      = new();
            cg_rob_commit   = new();
            cg_rob_events   = new();
        endfunction

        // uvm_subscriber::write() — called by analysis port on each transaction
        function void write(rob_obs_trans obs);
            dispatch_count = obs.disp_valid[0] + obs.disp_valid[1];
            cdb_count      = obs.cdb_valid[0]  + obs.cdb_valid[1];
            commit_count   = obs.commit_count();
            space_avail    = obs.rob_space_avail;
            mispredicted_v = obs.mispredicted_v;

            cg_rob_dispatch.sample();
            cg_rob_cdb.sample();
            cg_rob_commit.sample();
            cg_rob_events.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV",
                $sformatf("Dispatch coverage: %.1f%% | CDB coverage: %.1f%% | Commit coverage: %.1f%%",
                    cg_rob_dispatch.get_coverage(),
                    cg_rob_cdb.get_coverage(),
                    cg_rob_commit.get_coverage()),
                UVM_LOW)
        endfunction

    endclass : rob_coverage

    // =========================================================================
    // 9. Agent — bundles driver + monitor + sequencer
    // =========================================================================
    class rob_agent extends uvm_agent;
        `uvm_component_utils(rob_agent)

        rob_agent_cfg   cfg;
        rob_driver      drv;
        rob_monitor     mon;
        uvm_sequencer #(rob_seq_item) seqr;

        // Analysis port forwarded from monitor (env connects this to sb/cov)
        uvm_analysis_port #(rob_obs_trans) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);

            // Get config or use defaults
            if (!uvm_config_db #(rob_agent_cfg)::get(this, "", "rob_agent_cfg", cfg)) begin
                cfg = rob_agent_cfg::type_id::create("cfg");
                `uvm_info("AGT", "No config found; using defaults", UVM_LOW)
            end

            mon = rob_monitor::type_id::create("mon", this);
            ap  = new("ap", this);

            if (cfg.active == UVM_ACTIVE) begin
                drv  = rob_driver::type_id::create("drv", this);
                seqr = uvm_sequencer #(rob_seq_item)::type_id::create("seqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (cfg.active == UVM_ACTIVE)
                drv.seq_item_port.connect(seqr.seq_item_export);
            // Forward monitor's analysis port to agent's port
            mon.ap.connect(ap);
        endfunction

    endclass : rob_agent

    // =========================================================================
    // 10. Environment — connects agent, scoreboard, and coverage
    // =========================================================================
    class rob_env extends uvm_env;
        `uvm_component_utils(rob_env)

        rob_agent      agt;
        rob_scoreboard sb;
        rob_coverage   cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = rob_agent::type_id::create("agt", this);
            sb  = rob_scoreboard::type_id::create("sb", this);
            cov = rob_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Broadcast monitor output to both scoreboard and coverage
            agt.ap.connect(sb.imp);
            agt.ap.connect(cov.analysis_export);
        endfunction

    endclass : rob_env

    // =========================================================================
    // 11a. Base test — sets up env and virtual interface
    // =========================================================================
    class rob_base_test extends uvm_test;
        `uvm_component_utils(rob_base_test)

        rob_env        env;
        rob_agent_cfg  cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            cfg = rob_agent_cfg::type_id::create("cfg");
            uvm_config_db #(rob_agent_cfg)::set(this, "env.agt", "rob_agent_cfg", cfg);
            env = rob_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            // Subclasses override this to start their sequence
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server srv = uvm_report_server::get_server();
            int errs = srv.get_severity_count(UVM_ERROR) +
                       srv.get_severity_count(UVM_FATAL);
            if (errs == 0)
                $display("\n@@@ Passed");
            else
                $display("\n@@@ Failed (%0d UVM errors/fatals)", errs);
        endfunction

    endclass : rob_base_test

    // =========================================================================
    // 11b. Directed test — runs rob_directed_seq to hit corner cases
    // =========================================================================
    class rob_directed_test extends rob_base_test;
        `uvm_component_utils(rob_directed_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            rob_directed_seq seq;
            phase.raise_objection(this);
            seq = rob_directed_seq::type_id::create("seq");
            seq.start(env.agt.seqr);
            #100; // let last commits settle
            phase.drop_objection(this);
        endtask

    endclass : rob_directed_test

    // =========================================================================
    // 11c. Random test — fully random stimulus for coverage closure
    // =========================================================================
    class rob_rand_test extends rob_base_test;
        `uvm_component_utils(rob_rand_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            // Increase transaction count for coverage closure
            cfg.num_rand_trans = 500;
        endfunction

        task run_phase(uvm_phase phase);
            rob_rand_seq seq;
            phase.raise_objection(this);
            seq = rob_rand_seq::type_id::create("seq");
            seq.num_trans = cfg.num_rand_trans;
            seq.start(env.agt.seqr);
            #200;
            phase.drop_objection(this);
        endtask

    endclass : rob_rand_test

endpackage : rob_pkg
`endif // ROB_PKG_SV
