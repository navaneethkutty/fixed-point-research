`timescale 1ns/1ps

module tb_reciprocal_direct_lut_q8_24;

    localparam int NVEC = 1_000_001;
    localparam real CLK_PERIOD_NS = 2.58;
    localparam real Q_SCALE = 16777216.0;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    logic [31:0] test_x [0:NVEC-1];
    logic [31:0] test_golden [0:NVEC-1];

    initial begin
        $readmemh("q8_24_input.mem", test_x);
        $readmemh("q8_24_expected.mem", test_golden);

        if (^test_x[0] === 1'bx)
            $fatal(1, "ERROR: q8_24_input.mem failed to load.");

        if (^test_golden[0] === 1'bx)
            $fatal(1, "ERROR: q8_24_expected.mem failed to load.");
    end

    logic valid_in;
    logic [31:0] x_in;
    logic valid_out;
    logic [31:0] recip_out;

    reciprocal_direct_lut_q8_24 u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .x_in      (x_in),
        .valid_out (valid_out),
        .recip_out (recip_out)
    );

    int drive_idx;
    int out_idx;
    longint cycle_count;

    longint unsigned max_abs_err;
    longint unsigned sum_abs_err;
    longint unsigned sum_sq_err;
    longint worst_idx;

    longint first_input_cycle;
    longint first_output_cycle;

    real mae_lsb;
    real mae_value;
    real rms_error_lsb;
    real max_error_value;
    real relative_err;
    real max_relative_err;
    real latency_cycles;
    real latency_ns;
    real throughput_msps;

    time t_start;
    time t_end;

    int fd_csv;
    int fd_summary;

    function automatic longint signed signed32(input logic [31:0] value);
        signed32 = $signed(value);
    endfunction

    initial begin
        valid_in = 1'b0;
        x_in = '0;
        drive_idx = 0;

        repeat (4) @(posedge clk);

        @(negedge clk);
        rst_n = 1'b1;

        t_start = $time;

        while (drive_idx < NVEC) begin
            valid_in = 1'b1;
            x_in = test_x[drive_idx];
            drive_idx = drive_idx + 1;
            @(negedge clk);
        end

        valid_in = 1'b0;
        x_in = '0;
    end

    initial begin
        out_idx = 0;
        cycle_count = 0;

        max_abs_err = 0;
        sum_abs_err = 0;
        sum_sq_err = 0;
        worst_idx = -1;

        first_input_cycle = -1;
        first_output_cycle = -1;

        max_relative_err = 0.0;

        fd_csv = $fopen("direct_lut_results.csv", "w");
        fd_summary = $fopen("direct_lut_summary.txt", "w");

        if (fd_csv == 0)
            $fatal(1, "ERROR: Could not open direct_lut_results.csv.");

        if (fd_summary == 0)
            $fatal(1, "ERROR: Could not open direct_lut_summary.txt.");

        $fwrite(fd_csv,
                "idx,x_hex,golden_hex,hw_hex,abs_err_lsb,relative_err\n");
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (rst_n && valid_in) begin
            if (first_input_cycle < 0)
                first_input_cycle = cycle_count;
        end
    end

    always @(negedge clk) begin

        if (rst_n && valid_out) begin

            longint signed hw_value;
            longint signed golden_value;
            longint signed error;
            longint unsigned abs_error;

            if (out_idx >= NVEC)
                $fatal(1, "ERROR: More outputs than expected.");

            if (^recip_out === 1'bx)
                $fatal(1,
                    "ERROR: X detected on recip_out at output index %0d.",
                    out_idx);

            hw_value = signed32(recip_out);
            golden_value = signed32(test_golden[out_idx]);

            error = hw_value - golden_value;

            if (error < 0)
                abs_error = -error;
            else
                abs_error = error;

            if (abs_error > max_abs_err) begin
                max_abs_err = abs_error;
                worst_idx = out_idx;
            end

            sum_abs_err = sum_abs_err + abs_error;
            sum_sq_err = sum_sq_err + abs_error * abs_error;

            if (golden_value != 0)
                relative_err =
                    real'(abs_error) / real'(
                        (golden_value < 0) ?
                        -golden_value :
                        golden_value
                    );
            else
                relative_err = 0.0;

            if (relative_err > max_relative_err)
                max_relative_err = relative_err;

            if (out_idx == 0)
                first_output_cycle = cycle_count;

            $fwrite(fd_csv,
                    "%0d,%08h,%08h,%08h,%0d,%.12f\n",
                    out_idx,
                    test_x[out_idx],
                    test_golden[out_idx],
                    recip_out,
                    abs_error,
                    relative_err);

            out_idx = out_idx + 1;

            if (out_idx == NVEC) begin
                t_end = $time;
                report_results();
            end
        end
    end

    task automatic report_results();

        mae_lsb =
            real'(sum_abs_err) / real'(NVEC);

        mae_value =
            mae_lsb / Q_SCALE;

        rms_error_lsb =
            $sqrt(real'(sum_sq_err) / real'(NVEC));

        max_error_value =
            real'(max_abs_err) / Q_SCALE;

        latency_cycles =
            real'(first_output_cycle - first_input_cycle);

        latency_ns =
            latency_cycles * CLK_PERIOD_NS;

        throughput_msps =
            1000.0 / CLK_PERIOD_NS;

        $display("");
        $display("============================================================");
        $display("reciprocal_direct_lut_q8_24 verification");
        $display("============================================================");
        $display("Test vectors        : %0d", NVEC);
        $display("Input range         : [0.5, 2.5]");
        $display("Quantization        : Q8.24");
        $display("Simulation clock    : %.3f MHz",
                 1000.0 / CLK_PERIOD_NS);
        $display("Clock period        : %.3f ns",
                 CLK_PERIOD_NS);
        $display("Latency             : %.0f cycles",
                 latency_cycles);
        $display("Latency             : %.3f ns",
                 latency_ns);
        $display("Throughput          : %.3f Msps",
                 throughput_msps);
        $display("Max absolute error  : %0d LSB",
                 max_abs_err);
        $display("Max absolute error  : %.12f",
                 max_error_value);
        $display("Mean absolute error : %.6f LSB",
                 mae_lsb);
        $display("Mean absolute error : %.12f",
                 mae_value);
        $display("Max relative error  : %.12f %%",
                 max_relative_err * 100.0);
        $display("RMS error           : %.6f LSB",
                 rms_error_lsb);
        $display("Worst-case index    : %0d",
                 worst_idx);

        if (worst_idx >= 0)
            $display("Worst-case input    : %08h",
                     test_x[worst_idx]);

        $display("Simulation span     : %.3f ns",
                 real'(t_end - t_start));
        $display("============================================================");

        $fwrite(fd_summary,
                "============================================================\n");
        $fwrite(fd_summary,
                "reciprocal_direct_lut_q8_24 verification\n");
        $fwrite(fd_summary,
                "============================================================\n");
        $fwrite(fd_summary,
                "Test vectors        : %0d\n", NVEC);
        $fwrite(fd_summary,
                "Input range         : [0.5, 2.5]\n");
        $fwrite(fd_summary,
                "Quantization        : Q8.24\n");
        $fwrite(fd_summary,
                "Simulation clock    : %.3f MHz\n",
                1000.0 / CLK_PERIOD_NS);
        $fwrite(fd_summary,
                "Clock period        : %.3f ns\n",
                CLK_PERIOD_NS);
        $fwrite(fd_summary,
                "Latency             : %.0f cycles\n",
                latency_cycles);
        $fwrite(fd_summary,
                "Latency             : %.3f ns\n",
                latency_ns);
        $fwrite(fd_summary,
                "Throughput          : %.3f Msps\n",
                throughput_msps);
        $fwrite(fd_summary,
                "Max absolute error  : %0d LSB\n",
                max_abs_err);
        $fwrite(fd_summary,
                "Max absolute error  : %.12f\n",
                max_error_value);
        $fwrite(fd_summary,
                "Mean absolute error : %.6f LSB\n",
                mae_lsb);
        $fwrite(fd_summary,
                "Mean absolute error : %.12f\n",
                mae_value);
        $fwrite(fd_summary,
                "Max relative error  : %.12f %%\n",
                max_relative_err * 100.0);
        $fwrite(fd_summary,
                "RMS error           : %.6f LSB\n",
                rms_error_lsb);
        $fwrite(fd_summary,
                "Worst-case index    : %0d\n",
                worst_idx);

        if (worst_idx >= 0)
            $fwrite(fd_summary,
                    "Worst-case input    : %08h\n",
                    test_x[worst_idx]);

        $fwrite(fd_summary,
                "Simulation span     : %.3f ns\n",
                real'(t_end - t_start));
        $fwrite(fd_summary,
                "============================================================\n");

        $fclose(fd_csv);
        $fclose(fd_summary);

        $finish;

    endtask

    initial begin
        #(CLK_PERIOD_NS * (NVEC + 100) * 1.2);
        $fatal(1, "ERROR: Simulation timeout.");
    end

endmodule