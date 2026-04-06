`include "sys_defs.svh"

module victim_cache #(
    parameter int VC_LINES   = 4,
    parameter int LINE_BYTES = `DCACHE_LINE_BYTES
)(
    input  logic      clock,
    input  logic      reset,

    // dcache miss lookup
    input  logic                          dcache_miss_req_valid,
    input  logic                          req_is_load,
    input  logic [`DCACHE_TAG_BITS-1:0]   dcache_miss_req_tag,
    input  logic [`DCACHE_SET_BITS-1:0]   dcache_miss_req_set,
    input  LQ_IDX                         lq_index,
    input  logic                          grant,
    output logic                          vc_hit,
    output MEM_BLOCK                      vc_hit_data,
    output logic                          vc_hit_dirty,


    // store update from dcache
    input  logic [$clog2(LINE_BYTES)-1:0] vc_store_offset, //req addr
    input  MEM_SIZE                       vc_store_size,
    input  DATA                           vc_store_data,
    output logic                          vc_store_ready, //tells dcache we updated store block

    // dcache eviction into VC
    input  logic                          dcache_evicted_valid,
    input  logic [`DCACHE_TAG_BITS-1:0]   dcache_evicted_tag,
    input  logic [`DCACHE_SET_BITS-1:0]   dcache_evicted_set,
    input  MEM_BLOCK                      dcache_evicted_data,
    input  logic                          dcache_evicted_dirty,
    output logic                          dcache_evicted_ready, //in case we're evicting dirty from vc make sure it can go in wb

    // MEM commands
    input  MEM_TAG                        mem2proc_transaction_tag,
    output MEM_COMMAND                    vc2mem_command,
    output ADDR                           vc2mem_addr,
    output MEM_BLOCK                      vc2mem_data,
    output MEM_SIZE                       vc2mem_size,
    output logic                          vc_requesting
);

    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int VC_WAY_BITS = $clog2(VC_LINES);

    typedef struct packed {
        logic                        valid;
        logic                        dirty;
        logic [`DCACHE_TAG_BITS-1:0] tag;
        logic [`DCACHE_SET_BITS-1:0] set;
        logic [VC_WAY_BITS-1:0]      lru_val;
        MEM_BLOCK                    data;
        LQ_IDX                       lq_index;
    } vc_entry_t;

    vc_entry_t vc_entries      [VC_LINES-1:0];
    vc_entry_t next_vc_entries [VC_LINES-1:0];

    logic                   found_hit;
    logic [VC_WAY_BITS-1:0] hit_idx;
    logic [VC_WAY_BITS-1:0] old_lru;

    logic                   found_evict_way;
    logic [VC_WAY_BITS-1:0] evict_idx;

    logic                   do_lru_update;
    logic [VC_WAY_BITS-1:0] lru_update_idx;

    logic                   overwrite_dirty_valid;

    MEM_BLOCK               store_updated_block;
    logic cant_insert;

    // store helper
    function automatic MEM_BLOCK store_into_block( //takes a full line and updates it with account to size
        input MEM_BLOCK old_block,
        input logic [$clog2(LINE_BYTES)-1:0] offset,
        input MEM_SIZE size,
        input DATA store_data
    );
        MEM_BLOCK tmp;
        begin
            tmp = old_block;

            unique case (size)
                // BYTE store (1 byte)
                // offset = which byte (0–7) inside the 8-byte cache line
                // store_data[7:0] = the 1 byte we want to write
                BYTE: tmp.byte_level[offset] = store_data[7:0];
                // HALF store (2 bytes)
                // offset[2:1] groups bytes into pairs:
                //   bytes [0,1] -> index 0
                //   bytes [2,3] -> index 1
                //   bytes [4,5] -> index 2
                //   bytes [6,7] -> index 3
                // store_data[15:0] = the 2 bytes we want to write
                HALF: tmp.half_level[offset[2:1]] = store_data[15:0];
                // WORD store (4 bytes)
                // offset[2] selects which 4-byte word:
                //   0 -> lower 4 bytes  (bytes 0–3)
                //   1 -> upper 4 bytes  (bytes 4–7)
                // store_data = full 32-bit word
                WORD: tmp.word_level[offset[2]] = store_data;
                // fallback (should not happen)
                default: tmp = old_block;
            endcase

            store_into_block = tmp;
        end
    endfunction

    req_state_t req_state, next_req_state;

    ADDR      wb_addr, next_wb_addr;
    MEM_BLOCK wb_data, next_wb_data;
    logic need_request, next_need_request;

    always_comb begin
        next_vc_entries = vc_entries;

        found_hit = 1'b0;
        hit_idx   = '0;
        old_lru   = '0;

        next_need_request ='0;
        

        found_evict_way = 1'b0;
        evict_idx       = '0;

        do_lru_update  = 1'b0;
        lru_update_idx = '0;

        vc_hit         = 1'b0;
        vc_hit_data    = '0;
        vc_hit_dirty   = '0;
        vc_store_ready = 1'b0;

        dcache_evicted_ready = 1'b1;

        vc2mem_command       = MEM_NONE;
        vc2mem_addr          = '0;
        vc2mem_data          = '0;
        vc2mem_size          = DOUBLE;
        vc_requesting        = 1'b0;

        next_req_state       = req_state;
        next_wb_addr         = wb_addr;
        next_wb_data         = wb_data;

        // lookup
        for (int i = 0; i < VC_LINES; i++) begin
            if (dcache_miss_req_valid && !found_hit &&
                vc_entries[i].valid &&
                vc_entries[i].tag == dcache_miss_req_tag &&
                vc_entries[i].set == dcache_miss_req_set) begin
                found_hit = 1'b1;
                //hit_idx   = VC_WAY_BITS'(i);
                vc_hit       = 1'b1;
                vc_hit_data  = vc_entries[i].data;
                vc_hit_dirty = vc_entries[i].dirty;
                if (!req_is_load )begin
                    vc_store_ready = 1'b1;
                    store_updated_block = store_into_block( //store block if the hit is a store 
                        vc_entries[i].data,
                        vc_store_offset,
                        vc_store_size,
                        vc_store_data
                    );

                    next_vc_entries[i].data  = store_updated_block; //store completion
                    next_vc_entries[i].dirty = 1'b1;

                    old_lru = vc_entries[i].valid ? vc_entries[i].lru_val : 'd0;
                    next_vc_entries[i].lru_val = VC_LINES - 1;

                    for (int j = 0; j < VC_LINES; j++) begin
                        if (j != i) begin
                            next_vc_entries[j].lru_val =
                                (vc_entries[j].valid &&
                                vc_entries[j].lru_val > old_lru) ?
                                vc_entries[j].lru_val - 1 :
                                vc_entries[j].lru_val;
                        end
                    end     
                end
                if (req_is_load) begin
                    old_lru = vc_entries[i].valid ? vc_entries[i].lru_val : 'd0;
                    next_vc_entries[i].lru_val = VC_LINES - 1;

                    for (int j = 0; j < VC_LINES; j++) begin
                        if (j != i) begin
                            next_vc_entries[j].lru_val =
                                (vc_entries[j].valid &&
                                vc_entries[j].lru_val > old_lru) ?
                                vc_entries[j].lru_val - 1 :
                                vc_entries[j].lru_val;
                        end
                    end
                end
            end
            
        end
       ////////////////
       ///INPUT
       /////////////////
        if(dcache_evicted_valid)begin
            for (int i = 0; i < VC_LINES; i++) begin
                if (!found_evict_way && !vc_entries[i].valid) begin
                    found_evict_way = 1'b1;
                    evict_idx       = VC_WAY_BITS'(i);
                end
                else if (!found_evict_way && vc_entries[i].lru_val == '0) begin
                    found_evict_way = 1'b1;
                    evict_idx       = VC_WAY_BITS'(i);
                end
            end

            if( found_evict_way && vc_entries[evict_idx].valid && vc_entries[evict_idx].dirty) begin
                next_need_request = 1'b1;
                next_wb_addr = {
                    vc_entries[evict_idx].tag,
                    vc_entries[evict_idx].set,
                    {OFFSET_BITS{1'b0}}
                };
                next_wb_data = vc_entries[evict_idx].data;
                next_req_state = REQ_WAIT_ACCEPT;
            end
            next_vc_entries[evict_idx].valid = 1'b1;
            next_vc_entries[evict_idx].dirty = dcache_evicted_dirty;
            next_vc_entries[evict_idx].tag   = dcache_evicted_tag;
            next_vc_entries[evict_idx].set   = dcache_evicted_set;
            next_vc_entries[evict_idx].data  = dcache_evicted_data;
            next_vc_entries[evict_idx].lq_index = lq_index;

            old_lru = vc_entries[evict_idx].valid ? vc_entries[evict_idx].lru_val : 'd0;
            next_vc_entries[evict_idx].lru_val = VC_LINES - 1;

            for (int j = 0; j < VC_LINES; j++) begin
                if (j != evict_idx) begin
                    next_vc_entries[j].lru_val =
                        (vc_entries[j].valid &&
                            vc_entries[j].lru_val > old_lru) ?
                        vc_entries[j].lru_val - 1 :
                        vc_entries[j].lru_val;
                end
            end
        end

        if(need_request) begin
            vc2mem_command = MEM_STORE;
            vc2mem_addr = wb_addr;
            vc2mem_data = write_data;
            vc_requesting = 1'b1;
            if(grant && mem2proc_transaction_tag != 'd0) begin
                next_need_request = 1'b0;
            end
        end   
            
    end
        
    always_ff @(posedge clock) begin
        if (reset) begin
            req_state <= REQ_IDLE;
            wb_addr   <= '0;
            wb_data   <= '0;
            need_request <= '0;

            for (int i = 0; i < VC_LINES; i++) begin
                vc_entries[i] <= '0;
            end
        end
        else begin
            req_state <= next_req_state;
            wb_addr   <= next_wb_addr;
            wb_data   <= next_wb_data;
            need_request <=next_need_request;

            for (int i = 0; i < VC_LINES; i++) begin
                vc_entries[i] <= next_vc_entries[i];
            end
        end
    end
endmodule