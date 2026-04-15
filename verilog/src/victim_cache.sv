`include "sys_defs.svh"

module victim_cache #(
    parameter int VC_LINES   = `VC_LINES,
    parameter int LINE_BYTES = `DCACHE_LINE_BYTES
)(
    input  logic      clock,
    input  logic      reset,

    // dcache miss lookup
    input  logic                          dcache_miss_req_valid,
    input  logic                          req_is_load,
    input  logic [`DCACHE_TAG_BITS-1:0]   dcache_miss_req_tag,
    input  logic [`DCACHE_SET_BITS-1:0]   dcache_miss_req_set,
    input  logic [$clog2(LINE_BYTES)-1:0] d_request_offset,
    input  MEM_SIZE                       d_request_size,
    input  logic                          d_req_unsigned,
    input  LQ_IDX                         lq_index,
    input logic                           wb_full,
    
    output logic                          vc_hit,

    // formatted load-hit response back to dcache
    output DATA                           vc_load_resp_data,
    output LQ_IDX                         vc_load_resp_lq_index,


    // store update from dcache
    input  DATA                           vc_store_data,

    // dcache eviction into VC
    output logic                          vcache_accept,
    input  logic                          dcache_evicted_valid,
    input  logic [`DCACHE_TAG_BITS-1:0]   dcache_evicted_tag,
    input  logic [`DCACHE_SET_BITS-1:0]   dcache_evicted_set,
    input  MEM_BLOCK                      dcache_evicted_data,
    input  logic                          dcache_evicted_dirty,
    //input  logic                          wb_ready,
    output logic                          vc_wb_valid,
    output logic [`DCACHE_TAG_BITS-1:0]   vc_wb_tag,
    output logic [`DCACHE_SET_BITS-1:0]   vc_wb_set,
    output MEM_BLOCK                      vc_wb_data,

    output vc_entry_t                   [`VC_LINES-1: 0]  debug_vc_entries

);

    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int VC_WAY_BITS = $clog2(VC_LINES);


    vc_entry_t     [VC_LINES-1:0] vc_entries  ;
    vc_entry_t [VC_LINES-1:0] next_vc_entries ;

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

            case (size)
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

    assign vcache_accept = !wb_full;

    always_comb begin

        for(int j = 0; j < VC_LINES; ++j)begin
            debug_vc_entries[j] = vc_entries[j];
        end

        next_vc_entries = vc_entries;
        found_hit = 1'b0;
        hit_idx   = '0;
        old_lru   = '0;

        vc_load_resp_data     = '0;
        vc_load_resp_lq_index = '0;

        vc_wb_valid = 1'b0;
        vc_wb_tag   = '0;
        vc_wb_set   = '0;
        vc_wb_data  = '0;

        found_evict_way = 1'b0;
        evict_idx       = '0;

        do_lru_update  = 1'b0;
        lru_update_idx = '0;

        vc_hit         = 1'b0;


        // lookup
        for (int i = 0; i < VC_LINES; i++) begin
            if (dcache_miss_req_valid && !found_hit &&
                vc_entries[i].valid &&
                vc_entries[i].tag == dcache_miss_req_tag &&
                vc_entries[i].set == dcache_miss_req_set) begin
                found_hit = 1'b1;
                //hit_idx   = VC_WAY_BITS'(i);
                vc_hit       = 1'b1;
                // load hit: return already formatted data
                if (req_is_load) begin
                    vc_load_resp_lq_index = lq_index;
                    case (d_request_size)
                        BYTE: begin
                            vc_load_resp_data = d_req_unsigned ?
                                {{24{1'b0}}, vc_entries[i].data.byte_level[d_request_offset]} :
                                {{24{vc_entries[i].data.byte_level[d_request_offset][7]}},
                                 vc_entries[i].data.byte_level[d_request_offset]};
                        end

                        HALF: begin
                            vc_load_resp_data = d_req_unsigned ?
                                {{16{1'b0}}, vc_entries[i].data.half_level[d_request_offset[2:1]]} :
                                {{16{vc_entries[i].data.half_level[d_request_offset[2:1]][15]}},
                                 vc_entries[i].data.half_level[d_request_offset[2:1]]};
                        end
                        WORD: begin
                            vc_load_resp_data =
                                vc_entries[i].data.word_level[d_request_offset[2]];
                        end
                        default: begin
                            vc_load_resp_data = '0;
                        end
                    endcase
                end
                if (!req_is_load )begin
                    store_updated_block = store_into_block( //store block if the hit is a store 
                        vc_entries[i].data,
                        d_request_offset,
                        d_request_size,
                        vc_store_data
                    );

                    next_vc_entries[i].data  = store_updated_block; //store completion
                    next_vc_entries[i].dirty = 1'b1;
                end
                // load hit lru update
                
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
            //store eviction
            if( found_evict_way && vc_entries[evict_idx].valid && vc_entries[evict_idx].dirty && !wb_full) begin
                vc_wb_valid = 1'b1;
                vc_wb_tag   = vc_entries[evict_idx].tag;
                vc_wb_set   = vc_entries[evict_idx].set;
                vc_wb_data  = vc_entries[evict_idx].data;
            end

            next_vc_entries[evict_idx].valid = 1'b1;
            next_vc_entries[evict_idx].dirty = dcache_evicted_dirty;
            next_vc_entries[evict_idx].tag   = dcache_evicted_tag;
            next_vc_entries[evict_idx].set   = dcache_evicted_set;
            next_vc_entries[evict_idx].data  = dcache_evicted_data;

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
     
    end  
    always_ff @(posedge clock) begin
        if (reset) begin
            //for (int i = 0; i < VC_LINES; i++) begin
                vc_entries <= '0;
            //nd
        end
        else begin
            //for (int i = 0; i < VC_LINES; i++) begin
                vc_entries <= next_vc_entries;
            //end
        end
    end
endmodule