`default_nettype none
`timescale 1ns/1ps
module trapv_debug;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    initial begin repeat(4)@(posedge clk); rst_n=1; end

    logic [15:0] instr_word; logic instr_valid=0;
    logic [31:0] ext_data=0; logic ext_valid=0;
    logic instr_ack, eu_busy;
    logic [31:0] pc_wr_data=0,vbr_wr_data=0,pc_out,vbr_out;
    logic pc_wr_en=0,vbr_wr_en=0;
    logic [31:0] usp_out,msp_out,isp_out,cacr_out,caar_out;
    logic [15:0] sr_out; logic supervisor,master_mode; logic [2:0] ipl_mask;
    logic [31:0] decode_pc=0, branch_target;
    logic branch_taken;
    logic mem_req,mem_rw; logic [1:0] mem_siz; logic [2:0] mem_fc;
    logic [31:0] mem_addr,mem_wdata; logic [31:0] mem_rdata=0;
    logic mem_ack=0,mem_berr=0,mem_rmw;
    logic eu_coproc_req,eu_coproc_rw; logic [1:0] eu_coproc_siz;
    logic [2:0] eu_coproc_fc; logic [31:0] eu_coproc_addr,eu_coproc_wdata;
    logic eu_coproc_ack=0,eu_coproc_berr=0; logic [31:0] eu_coproc_rdata=0;
    logic eu_pflush_req,eu_pflush_all; logic [2:0] eu_pflush_fc;
    logic [31:0] eu_pflush_va; logic eu_pflush_ack=0;
    logic eu_ptest_req; logic [31:0] eu_ptest_va; logic [2:0] eu_ptest_fc;
    logic eu_ptest_ack=0; logic [15:0] eu_ptest_mmusr=0;
    logic [31:0] tc_out,tt0_out,tt1_out;
    logic an_wr_en; logic [2:0] an_wr_sel; logic [31:0] an_wr_data;
    logic div_trap,chk_trap;
    logic ssp_wr_en=0; logic [31:0] ssp_wr_data=0;
    logic exc_sr_wr_en=0; logic [15:0] exc_sr_wr_data=0;
    logic eu_trap_req; logic [3:0] eu_trap_num;
    logic eu_trapv_req,eu_illegal_req,eu_stop;

    m68030_eu dut(
        .clk_4x(clk),.rst_n(rst_n),.instr_word(instr_word),.instr_valid(instr_valid),
        .ext_data(ext_data),.ext_valid(ext_valid),.instr_ack(instr_ack),.eu_busy(eu_busy),
        .pc_wr_en(pc_wr_en),.pc_wr_data(pc_wr_data),.pc_out(pc_out),
        .vbr_wr_en(vbr_wr_en),.vbr_wr_data(vbr_wr_data),.vbr_out(vbr_out),
        .usp_out(usp_out),.msp_out(msp_out),.isp_out(isp_out),
        .cacr_out(cacr_out),.caar_out(caar_out),.sr_out(sr_out),
        .supervisor(supervisor),.master_mode(master_mode),.ipl_mask(ipl_mask),
        .decode_pc(decode_pc),.branch_taken(branch_taken),.branch_target(branch_target),
        .mem_req(mem_req),.mem_rw(mem_rw),.mem_siz(mem_siz),.mem_fc(mem_fc),
        .mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_rdata(mem_rdata),
        .mem_ack(mem_ack),.mem_berr(mem_berr),.mem_rmw(mem_rmw),
        .eu_coproc_req(eu_coproc_req),.eu_coproc_rw(eu_coproc_rw),
        .eu_coproc_siz(eu_coproc_siz),.eu_coproc_fc(eu_coproc_fc),
        .eu_coproc_addr(eu_coproc_addr),.eu_coproc_wdata(eu_coproc_wdata),
        .eu_coproc_rdata(eu_coproc_rdata),.eu_coproc_ack(eu_coproc_ack),
        .eu_coproc_berr(eu_coproc_berr),.eu_pflush_req(eu_pflush_req),
        .eu_pflush_all(eu_pflush_all),.eu_pflush_fc(eu_pflush_fc),
        .eu_pflush_va(eu_pflush_va),.eu_pflush_ack(eu_pflush_ack),
        .eu_ptest_req(eu_ptest_req),.eu_ptest_va(eu_ptest_va),
        .eu_ptest_fc(eu_ptest_fc),.eu_ptest_ack(eu_ptest_ack),
        .eu_ptest_mmusr(eu_ptest_mmusr),.tc_out(tc_out),.tt0_out(tt0_out),
        .tt1_out(tt1_out),.an_wr_en(an_wr_en),.an_wr_sel(an_wr_sel),
        .an_wr_data(an_wr_data),.div_trap(div_trap),.chk_trap(chk_trap),
        .eu_trap_req(eu_trap_req),.eu_trap_num(eu_trap_num),
        .eu_trapv_req(eu_trapv_req),.eu_illegal_req(eu_illegal_req),.eu_stop(eu_stop),
        .ssp_wr_en(ssp_wr_en),.ssp_wr_data(ssp_wr_data),
        .exc_sr_wr_en(exc_sr_wr_en),.exc_sr_wr_data(exc_sr_wr_data)
    );

    task issue_wait(input logic [15:0] w0, has_ext, input logic [31:0] ext);
        @(posedge clk); instr_word=w0; instr_valid=1; ext_data=ext; ext_valid=has_ext;
        repeat(200) begin @(posedge clk); if(instr_ack) break; end
        instr_valid=0; ext_valid=0; @(posedge clk);
    endtask

    initial begin
        @(posedge rst_n); repeat(2) @(posedge clk);
        // Set CCR to 0x1F: MOVEQ #31,D2; MOVE D2,CCR
        issue_wait(16'h741F, 0, 0);
        repeat(4) @(posedge clk);
        issue_wait(16'h44C2, 0, 0);
        repeat(4) @(posedge clk);
        $display("SR after MOVE D2,CCR: %04h, flag_v=%b", sr_out, dut.u_seq.flag_v);

        // TRAPV with V=1
        @(posedge clk);
        instr_word  = 16'h4E76;
        instr_valid = 1;
        repeat(10) begin
            @(posedge clk);
            $display("t=%0t sr=%04h flag_v=%b ex_valid=%b ex_is_trapv=%b eu_trapv_req=%b ack=%b",
                     $time, sr_out, dut.u_seq.flag_v,
                     dut.u_seq.ex_valid, dut.u_seq.ex_is_trapv,
                     eu_trapv_req, instr_ack);
            if (eu_trapv_req) begin $display("SAW trapv_req"); instr_valid=0; break; end
            if (instr_ack) instr_valid=0;
        end
        instr_valid=0;
        #100 $finish;
    end
    initial begin #50000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
