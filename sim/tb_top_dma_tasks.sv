`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_top_dma_tasks;
    localparam int MAX_WORDS = 12000;
    localparam int MAX_TASKS = 8;

    logic clk = 0;
    logic rst_n = 0;
    logic [127:0] s_data = 0;
    logic [15:0] s_keep = 0;
    logic s_valid = 0;
    wire s_ready;
    logic s_last = 0;
    wire [127:0] m_data;
    wire [15:0] m_keep;
    wire m_valid;
    logic m_ready = 1;
    wire m_last;
    logic [17:0] awaddr = 0;
    logic awvalid = 0;
    wire awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wvalid = 0;
    wire wready;
    wire bvalid;
    logic bready = 0;

    logic [31:0] request [0:MAX_WORDS-1];
    logic [31:0] response [0:MAX_WORDS-1];
    logic [31:0] expected_job [0:MAX_TASKS-1];
    logic [7:0] expected_task [0:MAX_TASKS-1];
    logic [31:0] expected_result_words [0:MAX_TASKS-1];
    logic [31:0] expected_items [0:MAX_TASKS-1];
    logic [31:0] expected_tag [0:MAX_TASKS-1];
    logic [23:0] expected_status [0:MAX_TASKS-1];
    logic [31:0] expected_detail [0:MAX_TASKS-1];
    integer request_count;
    integer response_count;
    integer expected_count;
    integer expected_tasks;
    integer batch_sequence;
    integer lane;
    integer engine_launch_count;
    wire [2:0] engine_start;
    reg saw_legacy_gnn_cfg_bank1 = 1'b0;
    reg saw_legacy_admet_cfg_bank1 = 1'b0;
    reg saw_reload_queue_capture = 1'b0;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(18),
        .MAX_NODES(2), .FEATURE_DIM(2), .HIDDEN_DIM(2)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awprot(3'd0), .s_axi_arprot(3'd0),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(18'd0), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .s_axis_job_tdata(s_data), .s_axis_job_tkeep(s_keep),
        .s_axis_job_tvalid(s_valid), .s_axis_job_tready(s_ready),
        .s_axis_job_tlast(s_last),
        .m_axis_result_tdata(m_data), .m_axis_result_tkeep(m_keep),
        .m_axis_result_tvalid(m_valid), .m_axis_result_tready(m_ready),
        .m_axis_result_tlast(m_last),
        .engine_start(engine_start),
        .lcd_pixel_clk(1'b0), .lcd_aresetn(1'b0),
        .lcd_clock_locked(1'b0)
    );

    task automatic axi_write(input [17:0] address, input [31:0] value);
        begin
            @(negedge clk);
            awaddr = address;
            awvalid = 1'b1;
            wdata = value;
            wstrb = 4'hf;
            wvalid = 1'b1;
            bready = 1'b1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid = 1'b0;
            wvalid = 1'b0;
            while (!bvalid) @(negedge clk);
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task automatic begin_batch(input integer task_count);
        begin
            request_count = 8;
            response_count = 0;
            expected_tasks = task_count;
            expected_count = 0;
            batch_sequence = batch_sequence + 1;
            request[0] = 32'h4d4f4c51;
            request[1] = 32'h00080001;
            request[2] = 32'h60000000 + batch_sequence;
            request[3] = task_count;
            request[4] = 0;
            request[5] = 1;
            request[6] = MAX_WORDS;
            request[7] = 0;
        end
    endtask

    task automatic add_task(
        input [31:0] job,
        input [7:0] id,
        input [31:0] flags,
        input integer payload_words,
        input integer result_words,
        input integer items,
        input [31:0] tag
    );
        integer p;
        begin
            request[request_count+0] = job;
            request[request_count+1] = flags | id;
            request[request_count+2] = payload_words;
            request[request_count+3] = result_words;
            request[request_count+4] = items;
            request[request_count+5] = tag;
            request[request_count+6] = 1000000;
            request[request_count+7] = 0;
            request_count = request_count + 8;
            for (p = 0; p < payload_words; p = p + 1) begin
                if (id == 0 || (id == 3 && p < 64))
                    request[request_count+p] = 32'hffff_ffff;
                else
                    request[request_count+p] = 0;
            end
            request_count = request_count + payload_words;
            expected_job[expected_count] = job;
            expected_task[expected_count] = id;
            expected_result_words[expected_count] = result_words;
            expected_items[expected_count] = items;
            expected_tag[expected_count] = tag;
            expected_status[expected_count] = 24'd0;
            expected_detail[expected_count] = 32'd0;
            expected_count = expected_count + 1;
        end
    endtask

    task automatic add_unsupported_full_task(
        input [31:0] job,
        input [7:0] id,
        input integer payload_words,
        input integer result_capacity,
        input [31:0] tag
    );
        begin
            add_task(job, id, 32'h100, payload_words,
                     result_capacity, 2, tag);
            expected_result_words[expected_count-1] = 0;
            expected_status[expected_count-1] = 24'd11;
            expected_detail[expected_count-1] = 32'h4655_4c4c;
        end
    endtask

    task automatic send_batch;
        integer beat;
        integer remaining;
        begin
            request[4] = request_count;
            for (beat = 0; beat < (request_count+3)/4; beat = beat + 1) begin
                remaining = request_count - beat*4;
                @(negedge clk);
                s_data = 0;
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (lane < remaining)
                        s_data[lane*32 +: 32] = request[beat*4+lane];
                case (remaining)
                    1: s_keep = 16'h000f;
                    2: s_keep = 16'h00ff;
                    3: s_keep = 16'h0fff;
                    default: s_keep = 16'hffff;
                endcase
                s_last = (beat == (request_count+3)/4-1);
                s_valid = 1;
                while (!s_ready) @(negedge clk);
                @(negedge clk);
                s_valid = 0;
                s_last = 0;
            end
        end
    endtask

    task automatic check_response(input [8*40-1:0] label);
        integer cursor;
        integer t;
        integer p;
        integer wanted_words;
        integer expected_errors;
        reg [31:0] expected_first_error_job;
        begin
            wanted_words = 16;
            expected_errors = 0;
            expected_first_error_job = 32'hffff_ffff;
            for (t = 0; t < expected_tasks; t = t + 1)
                wanted_words = wanted_words + 8 + expected_result_words[t];
            for (t = 0; t < expected_tasks; t = t + 1)
                if (expected_status[t] != 0) begin
                    if (expected_errors == 0)
                        expected_first_error_job = expected_job[t];
                    expected_errors = expected_errors + 1;
                end
            repeat (3000000) begin
                @(posedge clk);
                if (response_count == wanted_words) begin
                    if (response[0] !== 32'h4d4f4c52 ||
                        response[2] !== request[2] || response[3] !== expected_tasks ||
                        response[4] !== 0)
                        $fatal(1, "%0s response header mismatch", label);
                    cursor = 8;
                    for (t = 0; t < expected_tasks; t = t + 1) begin
                        if (response[cursor+0] !== expected_job[t] ||
                            response[cursor+1] !==
                                {expected_status[t], expected_task[t]} ||
                            response[cursor+2] !== expected_result_words[t] ||
                            response[cursor+5] !== expected_items[t] ||
                            response[cursor+6] !== expected_tag[t] ||
                            response[cursor+7] !== expected_detail[t])
                            $fatal(1, "%0s record %0d header mismatch at %0d",
                                   label, t, cursor);
                        if (expected_task[t] == 0)
                            for (p = 0; p < expected_result_words[t]; p = p + 1)
                                if (response[cursor+8+p] !== 32'h00010000)
                                    $fatal(1, "%0s Tanimoto result %0d mismatch", label, p);
                        if (expected_task[t] == 2)
                            for (p = 0; p < expected_result_words[t]; p = p + 1)
                                if (response[cursor+8+p] !== 32'h00000100)
                                    $fatal(1, "%0s ADMET result %0d mismatch: %08x",
                                           label, p, response[cursor+8+p]);
                        if (expected_task[t] == `MOL_DMA_TASK_WEIGHT_RELOAD &&
                            response[cursor+8] !== 32'd1)
                            $fatal(1, "%0s reload epoch mismatch: %08x",
                                   label, response[cursor+8]);
                        cursor = cursor + 8 + expected_result_words[t];
                    end
                    if (response[cursor] !== 32'h4d4f4c45 ||
                        response[cursor+1] !== request[2] ||
                        response[cursor+2] !== expected_tasks ||
                        response[cursor+3] !== expected_errors ||
                        response[cursor+4] !== wanted_words ||
                        response[cursor+5] !== 0 ||
                        response[cursor+6] !== expected_first_error_job ||
                        response[cursor+7] !== 0)
                        $fatal(1, "%0s trailer mismatch at %0d", label, cursor);
                    $display("PASS %0s (%0d tasks, %0d result words)",
                             label, expected_tasks, wanted_words);
                    disable check_response;
                end
            end
            $fatal(1, "%0s timeout: received %0d/%0d words",
                   label, response_count, wanted_words);
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n)
            engine_launch_count <= 0;
        else if (|engine_start)
            engine_launch_count <= engine_launch_count + 1;
        if (rst_n && !dut.dma_active && dut.core_gnn_weight_we) begin
            if (dut.core_weight_cfg_bank !== 1'b1)
                $fatal(1, "D: legacy GNN config selected bank0");
            saw_legacy_gnn_cfg_bank1 <= 1'b1;
        end
        if (rst_n && !dut.dma_active && dut.core_admet_cfg_we) begin
            if (dut.core_weight_cfg_bank !== 1'b1)
                $fatal(1, "D: legacy ADMET config selected bank0");
            saw_legacy_admet_cfg_bank1 <= 1'b1;
        end
        if (rst_n && dut.backend_result_valid && dut.backend_result_ready &&
            dut.u_dma_backend.reload_controller.reload_good) begin
            if (!dut.u_dma_queue.capture_active || dut.backend_abort)
                $fatal(1, "reload commit was not an abort-safe queue capture");
            saw_reload_queue_capture <= 1'b1;
        end
        if (rst_n && m_valid && m_ready) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                if (m_keep[lane*4 +: 4] == 4'hf) begin
                    response[response_count] = m_data[lane*32 +: 32];
                    response_count = response_count + 1;
                end
        end
    end

    initial begin
        integer launches_before;
        batch_sequence = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        begin_batch(2);
        add_task(1, 1, 0, 1679, 1, 1, 32'ha001);
        add_task(2, 1, 32'h100, 1679, 3200, 1, 32'ha002);
        send_batch();
        check_response("GNN summary/full");

        begin_batch(2);
        add_task(3, 2, 0, 20, 4, 1, 32'ha003);
        add_task(4, 2, 0, 1280, 256, 64, 32'ha004);
        send_batch();
        check_response("ADMET N=1/64");

        begin_batch(3);
        add_task(5, 3, 0, 1763, 4, 1, 32'ha005);
        add_task(6, 3, 32'h200, 1763, 6, 1, 32'ha006);
        add_task(7, 3, 32'h100, 1763, 3205, 1, 32'ha007);
        send_batch();
        check_response("Pipeline result modes");

        begin_batch(5);
        add_task(8, 0, 0, 64, 1, 1, 32'ha008);
        add_task(9, 0, 32'h400, 2080, 64, 64, 32'ha009);
        add_task(10, 1, 0, 1679, 1, 1, 32'ha00a);
        add_task(11, 2, 0, 40, 8, 2, 32'ha00b);
        add_task(12, 3, 0, 1763, 4, 1, 32'ha00c);
        send_batch();
        check_response("mixed 0/1/2/3 batch");

        launches_before = engine_launch_count;
        begin_batch(2);
        add_unsupported_full_task(13, 1, 3358, 6400, 32'ha00d);
        add_unsupported_full_task(14, 3, 3526, 6410, 32'ha00e);
        send_batch();
        check_response("batched FULL explicit unsupported");
        if (engine_launch_count != launches_before)
            $fatal(1, "unsupported FULL tasks launched a core: %0d -> %0d",
                   launches_before, engine_launch_count);

        // D: a completed DMA activation is also the bank used and configured
        // by the later legacy/MMIO path.
        begin_batch(1);
        add_task(15, `MOL_DMA_TASK_WEIGHT_RELOAD, 0, 4538, 1, 1,
                 32'hcb3f_efe2);
        expected_detail[expected_count-1] = 32'hcb3f_efe2;
        send_batch();
        check_response("reload then legacy");
        wait (dut.dma_active === 1'b0);
        repeat (2) @(posedge clk);
        if (dut.core_weight_run_bank !== 1'b1 ||
            dut.core_weight_cfg_bank !== 1'b1)
            $fatal(1, "D RED: legacy path reverted to bank0 after DMA activation");
        if (!saw_reload_queue_capture)
            $fatal(1, "reload result did not commit through queue capture");

        axi_write(18'h00400, 32'h0000_beef);
        axi_write(18'h00404, 32'd0);
        axi_write(18'h00410, 32'h0000_1234);
        axi_write(18'h00414, 32'd0);
        if (!saw_legacy_gnn_cfg_bank1 || !saw_legacy_admet_cfg_bank1)
            $fatal(1, "D: legacy config pulses missing GNN/ADMET=%b/%b",
                   saw_legacy_gnn_cfg_bank1, saw_legacy_admet_cfg_bank1);
        axi_write(18'h00000, 32'h0000_0003);
        wait (dut.gnn_start === 1'b1);
        @(posedge clk);
        @(negedge clk);
        if (dut.u_gnn.active_weight_bank !== 1'b1)
            $fatal(1, "D: legacy GNN start did not latch global bank1");

        $display("ALL TOP DMA TASK TESTS PASSED");
        $finish;
    end
endmodule
