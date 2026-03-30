/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  icache.sv                                           //
//                                                                     //
//  Description :  The instruction cache module that reroutes memory   //
//                 accesses to decrease misses.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module icache (
    input clock,
    input reset,

    // From memory
    input MEM_TAG   Imem2proc_transaction_tag, // Should be zero unless there is a response
    input MEM_BLOCK Imem2proc_data,
    input MEM_TAG   Imem2proc_data_tag,

    // From fetch stage
    input ADDR proc2Icache_addr,

    // To memory
    output MEM_COMMAND proc2Imem_command,
    output ADDR        proc2Imem_addr,

    // To fetch stage
    output MEM_BLOCK Icache_data_out, // Data is mem[proc2Icache_addr]
    output logic     Icache_valid_out // When valid is high
);
    localparam INDEX_BITS = $clog2(`ICACHE_LINES / 2);
    localparam TAG_BITS = 13 - INDEX_BITS;

    // Note: cache tags, not memory tags
    logic [TAG_BITS-1:0]    current_tag,   last_tag; // 8 bits
    logic [INDEX_BITS-1:0]  current_index, last_index; // 4 bits for 2-way

    assign {current_tag, current_index} = proc2Icache_addr[15:3];

    ADDR next_addr;
    logic [TAG_BITS-1:0] next_tag;
    logic [INDEX_BITS-1:0] next_index;
    assign next_addr = {proc2Icache_addr[31:3], 3'b0} + 8;
    assign {next_tag, next_index} = next_addr[15:3];

    // Cache
    logic lru   [`ICACHE_LINES/2 - 1 : 0];
    ICACHE_TAG [`ICACHE_LINES/2 - 1:0] icache_tags_0;
    ICACHE_TAG [`ICACHE_LINES/2 - 1:0] icache_tags_1;   

    MEM_BLOCK   rdata_0, rdata_1;

    // Hit logic for current address
    logic hit_0, hit_1;

    assign hit_0 = icache_tags_0[current_index].valid && (icache_tags_0[current_index].tags == current_tag);
    assign hit_1 = icache_tags_1[current_index].valid && (icache_tags_1[current_index].tags == current_tag);

    assign Icache_valid_out = hit_0 || hit_1;
    assign Icache_data_out = hit_0? rdata_0 : (hit_1)? rdata_1 : '0;

    // Hit logic for prefetch address
    logic pf_hit;
    assign pf_hit = (icache_tags_0[next_index].valid && (icache_tags_0[next_index].tags == next_tag)) || 
                        (icache_tags_1[next_index].valid && (icache_tags_1[next_index].tags == next_tag));

    // Demand tracking
    MEM_TAG current_mem_tag; // The current memory tag we might be waiting on
    logic miss_outstanding; // Whether a miss has received its response tag to wait on

    logic changed_addr;
    logic unanswered_miss;
    logic got_mem_data;
    logic [TAG_BITS-1:0]    locked_tag;
    logic [INDEX_BITS-1:0]  locked_index;

    assign changed_addr = (current_index != last_index) || (current_tag != last_tag);
    assign unanswered_miss = changed_addr ? !Icache_valid_out :
                                        miss_outstanding && (Imem2proc_transaction_tag == 0);
    assign got_mem_data = (current_mem_tag == Imem2proc_data_tag) && (current_mem_tag != 0);

    // Prefetch tracking
    MEM_TAG prefetch_mem_tag;
    logic [TAG_BITS-1:0]    locked_pf_tag;
    logic [INDEX_BITS-1:0]  locked_pf_index;
    logic got_prefetch_data;
    logic prefetching;

    assign got_prefetch_data = (prefetch_mem_tag != 0) && (prefetch_mem_tag == Imem2proc_data_tag);
    // Only issue a prefetch when next block is not in cache or in-flight
    assign prefetching = !pf_hit && (prefetch_mem_tag == 0 || changed_addr);

    // Memory bus control
    assign proc2Imem_command = (unanswered_miss || prefetching)? MEM_LOAD : MEM_NONE;
    assign proc2Imem_addr = unanswered_miss? {proc2Icache_addr[31:3], 3'b0} : {next_addr[31:3], 3'b0};

    // Write enable
    logic icache_we_0, icache_we_1, icache_we_pf_0, icache_we_pf_1;
    assign icache_we_0    = got_mem_data && !lru[locked_index];
    assign icache_we_1    = got_mem_data && lru[locked_index];
    assign icache_we_pf_0 = got_prefetch_data && !lru[locked_pf_index];
    assign icache_we_pf_1 = got_prefetch_data && lru[locked_pf_index];

    // Fillin control
    logic                   fill_we [1:0];
    logic [INDEX_BITS-1:0]  fill_index;
    MEM_BLOCK               fill_data;

    assign fill_index = (got_mem_data)? locked_index:locked_pf_index;
    assign fill_data = Imem2proc_data;
    assign fill_we[0] = got_mem_data && !lru[locked_index] || (!got_mem_data && got_prefetch_data && !lru[locked_pf_index]);
    assign fill_we[1] = got_mem_data && lru[locked_index]  || (!got_mem_data && got_prefetch_data && lru[locked_pf_index]);
    
    // ---- Cache state registers ---- //

    always_ff @(posedge clock) begin
        if (reset) begin
            last_index       <= -1; // These are -1 to get ball rolling when
            last_tag         <= -1; // reset goes low because addr "changes"
            current_mem_tag  <= '0;
            miss_outstanding <= '0;
            prefetch_mem_tag <= '0;
            locked_index     <= '0;
            locked_tag       <= '0;
            locked_pf_index  <= '0;
            locked_pf_tag       <= '0;
            icache_tags_0    <= '0; // Set all cache tags and valid bits to 0
            icache_tags_1    <= '0;
            lru              <= '{default: '0};
        end else begin
            last_index       <= current_index;
            last_tag         <= current_tag;
            miss_outstanding <= unanswered_miss;
            // Lock request address
            if(unanswered_miss && Imem2proc_transaction_tag != 0) begin
                current_mem_tag <= Imem2proc_transaction_tag;
                locked_index    <= current_index;
                locked_tag      <= current_tag;
            end else if (got_mem_data || changed_addr) begin
                current_mem_tag <= '0;
            end
            // Prefetch mem tag
            if(changed_addr || got_prefetch_data) begin
                prefetch_mem_tag    <= '0;
            end else if(prefetching && !unanswered_miss && Imem2proc_transaction_tag != 0) begin
                prefetch_mem_tag    <= Imem2proc_transaction_tag;      // Update transaction tag
                locked_pf_index     <= next_index;
                locked_pf_tag       <= next_tag;
            end
            // Update icache_tags
            if (icache_we_0) begin // If data came from memory, meaning tag matches
                icache_tags_0[locked_index].tags  <= locked_tag;
                icache_tags_0[locked_index].valid <= 1'b1;
                lru[locked_index]  <= 1'b1;    // We next fill into way1 (It's older)
            end
            if(icache_we_1) begin
                icache_tags_1[locked_index].tags  <= locked_tag;
                icache_tags_1[locked_index].valid <= 1'b1;
                lru[locked_index]  <= 1'b0;    // We next fill into way0
            end
            if(icache_we_pf_0) begin
                icache_tags_0[locked_pf_index].tags  <= locked_pf_tag;
                icache_tags_0[locked_pf_index].valid <= 1'b1;
                lru[locked_pf_index]  <= 1'b1;    // We next fill into way1 (It's older)
            end
            if(icache_we_pf_1) begin
                icache_tags_1[locked_pf_index].tags  <= locked_pf_tag;
                icache_tags_1[locked_pf_index].valid <= 1'b1;
                lru[locked_pf_index]  <= 1'b0;    // We next fill into way1 (It's older)
            end
            // Update LRU
            if(hit_0 && Icache_valid_out) lru[current_index] <= 1'b1;
            if(hit_1 && Icache_valid_out) lru[current_index] <= 1'b0;
        end
    end

    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (`ICACHE_LINES / 2),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    icache_mem0 (
        .clock(clock),
        .reset(reset),
        .re   (1'b1),
        .raddr(current_index),
        .rdata(rdata_0),
        .we   (fill_we[0]),
        .waddr(fill_index),
        .wdata(fill_data)
    );

    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (`ICACHE_LINES / 2),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    icache_mem1 (
        .clock(clock),
        .reset(reset),
        .re   (1'b1),
        .raddr(current_index),
        .rdata(rdata_1),
        .we   (fill_we[1]),
        .waddr(fill_index),
        .wdata(fill_data)
    );

endmodule // icache