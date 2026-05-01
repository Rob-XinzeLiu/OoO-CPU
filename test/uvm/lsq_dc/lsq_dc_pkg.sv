// lsq_dc_pkg.sv — UVM package for combined LQ + SQ + DCache verification
//
// Key scenarios covered:
//   1. Load dispatch → execute (addr fill) → dcache hit  → LQ CDB broadcast
//   2. Load dispatch → execute (addr fill) → dcache miss → refill → CDB
//   3. Store dispatch → execute (addr+data) → retire     → sq_out to dcache
//   4. Store-to-load forwarding: older store same addr → LQ gets data from SQ
//   5. LQ / SQ full (space_available = 0)
//   6. Mispredict recovery
`ifndef LSQ_DC_PKG_SV
`define LSQ_DC_PKG_SV

`include "sys_defs.svh"

package lsq_dc_pkg;
    import uvm_pkg::*;
    import sys_defs_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // 1. Operation type
    // =========================================================================
    typedef enum logic [3:0] {
        OP_IDLE,
        OP_DISPATCH_LOAD,    // dispatch 1 load (slot 0)
        OP_DISPATCH_STORE,   // dispatch 1 store (slot 0)
        OP_DISPATCH_BOTH,    // dispatch load (slot 0) + store (slot 1) simultaneously
        OP_EXECUTE_LOAD,     // fill load address into LQ entry
        OP_EXECUTE_STORE,    // fill store address + data into SQ entry
        OP_RETIRE_STORE,     // retire 1 store: commit to dcache via sq_out
        OP_RETIRE_LOAD,      // retire 1 load: free LQ head entry
        OP_MEMORY_REFILL,    // memory returns a cache line (simulate MSHR response)
        OP_MISPREDICT        // branch mispredict recovery
    } lsq_dc_op_e;

    // =========================================================================
    // 2. Sequence item
    // =========================================================================
    class lsq_dc_seq_item extends uvm_sequence_item;
        `uvm_object_utils(lsq_dc_seq_item)

        rand lsq_dc_op_e op;

        // ---- Dispatch fields ----
        rand int unsigned dest_tag_v [2];   // load destination physical reg
        rand int unsigned rob_idx_v  [2];
        rand int unsigned funct3_v   [2];   // memory access size (LW=2, SW=2...)

        // ---- Execute-load ----
        rand int unsigned ld_addr_v;        // byte address for load
        rand int unsigned ld_lq_idx_v;      // which LQ entry receives address
        rand int unsigned ld_dest_tag_v;    // dest tag (echoed in LQ_PACKET)
        rand int unsigned ld_gen_v;         // generation counter
        rand int unsigned ld_funct3_v;      // LB/LH/LW/LBU/LHU

        // ---- Execute-store ----
        rand int unsigned st_addr_v;        // byte address for store
        rand int unsigned st_data_v;        // store data
        rand int unsigned st_sq_idx_v;      // which SQ entry
        rand int unsigned st_rob_idx_v;
        rand int unsigned st_funct3_v;      // SB/SH/SW

        // ---- Retire-store ----
        rand int unsigned ret_sq_idx_v;
        rand int unsigned ret_addr_v;
        rand int unsigned ret_data_v;
        rand int unsigned ret_rob_idx_v;
        rand int unsigned ret_funct3_v;

        // ---- Mispredict ----
        rand int unsigned misp_lq_tail_v;
        rand int unsigned misp_sq_tail_v;

        // ---- Memory refill (simulate memory bus returning a cache line to MSHR) ----
        rand MEM_BLOCK    mem_data_v;         // 64-bit cache line from memory
        rand bit  [3:0]   mem_tag_v;          // transaction tag (matched by MSHR)

        // -------------------------------------------------------------------
        // Constraints
        // -------------------------------------------------------------------
        constraint c_op_dist {
            op dist {
                OP_IDLE           := 5,
                OP_DISPATCH_LOAD  := 20,
                OP_DISPATCH_STORE := 20,
                OP_DISPATCH_BOTH  := 10,
                OP_EXECUTE_LOAD   := 15,
                OP_EXECUTE_STORE  := 10,
                OP_RETIRE_STORE   := 10,
                OP_RETIRE_LOAD    := 5,
                OP_MEMORY_REFILL  := 4,
                OP_MISPREDICT     := 1
            };
        }

        constraint c_addr_align_by_size {
            (op == OP_EXECUTE_LOAD && ld_funct3_v inside {3'b001, 3'b101}) -> ld_addr_v[0] == 1'b0;
            (op == OP_EXECUTE_LOAD && ld_funct3_v == 3'b010)               -> ld_addr_v[1:0] == 2'b00;
            (op == OP_EXECUTE_STORE && st_funct3_v == 3'b001)              -> st_addr_v[0] == 1'b0;
            (op == OP_EXECUTE_STORE && st_funct3_v == 3'b010)              -> st_addr_v[1:0] == 2'b00;
            (ret_funct3_v == 3'b001)                                       -> ret_addr_v[0] == 1'b0;
            (ret_funct3_v == 3'b010)                                       -> ret_addr_v[1:0] == 2'b00;
        }

        // Keep addresses in a small range to maximise alias/forwarding hits
        constraint c_addr_range {
            ld_addr_v  inside {[32'h0000_0000 : 32'h0000_03FF]};
            st_addr_v  inside {[32'h0000_0000 : 32'h0000_03FF]};
            ret_addr_v inside {[32'h0000_0000 : 32'h0000_03FF]};
        }

        constraint c_funct3 {
            foreach (funct3_v[i]) funct3_v[i] inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            ld_funct3_v inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            st_funct3_v inside {3'b000, 3'b001, 3'b010};
            ret_funct3_v inside {3'b000, 3'b001, 3'b010};
            (op == OP_DISPATCH_LOAD)  -> funct3_v[0] inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            (op == OP_DISPATCH_STORE) -> funct3_v[0] inside {3'b000, 3'b001, 3'b010};
            (op == OP_DISPATCH_BOTH)  -> funct3_v[0] inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            (op == OP_DISPATCH_BOTH)  -> funct3_v[1] inside {3'b000, 3'b001, 3'b010};
        }

        constraint c_dest_tags {
            foreach (dest_tag_v[i])
                dest_tag_v[i] inside {[`ARCH_REG_SZ : `PHYS_REG_SZ_R10K-1]};
            ld_dest_tag_v inside {[`ARCH_REG_SZ : `PHYS_REG_SZ_R10K-1]};
        }

        constraint c_queue_indices {
            foreach (rob_idx_v[i]) rob_idx_v[i] inside {[0:`ROB_SZ-1]};
            ld_lq_idx_v    inside {[0:`LQ_SZ-1]};
            st_sq_idx_v    inside {[0:`SQ_SZ-1]};
            ret_sq_idx_v   inside {[0:`SQ_SZ-1]};
            misp_lq_tail_v inside {[0:`LQ_SZ-1]};
            misp_sq_tail_v inside {[0:`SQ_SZ-1]};
        }

        constraint c_mem_tag {
            mem_tag_v inside {[1:14]}; // 0 is sentinel "no outstanding transaction"
        }

        function new(string name = "lsq_dc_seq_item");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("[lsq_dc_seq_item] op=%-18s", op.name());
        endfunction
    endclass : lsq_dc_seq_item

    // =========================================================================
    // 3. Observation transaction (monitor → scoreboard / coverage)
    // =========================================================================
    class lsq_dc_obs_trans extends uvm_object;
        `uvm_object_utils(lsq_dc_obs_trans)

        // What was applied
        lsq_dc_op_e op;
        logic [`N-1:0] is_load_obs, is_store_obs;
        ADDR           ld_addr_obs, st_addr_obs;
        DATA           st_data_obs;
        int            ld_lq_idx_obs, st_sq_idx_obs;
        PRF_IDX        ld_dest_tag_obs;
        logic          ld_exec_valid_obs, st_exec_valid_obs;
        PRF_IDX        dest_tag_in_obs [`N-1:0];
        ROB_IDX        rob_index_obs   [`N-1:0];
        logic [2:0]    load_funct3_obs, store_funct3_obs;
        logic          miss_ret_obs;      // MSHR miss_returned observed
        logic          mispredicted_obs;

        // What the DUTs produced
        LQ_IDX  lq_index_out [`N-1:0];
        SQ_IDX  sq_index_out [`N-1:0];
        logic [1:0] lq_space_obs, sq_space_obs;
        logic       cdb_req_obs;
        LQ_PACKET   lq_out_obs;
        miss_request_t miss_req_obs;
        logic          miss_req_valid_obs;
        completed_mshr_t com_miss_req_obs;
        logic          dcache_accept_load_obs, dcache_accept_store_obs;

        function new(string name = "lsq_dc_obs_trans");
            super.new(name);
        endfunction
    endclass : lsq_dc_obs_trans

    // =========================================================================
    // 4a. Base sequence
    // =========================================================================
    class lsq_dc_base_seq extends uvm_sequence #(lsq_dc_seq_item);
        `uvm_object_utils(lsq_dc_base_seq)

        function new(string name = "lsq_dc_base_seq");
            super.new(name);
        endfunction

        task send_idle(int n = 1);
            lsq_dc_seq_item item;
            repeat (n) begin
                item = lsq_dc_seq_item::type_id::create("idle");
                start_item(item);
                item.op = OP_IDLE;
                finish_item(item);
            end
        endtask

        task dispatch_load(int dest_tag, int rob_idx, int funct3 = 2);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("dl");
            start_item(item);
            item.op          = OP_DISPATCH_LOAD;
            item.dest_tag_v[0] = dest_tag;
            item.rob_idx_v[0]  = rob_idx;
            item.funct3_v[0]   = funct3;
            finish_item(item);
        endtask

        task dispatch_store(int rob_idx, int funct3 = 2);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("ds");
            start_item(item);
            item.op          = OP_DISPATCH_STORE;
            item.rob_idx_v[0] = rob_idx;
            item.funct3_v[0]  = funct3;
            finish_item(item);
        endtask

        task execute_load(int lq_idx, int addr, int dest_tag, int gen = 0, int funct3 = 2);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("el");
            start_item(item);
            item.op           = OP_EXECUTE_LOAD;
            item.ld_lq_idx_v  = lq_idx;
            item.ld_addr_v    = addr;
            item.ld_dest_tag_v = dest_tag;
            item.ld_gen_v     = gen;
            item.ld_funct3_v  = funct3;
            finish_item(item);
        endtask

        task execute_store(int sq_idx, int rob_idx, int addr, int data, int funct3 = 2);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("es");
            start_item(item);
            item.op           = OP_EXECUTE_STORE;
            item.st_sq_idx_v  = sq_idx;
            item.st_rob_idx_v = rob_idx;
            item.st_addr_v    = addr;
            item.st_data_v    = data;
            item.st_funct3_v  = funct3;
            finish_item(item);
        endtask

        task retire_store(int sq_idx, int rob_idx, int addr, int data, int funct3 = 2);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("ret_st");
            start_item(item);
            item.op            = OP_RETIRE_STORE;
            item.ret_sq_idx_v  = sq_idx;
            item.ret_rob_idx_v = rob_idx;
            item.ret_addr_v    = addr;
            item.ret_data_v    = data;
            item.ret_funct3_v  = funct3;
            finish_item(item);
        endtask

        // Simulate memory returning a cache line to MSHR.
        // mem_tag must match an outstanding MSHR transaction tag.
        task memory_refill(MEM_BLOCK data, int mem_tag = 1);
            lsq_dc_seq_item item;
            item = lsq_dc_seq_item::type_id::create("refill");
            start_item(item);
            item.op        = OP_MEMORY_REFILL;
            item.mem_data_v = data;
            item.mem_tag_v  = mem_tag[3:0];
            finish_item(item);
        endtask
    endclass : lsq_dc_base_seq

    // =========================================================================
    // 4b. Directed scenario sequence
    // =========================================================================
    class lsq_dc_directed_seq extends lsq_dc_base_seq;
        `uvm_object_utils(lsq_dc_directed_seq)

        function new(string name = "lsq_dc_directed_seq");
            super.new(name);
        endfunction

        task body();
            `uvm_info("SEQ", "Starting LSQ+Dcache directed sequence", UVM_LOW)

            // ------------------------------------------------------------------
            // Scenario 1: Store then Load to SAME address → forwarding expected
            //   cycle 0: dispatch store (SQ[0], rob=0)
            //   cycle 1: dispatch load  (LQ[0], rob=1, dest=p32)
            //   cycle 2: execute store  (SQ[0], addr=0x100, data=0xDEAD_BEEF)
            //   cycle 3: execute load   (LQ[0], addr=0x100) → should forward from SQ
            //   cycle 4: observe lq_out.valid, data should be 0xDEAD_BEEF
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 1: store-to-load forwarding", UVM_LOW)
            dispatch_store(.rob_idx(0));
            dispatch_load (.dest_tag(32), .rob_idx(1));
            send_idle(1);
            execute_store(.sq_idx(0), .rob_idx(0), .addr(32'h0000_0100), .data(32'hDEAD_BEEF));
            execute_load (.lq_idx(0), .addr(32'h0000_0100), .dest_tag(32));
            send_idle(3);  // wait for forwarding to resolve

            // ------------------------------------------------------------------
            // Scenario 2: Load with no matching store → goes to dcache (miss)
            //   cycle 0: dispatch load (LQ[1], dest=p33)
            //   cycle 1: execute load (addr=0x200) → miss_request expected
            //   cycle 2: send memory refill
            //   cycle 3: observe lq_out.valid with returned data
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 2: cache miss path", UVM_LOW)
            dispatch_load (.dest_tag(33), .rob_idx(2));
            send_idle(1);
            // Queue the line data before the miss is issued; the driver memory
            // responder will attach it to the next MSHR transaction tag.
            begin
                MEM_BLOCK refill_blk;
                refill_blk = '0;
                refill_blk.dbbl_level = 64'hCCCC_DDDD_AAAA_BBBB;
                memory_refill(.data(refill_blk), .mem_tag(1));
            end
            execute_load  (.lq_idx(1), .addr(32'h0000_0200), .dest_tag(33));
            send_idle(2);  // let miss_request fire
            send_idle(3);  // dcache refills → lq_out should fire

            // ------------------------------------------------------------------
            // Scenario 2b: Load the same line again → should hit in dcache
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 2b: cache hit after refill", UVM_LOW)
            dispatch_load (.dest_tag(34), .rob_idx(3));
            send_idle(1);
            execute_load  (.lq_idx(2), .addr(32'h0000_0200), .dest_tag(34));
            send_idle(3);

            // ------------------------------------------------------------------
            // Scenario 2c: Byte/half unsigned loads with nonzero offsets
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 2c: byte/half offset loads", UVM_LOW)
            dispatch_load (.dest_tag(35), .rob_idx(4), .funct3(3'b100)); // LBU
            send_idle(1);
            execute_load  (.lq_idx(3), .addr(32'h0000_0201), .dest_tag(35), .funct3(3'b100));
            send_idle(2);

            dispatch_load (.dest_tag(36), .rob_idx(5), .funct3(3'b101)); // LHU
            send_idle(1);
            execute_load  (.lq_idx(4), .addr(32'h0000_0202), .dest_tag(36), .funct3(3'b101));
            send_idle(3);

            // ------------------------------------------------------------------
            // Scenario 3: Retire a store → dcache accepts it
            //   Assumes store from scenario 1 still pending retirement
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 3: store retirement to dcache", UVM_LOW)
            retire_store(.sq_idx(0), .rob_idx(0),
                         .addr(32'h0000_0100), .data(32'hDEAD_BEEF));
            send_idle(2);

            // ------------------------------------------------------------------
            // Scenario 4: Mispredict recovery
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 4: mispredict recovery", UVM_LOW)
            begin
                lsq_dc_seq_item item;
                item = lsq_dc_seq_item::type_id::create("misp");
                start_item(item);
                item.op             = OP_MISPREDICT;
                item.misp_lq_tail_v = 0;
                item.misp_sq_tail_v = 0;
                finish_item(item);
                send_idle(2);
            end

            // ------------------------------------------------------------------
            // Scenario 5: Fill LQ to check space_available
            // ------------------------------------------------------------------
            `uvm_info("SEQ", "Scenario 5: fill LQ", UVM_LOW)
            for (int i = 0; i < `LQ_SZ; i++) begin
                dispatch_load(.dest_tag(32 + i % 32), .rob_idx(i % `ROB_SZ));
            end
            send_idle(2);

            `uvm_info("SEQ", "Directed sequence complete", UVM_LOW)
        endtask
    endclass : lsq_dc_directed_seq

    // =========================================================================
    // 4c. Minimal smoke sequence
    // =========================================================================
    class lsq_dc_smoke_seq extends lsq_dc_base_seq;
        `uvm_object_utils(lsq_dc_smoke_seq)

        function new(string name = "lsq_dc_smoke_seq");
            super.new(name);
        endfunction

        task body();
            MEM_BLOCK refill_blk;
            `uvm_info("SEQ", "Starting LSQ+Dcache smoke sequence", UVM_LOW)

            refill_blk = '0;
            refill_blk.dbbl_level = 64'h1234_5678_CAFE_BABE;

            dispatch_load(.dest_tag(32), .rob_idx(0));
            send_idle(1);
            memory_refill(.data(refill_blk), .mem_tag(1));
            execute_load(.lq_idx(0), .addr(32'h0000_0080), .dest_tag(32));
            send_idle(8);

            `uvm_info("SEQ", "Smoke sequence complete", UVM_LOW)
        endtask
    endclass : lsq_dc_smoke_seq

    // =========================================================================
    // 4d. Random sequence
    // =========================================================================
    class lsq_dc_rand_seq extends lsq_dc_base_seq;
        `uvm_object_utils(lsq_dc_rand_seq)
        int unsigned num_trans = 300;

        typedef struct {
            bit valid;
            bit executed;
            int lq_idx;
            int rob_idx;
            int dest_tag;
            int funct3;
            int addr;
            bit [`SQ_SZ-1:0] older_store_mask;
        } rand_load_t;

        typedef struct {
            bit valid;
            bit executed;
            int sq_idx;
            int rob_idx;
            int funct3;
            int addr;
            int data;
        } rand_store_t;

        rand_load_t  loads [`LQ_SZ];
        rand_store_t stores[`SQ_SZ];
        int unsigned lq_tail, lq_head, lq_count;
        int unsigned sq_tail, sq_head, sq_count;
        int unsigned rob_next, dest_next;

        function new(string name = "lsq_dc_rand_seq");
            super.new(name);
        endfunction

        function automatic int rand_load_funct3();
            int choices[5] = '{3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            return choices[$urandom_range(0, 4)];
        endfunction

        function automatic int rand_store_funct3();
            int choices[3] = '{3'b000, 3'b001, 3'b010};
            return choices[$urandom_range(0, 2)];
        endfunction

        function automatic int rand_aligned_addr(input int funct3);
            int addr;
            addr = $urandom_range(0, 32'h3ff);
            case (funct3[1:0])
                2'b01: addr[0]   = 1'b0;    // halfword aligned
                2'b10: addr[1:0] = 2'b00;   // word aligned
                default: ;
            endcase
            return addr;
        endfunction

        function automatic bit older_store_addrs_ready(input rand_load_t ld);
            older_store_addrs_ready = 1'b1;
            for (int i = 0; i < `SQ_SZ; i++) begin
                if (ld.older_store_mask[i] && stores[i].valid && !stores[i].executed)
                    older_store_addrs_ready = 1'b0;
            end
        endfunction

        function automatic bit has_executable_store();
            has_executable_store = 1'b0;
            foreach (stores[i]) begin
                if (stores[i].valid && !stores[i].executed)
                    has_executable_store = 1'b1;
            end
        endfunction

        function automatic bit has_executable_load();
            has_executable_load = 1'b0;
            foreach (loads[i]) begin
                if (loads[i].valid && !loads[i].executed && older_store_addrs_ready(loads[i]))
                    has_executable_load = 1'b1;
            end
        endfunction

        function automatic bit [`SQ_SZ-1:0] current_store_mask();
            current_store_mask = '0;
            foreach (stores[i]) begin
                if (stores[i].valid)
                    current_store_mask[i] = 1'b1;
            end
        endfunction

        task dispatch_random_load();
            int idx;
            idx = lq_tail % `LQ_SZ;
            loads[idx].valid            = 1'b1;
            loads[idx].executed         = 1'b0;
            loads[idx].lq_idx           = idx;
            loads[idx].rob_idx          = rob_next % `ROB_SZ;
            loads[idx].dest_tag         = `ARCH_REG_SZ + (dest_next % (`PHYS_REG_SZ_R10K - `ARCH_REG_SZ));
            loads[idx].funct3           = rand_load_funct3();
            loads[idx].addr             = rand_aligned_addr(loads[idx].funct3);
            loads[idx].older_store_mask = current_store_mask();

            dispatch_load(loads[idx].dest_tag, loads[idx].rob_idx, loads[idx].funct3);
            lq_tail = (lq_tail + 1) % `LQ_SZ;
            lq_count++;
            rob_next++;
            dest_next++;
        endtask

        task dispatch_random_store();
            int idx;
            idx = sq_tail % `SQ_SZ;
            stores[idx].valid    = 1'b1;
            stores[idx].executed = 1'b0;
            stores[idx].sq_idx   = idx;
            stores[idx].rob_idx  = rob_next % `ROB_SZ;
            stores[idx].funct3   = rand_store_funct3();
            stores[idx].addr     = rand_aligned_addr(stores[idx].funct3);
            stores[idx].data     = $urandom();

            dispatch_store(stores[idx].rob_idx, stores[idx].funct3);
            sq_tail = (sq_tail + 1) % `SQ_SZ;
            sq_count++;
            rob_next++;
        endtask

        task execute_random_store();
            int candidates[$];
            int idx;
            foreach (stores[i]) begin
                if (stores[i].valid && !stores[i].executed)
                    candidates.push_back(i);
            end
            if (candidates.size() == 0) begin
                send_idle(1);
                return;
            end
            idx = candidates[$urandom_range(0, candidates.size() - 1)];
            execute_store(stores[idx].sq_idx, stores[idx].rob_idx,
                          stores[idx].addr, stores[idx].data, stores[idx].funct3);
            stores[idx].executed = 1'b1;
        endtask

        task execute_random_load();
            int candidates[$];
            int idx;
            MEM_BLOCK refill_blk;
            foreach (loads[i]) begin
                if (loads[i].valid && !loads[i].executed && older_store_addrs_ready(loads[i]))
                    candidates.push_back(i);
            end
            if (candidates.size() == 0) begin
                send_idle(1);
                return;
            end
            idx = candidates[$urandom_range(0, candidates.size() - 1)];

            refill_blk.dbbl_level = {$urandom(), $urandom()};
            memory_refill(refill_blk, 1);
            execute_load(loads[idx].lq_idx, loads[idx].addr, loads[idx].dest_tag,
                         0, loads[idx].funct3);
            loads[idx].executed = 1'b1;
        endtask

        task retire_random_store();
            int idx;
            idx = sq_head % `SQ_SZ;
            if (sq_count != 0 && stores[idx].valid && stores[idx].executed) begin
                retire_store(stores[idx].sq_idx, stores[idx].rob_idx,
                             stores[idx].addr, stores[idx].data, stores[idx].funct3);
                stores[idx].valid = 1'b0;
                sq_head = (sq_head + 1) % `SQ_SZ;
                sq_count--;
            end else begin
                send_idle(1);
            end
        endtask

        task retire_random_load();
            int idx;
            idx = lq_head % `LQ_SZ;
            if (lq_count != 0 && loads[idx].valid && loads[idx].executed) begin
                lsq_dc_seq_item item;
                item = lsq_dc_seq_item::type_id::create("ret_ld");
                start_item(item);
                item.op = OP_RETIRE_LOAD;
                finish_item(item);
                loads[idx].valid = 1'b0;
                lq_head = (lq_head + 1) % `LQ_SZ;
                lq_count--;
            end else begin
                send_idle(1);
            end
        endtask

        task body();
            int action;
            loads = '{default:'0};
            stores = '{default:'0};
            lq_tail = 0;
            lq_head = 0;
            lq_count = 0;
            sq_tail = 0;
            sq_head = 0;
            sq_count = 0;
            rob_next = 0;
            dest_next = 0;

            `uvm_info("SEQ", $sformatf("Starting %0d-transaction stateful random sequence", num_trans), UVM_LOW)
            for (int i = 0; i < num_trans; i++) begin
                action = $urandom_range(0, 99);
                if (action < 20 && lq_count < `LQ_SZ) begin
                    dispatch_random_load();
                end else if (action < 38 && sq_count < `SQ_SZ) begin
                    dispatch_random_store();
                end else if (action < 58 && has_executable_store()) begin
                    execute_random_store();
                end else if (action < 78 && has_executable_load()) begin
                    execute_random_load();
                end else if (action < 88 && sq_count != 0) begin
                    retire_random_store();
                end else if (action < 96 && lq_count != 0) begin
                    retire_random_load();
                end else begin
                    send_idle(1);
                end
            end

            for (int i = 0; i < `SQ_SZ; i++) begin
                if (has_executable_store())
                    execute_random_store();
            end
            for (int i = 0; i < `LQ_SZ; i++) begin
                if (has_executable_load())
                    execute_random_load();
            end
            send_idle(10);
        endtask
    endclass : lsq_dc_rand_seq

    // =========================================================================
    // 5. Driver
    // =========================================================================
    class lsq_dc_driver extends uvm_driver #(lsq_dc_seq_item);
        `uvm_component_utils(lsq_dc_driver)

        virtual lsq_dc_if vif;
        MEM_BLOCK refill_q[$];
        MEM_TAG next_mem_tag = 4'd1;

        typedef struct {
            MEM_TAG   tag;
            MEM_BLOCK data;
            int       delay;
        } pending_mem_return_t;
        pending_mem_return_t pending_returns[$];

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual lsq_dc_if)::get(this, "", "lsq_dc_vif", vif))
                `uvm_fatal("DRV", "Cannot get lsq_dc_vif from config_db")
        endfunction

        task run_phase(uvm_phase phase);
            lsq_dc_seq_item item;
            fork
                memory_responder();
            join_none
            forever begin
                seq_item_port.get_next_item(item);
                drive_item(item);
                seq_item_port.item_done();
            end
        endtask

        function automatic MEM_BLOCK default_line(input ADDR addr);
            MEM_BLOCK line;
            line = '0;
            line.word_level[0] = DATA'(addr ^ 32'hA5A5_1000);
            line.word_level[1] = DATA'(addr ^ 32'h5A5A_2000);
            return line;
        endfunction

        task memory_responder();
            pending_mem_return_t ret;
            MEM_BLOCK line;
            vif.drv_cb.mem2proc_transaction_tag <= '0;
            vif.drv_cb.mem2proc_data_tag        <= '0;
            vif.drv_cb.mem2proc_data            <= '0;

            forever begin
                @(vif.drv_cb);

                vif.drv_cb.mem2proc_transaction_tag <= '0;
                vif.drv_cb.mem2proc_data_tag        <= '0;
                vif.drv_cb.mem2proc_data            <= '0;

                if (vif.mshr2mem_command == MEM_LOAD && vif.mshr2mem_addr < `MEM_SIZE_IN_BYTES) begin
                    if (refill_q.size() != 0) line = refill_q.pop_front();
                    else                      line = default_line(vif.mshr2mem_addr);

                    ret.tag   = next_mem_tag;
                    ret.data  = line;
                    ret.delay = 2;
                    pending_returns.push_back(ret);

                    vif.drv_cb.mem2proc_transaction_tag <= next_mem_tag;
                    next_mem_tag = (next_mem_tag == MEM_TAG'(`NUM_MEM_TAGS)) ? MEM_TAG'(1) : MEM_TAG'(next_mem_tag + 1'b1);
                end

                foreach (pending_returns[i]) begin
                    pending_returns[i].delay--;
                end

                if (pending_returns.size() != 0 && pending_returns[0].delay <= 0) begin
                    ret = pending_returns.pop_front();
                    vif.drv_cb.mem2proc_data_tag <= ret.tag;
                    vif.drv_cb.mem2proc_data     <= ret.data;
                end
            end
        endtask

        task drive_item(lsq_dc_seq_item item);
            // Default: clear all stimulus
            vif.drv_cb.is_load           <= '0;
            vif.drv_cb.is_store          <= '0;
            vif.drv_cb.is_branch         <= '0;
            vif.drv_cb.inst_in           <= '{default: '0};
            vif.drv_cb.rob_index         <= '{default: '0};
            vif.drv_cb.dest_tag_in       <= '{default: '0};
            vif.drv_cb.load_execute_pack <= '0;
            vif.drv_cb.store_execute_pack<= '0;
            vif.drv_cb.store_retire_pack <= '{default: '0};
            vif.drv_cb.load_retire_valid <= 0;
            vif.drv_cb.load_retire_num   <= 0;
            vif.drv_cb.mispredicted      <= 0;
            vif.drv_cb.BS_lq_tail_in     <= '0;
            vif.drv_cb.BS_sq_tail_in     <= '0;
            vif.drv_cb.mshr_grant        <= 1;
            vif.drv_cb.wb_grant          <= 1;

            case (item.op)

                OP_DISPATCH_LOAD: begin
                    vif.drv_cb.inst_in[0].i.opcode <= 7'b000_0011;
                    vif.drv_cb.inst_in[0].i.funct3 <= item.funct3_v[0][2:0];
                    vif.drv_cb.is_load[0]    <= 1;
                    vif.drv_cb.dest_tag_in[0]<= PRF_IDX'(item.dest_tag_v[0]);
                    vif.drv_cb.rob_index[0]  <= ROB_IDX'(item.rob_idx_v[0]);
                end

                OP_DISPATCH_STORE: begin
                    vif.drv_cb.inst_in[0].s.opcode <= 7'b010_0011;
                    vif.drv_cb.inst_in[0].s.funct3 <= item.funct3_v[0][2:0];
                    vif.drv_cb.is_store[0]  <= 1;
                    vif.drv_cb.rob_index[0] <= ROB_IDX'(item.rob_idx_v[0]);
                end

                OP_DISPATCH_BOTH: begin
                    vif.drv_cb.inst_in[0].i.opcode <= 7'b000_0011;
                    vif.drv_cb.inst_in[0].i.funct3 <= item.funct3_v[0][2:0];
                    vif.drv_cb.inst_in[1].s.opcode <= 7'b010_0011;
                    vif.drv_cb.inst_in[1].s.funct3 <= item.funct3_v[1][2:0];
                    vif.drv_cb.is_load[0]    <= 1;
                    vif.drv_cb.is_store[1]   <= 1;
                    vif.drv_cb.dest_tag_in[0]<= PRF_IDX'(item.dest_tag_v[0]);
                    vif.drv_cb.rob_index[0]  <= ROB_IDX'(item.rob_idx_v[0]);
                    vif.drv_cb.rob_index[1]  <= ROB_IDX'(item.rob_idx_v[1]);
                end

                OP_EXECUTE_LOAD: begin
                    vif.drv_cb.load_execute_pack.valid      <= 1;
                    vif.drv_cb.load_execute_pack.addr       <= ADDR'(item.ld_addr_v);
                    vif.drv_cb.load_execute_pack.lq_index   <= LQ_IDX'(item.ld_lq_idx_v);
                    vif.drv_cb.load_execute_pack.dest_tag   <= PRF_IDX'(item.ld_dest_tag_v);
                    vif.drv_cb.load_execute_pack.generation <= item.ld_gen_v[1:0];
                    vif.drv_cb.load_execute_pack.funct3     <= item.ld_funct3_v[2:0];
                end

                OP_EXECUTE_STORE: begin
                    vif.drv_cb.store_execute_pack.valid     <= 1;
                    vif.drv_cb.store_execute_pack.addr      <= ADDR'(item.st_addr_v);
                    vif.drv_cb.store_execute_pack.data      <= DATA'(item.st_data_v);
                    vif.drv_cb.store_execute_pack.sq_index  <= SQ_IDX'(item.st_sq_idx_v);
                    vif.drv_cb.store_execute_pack.rob_index <= ROB_IDX'(item.st_rob_idx_v);
                    vif.drv_cb.store_execute_pack.funct3    <= item.st_funct3_v[2:0];
                end

                OP_RETIRE_STORE: begin
                    vif.drv_cb.store_retire_pack[0].valid     <= 1;
                    vif.drv_cb.store_retire_pack[0].addr      <= ADDR'(item.ret_addr_v);
                    vif.drv_cb.store_retire_pack[0].data      <= DATA'(item.ret_data_v);
                    vif.drv_cb.store_retire_pack[0].sq_index  <= SQ_IDX'(item.ret_sq_idx_v);
                    vif.drv_cb.store_retire_pack[0].rob_index <= ROB_IDX'(item.ret_rob_idx_v);
                    vif.drv_cb.store_retire_pack[0].funct3    <= item.ret_funct3_v[2:0];
                end

                OP_RETIRE_LOAD: begin
                    vif.drv_cb.load_retire_valid <= 1;
                    vif.drv_cb.load_retire_num   <= 2'd1;
                end

                OP_MEMORY_REFILL: begin
                    // Queue data for the next MSHR memory request. The background
                    // responder assigns the actual transaction tag and returns data
                    // a few cycles later.
                    refill_q.push_back(item.mem_data_v);
                end

                OP_MISPREDICT: begin
                    vif.drv_cb.mispredicted  <= 1;
                    vif.drv_cb.BS_lq_tail_in <= LQ_IDX'(item.misp_lq_tail_v);
                    vif.drv_cb.BS_sq_tail_in <= SQ_IDX'(item.misp_sq_tail_v);
                end

                OP_IDLE: ; // defaults already applied

                default: `uvm_warning("DRV", "Unknown op")
            endcase

            @(vif.drv_cb); // advance one negedge
        endtask

    endclass : lsq_dc_driver

    // =========================================================================
    // 6. Monitor
    // =========================================================================
    class lsq_dc_monitor extends uvm_monitor;
        `uvm_component_utils(lsq_dc_monitor)

        virtual lsq_dc_if vif;
        uvm_analysis_port #(lsq_dc_obs_trans) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual lsq_dc_if)::get(this, "", "lsq_dc_vif", vif))
                `uvm_fatal("MON", "Cannot get lsq_dc_vif from config_db")
        endfunction

        task run_phase(uvm_phase phase);
            lsq_dc_obs_trans obs;
            forever begin
                @(vif.mon_cb);
                obs = lsq_dc_obs_trans::type_id::create("obs");

                // Capture inputs applied at previous negedge
                obs.is_load_obs   = vif.mon_cb.is_load;
                obs.is_store_obs  = vif.mon_cb.is_store;
                obs.ld_addr_obs   = vif.mon_cb.load_execute_pack.addr;
                obs.st_addr_obs   = vif.mon_cb.store_execute_pack.addr;
                obs.st_data_obs   = vif.mon_cb.store_execute_pack.data;
                obs.ld_exec_valid_obs = vif.mon_cb.load_execute_pack.valid;
                obs.st_exec_valid_obs = vif.mon_cb.store_execute_pack.valid;
                obs.ld_lq_idx_obs = int'(vif.mon_cb.load_execute_pack.lq_index);
                obs.st_sq_idx_obs = int'(vif.mon_cb.store_execute_pack.sq_index);
                obs.ld_dest_tag_obs = vif.mon_cb.load_execute_pack.dest_tag;
                obs.load_funct3_obs  = vif.mon_cb.load_execute_pack.funct3;
                obs.store_funct3_obs = vif.mon_cb.store_execute_pack.funct3;
                obs.miss_ret_obs      = vif.mon_cb.miss_returned;
                obs.mispredicted_obs  = vif.mon_cb.mispredicted;
                // Completed MSHR response is observed for end-to-end refill checks.

                // Capture DUT outputs
                for (int i = 0; i < `N; i++) begin
                    obs.lq_index_out[i] = vif.mon_cb.lq_index[i];
                    obs.sq_index_out[i] = vif.mon_cb.sq_index[i];
                    obs.dest_tag_in_obs[i] = vif.mon_cb.dest_tag_in[i];
                    obs.rob_index_obs[i]   = vif.mon_cb.rob_index[i];
                end
                obs.lq_space_obs            = vif.mon_cb.lq_space_available;
                obs.sq_space_obs            = vif.mon_cb.sq_space_available;
                obs.cdb_req_obs             = vif.mon_cb.cdb_req_load;
                obs.lq_out_obs.valid        = vif.mon_cb.lq_out.valid;
                obs.lq_out_obs.addr         = vif.mon_cb.lq_out.addr;
                obs.lq_out_obs.data         = vif.mon_cb.lq_out.data;
                obs.lq_out_obs.funct3       = vif.mon_cb.lq_out.funct3;
                obs.lq_out_obs.lq_index     = vif.mon_cb.lq_out.lq_index;
                obs.lq_out_obs.rob_index    = vif.mon_cb.lq_out.rob_index;
                obs.lq_out_obs.dest_tag     = vif.mon_cb.lq_out.dest_tag;
                obs.lq_out_obs.generation   = vif.mon_cb.lq_out.generation;

                obs.miss_req_obs.valid             = vif.mon_cb.miss_request.valid;
                obs.miss_req_obs.miss_req_address  = vif.mon_cb.miss_request.miss_req_address;
                obs.miss_req_obs.miss_req_tag      = vif.mon_cb.miss_request.miss_req_tag;
                obs.miss_req_obs.miss_req_set      = vif.mon_cb.miss_request.miss_req_set;
                obs.miss_req_obs.miss_req_offset   = vif.mon_cb.miss_request.miss_req_offset;
                obs.miss_req_obs.req_is_load       = vif.mon_cb.miss_request.req_is_load;
                obs.miss_req_obs.miss_req_size     = vif.mon_cb.miss_request.miss_req_size;
                obs.miss_req_obs.miss_req_unsigned = vif.mon_cb.miss_request.miss_req_unsigned;
                obs.miss_req_obs.miss_req_data     = vif.mon_cb.miss_request.miss_req_data;
                obs.miss_req_obs.lq_index          = vif.mon_cb.miss_request.lq_index;
                obs.miss_req_obs.generation        = vif.mon_cb.miss_request.generation;
                obs.miss_req_valid_obs      = vif.mon_cb.miss_request.valid;
                obs.com_miss_req_obs.valid             = vif.mon_cb.com_miss_req.valid;
                obs.com_miss_req_obs.dep_miss          = vif.mon_cb.com_miss_req.dep_miss;
                obs.com_miss_req_obs.miss_req_address  = vif.mon_cb.com_miss_req.miss_req_address;
                obs.com_miss_req_obs.miss_req_tag      = vif.mon_cb.com_miss_req.miss_req_tag;
                obs.com_miss_req_obs.miss_req_set      = vif.mon_cb.com_miss_req.miss_req_set;
                obs.com_miss_req_obs.miss_req_offset   = vif.mon_cb.com_miss_req.miss_req_offset;
                obs.com_miss_req_obs.req_is_load       = vif.mon_cb.com_miss_req.req_is_load;
                obs.com_miss_req_obs.miss_req_size     = vif.mon_cb.com_miss_req.miss_req_size;
                obs.com_miss_req_obs.miss_req_unsigned = vif.mon_cb.com_miss_req.miss_req_unsigned;
                obs.com_miss_req_obs.miss_req_data     = vif.mon_cb.com_miss_req.miss_req_data;
                obs.com_miss_req_obs.refill_data       = vif.mon_cb.com_miss_req.refill_data;
                obs.com_miss_req_obs.lq_index          = vif.mon_cb.com_miss_req.lq_index;
                obs.com_miss_req_obs.generation        = vif.mon_cb.com_miss_req.generation;
                obs.dcache_accept_load_obs  = vif.mon_cb.dcache_can_accept_load;
                obs.dcache_accept_store_obs = vif.mon_cb.dcache_can_accept_store;

                ap.write(obs);
            end
        endtask
    endclass : lsq_dc_monitor

    // =========================================================================
    // 7. Scoreboard — checks forwarding, cache miss generation, CDB broadcast
    // =========================================================================
    class lsq_dc_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(lsq_dc_scoreboard)

        uvm_analysis_imp #(lsq_dc_obs_trans, lsq_dc_scoreboard) imp;

        // ---- Shadow store queue: tracks recent stores for forwarding checks ----
        typedef struct {
            logic valid;
            ADDR  addr;
            DATA  data;
            int   sq_idx;
            logic addr_ready;
            logic data_ready;
            logic [2:0] funct3;
        } shadow_store_t;
        shadow_store_t shadow_sq [`SQ_SZ];

        // ---- Shadow load queue: pending loads and their expected data source ----
        typedef struct {
            logic   valid;
            ADDR    addr;
            PRF_IDX dest_tag;
            logic   expect_forward;  // 1 = should be satisfied via forwarding
            DATA    expected_data;   // data expected from store forwarding
            logic   expect_miss;
            logic   expect_refill;
            logic   expect_cache_hit;
            int     miss_age;
            ROB_IDX rob_index;
        } shadow_load_t;
        shadow_load_t shadow_lq [`LQ_SZ];
        MEM_BLOCK shadow_cache[BLOCK_ADDR];

        // ---- Counters ----
        int unsigned forward_checks   = 0;
        int unsigned forward_errors   = 0;
        int unsigned miss_req_seen    = 0;
        int unsigned cdb_broadcasts   = 0;
        int unsigned checks_pass      = 0;
        int unsigned miss_checks      = 0;
        int unsigned refill_checks    = 0;
        int unsigned cache_hit_checks = 0;
        int unsigned scoreboard_errors = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            imp = new("imp", this);
        endfunction

        function automatic DATA load_from_block(
            input MEM_BLOCK block,
            input logic [`DCACHE_OFFSET_BITS-1:0] offset,
            input logic [2:0] funct3
        );
            DATA data;
            logic [7:0] byte_val;
            logic [15:0] half_val;
            begin
                data = '0;
                case (funct3[1:0])
                    2'b00: begin
                        byte_val = block.byte_level[offset];
                        data = funct3[2] ? {24'b0, byte_val} : {{24{byte_val[7]}}, byte_val};
                    end
                    2'b01: begin
                        half_val = block.half_level[offset[`DCACHE_OFFSET_BITS-1:1]];
                        data = funct3[2] ? {16'b0, half_val} : {{16{half_val[15]}}, half_val};
                    end
                    2'b10: begin
                        data = block.word_level[offset[`DCACHE_OFFSET_BITS-1:2]];
                    end
                    default: data = '0;
                endcase
                return data;
            end
        endfunction

        function automatic BLOCK_ADDR line_key(input ADDR addr);
            return BLOCK_ADDR'(addr[31:`DCACHE_OFFSET_BITS]);
        endfunction

        function void write(lsq_dc_obs_trans obs);
            BLOCK_ADDR key;
            foreach (shadow_lq[i]) begin
                if (shadow_lq[i].valid && shadow_lq[i].expect_miss) begin
                    shadow_lq[i].miss_age++;
                    if (shadow_lq[i].miss_age > 20) begin
                        `uvm_error("SB",
                            $sformatf("Timeout waiting for miss/CDB for LQ[%0d] addr=0x%08x",
                                i, shadow_lq[i].addr))
                        shadow_lq[i].expect_miss = 0;
                        scoreboard_errors++;
                    end
                end
            end

            // 1. Track dispatched stores into shadow_sq (based on sq_index_out)
            for (int s = 0; s < `N; s++) begin
                if (obs.is_store_obs[s]) begin
                    int sq_i = int'(obs.sq_index_out[s]);
                    shadow_sq[sq_i].valid  = 1;
                    shadow_sq[sq_i].sq_idx = sq_i;
                    shadow_sq[sq_i].addr_ready = 0;
                    shadow_sq[sq_i].data_ready = 0;
                    // address/data not yet known at dispatch; filled during execute
                end
            end

            // 2. Track executed store: fill in address and data
            if (obs.st_exec_valid_obs) begin
                int sq_i = obs.st_sq_idx_obs;
                if (sq_i < `SQ_SZ) begin
                    shadow_sq[sq_i].valid = 1;
                    shadow_sq[sq_i].addr = obs.st_addr_obs;
                    shadow_sq[sq_i].data = obs.st_data_obs;
                    shadow_sq[sq_i].funct3 = obs.store_funct3_obs;
                    shadow_sq[sq_i].addr_ready = 1;
                    shadow_sq[sq_i].data_ready = 1;
                end
            end

            // 3. Track dispatched loads; check if any older store matches addr
            for (int s = 0; s < `N; s++) begin
                if (obs.is_load_obs[s]) begin
                    int lq_i = int'(obs.lq_index_out[s]);
                    shadow_lq[lq_i].valid   = 1;
                    shadow_lq[lq_i].dest_tag = obs.dest_tag_in_obs[s];
                    shadow_lq[lq_i].rob_index = obs.rob_index_obs[s];
                    // Address comes later at execute; no forwarding decision yet
                    shadow_lq[lq_i].expect_forward = 0;
                    shadow_lq[lq_i].expect_miss = 0;
                    shadow_lq[lq_i].expect_refill = 0;
                    shadow_lq[lq_i].expect_cache_hit = 0;
                    shadow_lq[lq_i].miss_age = 0;
                end
            end

            // 4. When execute-load fires: check for forwarding opportunity
            if (obs.ld_exec_valid_obs) begin
                int lq_i = obs.ld_lq_idx_obs;
                if (lq_i < `LQ_SZ && shadow_lq[lq_i].valid) begin
                    shadow_lq[lq_i].addr = obs.ld_addr_obs;
                    // Search shadow_sq for a matching addr (same word address)
                    for (int sq_i = `SQ_SZ - 1; sq_i >= 0; sq_i--) begin
                        if (!shadow_lq[lq_i].expect_forward &&
                            shadow_sq[sq_i].valid &&
                            shadow_sq[sq_i].addr_ready &&
                            shadow_sq[sq_i].data_ready &&
                            shadow_sq[sq_i].funct3[1:0] == 2'b10 &&
                            obs.load_funct3_obs[1:0] == 2'b10 &&
                            shadow_sq[sq_i].addr == obs.ld_addr_obs) begin
                            shadow_lq[lq_i].expect_forward = 1;
                            shadow_lq[lq_i].expected_data  = shadow_sq[sq_i].data;
                        end
                    end
                    if (!shadow_lq[lq_i].expect_forward) begin
                        key = line_key(obs.ld_addr_obs);
                        if (shadow_cache.exists(key)) begin
                            shadow_lq[lq_i].expected_data = load_from_block(
                                shadow_cache[key],
                                obs.ld_addr_obs[`DCACHE_OFFSET_BITS-1:0],
                                obs.load_funct3_obs
                            );
                            shadow_lq[lq_i].expect_refill = 1;
                            shadow_lq[lq_i].expect_cache_hit = 1;
                        end else begin
                            shadow_lq[lq_i].expect_miss = 1;
                            shadow_lq[lq_i].miss_age = 0;
                        end
                    end
                end
            end

            // 5. Cache miss check: if a load address fired without a forwarding
            //    source, the cache should generate miss_request.valid eventually
            if (obs.miss_req_valid_obs) begin
                miss_req_seen++;
                for (int lq_i = 0; lq_i < `LQ_SZ; lq_i++) begin
                    if (shadow_lq[lq_i].valid &&
                        shadow_lq[lq_i].expect_miss &&
                        shadow_lq[lq_i].addr == obs.miss_req_obs.miss_req_address) begin
                        shadow_lq[lq_i].expect_miss = 0;
                        miss_checks++;
                    end
                end
                `uvm_info("SB",
                    $sformatf("Cache miss request: addr=0x%08x", obs.miss_req_obs.miss_req_address),
                    UVM_HIGH)
            end

            if (obs.miss_ret_obs && obs.com_miss_req_obs.valid && obs.com_miss_req_obs.req_is_load) begin
                int lq_i = int'(obs.com_miss_req_obs.lq_index);
                shadow_cache[line_key(obs.com_miss_req_obs.miss_req_address)] = obs.com_miss_req_obs.refill_data;
                if (lq_i < `LQ_SZ && shadow_lq[lq_i].valid) begin
                    shadow_lq[lq_i].expected_data = load_from_block(
                        obs.com_miss_req_obs.refill_data,
                        obs.com_miss_req_obs.miss_req_offset,
                        obs.com_miss_req_obs.miss_req_size
                    );
                    shadow_lq[lq_i].expect_refill = 1;
                end
            end

            // 6. CDB broadcast check: when lq_out.valid fires, verify data is coherent
            if (obs.lq_out_obs.valid) begin
                int lq_i = -1;
                cdb_broadcasts++;
                for (int i = 0; i < `LQ_SZ; i++) begin
                    if (shadow_lq[i].valid &&
                        shadow_lq[i].dest_tag == obs.lq_out_obs.dest_tag &&
                        shadow_lq[i].rob_index == obs.lq_out_obs.rob_index &&
                        lq_i == -1) begin
                        lq_i = i;
                    end
                end

                if (lq_i >= 0 && lq_i < `LQ_SZ && shadow_lq[lq_i].valid &&
                    shadow_lq[lq_i].expect_forward) begin
                    // Check forwarded data matches expected
                    if (obs.lq_out_obs.data !== shadow_lq[lq_i].expected_data) begin
                        `uvm_error("SB",
                            $sformatf("FWD MISMATCH LQ[%0d]: got 0x%08x, exp 0x%08x",
                                lq_i, obs.lq_out_obs.data, shadow_lq[lq_i].expected_data))
                        forward_errors++;
                        scoreboard_errors++;
                    end else begin
                        forward_checks++;
                        checks_pass++;
                        `uvm_info("SB",
                            $sformatf("FWD OK LQ[%0d]: data=0x%08x", lq_i, obs.lq_out_obs.data),
                            UVM_HIGH)
                    end
                end
                if (lq_i >= 0 && lq_i < `LQ_SZ && shadow_lq[lq_i].valid &&
                    shadow_lq[lq_i].expect_refill) begin
                    if (obs.lq_out_obs.data !== shadow_lq[lq_i].expected_data) begin
                        `uvm_error("SB",
                            $sformatf("REFILL MISMATCH LQ[%0d]: got 0x%08x, exp 0x%08x",
                                lq_i, obs.lq_out_obs.data, shadow_lq[lq_i].expected_data))
                        scoreboard_errors++;
                    end else begin
                        refill_checks++;
                        if (shadow_lq[lq_i].expect_cache_hit)
                            cache_hit_checks++;
                        checks_pass++;
                        `uvm_info("SB",
                            $sformatf("REFILL OK LQ[%0d]: data=0x%08x", lq_i, obs.lq_out_obs.data),
                            UVM_HIGH)
                    end
                end
                if (lq_i >= 0 && lq_i < `LQ_SZ) shadow_lq[lq_i].expect_miss = 0;
                // Free shadow entry after broadcast
                if (lq_i >= 0 && lq_i < `LQ_SZ) shadow_lq[lq_i].valid = 0;
            end

            // 7. Mispredict: clear shadow LQ/SQ above the restored tails
            if (obs.mispredicted_obs) begin
                foreach (shadow_lq[i]) shadow_lq[i].valid = 0;
                foreach (shadow_sq[i]) shadow_sq[i].valid = 0;
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB",
                $sformatf("Summary: %0d CDB broadcasts | %0d forwarding checks (%0d errors) | %0d refill/hit checks (%0d cache hits) | %0d miss reqs (%0d matched)",
                    cdb_broadcasts, forward_checks, forward_errors, refill_checks, cache_hit_checks, miss_req_seen, miss_checks),
                UVM_LOW)
            if (scoreboard_errors > 0)
                `uvm_error("SB", "Scoreboard detected LSQ/Dcache errors")
        endfunction

    endclass : lsq_dc_scoreboard

    // =========================================================================
    // 8. Coverage collector
    // =========================================================================
    class lsq_dc_coverage extends uvm_subscriber #(lsq_dc_obs_trans);
        `uvm_component_utils(lsq_dc_coverage)

        // Mirror fields for sampling
        int   dispatch_loads, dispatch_stores;
        logic cdb_fired;
        logic miss_fired;
        logic refill_fired;
        logic [1:0] lq_space, sq_space;
        logic accept_load, accept_store;
        logic mispredicted;
        logic ld_exec_valid, st_exec_valid;
        logic [2:0] load_funct3, store_funct3;
        logic [1:0] load_offset, store_offset;
        logic [4:0] load_shape, store_shape;

        // -- Coverage groups --

        // Which dispatch combination is exercised each cycle?
        covergroup cg_dispatch_combo;
            cp_ld : coverpoint dispatch_loads  { bins none={0}; bins one={1}; bins two={2}; }
            cp_st : coverpoint dispatch_stores { bins none={0}; bins one={1}; bins two={2}; }
            cx    : cross cp_ld, cp_st;
        endgroup

        // LQ / SQ occupancy (space_available output)
        covergroup cg_queue_space;
            cp_lq_space : coverpoint lq_space {
                bins empty   = {2'd0};
                bins one     = {2'd1};
                bins plenty  = {2'd2};
            }
            cp_sq_space : coverpoint sq_space {
                bins empty   = {2'd0};
                bins one     = {2'd1};
                bins plenty  = {2'd2};
            }
            cx_queues : cross cp_lq_space, cp_sq_space;
        endgroup

        // CDB broadcast and cache miss events
        covergroup cg_mem_events;
            cp_cdb  : coverpoint cdb_fired   { bins fired={1}; bins idle={0}; }
            cp_miss : coverpoint miss_fired  { bins fired={1}; bins idle={0}; }
            cp_fill : coverpoint refill_fired { bins fired={1}; bins idle={0}; }
            cp_misp : coverpoint mispredicted { bins fired={1}; bins idle={0}; }
            cx      : cross cp_cdb, cp_miss;
        endgroup

        // Dcache backpressure
        covergroup cg_dcache_accept;
            cp_load  : coverpoint accept_load  { bins yes={1}; bins no={0}; }
            cp_store : coverpoint accept_store { bins yes={1}; bins no={0}; }
        endgroup

        // Access shape: size/sign and low address offset.
        covergroup cg_access_shape;
            cp_ld_funct3 : coverpoint load_funct3 iff (ld_exec_valid) {
                bins lb  = {3'b000};
                bins lh  = {3'b001};
                bins lw  = {3'b010};
                bins lbu = {3'b100};
                bins lhu = {3'b101};
            }
            cp_st_funct3 : coverpoint store_funct3 iff (st_exec_valid) {
                bins sb = {3'b000};
                bins sh = {3'b001};
                bins sw = {3'b010};
            }
            cp_ld_offset : coverpoint load_offset iff (ld_exec_valid) {
                bins off0 = {2'd0};
                bins off1 = {2'd1};
                bins off2 = {2'd2};
                bins off3 = {2'd3};
            }
            cp_st_offset : coverpoint store_offset iff (st_exec_valid) {
                bins off0 = {2'd0};
                bins off1 = {2'd1};
                bins off2 = {2'd2};
                bins off3 = {2'd3};
            }
            cp_ld_shape : coverpoint load_shape iff (ld_exec_valid) {
                bins lb_all_offsets[]  = {5'b000_00, 5'b000_01, 5'b000_10, 5'b000_11};
                bins lh_even_offsets[] = {5'b001_00, 5'b001_10};
                bins lw_aligned        = {5'b010_00};
                bins lbu_all_offsets[] = {5'b100_00, 5'b100_01, 5'b100_10, 5'b100_11};
                bins lhu_even_offsets[]= {5'b101_00, 5'b101_10};
            }
            cp_st_shape : coverpoint store_shape iff (st_exec_valid) {
                bins sb_all_offsets[]  = {5'b000_00, 5'b000_01, 5'b000_10, 5'b000_11};
                bins sh_even_offsets[] = {5'b001_00, 5'b001_10};
                bins sw_aligned        = {5'b010_00};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_dispatch_combo = new();
            cg_queue_space    = new();
            cg_mem_events     = new();
            cg_dcache_accept  = new();
            cg_access_shape   = new();
        endfunction

        function void write(lsq_dc_obs_trans obs);
            dispatch_loads  = obs.is_load_obs[0]  + obs.is_load_obs[1];
            dispatch_stores = obs.is_store_obs[0] + obs.is_store_obs[1];
            cdb_fired       = obs.lq_out_obs.valid;
            miss_fired      = obs.miss_req_valid_obs;
            refill_fired    = obs.miss_ret_obs && obs.com_miss_req_obs.valid;
            lq_space        = obs.lq_space_obs;
            sq_space        = obs.sq_space_obs;
            accept_load     = obs.dcache_accept_load_obs;
            accept_store    = obs.dcache_accept_store_obs;
            mispredicted    = obs.mispredicted_obs;
            ld_exec_valid   = obs.ld_exec_valid_obs;
            st_exec_valid   = obs.st_exec_valid_obs;
            load_funct3     = obs.load_funct3_obs;
            store_funct3    = obs.store_funct3_obs;
            load_offset     = obs.ld_addr_obs[1:0];
            store_offset    = obs.st_addr_obs[1:0];
            load_shape      = {load_funct3, load_offset};
            store_shape     = {store_funct3, store_offset};

            cg_dispatch_combo.sample();
            cg_queue_space.sample();
            cg_mem_events.sample();
            cg_dcache_accept.sample();
            cg_access_shape.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV",
                $sformatf("Dispatch: %.1f%% | Queue space: %.1f%% | Mem events: %.1f%% | Access shape: %.1f%%",
                    cg_dispatch_combo.get_coverage(),
                    cg_queue_space.get_coverage(),
                    cg_mem_events.get_coverage(),
                    cg_access_shape.get_coverage()),
                UVM_LOW)
        endfunction

    endclass : lsq_dc_coverage

    // =========================================================================
    // 9. Agent
    // =========================================================================
    class lsq_dc_agent extends uvm_agent;
        `uvm_component_utils(lsq_dc_agent)

        lsq_dc_driver  drv;
        lsq_dc_monitor mon;
        uvm_sequencer #(lsq_dc_seq_item) seqr;
        uvm_analysis_port #(lsq_dc_obs_trans) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv  = lsq_dc_driver ::type_id::create("drv",  this);
            mon  = lsq_dc_monitor::type_id::create("mon",  this);
            seqr = uvm_sequencer #(lsq_dc_seq_item)::type_id::create("seqr", this);
            ap   = new("ap", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
            mon.ap.connect(ap);
        endfunction
    endclass : lsq_dc_agent

    // =========================================================================
    // 10. Environment
    // =========================================================================
    class lsq_dc_env extends uvm_env;
        `uvm_component_utils(lsq_dc_env)

        lsq_dc_agent       agt;
        lsq_dc_scoreboard  sb;
        lsq_dc_coverage    cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = lsq_dc_agent    ::type_id::create("agt", this);
            sb  = lsq_dc_scoreboard::type_id::create("sb",  this);
            cov = lsq_dc_coverage ::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agt.ap.connect(sb.imp);
            agt.ap.connect(cov.analysis_export);
        endfunction
    endclass : lsq_dc_env

    // =========================================================================
    // 11. Tests
    // =========================================================================
    class lsq_dc_base_test extends uvm_test;
        `uvm_component_utils(lsq_dc_base_test)

        lsq_dc_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = lsq_dc_env::type_id::create("env", this);
        endfunction

        function void report_phase(uvm_phase phase);
            uvm_report_server srv = uvm_report_server::get_server();
            int errs = srv.get_severity_count(UVM_ERROR) +
                       srv.get_severity_count(UVM_FATAL);
            if (errs == 0) $display("\n@@@ Passed");
            else           $display("\n@@@ Failed (%0d errors)", errs);
        endfunction
    endclass : lsq_dc_base_test

    class lsq_dc_directed_test extends lsq_dc_base_test;
        `uvm_component_utils(lsq_dc_directed_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            lsq_dc_directed_seq seq;
            phase.raise_objection(this);
            seq = lsq_dc_directed_seq::type_id::create("seq");
            seq.start(env.agt.seqr);
            #500;
            phase.drop_objection(this);
        endtask
    endclass : lsq_dc_directed_test

    class lsq_dc_smoke_test extends lsq_dc_base_test;
        `uvm_component_utils(lsq_dc_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            lsq_dc_smoke_seq seq;
            phase.raise_objection(this);
            seq = lsq_dc_smoke_seq::type_id::create("seq");
            seq.start(env.agt.seqr);
            #200;
            phase.drop_objection(this);
        endtask
    endclass : lsq_dc_smoke_test

    class lsq_dc_rand_test extends lsq_dc_base_test;
        `uvm_component_utils(lsq_dc_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            lsq_dc_rand_seq seq;
            phase.raise_objection(this);
            seq = lsq_dc_rand_seq::type_id::create("seq");
            seq.num_trans = 500;
            seq.start(env.agt.seqr);
            #500;
            phase.drop_objection(this);
        endtask
    endclass : lsq_dc_rand_test

endpackage : lsq_dc_pkg
`endif
