`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_weight_bank_switch;
    localparam integer MAX_NODES = 1;
    localparam integer FEATURE_DIM = 64;
    localparam integer HIDDEN_DIM = 128;
    localparam integer DATA_WIDTH = 16;
    localparam integer PIPELINE_WORDS = 1763;
    localparam integer RELOAD_WORDS = `MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
    localparam [31:0] IMAGE1_CRC = 32'h80d1_f408;
    localparam [31:0] IMAGE2_CRC = 32'hbad3_f073;
    localparam [31:0] BAD2_CRC = 32'hbceb_e904;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg [7:0] task_id = 0;
    reg [31:0] task_flags = 0;
    reg [31:0] task_user_tag = 0;
    reg [5:0] task_sequence = 0;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_data = 0;
    reg payload_last = 1'b0;
    wire done_valid;
    reg done_ready = 1'b1;
    wire [23:0] done_status;
    wire [31:0] done_result_words;
    wire [31:0] done_detail;
    wire [5:0] done_sequence;
    wire result_valid;
    reg result_ready = 1'b1;
    wire [31:0] result_data;

    wire tanimoto_start;
    reg [5:0] tanimoto_countdown = 0;
    wire tanimoto_busy = tanimoto_countdown != 0;
    wire tanimoto_valid = tanimoto_countdown == 1;

    wire gnn_start;
    wire gnn_input_write_bank;
    wire gnn_input_run_bank;
    wire gnn_feature_we;
    wire [4:0] gnn_feature_addr;
    wire [31:0] gnn_feature_wdata;
    wire [3:0] gnn_feature_wstrb;
    wire gnn_adjacency_we;
    wire [0:0] gnn_adjacency_addr;
    wire [31:0] gnn_adjacency_wdata;
    wire [3:0] gnn_adjacency_wstrb;
    wire gnn_output_re;
    wire [5:0] gnn_output_addr;
    wire [31:0] gnn_output_rdata;
    wire gnn_busy;
    wire gnn_valid;
    wire backend_gnn_weight_we;
    wire [12:0] backend_gnn_weight_addr;
    wire [15:0] backend_gnn_weight_wdata;

    wire admet_start;
    wire admet_input_write_bank;
    wire admet_input_run_bank;
    wire descriptor_we;
    wire [4:0] descriptor_addr;
    wire [15:0] descriptor_wdata;
    reg [20*DATA_WIDTH*2-1:0] descriptor_buffer = 0;
    wire [20*DATA_WIDTH-1:0] active_descriptors =
        admet_input_run_bank ? descriptor_buffer[20*DATA_WIDTH +: 20*DATA_WIDTH] :
                               descriptor_buffer[0 +: 20*DATA_WIDTH];
    wire admet_busy;
    wire admet_valid;
    wire [4*DATA_WIDTH-1:0] admet_predictions;
    wire backend_admet_cfg_we;
    wire [1:0] backend_admet_cfg_model;
    wire [1:0] backend_admet_cfg_layer;
    wire [15:0] backend_admet_cfg_addr;
    wire [15:0] backend_admet_cfg_wdata;
    wire weight_cfg_bank;
    wire weight_run_bank;

    reg manual_cfg = 1'b0;
    reg manual_gnn_we = 1'b0;
    reg [12:0] manual_gnn_addr = 0;
    reg [15:0] manual_gnn_data = 0;
    reg manual_admet_we = 1'b0;
    reg [1:0] manual_admet_model = 0;
    reg [1:0] manual_admet_layer = 0;
    reg [15:0] manual_admet_addr = 0;
    reg [15:0] manual_admet_data = 0;
    wire core_gnn_weight_we = manual_cfg ? manual_gnn_we : backend_gnn_weight_we;
    wire [12:0] core_gnn_weight_addr =
        manual_cfg ? manual_gnn_addr : backend_gnn_weight_addr;
    wire [15:0] core_gnn_weight_data =
        manual_cfg ? manual_gnn_data : backend_gnn_weight_wdata;
    wire core_admet_cfg_we = manual_cfg ? manual_admet_we : backend_admet_cfg_we;
    wire [1:0] core_admet_cfg_model =
        manual_cfg ? manual_admet_model : backend_admet_cfg_model;
    wire [1:0] core_admet_cfg_layer =
        manual_cfg ? manual_admet_layer : backend_admet_cfg_layer;
    wire [15:0] core_admet_cfg_addr =
        manual_cfg ? manual_admet_addr : backend_admet_cfg_addr;
    wire [15:0] core_admet_cfg_data =
        manual_cfg ? manual_admet_data : backend_admet_cfg_wdata;
    wire core_cfg_bank = manual_cfg ? 1'b0 : weight_cfg_bank;

    reg done_seen [0:63];
    reg [23:0] seen_status [0:63];
    reg [31:0] seen_words [0:63];
    reg [31:0] seen_detail [0:63];
    reg [31:0] seen_result [0:63][0:7];
    integer seen_result_count [0:63];
    reg capture_active = 1'b0;
    reg [5:0] capture_sequence = 0;
    integer capture_index = 0;
    reg saw_gnn_reload_overlap = 1'b0;
    reg saw_gnn_bank1_high_address = 1'b0;

    function automatic [15:0] reload_half(
        input integer image,
        input integer half_index
    );
        integer admet_offset;
        begin
            reload_half = 16'd0;
            if (half_index == 0)
                reload_half = (image == 1) ? 16'd512 : 16'd768;
            else if (half_index == 1)
                reload_half = (image == 1) ? 16'h1234 : 16'h4321;
            else if (half_index == 2)
                reload_half = (image == 1) ? 16'h00ab : 16'h00cd;
            else if (half_index == 8191)
                reload_half = (image == 1) ? 16'h5aa5 : 16'ha55a;
            else if (half_index >= 8192) begin
                admet_offset = (half_index-8192) % 221;
                if (admet_offset == 0)
                    reload_half = (image == 1) ? 16'd512 : 16'd768;
                else if (admet_offset == 1)
                    reload_half = ((((half_index-8192) / 221) + 1) *
                                   16'h1111 + image) & 16'hffff;
                else if (admet_offset == 210)
                    reload_half = 16'd256;
                else if (admet_offset == 199 || admet_offset == 209 ||
                         admet_offset == 219 || admet_offset == 220)
                    reload_half = 16'd128;
            end
        end
    endfunction

    function automatic [31:0] reload_word(
        input integer image,
        input integer word_index
    );
        reload_word = {reload_half(image, word_index*2+1),
                       reload_half(image, word_index*2)};
    endfunction

    function automatic [31:0] pipeline_word(input integer word_index);
        integer feature_word;
        begin
            pipeline_word = 32'd0;
            if (word_index >= 64 && word_index < 143)
                pipeline_word = 32'd1;
            else if (word_index >= 143 && word_index < 1743) begin
                feature_word = word_index - 143;
                if ((feature_word % 32) == 0)
                    pipeline_word = 32'h0000_0100;
            end else if (word_index == 1743 || word_index == 1762)
                pipeline_word = 32'h0000_0100;
        end
    endfunction

    dma_accelerator_backend #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(task_id), .task_flags(task_flags), .task_item_count(32'd1),
        .task_user_tag(task_user_tag), .task_sequence(task_sequence),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_status(done_status), .done_result_words(done_result_words),
        .done_detail(done_detail), .done_sequence(done_sequence),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .abort(1'b0),
        .engine_busy(), .engine_start(), .engine_done(),
        .tanimoto_start(tanimoto_start), .fingerprint_we(),
        .fingerprint_db_select(), .fingerprint_addr(), .fingerprint_wdata(),
        .tanimoto_input_write_bank(), .tanimoto_input_run_bank(),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(32'h1111_0001),
        .gnn_start(gnn_start), .gnn_input_write_bank(gnn_input_write_bank),
        .gnn_input_run_bank(gnn_input_run_bank),
        .gnn_feature_we(gnn_feature_we), .gnn_feature_addr(gnn_feature_addr),
        .gnn_feature_wdata(gnn_feature_wdata),
        .gnn_feature_wstrb(gnn_feature_wstrb),
        .gnn_adjacency_we(gnn_adjacency_we),
        .gnn_adjacency_addr(gnn_adjacency_addr),
        .gnn_adjacency_wdata(gnn_adjacency_wdata),
        .gnn_adjacency_wstrb(gnn_adjacency_wstrb),
        .gnn_output_re(gnn_output_re), .gnn_output_addr(gnn_output_addr),
        .gnn_output_rdata(gnn_output_rdata), .gnn_busy(gnn_busy),
        .gnn_valid(gnn_valid), .gnn_weight_we(backend_gnn_weight_we),
        .gnn_weight_addr(backend_gnn_weight_addr),
        .gnn_weight_wdata(backend_gnn_weight_wdata),
        .admet_start(admet_start),
        .admet_input_write_bank(admet_input_write_bank),
        .admet_input_run_bank(admet_input_run_bank),
        .descriptor_we(descriptor_we), .descriptor_addr(descriptor_addr),
        .descriptor_wdata(descriptor_wdata), .admet_busy(admet_busy),
        .admet_valid(admet_valid), .admet_predictions(admet_predictions),
        .admet_cfg_we(backend_admet_cfg_we),
        .admet_cfg_model(backend_admet_cfg_model),
        .admet_cfg_layer(backend_admet_cfg_layer),
        .admet_cfg_addr(backend_admet_cfg_addr),
        .admet_cfg_wdata(backend_admet_cfg_wdata),
        .weight_cfg_bank(weight_cfg_bank), .weight_run_bank(weight_run_bank)
    );

    gnn_message_passing #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH),
        .AGG_FEATURE_LANES(1), .HIDDEN_LANES(2), .MAC_FEATURE_LANES(1)
    ) gnn_core (
        .clk(clk), .rst_n(rst_n), .start(gnn_start),
        .input_write_bank(gnn_input_write_bank),
        .input_run_bank(gnn_input_run_bank),
        .node_features_in({MAX_NODES*FEATURE_DIM*DATA_WIDTH{1'b0}}),
        .adjacency_in({MAX_NODES*MAX_NODES{1'b0}}), .node_features_out(),
        .feature_we(gnn_feature_we), .feature_word_addr(gnn_feature_addr),
        .feature_wdata(gnn_feature_wdata), .feature_wstrb(gnn_feature_wstrb),
        .adjacency_we(gnn_adjacency_we),
        .adjacency_word_addr(gnn_adjacency_addr),
        .adjacency_wdata(gnn_adjacency_wdata),
        .adjacency_wstrb(gnn_adjacency_wstrb),
        .output_re(gnn_output_re), .output_word_addr(gnn_output_addr),
        .output_rdata(gnn_output_rdata), .weight_we(core_gnn_weight_we),
        .weight_addr(core_gnn_weight_addr), .weight_wdata(core_gnn_weight_data),
        .cfg_bank(core_cfg_bank), .run_bank(weight_run_bank),
        .busy(gnn_busy), .valid(gnn_valid)
    );

    admet_predictor admet_core (
        .clk(clk), .rst_n(rst_n), .start(admet_start),
        .descriptors(active_descriptors), .cfg_we(core_admet_cfg_we),
        .cfg_model(core_admet_cfg_model), .cfg_layer(core_admet_cfg_layer),
        .cfg_addr(core_admet_cfg_addr), .cfg_wdata(core_admet_cfg_data),
        .cfg_bank(core_cfg_bank), .run_bank(weight_run_bank),
        .busy(admet_busy), .valid(admet_valid), .logp(),
        .oral_bioavailability(), .herg_ic50(), .bbb_permeability(),
        .predictions(admet_predictions)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            tanimoto_countdown <= 0;
            capture_active <= 1'b0;
            saw_gnn_reload_overlap <= 1'b0;
            saw_gnn_bank1_high_address <= 1'b0;
        end else begin
            if (tanimoto_start)
                tanimoto_countdown <= 6'd20;
            else if (tanimoto_countdown != 0)
                tanimoto_countdown <= tanimoto_countdown - 1'b1;
            if (descriptor_we)
                descriptor_buffer[(admet_input_write_bank*20 + descriptor_addr)*
                                  DATA_WIDTH +: DATA_WIDTH] <= descriptor_wdata;
            if (backend_gnn_weight_we && gnn_busy)
                saw_gnn_reload_overlap <= 1'b1;
            if (backend_gnn_weight_we && weight_cfg_bank &&
                backend_gnn_weight_addr == 13'd8191) begin
                if (gnn_core.weight_write_addr != 13'd8191)
                    $fatal(1, "GNN bank1 highest physical address=%0d",
                           gnn_core.weight_write_addr);
                saw_gnn_bank1_high_address <= 1'b1;
            end
            if (done_valid && done_ready) begin
                done_seen[done_sequence] <= 1'b1;
                seen_status[done_sequence] <= done_status;
                seen_words[done_sequence] <= done_result_words;
                seen_detail[done_sequence] <= done_detail;
                capture_sequence <= done_sequence;
                capture_index <= 0;
                capture_active <= done_result_words != 0;
            end
            if (result_valid && result_ready && capture_active) begin
                seen_result[capture_sequence][capture_index] <= result_data;
                seen_result_count[capture_sequence] <= capture_index + 1;
                if (capture_index + 1 == seen_words[capture_sequence])
                    capture_active <= 1'b0;
                else
                    capture_index <= capture_index + 1;
            end
        end
    end

    task automatic pulse_gnn_config(input integer address, input [15:0] value);
        begin
            @(negedge clk);
            manual_gnn_addr = address[12:0];
            manual_gnn_data = value;
            manual_gnn_we = 1'b1;
            @(negedge clk);
            manual_gnn_we = 1'b0;
        end
    endtask

    task automatic pulse_admet_config(
        input integer model,
        input [1:0] layer,
        input integer address,
        input [15:0] value
    );
        begin
            @(negedge clk);
            manual_admet_model = model[1:0];
            manual_admet_layer = layer;
            manual_admet_addr = address[15:0];
            manual_admet_data = value;
            manual_admet_we = 1'b1;
            @(negedge clk);
            manual_admet_we = 1'b0;
        end
    endtask

    task automatic send_task(
        input [7:0] id,
        input [31:0] flags,
        input [31:0] expected_crc,
        input [5:0] seq
    );
        begin
            @(negedge clk);
            task_id = id;
            task_flags = flags;
            task_user_tag = expected_crc;
            task_sequence = seq;
            while (!task_ready) @(negedge clk);
            task_valid = 1'b1;
            @(negedge clk);
            task_valid = 1'b0;
        end
    endtask

    task automatic send_word(input [31:0] value, input bit last_word);
        begin
            payload_data = value;
            payload_last = last_word;
            while (!payload_ready) @(negedge clk);
            payload_valid = 1'b1;
            @(negedge clk);
            payload_valid = 1'b0;
            payload_last = 1'b0;
        end
    endtask

    task automatic send_pipeline(input [5:0] seq);
        integer word_index;
        begin
            send_task(`MOL_DMA_TASK_PIPELINE,
                      `MOL_DMA_FLAG_RETURN_INTERMEDIATE, 32'd0, seq);
            for (word_index = 0; word_index < PIPELINE_WORDS;
                 word_index = word_index + 1)
                send_word(pipeline_word(word_index),
                          word_index == PIPELINE_WORDS-1);
        end
    endtask

    task automatic send_reload(
        input integer image,
        input bit corrupt,
        input [31:0] expected_crc,
        input [5:0] seq,
        input bit expected_active_bank
    );
        integer word_index;
        reg [31:0] value;
        begin
            send_task(`MOL_DMA_TASK_WEIGHT_RELOAD, 32'd0, expected_crc, seq);
            if (weight_cfg_bank == expected_active_bank)
                $fatal(1, "reload seq=%0d did not latch inactive bank", seq);
            for (word_index = 0; word_index < RELOAD_WORDS;
                 word_index = word_index + 1) begin
                value = reload_word(image, word_index);
                if (corrupt && word_index == 17)
                    value = value ^ 32'd1;
                send_word(value, word_index == RELOAD_WORDS-1);
                if (word_index != RELOAD_WORDS-1 &&
                    weight_run_bank !== expected_active_bank)
                    $fatal(1, "reload seq=%0d exposed a partial bank", seq);
            end
        end
    endtask

    task automatic wait_task(input [5:0] seq);
        begin
            while (!(done_seen[seq] &&
                     seen_result_count[seq] == seen_words[seq]))
                @(posedge clk);
        end
    endtask

    task automatic check_pipeline(
        input [5:0] seq,
        input [15:0] expected_gnn,
        input [15:0] expected_admet
    );
        integer model;
        begin
            wait_task(seq);
            if (seen_status[seq] != 0 || seen_words[seq] != 6)
                $fatal(1, "Pipeline seq=%0d status=%h words=%0d",
                       seq, seen_status[seq], seen_words[seq]);
            if (seen_result[seq][1][15:0] != expected_gnn)
                $fatal(1, "Pipeline seq=%0d GNN=%h expected=%h",
                       seq, seen_result[seq][1][15:0], expected_gnn);
            for (model = 0; model < 4; model = model + 1)
                if (seen_result[seq][model+2][15:0] != expected_admet)
                    $fatal(1, "Pipeline seq=%0d ADMET%0d=%h expected=%h",
                           seq, model, seen_result[seq][model+2][15:0],
                           expected_admet);
        end
    endtask

    initial begin : test
        integer index;
        integer model;
        integer address;
        reg [23:0] held_status;
        reg [31:0] held_detail;

        for (index = 0; index < 64; index = index + 1) begin
            done_seen[index] = 1'b0;
            seen_result_count[index] = 0;
        end
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Initialize bank 0 to GNN weight 1.0 and ADMET sigmoid(1.0).
        manual_cfg = 1'b1;
        for (address = 0; address < 8192; address = address + 1)
            pulse_gnn_config(address, address == 0 ? 16'd256 : 16'd0);
        for (model = 0; model < 4; model = model + 1) begin
            for (address = 0; address < 200; address = address + 1)
                pulse_admet_config(model, 2'd0, address,
                                   address == 0 ? 16'd256 : 16'd0);
            for (address = 0; address < 10; address = address + 1)
                pulse_admet_config(model, 2'd1, address, 16'd0);
            for (address = 0; address < 10; address = address + 1)
                pulse_admet_config(model, 2'd2, address,
                                   address == 0 ? 16'd256 : 16'd0);
            pulse_admet_config(model, 2'd3, 0, 16'd0);
        end
        manual_cfg = 1'b0;

        // Pipeline latches bank 0, then image 1 reloads bank 1 while it runs.
        send_pipeline(6'd1);
        wait (gnn_busy && admet_busy);
        send_reload(1, 1'b0, IMAGE1_CRC, 6'd2, 1'b0);
        wait_task(6'd2);
        if (seen_status[2] != 0 || seen_detail[2] != IMAGE1_CRC ||
            seen_result[2][0] != 1 || weight_run_bank != 1'b1)
            $fatal(1, "image1 activation mismatch status=%h detail=%h epoch=%0d bank=%b",
                   seen_status[2], seen_detail[2], seen_result[2][0],
                   weight_run_bank);
        if (!saw_gnn_reload_overlap)
            $fatal(1, "no real GNN inference overlapped reload writes");
        if (!saw_gnn_bank1_high_address)
            $fatal(1, "GNN bank1 highest address was not exercised");
        check_pipeline(6'd1, 16'd256, 16'd187);

        // Corruption reports Python-zlib observed CRC and cannot flip/advance.
        send_reload(2, 1'b1, IMAGE2_CRC, 6'd3, 1'b1);
        done_ready = 1'b0;
        wait (done_valid && done_sequence == 6'd3);
        held_status = done_status;
        held_detail = done_detail;
        repeat (3) @(posedge clk);
        if (!done_valid || done_status != held_status || done_detail != held_detail)
            $fatal(1, "reload detail/status changed under backpressure");
        if (held_status != `MOL_DMA_STATUS_INTERNAL_ERROR ||
            held_detail != BAD2_CRC)
            $fatal(1, "bad CRC status=%h observed=%h", held_status, held_detail);
        result_ready = 1'b0;
        @(negedge clk);
        done_ready = 1'b1;
        wait (result_valid);
        repeat (3) @(posedge clk);
        if (!result_valid || result_data != 1)
            $fatal(1, "bad CRC epoch result changed under backpressure");
        @(negedge clk);
        result_ready = 1'b1;
        wait_task(6'd3);
        if (weight_run_bank != 1'b1)
            $fatal(1, "bad CRC flipped active bank");
        send_pipeline(6'd4);
        check_pipeline(6'd4, 16'd512, 16'd238);

        // Rewrite the inactive bank correctly, toggle back, and advance epoch.
        send_reload(2, 1'b0, IMAGE2_CRC, 6'd5, 1'b1);
        wait_task(6'd5);
        if (seen_status[5] != 0 || seen_detail[5] != IMAGE2_CRC ||
            seen_result[5][0] != 2 || weight_run_bank != 1'b0)
            $fatal(1, "image2 activation mismatch");
        send_pipeline(6'd6);
        check_pipeline(6'd6, 16'd768, 16'd251);

        // Reset restores bank 0 / epoch 0 even after both directions toggled.
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        if (weight_run_bank !== 1'b0 || dut.reload_controller.reload_epoch != 0)
            $fatal(1, "reset did not restore bank/epoch");

        $display("PASS CRC-verified GNN/ADMET A/B banks, atomic Pipeline latch and backpressure");
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "weight bank switch timeout");
    end
endmodule
