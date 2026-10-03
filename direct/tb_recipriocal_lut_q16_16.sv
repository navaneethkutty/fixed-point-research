`timescale 1ns / 1ps

module tb_reciprocal_direct_lut_q16_16;

    // ================================================================
    // Configuration
    // ================================================================

    localparam int  NUM_VECTORS    = 1_000_001;
    localparam int  WARMUP_SAMPLES = 30;

    // Common implementation target
    localparam real CLK_PERIOD_NS  = 2.580;

    // Q16.16
    localparam int  FRAC_BITS      = 16;
    localparam real Q_SCALE_REAL   = 65536.0;

    localparam string INPUT_FILE =
        "q16_16_input.mem";

    localparam string EXPECTED_FILE =
        "q16_16_expected.mem";

    localparam string CSV_FILE =
        "q16_16_direct_lut_results.csv";

    localparam string SUMMARY_FILE =
        "q16_16_direct_lut_summary.txt";


    // ================================================================
    // Clock / reset
    // ================================================================

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD_NS / 2.0)
        clk = ~clk;


    // ================================================================
    // DUT interface
    // ================================================================

    logic        valid_in;
    logic [31:0] x_in;

    logic        valid_out;
    logic [31:0] recip_out;


    // ================================================================
    // DUT
    // ================================================================

    reciprocal_direct_lut_q16_16 u_dut (

        .clk       (clk),
        .rst_n     (rst_n),

        .valid_in  (valid_in),
        .x_in      (x_in),

        .valid_out (valid_out),
        .recip_out (recip_out)

    );


    // ================================================================
    // Test memories
    // ================================================================

    logic [31:0] input_mem    [0:NUM_VECTORS-1];
    logic [31:0] expected_mem [0:NUM_VECTORS-1];


    // ================================================================
    // File handles
    // ================================================================

    integer fd_csv;
    integer fd_summary;


    // ================================================================
    // Input / output counters
    // ================================================================

    int input_index;
    int output_index;
    int scored_count;


    // ================================================================
    // Match statistics
    // ================================================================

    int exact_count;
    int within1_count;
    int within2_count;
    int within4_count;
    int within8_count;
    int fail_count;


    // ================================================================
    // Error metrics
    // ================================================================

    longint signed   error_lsb;
    longint unsigned abs_error_lsb;
    longint unsigned max_error_lsb;

    real input_real;
    real golden_real;
    real hw_real;

    real abs_error_real;
    real relative_error;

    real sum_abs_error;
    real sum_squared_error;
    real max_relative_error;

    real mae_lsb;
    real rmse_lsb;

    real exact_percent;
    real within1_percent;
    real within2_percent;
    real within4_percent;
    real within8_percent;


    // ================================================================
    // Worst-case tracking
    // ================================================================

    int max_error_index;
    int max_relative_index;

    logic [31:0] max_error_x_hex;
    logic [31:0] max_error_golden_hex;
    logic [31:0] max_error_hw_hex;

    logic [31:0] max_relative_x_hex;
    logic [31:0] max_relative_golden_hex;
    logic [31:0] max_relative_hw_hex;


    // ================================================================
    // Latency / throughput
    // ================================================================

    longint cycle_count;

    longint first_input_cycle;
    longint first_output_cycle;

    longint measured_latency_cycles;

    real measured_latency_ns;
    real throughput_mhz;

    logic latency_measured;


    // ================================================================
    // Simulation timing
    // ================================================================

    time t_start;
    time t_end;


    // ================================================================
    // Signed helper
    // ================================================================

    function automatic longint signed signed32(
        input logic [31:0] value
    );

        signed32 = $signed(value);

    endfunction


    // ================================================================
    // Load memories
    // ================================================================

    initial begin

        $display("==============================================================");
        $display(" Q16.16 DIRECT LUT 1,000,001-POINT TEST");
        $display("==============================================================");

        $display(
            "Input file             : %s",
            INPUT_FILE
        );

        $display(
            "Expected file          : %s",
            EXPECTED_FILE
        );

        $display(
            "Test vectors           : %0d",
            NUM_VECTORS
        );

        $display(
            "Warm-up samples        : %0d",
            WARMUP_SAMPLES
        );

        $display(
            "Clock period           : %.3f ns",
            CLK_PERIOD_NS
        );

        $display(
            "Clock frequency        : %.3f MHz",
            1000.0 / CLK_PERIOD_NS
        );

        $display(
            "Quantization           : Q16.16"
        );

        $display(
            "LUT entries            : 4096"
        );

        $display(
            "LUT data width         : 32 bits"
        );

        $display("==============================================================");


        $display("Loading input memory...");

        $readmemh(
            INPUT_FILE,
            input_mem
        );


        $display("Loading expected memory...");

        $readmemh(
            EXPECTED_FILE,
            expected_mem
        );


        // ------------------------------------------------------------
        // Verify memory loading
        // ------------------------------------------------------------

        if (^input_mem[0] === 1'bx) begin

            $fatal(
                1,
                "ERROR: %s failed to load.",
                INPUT_FILE
            );

        end


        if (^expected_mem[0] === 1'bx) begin

            $fatal(
                1,
                "ERROR: %s failed to load.",
                EXPECTED_FILE
            );

        end


        $display(
            "input[0]               : %08h",
            input_mem[0]
        );

        $display(
            "expected[0]            : %08h",
            expected_mem[0]
        );

        $display("Memory loading complete.");
        $display("==============================================================");


        // ------------------------------------------------------------
        // Open output files
        // ------------------------------------------------------------

        fd_csv = $fopen(
            CSV_FILE,
            "w"
        );

        if (fd_csv == 0) begin

            $fatal(
                1,
                "ERROR: Could not create %s",
                CSV_FILE
            );

        end


        fd_summary = $fopen(
            SUMMARY_FILE,
            "w"
        );

        if (fd_summary == 0) begin

            $fatal(
                1,
                "ERROR: Could not create %s",
                SUMMARY_FILE
            );

        end


        // ------------------------------------------------------------
        // CSV header
        // ------------------------------------------------------------

        $fwrite(
            fd_csv,
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb,input_real,golden_real,hw_real,abs_error_real,relative_error\n"
        );

    end


    // ================================================================
    // Input driver
    // ================================================================

    initial begin

        valid_in    = 1'b0;
        x_in        = 32'd0;
        input_index = 0;


        // ------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------

        repeat (4)
            @(posedge clk);

        @(negedge clk);

        rst_n = 1'b1;

        t_start = $time;


        $display("");
        $display("Reset released.");
        $display("Starting input stream...");
        $display("");


        // ------------------------------------------------------------
        // Continuous input stream
        // ------------------------------------------------------------

        while (input_index < NUM_VECTORS) begin

            valid_in = 1'b1;

            x_in =
                input_mem[input_index];

            input_index =
                input_index + 1;

            @(negedge clk);

        end


        // ------------------------------------------------------------
        // Stop input
        // ------------------------------------------------------------

        valid_in = 1'b0;
        x_in     = 32'd0;

    end


    // ================================================================
    // Cycle counter + first-input measurement
    // ================================================================

    always @(posedge clk) begin

        cycle_count =
            cycle_count + 1;


        // ------------------------------------------------------------
        // First accepted input
        // ------------------------------------------------------------

        if (
            rst_n &&
            valid_in &&
            first_input_cycle < 0
        ) begin

            first_input_cycle =
                cycle_count;

        end

    end


    // ================================================================
    // Main output monitor / verification engine
    // ================================================================

    initial begin

        // ------------------------------------------------------------
        // Initialize counters
        // ------------------------------------------------------------

        output_index = 0;
        scored_count = 0;

        exact_count   = 0;
        within1_count = 0;
        within2_count = 0;
        within4_count = 0;
        within8_count = 0;
        fail_count    = 0;


        // ------------------------------------------------------------
        // Initialize errors
        // ------------------------------------------------------------

        max_error_lsb   = 0;
        max_error_index = -1;

        max_relative_error = 0.0;
        max_relative_index = -1;

        sum_abs_error     = 0.0;
        sum_squared_error = 0.0;


        // ------------------------------------------------------------
        // Initialize worst-case storage
        // ------------------------------------------------------------

        max_error_x_hex      = 32'd0;
        max_error_golden_hex = 32'd0;
        max_error_hw_hex     = 32'd0;

        max_relative_x_hex      = 32'd0;
        max_relative_golden_hex = 32'd0;
        max_relative_hw_hex     = 32'd0;


        // ------------------------------------------------------------
        // Latency initialization
        // ------------------------------------------------------------

        cycle_count = 0;

        first_input_cycle  = -1;
        first_output_cycle = -1;

        measured_latency_cycles = -1;
        measured_latency_ns     = 0.0;

        throughput_mhz =
            1000.0 / CLK_PERIOD_NS;

        latency_measured = 1'b0;


        // ------------------------------------------------------------
        // Wait for reset release
        // ------------------------------------------------------------

        wait (rst_n == 1'b1);


        // ============================================================
        // Wait for and process outputs
        // ============================================================

        while (output_index < NUM_VECTORS) begin

            @(negedge clk);


            if (valid_out) begin

                longint signed   hw_value;
                longint signed   golden_value;


                // ----------------------------------------------------
                // Check for X
                // ----------------------------------------------------

                if (^recip_out === 1'bx) begin

                    $fatal(
                        1,
                        "ERROR: X detected on output %0d.",
                        output_index
                    );

                end


                // ----------------------------------------------------
                // Automatic latency measurement
                // ----------------------------------------------------

                if (!latency_measured) begin

                    first_output_cycle =
                        cycle_count;


                    measured_latency_cycles =
                        first_output_cycle -
                        first_input_cycle;


                    measured_latency_ns =
                        measured_latency_cycles *
                        CLK_PERIOD_NS;


                    latency_measured = 1'b1;


                    $display("");
                    $display(
                        "============================================================"
                    );

                    $display(
                        "AUTOMATIC LATENCY MEASUREMENT"
                    );

                    $display(
                        "============================================================"
                    );

                    $display(
                        "First input cycle  : %0d",
                        first_input_cycle
                    );

                    $display(
                        "First output cycle : %0d",
                        first_output_cycle
                    );

                    $display(
                        "Latency            : %0d cycles",
                        measured_latency_cycles
                    );

                    $display(
                        "Latency            : %.3f ns",
                        measured_latency_ns
                    );

                    $display(
                        "Clock period       : %.3f ns",
                        CLK_PERIOD_NS
                    );

                    $display(
                        "Clock frequency    : %.3f MHz",
                        1000.0 / CLK_PERIOD_NS
                    );

                    $display(
                        "Throughput         : %.3f M results/s",
                        throughput_mhz
                    );

                    $display(
                        "============================================================"
                    );

                end


                // ----------------------------------------------------
                // Signed values
                // ----------------------------------------------------

                hw_value =
                    signed32(recip_out);

                golden_value =
                    signed32(
                        expected_mem[output_index]
                    );


                // ----------------------------------------------------
                // Error in LSB
                // ----------------------------------------------------

                error_lsb =
                    hw_value -
                    golden_value;


                if (error_lsb < 0)
                    abs_error_lsb = -error_lsb;
                else
                    abs_error_lsb = error_lsb;


                // ----------------------------------------------------
                // Convert to real Q16.16
                // ----------------------------------------------------

                input_real =
                    signed32(
                        input_mem[output_index]
                    ) /
                    Q_SCALE_REAL;

                golden_real =
                    golden_value /
                    Q_SCALE_REAL;

                hw_real =
                    hw_value /
                    Q_SCALE_REAL;

                abs_error_real =
                    abs_error_lsb /
                    Q_SCALE_REAL;


                // ----------------------------------------------------
                // Relative error
                // ----------------------------------------------------

                if (golden_real != 0.0) begin

                    relative_error =
                        abs_error_real /
                        golden_real;

                    if (relative_error < 0.0)
                        relative_error =
                            -relative_error;

                end
                else begin

                    relative_error = 0.0;

                end


                // ====================================================
                // Statistics
                // ====================================================

                if (
                    output_index >= WARMUP_SAMPLES
                ) begin

                    scored_count++;


                    // ------------------------------------------------
                    // MAE / RMSE
                    // ------------------------------------------------

                    sum_abs_error =
                        sum_abs_error +
                        abs_error_real;

                    sum_squared_error =
                        sum_squared_error +
                        (
                            abs_error_real *
                            abs_error_real
                        );


                    // ------------------------------------------------
                    // Match distribution
                    // ------------------------------------------------

                    if (abs_error_lsb == 0)
                        exact_count++;

                    if (abs_error_lsb <= 1)
                        within1_count++;

                    if (abs_error_lsb <= 2)
                        within2_count++;

                    if (abs_error_lsb <= 4)
                        within4_count++;

                    if (abs_error_lsb <= 8)
                        within8_count++;

                    if (abs_error_lsb > 8)
                        fail_count++;


                    // ------------------------------------------------
                    // Maximum absolute error
                    // ------------------------------------------------

                    if (
                        abs_error_lsb >
                        max_error_lsb
                    ) begin

                        max_error_lsb =
                            abs_error_lsb;

                        max_error_index =
                            output_index;

                        max_error_x_hex =
                            input_mem[output_index];

                        max_error_golden_hex =
                            expected_mem[output_index];

                        max_error_hw_hex =
                            recip_out;

                    end


                    // ------------------------------------------------
                    // Maximum relative error
                    // ------------------------------------------------

                    if (
                        relative_error >
                        max_relative_error
                    ) begin

                        max_relative_error =
                            relative_error;

                        max_relative_index =
                            output_index;

                        max_relative_x_hex =
                            input_mem[output_index];

                        max_relative_golden_hex =
                            expected_mem[output_index];

                        max_relative_hw_hex =
                            recip_out;

                    end

                end


                // ----------------------------------------------------
                // CSV
                // ----------------------------------------------------

                $fwrite(
                    fd_csv,
                    "%0d,%08h,%08h,%08h,%0d,%0d,%f,%f,%f,%f,%f\n",

                    output_index,

                    input_mem[output_index],

                    expected_mem[output_index],

                    recip_out,

                    error_lsb,

                    abs_error_lsb,

                    input_real,

                    golden_real,

                    hw_real,

                    abs_error_real,

                    relative_error
                );


                output_index++;


                // ----------------------------------------------------
                // Progress
                // ----------------------------------------------------

                if (
                    (output_index % 100000) == 0
                ) begin

                    $display(
                        "Outputs checked: %0d / %0d",
                        output_index,
                        NUM_VECTORS
                    );

                end

            end

        end


        // ============================================================
        // Final calculations
        // ============================================================

        t_end = $time;


        mae_lsb =
            (
                sum_abs_error /
                scored_count
            ) *
            Q_SCALE_REAL;


        rmse_lsb =
            $sqrt(
                sum_squared_error /
                scored_count
            ) *
            Q_SCALE_REAL;


        exact_percent =
            (100.0 * exact_count) /
            scored_count;

        within1_percent =
            (100.0 * within1_count) /
            scored_count;

        within2_percent =
            (100.0 * within2_count) /
            scored_count;

        within4_percent =
            (100.0 * within4_count) /
            scored_count;

        within8_percent =
            (100.0 * within8_count) /
            scored_count;


        // ============================================================
        // Console report
        // ============================================================

        $display("");
        $display("==============================================================");
        $display(" FINAL Q16.16 DIRECT LUT RESULTS");
        $display("==============================================================");

        $display(
            "Samples driven       : %0d",
            input_index
        );

        $display(
            "Samples checked      : %0d",
            output_index
        );

        $display(
            "Warm-up ignored      : %0d",
            WARMUP_SAMPLES
        );

        $display(
            "Samples scored       : %0d",
            scored_count
        );


        // ------------------------------------------------------------
        // Accuracy
        // ------------------------------------------------------------

        $display("");
        $display("ACCURACY METRICS");
        $display("--------------------------------------------------------------");

        $display(
            "Maximum error        : %0d LSB",
            max_error_lsb
        );

        $display(
            "Maximum error        : %.12f",
            max_error_lsb /
            Q_SCALE_REAL
        );

        $display(
            "MAE                  : %.6f LSB",
            mae_lsb
        );

        $display(
            "RMSE                 : %.6f LSB",
            rmse_lsb
        );

        $display(
            "Maximum relative err : %.12f",
            max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            max_relative_error *
            100.0
        );


        // ------------------------------------------------------------
        // Match distribution
        // ------------------------------------------------------------

        $display("");
        $display("MATCH DISTRIBUTION");
        $display("--------------------------------------------------------------");

        $display(
            "Exact matches        : %0d (%.6f %%)",
            exact_count,
            exact_percent
        );

        $display(
            "Within 1 LSB         : %0d (%.6f %%)",
            within1_count,
            within1_percent
        );

        $display(
            "Within 2 LSB         : %0d (%.6f %%)",
            within2_count,
            within2_percent
        );

        $display(
            "Within 4 LSB         : %0d (%.6f %%)",
            within4_count,
            within4_percent
        );

        $display(
            "Within 8 LSB         : %0d (%.6f %%)",
            within8_count,
            within8_percent
        );

        $display(
            "Errors > 8 LSB       : %0d",
            fail_count
        );


        // ------------------------------------------------------------
        // Pipeline
        // ------------------------------------------------------------

        $display("");
        $display("PIPELINE METRICS");
        $display("--------------------------------------------------------------");

        $display(
            "First input cycle    : %0d",
            first_input_cycle
        );

        $display(
            "First output cycle   : %0d",
            first_output_cycle
        );

        $display(
            "Latency              : %0d cycles",
            measured_latency_cycles
        );

        $display(
            "Latency              : %.3f ns",
            measured_latency_ns
        );

        $display(
            "Throughput           : %.3f M results/s",
            throughput_mhz
        );


        // ------------------------------------------------------------
        // Worst absolute error
        // ------------------------------------------------------------

        $display("");
        $display("WORST ABSOLUTE ERROR");
        $display("--------------------------------------------------------------");

        $display(
            "Index                : %0d",
            max_error_index
        );

        $display(
            "Input HEX            : %08h",
            max_error_x_hex
        );

        $display(
            "Expected HEX         : %08h",
            max_error_golden_hex
        );

        $display(
            "Actual HEX           : %08h",
            max_error_hw_hex
        );

        $display(
            "Signed error         : %0d LSB",
            signed32(max_error_hw_hex) -
            signed32(max_error_golden_hex)
        );


        // ------------------------------------------------------------
        // Worst relative error
        // ------------------------------------------------------------

        $display("");
        $display("WORST RELATIVE ERROR");
        $display("--------------------------------------------------------------");

        $display(
            "Index                : %0d",
            max_relative_index
        );

        $display(
            "Input HEX            : %08h",
            max_relative_x_hex
        );

        $display(
            "Expected HEX         : %08h",
            max_relative_golden_hex
        );

        $display(
            "Actual HEX           : %08h",
            max_relative_hw_hex
        );

        $display(
            "Maximum relative err : %.12f",
            max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            max_relative_error *
            100.0
        );


        // ------------------------------------------------------------
        // Simulation info
        // ------------------------------------------------------------

        $display("");
        $display("SIMULATION");
        $display("--------------------------------------------------------------");

        $display(
            "Simulation span      : %.1f ns",
            real'(t_end - t_start)
        );

        $display(
            "CSV                  : %s",
            CSV_FILE
        );

        $display(
            "Summary              : %s",
            SUMMARY_FILE
        );

        $display("==============================================================");


        // ============================================================
        // Summary file
        // ============================================================

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            " Q16.16 DIRECT LUT RESULTS\n"
        );

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            "Algorithm                  : Direct LUT (No Interpolation)\n"
        );

        $fwrite(
            fd_summary,
            "Configuration              : Q16.16 Fixed-Point\n"
        );

        $fwrite(
            fd_summary,
            "Integer bits               : 16\n"
        );

        $fwrite(
            fd_summary,
            "Fraction bits              : 16\n"
        );

        $fwrite(
            fd_summary,
            "Input range                : [0.5, 2.5]\n"
        );

        $fwrite(
            fd_summary,
            "Test vectors               : %0d\n",
            NUM_VECTORS
        );

        $fwrite(
            fd_summary,
            "Warm-up samples            : %0d\n",
            WARMUP_SAMPLES
        );

        $fwrite(
            fd_summary,
            "LUT entries                : 4096\n"
        );

        $fwrite(
            fd_summary,
            "LUT data width             : 32 bits\n"
        );

        $fwrite(
            fd_summary,
            "Clock period (ns)          : %.3f\n",
            CLK_PERIOD_NS
        );

        $fwrite(
            fd_summary,
            "Target frequency (MHz)     : %.6f\n",
            throughput_mhz
        );

        $fwrite(
            fd_summary,
            "\n"
        );


        // ------------------------------------------------------------
        // Accuracy
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "ACCURACY METRICS\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Max absolute error (LSB)  : %0d\n",
            max_error_lsb
        );

        $fwrite(
            fd_summary,
            "Max absolute error        : %.12f\n",
            max_error_lsb /
            Q_SCALE_REAL
        );

        $fwrite(
            fd_summary,
            "MAE (LSB)                 : %.6f\n",
            mae_lsb
        );

        $fwrite(
            fd_summary,
            "RMSE (LSB)                : %.6f\n",
            rmse_lsb
        );

        $fwrite(
            fd_summary,
            "Max relative error (%%)    : %.6f\n",
            max_relative_error *
            100.0
        );


        // ------------------------------------------------------------
        // Match distribution
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nMATCH DISTRIBUTION\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Exact matches              : %0d (%.6f %%)\n",
            exact_count,
            exact_percent
        );

        $fwrite(
            fd_summary,
            "Within 1 LSB               : %0d (%.6f %%)\n",
            within1_count,
            within1_percent
        );

        $fwrite(
            fd_summary,
            "Within 2 LSB               : %0d (%.6f %%)\n",
            within2_count,
            within2_percent
        );

        $fwrite(
            fd_summary,
            "Within 4 LSB               : %0d (%.6f %%)\n",
            within4_count,
            within4_percent
        );

        $fwrite(
            fd_summary,
            "Within 8 LSB               : %0d (%.6f %%)\n",
            within8_count,
            within8_percent
        );

        $fwrite(
            fd_summary,
            "Errors > 8 LSB             : %0d\n",
            fail_count
        );


        // ------------------------------------------------------------
        // Pipeline
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nPIPELINE METRICS\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "First input cycle          : %0d\n",
            first_input_cycle
        );

        $fwrite(
            fd_summary,
            "First output cycle         : %0d\n",
            first_output_cycle
        );

        $fwrite(
            fd_summary,
            "Latency (cycles)           : %0d\n",
            measured_latency_cycles
        );

        $fwrite(
            fd_summary,
            "Latency (ns)               : %.3f\n",
            measured_latency_ns
        );

        $fwrite(
            fd_summary,
            "Throughput (M results/s)   : %.3f\n",
            throughput_mhz
        );


        // ------------------------------------------------------------
        // Worst-case absolute error
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nWORST ABSOLUTE ERROR\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Index                      : %0d\n",
            max_error_index
        );

        $fwrite(
            fd_summary,
            "Input HEX                  : %08h\n",
            max_error_x_hex
        );

        $fwrite(
            fd_summary,
            "Expected HEX               : %08h\n",
            max_error_golden_hex
        );

        $fwrite(
            fd_summary,
            "Actual HEX                 : %08h\n",
            max_error_hw_hex
        );

        $fwrite(
            fd_summary,
            "Signed error (LSB)         : %0d\n",
            signed32(max_error_hw_hex) -
            signed32(max_error_golden_hex)
        );


        // ------------------------------------------------------------
        // Worst relative error
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nWORST RELATIVE ERROR\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Index                      : %0d\n",
            max_relative_index
        );

        $fwrite(
            fd_summary,
            "Input HEX                  : %08h\n",
            max_relative_x_hex
        );

        $fwrite(
            fd_summary,
            "Expected HEX               : %08h\n",
            max_relative_golden_hex
        );

        $fwrite(
            fd_summary,
            "Actual HEX                 : %08h\n",
            max_relative_hw_hex
        );

        $fwrite(
            fd_summary,
            "Max relative error (%%)     : %.6f\n",
            max_relative_error *
            100.0
        );


        // ------------------------------------------------------------
        // Simulation
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nSIMULATION\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Simulation span (ns)      : %.1f\n",
            real'(t_end - t_start)
        );

        $fwrite(
            fd_summary,
            "CSV file                   : %s\n",
            CSV_FILE
        );

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );


        // ------------------------------------------------------------
        // Close files
        // ------------------------------------------------------------

        $fclose(fd_csv);
        $fclose(fd_summary);


        // ============================================================
        // Final result
        // ============================================================

        if (
            output_index == NUM_VECTORS &&
            scored_count == (NUM_VECTORS - WARMUP_SAMPLES) &&
            measured_latency_cycles >= 0
        ) begin

            $display("RESULT: PASS");

        end
        else begin

            $display("RESULT: FAIL");

        end

        $display("==============================================================");

        $finish;

    end


    // ================================================================
    // Safety timeout
    // ================================================================

    initial begin

        #(
            CLK_PERIOD_NS *
            (NUM_VECTORS + 100) *
            1.20
        );

        $fatal(
            1,
            "ERROR: Simulation timeout before all outputs were produced."
        );

    end

endmodule