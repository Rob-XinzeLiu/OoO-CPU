`include "sys_defs.svh"

module testbench;
    logic                         clock;                           
    logic                         reset;                            
    logic                         mispredicted;                        //from execute stage
    B_MASK                        mispredicted_bmask_index;            //from execute stage
    ROB_IDX                       rob_index             [`N-1:0];      //from rob
    logic [1:0]                   dispatch_num;                        //number of instructions dispatched in this cycle
    D_S_PACKET                    dispatch_pack         [`N-1:0];      //from dispatcher
    X_C_PACKET                    cdb                   [`N-1:0];  
    logic                         resolved;                            
    B_MASK                        resolved_bmask_index;             
    logic                         alu0_ready;                        
    logic                         alu1_ready;                        
  
    D_S_PACKET                   issue_pack         [`N-1:0];           //to issue stage
    logic [$clog2(`RS_SZ)-1:0]   empty_entries_num;

rs dut (
    .clock(clock), .reset(reset), .mispredicted(mispredicted), .mispredicted_bmask_index(mispredicted_bmask_index), 
    .rob_index(rob_index), .dispatch_num(dispatch_num), .dispatch_pack(dispatch_pack), .cdb(cdb), .resolved(resolved),
    .resolved_bmask_index(resolved_bmask_index), .alu0_ready(alu0_ready), .alu1_ready(alu1_ready),
    .issue_pack(issue_pack), .empty_entries_num(empty_entries_num)
);

initial clock = 0;
always #5 clock = ~clock;

task automatic tick();
@(posedge clock);
#1;
endtask

task reset_dut();
    clock =0; reset = 1;
    mispredicted = 0; 
    mispredicted_bmask_index = 0;
    resolved = 0;
    resolved_bmask_index = 0;
    dispatch_num = 0;
    alu0_ready = 0;
    alu1_ready = 0;

    for (int k = 0; k < `N; k++) begin
        dispatch_pack[k] = 0;
        rob_index[k] = 0;
        cdb[k] = 0;
    end
endtask

function automatic int issued_count();
    int cnt = 0;
    for (int k = 0; k < `N; k++) begin
        if (issue_pack[k].inst != 0)
        cnt++;
    end
    return cnt;
endfunction 

initial begin 
    reset_dut();
    tick();
    tick();
    tick();
    reset = 0;
   
   alu0_ready = 1;
   alu1_ready = 1;
   dispatch_num = 1;

   dispatch_pack[0] = 0;
   dispatch_pack[0].mult = 0;
   dispatch_pack[0].t1 = PRF_IDX'(12);
   dispatch_pack[0].t2 = PRF_IDX'(13);
   dispatch_pack[0].t1_ready = 0;
   dispatch_pack[0].t2_ready = 1;
   dispatch_pack[0].PC = ADDR'(32'h1000);
   dispatch_pack[0].NPC = ADDR'(32'h1004);
   dispatch_pack[0].inst = INST'(32'hDEADBEEF);
   dispatch_pack[0].opcode = 7'h33;
   rob_index[0] = ROB_IDX'(3);
   tick(); //enqueue into rs

   dispatch_num = 2'd0;
   cdb[0] = 0;
   cdb[0].valid = 1;
   cdb[0].complete_tag = PRF_IDX'(12);
   tick(); //next cycle expect issue
   cdb[0] = 0;
   tick();
   if (issued_count() ==0)begin 
    $error("FAIL:expected issued instruction but got none");
    $finish;
   end else begin
    $display("PASS: issued_count=%0d, issue_pack0.mult=%0b, issue_pack1.mult=%0b", 
    issued_count(), issue_pack[0].mult, issue_pack[1].mult);
    $finish;
   end
end




endmodule