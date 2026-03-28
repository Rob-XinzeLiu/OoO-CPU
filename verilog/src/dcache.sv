`include "sys_defs.svh"
`include "ISA.svh"

module Dcache 
#(
    parameter int WAYS = 4,
    parameter int SETS = 8,
    parameter int LINES = SETS * WAYS,
    parameter int LINE_BYTES = 8
)(
    input   logic            clock,
    input   logic            reset,
    input   INST             inst,
    input   ADDR             request_address,
    input   logic            req_is_load, 
    input   DATA             req_store_data,
    input   logic            req_valid,
    input   completed_mshr_t com_miss_req, // from mshr
    input   logic            miss_returned,
    input   logic            miss_queue_full,

    output  dcache_data_t   cache_resp_data, // slot 2 will be for cache miss loads
    output  logic            resp_valid,
    output  logic            cache_ready, // it is ready while the miss queue is not full
    output  miss_request_t   miss_request,

    output MEM_COMMAND      vc2mem_command,
    output ADDR             vc2mem_addr,
    output MEM_BLOCK        vc2mem_data,
    output MEM_SIZE         vc2mem_size
);

    localparam int ADDR_BITS   = $bits(ADDR);
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int SET_BITS  = $clog2(SETS);
    localparam int TAG_BITS    = ADDR_BITS - OFFSET_BITS - SET_BITS;

    MEM_SIZE d_request_size;
    logic                    d_req_unsigned;

    miss_request_t next_miss_request;

    cache_tag_t cache_tags [SETS-1:0][WAYS-1:0];
    cache_tag_t next_cache_tags [SETS-1:0][WAYS-1:0];

    logic [TAG_BITS-1:0]     d_request_tag;
    logic [SET_BITS-1:0]     d_request_set;
    logic [OFFSET_BITS-1:0]  d_request_offset;
    logic                    hit;
    logic [$clog2(WAYS)-1:0] hit_way;

    //logic [$clog2(WAYS)-1:0] lru_way; //to tell VC we're eveicting 


    //////////////////////
    // MEMDP VARIABLES //
    //////////////////////

    localparam int DATA_DEPTH      = LINES;
    localparam int DATA_WIDTH      = $bits(MEM_BLOCK);
    localparam int DATA_READ_PORTS = 1;
    localparam int DATA_ADDR_BITS  = $clog2(DATA_DEPTH);

    logic [DATA_READ_PORTS-1:0]                    data_re;
    logic [DATA_READ_PORTS-1:0][DATA_ADDR_BITS-1:0] data_raddr;
    logic [DATA_READ_PORTS-1:0][DATA_WIDTH-1:0]     data_rdata;

    logic                       data_we;
    logic [DATA_ADDR_BITS-1:0]  data_waddr;
    logic [DATA_WIDTH-1:0]      data_wdata;

    memDP #(
        .WIDTH(DATA_WIDTH),
        .DEPTH(DATA_DEPTH),
        .READ_PORTS(DATA_READ_PORTS),
        .BYPASS_EN(0)
    ) cache_structure (
        .clock(clock),
        .reset(reset),

        .re(data_re),
        .raddr(data_raddr),
        .rdata(data_rdata),

        .we(data_we),
        .waddr(data_waddr),
        .wdata(data_wdata)
    );
    
    assign d_request_size   = MEM_SIZE'(inst.r.funct3[1:0]);
    assign d_req_unsigned   = inst.r.funct3[2];

    assign d_request_tag    = request_address[ADDR_BITS-1 : OFFSET_BITS + SET_BITS];
    assign d_request_set    = request_address[OFFSET_BITS + SET_BITS - 1 : OFFSET_BITS];
    assign d_request_offset = request_address[OFFSET_BITS-1:0];

    assign cache_ready  = !miss_returned && !miss_queue_full ; // && mshr is not full // TODO: PLEASE ENSURE THAT THIS CHANGES. for now cache ready

    // VC signals
    logic                    vc_hit;
    MEM_BLOCK                vc_hit_data;
    logic                    vc_hit_dirty;
    logic                    vc_evicted_ready;
    logic                    vc_lookup_valid;

    logic                    dcache_evicted_valid;
    logic [`DCACHE_TAG_BITS-1:0] dcache_evicted_tag;
    logic [`DCACHE_SET_BITS-1:0] dcache_evicted_set;
    MEM_BLOCK                dcache_evicted_data;
    logic                    dcache_evicted_dirty;
    logic                    vc_store_ready;
 
    //LRU LOGIC STUFF
    logic [$clog2(WAYS)-1:0] old_lru_index_hit;

    logic                    found_way_miss;
    logic [$clog2(WAYS)-1:0] way_index_miss;
    logic [$clog2(WAYS)-1:0] old_lru_index_miss;
    
    assign vc_lookup_valid = req_valid && !hit && cache_ready; // only look up when not refilling

    logic is_valid_load;
    logic is_valid_store;

    assign is_valid_load = req_valid && req_is_load;
    assign is_valid_store = req_valid && !req_is_load;

    MEM_BLOCK selected_read_data;
    MEM_BLOCK merged_store_data;
    
    assign selected_read_data = hit ? MEM_BLOCK'(data_rdata[0]) : '0;

    function automatic logic [$clog2(SETS*WAYS)-1:0] flat_idx(
        input logic [SET_BITS-1:0] set_idx,
        input logic [$clog2(WAYS)-1:0] way_idx
    );
        flat_idx = set_idx * WAYS + way_idx;
    endfunction

    always_comb begin 
        next_cache_tags   = cache_tags;

        next_miss_request = '0;

        hit     = 1'b0;
        hit_way = '0;
        old_lru_index_hit = '0;
        
       
        data_re[0]    = 1'b0;
        data_raddr[0] = '0;
        data_we    = 1'b0;
        data_waddr = '0;
        data_wdata = '0;
    
        dcache_evicted_valid = 1'b0;
        dcache_evicted_tag   = '0;
        dcache_evicted_set   = '0;
        dcache_evicted_data  = '0;
        dcache_evicted_dirty = '0;

        cache_resp_data = '0;
        resp_valid      = 1'b0;

        //data_re    = req_valid;
        /////////////////
        // Miss logic  //
        /////////////////

        found_way_miss      = '0;
        way_index_miss      = '0;
        old_lru_index_miss  = '0;

        if (miss_returned) begin
            // STEP 1. CHECK IF THERE IS AN INVALID WAY IN THE SET.
            for (int i = 0; i < WAYS; ++i) begin
                if (!cache_tags[com_miss_req.miss_req_set][i].valid && !found_way_miss) begin
                    found_way_miss = 1'b1;
                    way_index_miss = i[$clog2(WAYS)-1:0]; // cast this
                end 
                else if (cache_tags[com_miss_req.miss_req_set][i].lru_val == 'd0 && !found_way_miss) begin
                    way_index_miss = i[$clog2(WAYS)-1:0]; // cast this
                    found_way_miss = 1'b1;
                end
            end

            if (found_way_miss) begin
                // If overwriting a valid dcache line, send it to VC
                
                data_we = 1'b1;
                data_waddr = flat_idx(com_miss_req.miss_req_set, way_index_miss); // is this the correct address if we are filling up an entire 64 bit block
                data_wdata = com_miss_req.refill_data;

                if (com_miss_req.req_is_load) begin
                    cache_resp_data.address = com_miss_req.miss_req_address;
                    cache_resp_data.valid   = 1'b1;

                    unique case (com_miss_req.miss_req_size)
                        BYTE: begin
                            cache_resp_data.data = com_miss_req.miss_req_unsigned ?
                                {{24{1'b0}}, com_miss_req.refill_data.byte_level[com_miss_req.miss_req_offset]} :
                                {{24{com_miss_req.refill_data.byte_level[com_miss_req.miss_req_offset][7]}},
                                com_miss_req.refill_data.byte_level[com_miss_req.miss_req_offset]};
                        end

                        HALF: begin
                            cache_resp_data.data = com_miss_req.miss_req_unsigned ?
                                {{16{1'b0}}, com_miss_req.refill_data.half_level[com_miss_req.miss_req_offset[2:1]]} :
                                {{16{com_miss_req.refill_data.half_level[com_miss_req.miss_req_offset[2:1]][15]}},
                                com_miss_req.refill_data.half_level[com_miss_req.miss_req_offset[2:1]]};
                        end

                        WORD: begin
                            cache_resp_data.data =
                                com_miss_req.refill_data.word_level[com_miss_req.miss_req_offset[2]];
                        end

                        default: begin
                            cache_resp_data.data = '0;
                        end
                    endcase

                    resp_valid = 1'b1;
                end

                if(!com_miss_req.req_is_load) begin
                    merged_store_data = com_miss_req.refill_data;
                    data_we = 1'b1;
                    data_waddr = flat_idx(com_miss_req.miss_req_set, way_index_miss);
                    case (com_miss_req.miss_req_size)
                        BYTE: merged_store_data.byte_level[com_miss_req.miss_req_offset] = com_miss_req.miss_req_data[7:0];
                        HALF: merged_store_data.half_level[com_miss_req.miss_req_offset[2:1]] = com_miss_req.miss_req_data[15:0];
                        WORD: merged_store_data.word_level[com_miss_req.miss_req_offset[2]] = com_miss_req.miss_req_data;
                    endcase

                    data_wdata = merged_store_data;
                    next_cache_tags[com_miss_req.miss_req_set][way_index_miss].dirty = 1'b1;
                end
    
                if (cache_tags[com_miss_req.miss_req_set][way_index_miss].valid) begin
                    data_re[0] = 1'b1;
                    data_raddr[0] = flat_idx(com_miss_req.miss_req_set, way_index_miss);

                    dcache_evicted_valid = 1'b1;
                    dcache_evicted_tag   = cache_tags[com_miss_req.miss_req_set][way_index_miss].tag;
                    dcache_evicted_set   = com_miss_req.miss_req_set;
                    dcache_evicted_data  = data_rdata[0]; 
                    dcache_evicted_dirty = cache_tags[com_miss_req.miss_req_set][way_index_miss].dirty;
                end

                if (!dcache_evicted_valid || vc_evicted_ready) begin  // update lru logic here
                    old_lru_index_miss =
                        cache_tags[com_miss_req.miss_req_set][way_index_miss].valid ?
                        cache_tags[com_miss_req.miss_req_set][way_index_miss].lru_val : 'd0;

                    next_cache_tags[com_miss_req.miss_req_set][way_index_miss].tag   = com_miss_req.miss_req_tag;
                    next_cache_tags[com_miss_req.miss_req_set][way_index_miss].valid = 1'b1;
                    next_cache_tags[com_miss_req.miss_req_set][way_index_miss].dirty = !com_miss_req.req_is_load;
                    next_cache_tags[com_miss_req.miss_req_set][way_index_miss].lru_val = WAYS - 1;

                    for(int i = 0; i < WAYS; i++) begin
                        if ((i != way_index_miss) && cache_tags[com_miss_req.miss_req_set][i].valid &&
                                cache_tags[com_miss_req.miss_req_set][i].lru_val > old_lru_index_miss) begin
                                next_cache_tags[com_miss_req.miss_req_set][i].lru_val =
                                    cache_tags[com_miss_req.miss_req_set][i].lru_val - 'd1;
                            end
                    end
                end
            end
        end else begin
            
            for (int i = 0; i < WAYS; i++) begin
                if (cache_ready && req_valid && cache_tags[d_request_set][i].valid &&
                    cache_tags[d_request_set][i].tag == d_request_tag && !hit) begin
                    data_re[0] = 1'b1;
                    hit     = 1'b1;
                    hit_way = i[$clog2(WAYS)-1:0];

                    data_raddr[0] = flat_idx(d_request_set, i[$clog2(WAYS)-1:0]); // request for memDP

                    old_lru_index_hit = cache_tags[d_request_set][i].lru_val;// should be 0 if not valid

                    for (int j = 0; j < WAYS; j++) begin
                        if (j != i && cache_tags[d_request_set][j].valid &&
                            cache_tags[d_request_set][j].lru_val > old_lru_index_hit) begin
                            next_cache_tags[d_request_set][j].lru_val =
                                cache_tags[d_request_set][j].lru_val - 1'b1;
                        end
                    end
                    next_cache_tags[d_request_set][i].lru_val = WAYS - 'd1;
                end
            end
            if (!hit && !vc_hit && req_valid && cache_ready) begin
                next_miss_request.valid             = 1'b1;
                next_miss_request.miss_req_address  = request_address;
                next_miss_request.miss_req_tag      = d_request_tag;
                next_miss_request.miss_req_set      = d_request_set;
                next_miss_request.miss_req_offset   = d_request_offset;
                next_miss_request.req_is_load       = req_is_load;
                next_miss_request.miss_req_size     = d_request_size;
                next_miss_request.miss_req_unsigned = d_req_unsigned;
                next_miss_request.miss_req_data     = !req_is_load ? req_store_data : '0; 
            end
            if(hit && is_valid_load) begin
                cache_resp_data.address = request_address;
                cache_resp_data.valid   = 1'b1;
                case (d_request_size)
                    BYTE: begin
                        cache_resp_data.data = d_req_unsigned ?
                            {{24{1'b0}}, selected_read_data.byte_level[d_request_offset]} :
                            {{24{selected_read_data.byte_level[d_request_offset][7]}},
                            selected_read_data.byte_level[d_request_offset]};
                    end
                    HALF: begin
                        cache_resp_data.data = d_req_unsigned ?
                            {{16{1'b0}}, selected_read_data.half_level[d_request_offset[2:1]]} :
                            {{16{selected_read_data.half_level[d_request_offset[2:1]][15]}},
                            selected_read_data.half_level[d_request_offset[2:1]]};
                    end
                    WORD: begin
                        cache_resp_data.data = selected_read_data.word_level[d_request_offset[2]];
                    end
                    default: begin
                        cache_resp_data.data = '0;
                    end
                endcase
                resp_valid = 1'b1;
            end
            if(hit && is_valid_store)begin
                merged_store_data = selected_read_data;
                data_we    = 1'b1;
                data_waddr = flat_idx(d_request_set, hit_way);
                next_cache_tags[d_request_set][hit_way].dirty = 1'b1;
                case (d_request_size)
                    BYTE: begin
                        merged_store_data.byte_level[d_request_offset] = req_store_data[7:0];
                    end
                    HALF: begin
                        merged_store_data.half_level[d_request_offset[2:1]] = req_store_data[15:0];
                    end
                    WORD: begin
                        merged_store_data.word_level[d_request_offset[2]] = req_store_data;
                    end
                    default: begin
                        merged_store_data = '0;
                    end
                endcase
                data_wdata = merged_store_data;
            end
            // Vc Load hit
            if (vc_hit && req_is_load) begin
                unique case (d_request_size)
                    BYTE: begin
                        cache_resp_data.data = d_req_unsigned ?
                            {{24{1'b0}}, vc_hit_data.byte_level[d_request_offset]} :
                            {{24{vc_hit_data.byte_level[d_request_offset][7]}},
                            vc_hit_data.byte_level[d_request_offset]};
                    end

                    HALF: begin
                        cache_resp_data.data = d_req_unsigned ?
                            {{16{1'b0}}, vc_hit_data.half_level[d_request_offset[2:1]]} :
                            {{16{vc_hit_data.half_level[d_request_offset[2:1]][15]}},
                            vc_hit_data.half_level[d_request_offset[2:1]]};
                    end

                    WORD: begin
                        cache_resp_data.data = vc_hit_data.word_level[d_request_offset[2]];
                    end

                    default: begin
                        cache_resp_data.data = '0;
                    end
                endcase

                resp_valid = 1'b1;
            end
        end   
    end

    // logic record_miss;
    // assign record_miss = req_valid && cache_ready && !hit && !vc_hit;

    always_ff @(posedge clock) begin
        if (reset) begin 
            cache_tags    <= {default: '0};
            miss_request  <= '0;
        end
        else begin
            cache_tags <= next_cache_tags;
            miss_request <= next_miss_request; 
        end
    end


    victim_cache #(.VC_LINES(4)) vc (
        .clock                (clock),
        .reset                (reset),

        // dcache miss lookup
        .dcache_miss_req_valid(vc_lookup_valid), //valid request and not hit
        .req_is_load          (req_is_load),     
        .dcache_miss_req_tag  (d_request_tag),
        .dcache_miss_req_set  (d_request_set),
        .vc_hit               (vc_hit),
        .vc_hit_data          (vc_hit_data),
        .vc_hit_dirty         (vc_hit_dirty),

        // store update from dcache
        .vc_store_offset      (d_request_offset),
        .vc_store_size        (d_request_size),
        .vc_store_data        (req_store_data),
        .vc_store_ready       (vc_store_ready),

        // dcache eviction into VC
        .dcache_evicted_valid (dcache_evicted_valid),
        .dcache_evicted_tag   (dcache_evicted_tag),
        .dcache_evicted_set   (dcache_evicted_set),
        .dcache_evicted_data  (dcache_evicted_data),
        .dcache_evicted_dirty (dcache_evicted_dirty),
        .dcache_evicted_ready (vc_evicted_ready),

        // vc write to mem 
        .vc2mem_command       (vc2mem_command),
        .vc2mem_addr          (vc2mem_addr),
        .vc2mem_data          (vc2mem_data),
        .vc2mem_size          (vc2mem_size)
    );

endmodule