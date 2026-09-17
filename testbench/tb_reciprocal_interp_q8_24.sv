`timescale 1ns/1ps

module tb_reciprocal_interp_q8_24;

    localparam int NVEC = 1_000_001;
    localparam real CLK_PERIOD_NS = 2.58;

    logic clk;
    logic rst_n;

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

    reciprocal_interp_q8_24 u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .x_in(x_in),
        .valid_out(valid_out),
        .recip_out(recip_out)
    );

    int drive_idx;
    logic driving;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drive_idx <= 0;
            driving <= 1'b0;
            valid_in <= 1'b0;
            x_in <= 32'd0;
        end
        else begin
            driving <= 1'b1;

            if (driving && drive_idx < NVEC) begin
                valid_in <= 1'b1;
                x_in <= test_x[drive_idx];
                drive_idx <= drive_idx + 1;
            end
            else begin
                valid_in <= 1'b0;
            end
        end
    end

    int out_idx;

    longint unsigned max_abs_err;
    longint unsigned sum_abs_err;
    longint unsigned sumsq_err;

    longint signed err;
    longint unsigned abs_err;
    longint worst_idx;

    real mae_lsb;
    real mae_value;

    real relative_err;
    real max_relative_err;

    time t_start;
    time t_end;

    int fd_csv;
    int fd_summary;

    longint cycle_count;
    longint first_input_cycle;
    longint first_output_cycle;
    longint measured_latency_cycles;

    real measured_latency_ns;

    logic latency_measured;

    function automatic longint signed signed32(input logic [31:0] value);
        signed32 = $signed(value);
    endfunction

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        valid_in = 1'b0;
        x_in = 32'd0;

        out_idx = 0;

        max_abs_err = 0;
        sum_abs_err = 0;
        sumsq_err = 0;
        worst_idx = -1;

        mae_lsb = 0.0;
        mae_value = 0.0;

        max_relative_err = 0.0;
        relative_err = 0.0;

        cycle_count = 0;
        first_input_cycle = -1;
        first_output_cycle = -1;
        measured_latency_cycles = -1;
        measured_latency_ns = 0.0;
        latency_measured = 1'b0;

        fd_csv = $fopen("interp_lut_results.csv", "w");
        fd_summary = $fopen("interp_lut_summary.txt", "w");

        if (fd_csv == 0)
            $fatal(1, "ERROR: Could not open interp_lut_results.csv");

        if (fd_summary == 0)
            $fatal(1, "ERROR: Could not open interp_lut_summary.txt");

        $fwrite(fd_csv,
                "idx,x_hex,golden_hex,hw_hex,abs_err_lsb,relative_err\n");

        repeat (4) @(posedge clk);

        rst_n = 1'b1;
        t_start = $time;
    end

    always @(posedge clk) begin

        if (!rst_n) begin
            cycle_count <= 0;
        end
        else begin
            cycle_count <= cycle_count + 1;
        end

        if (rst_n && valid_in && first_input_cycle < 0) begin
            first_input_cycle = cycle_count;
        end

        if (rst_n && valid_out) begin

            if (!latency_measured) begin
                first_output_cycle = cycle_count;

                measured_latency_cycles =
                    first_output_cycle - first_input_cycle;

                measured_latency_ns =
                    real'(measured_latency_cycles) * CLK_PERIOD_NS;

                latency_measured = 1'b1;

                $display("============================================================");
                $display("AUTOMATIC LATENCY MEASUREMENT");
                $display("============================================================");
                $display("First input cycle  : %0d", first_input_cycle);
                $display("First output cycle : %0d", first_output_cycle);
                $display("Measured latency   : %0d cycles",
                         measured_latency_cycles);
                $display("Measured latency   : %.3f ns",
                         measured_latency_ns);
                $display("Clock period       : %.3f ns",
                         CLK_PERIOD_NS);
                $display("Clock frequency    : %.3f MHz",
                         1000.0 / CLK_PERIOD_NS);
                $display("Throughput         : %.3f Msps",
                         1000.0 / CLK_PERIOD_NS);
                $display("============================================================");
            end

            err = signed32(recip_out) -
                  signed32(test_golden[out_idx]);

            if (err < 0)
                abs_err = -err;
            else
                abs_err = err;

            sum_abs_err = sum_abs_err + abs_err;
            sumsq_err = sumsq_err + (abs_err * abs_err);

            if (test_golden[out_idx] != 0)
                relative_err =
                    real'(abs_err) /
                    real'(test_golden[out_idx]);
            else
                relative_err = 0.0;

            if (relative_err > max_relative_err)
                max_relative_err = relative_err;

            if (abs_err > max_abs_err) begin
                max_abs_err = abs_err;
                worst_idx = out_idx;
            end

            $fwrite(fd_csv,
                    "%0d,%08h,%08h,%08h,%0d,%.12f\n",
                    out_idx,
                    test_x[out_idx],
                    test_golden[out_idx],
                    recip_out,
                    abs_err,
                    relative_err);

            if (out_idx == NVEC - 1) begin

                t_end = $time;

                mae_lsb =
                    real'(sum_abs_err) / real'(NVEC);

                mae_value =
                    mae_lsb / 16777216.0;

                $display("============================================================");
                $display("reciprocal_interp_q8_24 verification");
                $display("============================================================");
                $display("Test vectors        : %0d", NVEC);
                $display("Input range         : [0.5, 2.5]");
                $display("Quantization        : Q8.24");
                $display("Simulation clock    : %.3f MHz",
                         1000.0 / CLK_PERIOD_NS);
                $display("Clock period        : %.3f ns",
                         CLK_PERIOD_NS);
                $display("Measured latency    : %0d cycles",
                         measured_latency_cycles);
                $display("Measured latency    : %.3f ns",
                         measured_latency_ns);
                $display("Throughput          : %.3f Msps",
                         1000.0 / CLK_PERIOD_NS);
                $display("Max absolute error  : %0d LSB",
                         max_abs_err);
                $display("Max absolute error  : %.12f",
                         real'(max_abs_err) / 16777216.0);
                $display("Mean absolute error : %.6f LSB",
                         mae_lsb);
                $display("Mean absolute error : %.12f",
                         mae_value);
                $display("Max relative error  : %.12f %%",
                         max_relative_err * 100.0);
                $display("RMS error           : %.6f LSB",
                         $sqrt(real'(sumsq_err) / real'(NVEC)));
                $display("Worst-case index    : %0d",
                         worst_idx);
                $display("Worst-case input    : %08h",
                         test_x[worst_idx]);
                $display("Simulation span     : %.1f ns",
                         real'(t_end - t_start));
                $display("============================================================");

                $fwrite(fd_summary,
                        "============================================================\n");
                $fwrite(fd_summary,
                        "reciprocal_interp_q8_24 verification\n");
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
                        "Measured latency    : %0d cycles\n",
                        measured_latency_cycles);
                $fwrite(fd_summary,
                        "Measured latency    : %.3f ns\n",
                        measured_latency_ns);
                $fwrite(fd_summary,
                        "Throughput          : %.3f Msps\n",
                        1000.0 / CLK_PERIOD_NS);
                $fwrite(fd_summary,
                        "Max absolute error  : %0d LSB\n",
                        max_abs_err);
                $fwrite(fd_summary,
                        "Max absolute error  : %.12f\n",
                        real'(max_abs_err) / 16777216.0);
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
                        $sqrt(real'(sumsq_err) / real'(NVEC)));
                $fwrite(fd_summary,
                        "Worst-case index    : %0d\n",
                        worst_idx);
                $fwrite(fd_summary,
                        "Worst-case input    : %08h\n",
                        test_x[worst_idx]);
                $fwrite(fd_summary,
                        "Simulation span     : %.1f ns\n",
                        real'(t_end - t_start));
                $fwrite(fd_summary,
                        "============================================================\n");

                $fclose(fd_csv);
                $fclose(fd_summary);

                $finish;
            end

            out_idx = out_idx + 1;
        end
    end

    initial begin
        #(CLK_PERIOD_NS * (NVEC + 100) * 1.2);
        $fatal(1, "ERROR: Simulation timeout.");
    end

endmodule