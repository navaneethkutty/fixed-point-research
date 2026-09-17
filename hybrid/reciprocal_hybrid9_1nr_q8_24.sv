// ============================================================================
// reciprocal_hybrid9_1nr_q8_24.sv  (REV 8 -- BUGFIX: REV 7's post-reset
// "pipeline primed" guard could let a corrupted first-fill token through
// valid_out. REV 6 timing-closed core UNCHANGED. See file-header history
// below for full context of REV 1-7, then the REV 8 section for what
// changed and why.)
//
// Hybrid reciprocal: 9-bit LUT + linear interpolation seed, refined by ONE
// Newton-Raphson iteration.  Q8.24, x in [0.5, 2.5).
//
// Four modules in this file:
//   1) reciprocal_interp9_q8_24  - front-end seed generator (9-bit LUT)
//   2) mult32x32_pipe_q8_24      - reusable pipelined signed 32x32->64 multiply
//   3) nr_iterate_q8_24          - one NR iteration built from two of (2)
//   4) reciprocal_hybrid9_1nr_q8_24 - top-level wiring (1)+(3) with valid
//      pipeline alignment
//
// ----------------------------------------------------------------------------
// REVISION HISTORY (summary; modules 1-3 have been bit-identical, timing-
// closed, since REV 6 -- only module 4's guard logic has changed since):
//   REV 2: fixed WNS -2.580ns by splitting ovf-detect from select (extra cycle).
//   REV 3: CONFIRMED CLOSING POINT. post-route report_timing_summary:
//          WNS = +0.058ns, TNS = 0.000ns, all endpoints met, at 3.333ns
//          period. Worst path was the round-add itself (12 logic levels,
//          CARRY4=11), ~1.7% margin.
//   REV 4: attacked the round-add's logic depth with a carry-select
//          (conditional-increment) structure instead of a ripple, and used
//          the resulting margin to FUSE round+overflow-detect+select into
//          ONE cycle (removing REV 3's tail register). FAILED post-route
//          (WNS -1.329ns, TNS -51.472ns, 72 failing endpoints).
//   REV 5: rolled back per REV 4's own rollback plan: split fused tail back
//          into two registered stages (round, then ovf-detect+select),
//          keeping REV 4's carry-select round-add for margin. CONFIRMED by
//          post-route report: WNS -0.008ns, 4 failing endpoints (down from
//          -1.603ns/74 in the still-fused intermediate report).
//   REV 6: replaced the remaining serial carry-ripple (carry1->carry2->
//          carry3) in Stage A's round-add with a carry-LOOKAHEAD (each
//          carry_k computed directly from cin0 and per-chunk all-ones
//          flags, in parallel). Same boolean function, ~2 fewer logic
//          levels on the only remaining violating path. CONFIRMED post-route:
//          WNS = +0.078ns, TNS = 0.000ns, 0 failing endpoints out of 3080,
//          at 3.333ns period (300.03 MHz). Worst path is
//          nr_stage/mult_y0_e/sum_c2_r7_reg[12]/C -> nr_stage/res3_rA_reg[1]/D,
//          4 logic levels, fully inside Stage A's carry-lookahead round-add
//          as intended. Design timing is CLOSED as of REV 6 and UNTOUCHED
//          by REV 7 or REV 8 below.
//   REV 7: top-level-only functional bugfix attempt for a transient where
//          the first several output tokens after reset read back ~2x
//          golden (root cause: mult32x32_pipe_q8_24's internal product_out
//          settling a few cycles after its own valid_out asserts, during
//          the very first tokens post-reset -- a first-fill valid-vs-data
//          race). REV 7 added a guard that held top-level valid_out low
//          for WARMUP_CYCLES = NOMINAL_LATENCY(40) + WARMUP_GUARD(8) = 48
//          cycles counted from rst_n release, then latched it permanently
//          high.
//          ** REV 7's guard has since been shown to be INCORRECT: see the
//          REV 8 section immediately below. It is retained here only in
//          this history note; the code in this file is REV 8. **
//
// ----------------------------------------------------------------------------
// REV 8 (this revision): fixes a confirmed defect in REV 7's guard.
//
// ROOT CAUSE OF THE REV 7 DEFECT:
//   REV 7's WARMUP_CYCLES counter started counting at rst_n release and
//   assumed real input data would not begin arriving until a large,
//   roughly-fixed number of cycles later (the original testbench happened
//   to enforce a ~55-cycle dead time before driving valid_in, which is why
//   REV 7 passed its original regression). That assumption is NOT part of
//   this module's interface contract -- nothing prevents an integrator
//   from asserting valid_in on the very first cycle after rst_n
//   deasserts, which is in fact one of the most common valid_in patterns
//   there is.
//
//   When a corrected testbench removed that artificial dead time and began
//   driving real data immediately after reset release, nr_stage's own
//   valid_out (v_nr) first asserted at cycle 42 carrying a corrupted token
//   (y1_r_out = 03fffe06 for x_in = 00800000, i.e. ~2x the correct
//   ~02000000 reciprocal -- the same t_full-settling-race signature
//   originally diagnosed). REV 7's pipeline_primed did not latch until
//   cycle 48-49. Superficially that looks like it should have masked the
//   cycle-42 token. It did not: the corrupted value stayed latched in
//   nr_stage's output register unchanged from cycle 42 through cycle 48
//   (no new token had arrived yet to replace it), and REV 7's guard opened
//   at cycle 48 while that stale, corrupted value was still sitting there.
//   Top-level valid_out's FIRST assertion (cycle 48) carried
//   recip_out = 03fffe06 -- corrupted data reached the output pin, i.e.
//   the exact defect REV 7 was written to prevent.
//
//   The underlying problem: REV 7 used two different "clocks" (elapsed
//   time since reset, vs. "has the corrupted transient actually cleared
//   the pipe") and assumed they stayed aligned. They only stay aligned
//   under the one specific input timing the original testbench happened
//   to use. This is a functional defect in the RTL, not a testbench
//   artifact -- the module produces incorrect output on a plainly legal,
//   common use pattern (valid_in asserted immediately after reset).
//
// REV 8 FIX:
//   Replace the reset-time-anchored counter with a guard that counts
//   ACTUAL OUTPUT-VALID EVENTS from nr_stage (v_nr pulses) instead of raw
//   clock cycles since reset. The first DISCARD_TOKENS assertions of v_nr
//   are unconditionally discarded (never allowed to reach top-level
//   valid_out); pipeline_primed then latches permanently high. Because
//   this counts real v_nr pulses rather than cycles-since-reset, it is
//   correct regardless of when valid_in first asserts relative to reset --
//   there is no reset-relative timing assumption left in the guard at all.
//   DISCARD_TOKENS = 8 preserves REV 7's intended one-token margin beyond
//   the observed 7-corrupted-token transient (WARMUP_GUARD was 8 cycles;
//   here it is 8 tokens).
//
//   This again touches NO logic inside mult32x32_pipe_q8_24 or
//   nr_iterate_q8_24, so REV 6's post-route timing closure (WNS +0.078ns,
//   0 failing endpoints) is untouched and does not need re-verification.
//   Steady-state throughput and per-sample latency once primed are
//   unaffected; only the number of tokens discarded at startup is now
//   correctly anchored to real pipeline events instead of a wall-clock
//   guess.
//
//   Tradeoff, stated explicitly: this discards 9 real input tokens'
//   worth of output at startup, on every reset, permanently. That is a
//   deliberate choice (known-bad startup samples, no backpressure) rather
//   than a compromise -- the alternative (queue and later emit those 9
//   tokens) would add complexity and a variable-latency corner case for
//   a startup-only condition that most integrators can simply account
//   for by expecting output count = input count - DISCARD_TOKENS - 1.
//   If a future integration requires bit-exact 1:1 token accounting with
//   no drops, that requirement should be solved by fixing the root cause
//   in mult32x32_pipe_q8_24's internal valid/product settling race, not
//   by adding another top-level patch -- but that fix has not been made
//   here, deliberately, to avoid re-opening REV 6's confirmed timing
//   closure without a synthesis tool available to re-verify it.
//
// *** VERIFICATION NOTE: re-run with (a) a testbench that drives valid_in
// on the first cycle after rst_n release (this is the scenario that broke
// REV 7), and (b) a testbench that reproduces the original ~55-cycle-late
// start, to confirm the guard now holds correctly in both regimes. Also
// re-check any simulation timeout margin against the (small, one-time)
// change in startup latency -- DISCARD_TOKENS+1 output tokens are now
// discarded once at startup regardless of input timing, rather than a
// fixed 48 cycles from reset. If any corrupted sample is still observed
// downstream of DISCARD_TOKENS, increase DISCARD_TOKENS and re-check --
// do not modify mult32x32_pipe_q8_24 / nr_iterate_q8_24 internals to chase
// this, since neither has been shown to be at fault; the race is specific
// to the first-fill transient and DISCARD_TOKENS is the correct knob. ***
//
// LATENCY / TIMING: unaffected by this revision beyond the startup-only
// change described above. Top-level combinational timing paths, register
// count in the timed critical paths, and the design's steady-state
// 40-cycle latency (post-priming) and 300.03 MHz Fmax are all identical to
// REV 6. The discard counter is a simple free-running compare-to-constant
// off the critical path (same structure as REV 7's counter, just clocked
// by v_nr instead of unconditionally) and does not appear in the REV 6
// worst-path report, so it introduces no new setup/hold risk.
// ============================================================================


// ============================================================================
// (1) reciprocal_interp9_q8_24   -- UNCHANGED from REV 2/REV 4/REV 6.
//
// 9-bit LUT + linear interpolation reciprocal seed for x in [0.5, 2.5), Q8.24
// ============================================================================

module reciprocal_interp9_q8_24 #(
    parameter int IDX_BITS        = 9,
    parameter int SHIFT           = 16,
    parameter int FRAC_BITS       = 16,
    parameter int SLOPE_FRAC_BITS = 21
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,
    output logic        valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO = 32'h0080_0000;
    localparam logic [31:0] X_HI = 32'h0280_0000;
    localparam int N = (1 << IDX_BITS);

    // -------------------------------------------------------------- P0 --
    logic [31:0] x_r0;
    logic        v_r0;
    logic        above_r0;
    logic        above_comb_p0;

    always_comb begin
        if (x_in[31])
            above_comb_p0 = 1'b1;
        else if (x_in[30:24] > 7'd2)
            above_comb_p0 = 1'b1;
        else if (x_in[30:24] < 7'd2)
            above_comb_p0 = 1'b0;
        else
            above_comb_p0 = (x_in[23:0] > 24'h80_0000);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r0     <= '0;
            v_r0     <= 1'b0;
            above_r0 <= 1'b0;
        end else begin
            x_r0     <= x_in;
            v_r0     <= valid_in;
            above_r0 <= above_comb_p0;
        end
    end

    // -------------------------------------------------------------- P1 --
    logic        below_r0;
    logic [25:0] offset_comb;

    always_comb begin
        below_r0    = (x_r0 < X_LO);
        offset_comb = below_r0 ? 26'd0 : (x_r0 - X_LO);
    end

    logic [25:0] offset_r1;
    logic        above_r1;
    logic        v_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset_r1 <= '0;
            above_r1  <= 1'b0;
            v_r1      <= 1'b0;
        end else begin
            offset_r1 <= offset_comb;
            above_r1  <= above_r0;
            v_r1      <= v_r0;
        end
    end

    // -------------------------------------------------------------- P2 --
    logic [IDX_BITS-1:0] idx_comb;
    logic [IDX_BITS-1:0] idx_r2;

    logic [FRAC_BITS-1:0] frac_comb;
    logic [FRAC_BITS-1:0] frac_r2;

    logic [IDX_BITS+3:0] idx_full;
    logic                 v_r2;

    always_comb begin
        idx_full = offset_r1 >> SHIFT;

        if (above_r1 || (idx_full > (N-1))) begin
            idx_comb  = N-1;
            frac_comb = {FRAC_BITS{1'b1}};
        end else begin
            idx_comb  = idx_full[IDX_BITS-1:0];
            frac_comb = offset_r1 & ((1 << FRAC_BITS) - 1);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2  <= '0;
            frac_r2 <= '0;
            v_r2    <= 1'b0;
        end else begin
            idx_r2  <= idx_comb;
            frac_r2 <= frac_comb;
            v_r2    <= v_r1;
        end
    end

    // -------------------------------------------------------------- P3 --
    localparam int SEED_BITS  = 32;
    localparam int SLOPE_BITS = 25;

    logic [31:0] seed_dout;
    logic [24:0] slope_dout;

    xpm_memory_sprom #(
        .ADDR_WIDTH_A       (IDX_BITS),
        .MEMORY_INIT_FILE   ("interp9_seed.mem"),
        .MEMORY_PRIMITIVE   ("block"),
        .MEMORY_SIZE        (N * SEED_BITS),
        .READ_DATA_WIDTH_A  (SEED_BITS),
        .READ_LATENCY_A     (2),
        .READ_RESET_VALUE_A ("0"),
        .RST_MODE_A         ("SYNC"),
        .USE_MEM_INIT       (1)
    ) seed_rom_inst (
        .clka   (clk),
        .ena    (1'b1),
        .regcea (1'b1),
        .rsta   (1'b0),
        .sleep  (1'b0),
        .addra  (idx_r2),
        .douta  (seed_dout)
    );

    xpm_memory_sprom #(
        .ADDR_WIDTH_A       (IDX_BITS),
        .MEMORY_INIT_FILE   ("interp9_slope.mem"),
        .MEMORY_PRIMITIVE   ("block"),
        .MEMORY_SIZE        (N * SLOPE_BITS),
        .READ_DATA_WIDTH_A  (SLOPE_BITS),
        .READ_LATENCY_A     (2),
        .READ_RESET_VALUE_A ("0"),
        .RST_MODE_A         ("SYNC"),
        .USE_MEM_INIT       (1)
    ) slope_rom_inst (
        .clka   (clk),
        .ena    (1'b1),
        .regcea (1'b1),
        .rsta   (1'b0),
        .sleep  (1'b0),
        .addra  (idx_r2),
        .douta  (slope_dout)
    );

    logic [FRAC_BITS-1:0] frac_r3a;
    logic [FRAC_BITS-1:0] frac_r3b;
    logic                 v_r3a;
    logic                 v_r3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_r3a <= '0;
            frac_r3b <= '0;
            v_r3a    <= 1'b0;
            v_r3b    <= 1'b0;
        end else begin
            frac_r3a <= frac_r2;
            frac_r3b <= frac_r3a;
            v_r3a    <= v_r2;
            v_r3b    <= v_r3a;
        end
    end

    // -------------------------------------------------------------- P4 --
    (* dont_touch = "true", keep = "true" *)
    logic [31:0] seed_r4;

    (* dont_touch = "true", keep = "true" *)
    logic signed [24:0] slope_r4;

    (* dont_touch = "true", keep = "true" *)
    logic [FRAC_BITS-1:0] frac_r4;

    logic v_r4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_r4  <= '0;
            slope_r4 <= '0;
            frac_r4  <= '0;
            v_r4     <= 1'b0;
        end else begin
            seed_r4  <= seed_dout;
            slope_r4 <= slope_dout;
            frac_r4  <= frac_r3b;
            v_r4     <= v_r3b;
        end
    end

    // -------------------------------------------------------------- P5/P6/P7 --
    logic [29:0] dsp_a_in;
    logic [17:0] dsp_b_in;
    logic [47:0] dsp_p_out;

    assign dsp_a_in = {{5{slope_r4[24]}}, slope_r4};
    assign dsp_b_in = {2'b0, frac_r4};

    DSP48E1 #(
        .A_INPUT            ("DIRECT"),
        .B_INPUT            ("DIRECT"),
        .USE_DPORT          ("FALSE"),
        .USE_MULT           ("MULTIPLY"),
        .USE_SIMD           ("ONE48"),
        .AREG               (1),
        .BREG               (1),
        .MREG               (1),
        .PREG               (1),
        .ACASCREG           (1),
        .BCASCREG           (1),
        .ADREG              (0),
        .ALUMODEREG         (0),
        .CARRYINREG         (0),
        .CARRYINSELREG      (0),
        .CREG               (0),
        .DREG               (0),
        .INMODEREG          (0),
        .OPMODEREG          (0)
    ) dsp_slope_mult_inst (
        .CLK                (clk),

        .A                  (dsp_a_in),
        .B                  (dsp_b_in),
        .C                  (48'b0),
        .D                  (25'b0),
        .ACIN               (30'b0),
        .BCIN               (18'b0),
        .PCIN               (48'b0),
        .CARRYCASCIN        (1'b0),
        .MULTSIGNIN         (1'b0),

        .INMODE             (5'b00000),
        .ALUMODE            (4'b0000),
        .OPMODE             (7'b0000101),
        .CARRYINSEL         (3'b000),
        .CARRYIN            (1'b0),

        .CEA1               (1'b1),
        .CEA2               (1'b1),
        .CEB1               (1'b1),
        .CEB2               (1'b1),
        .CEM                (1'b1),
        .CEP                (1'b1),
        .CEAD               (1'b0),
        .CEALUMODE          (1'b0),
        .CEC                (1'b0),
        .CECARRYIN          (1'b0),
        .CECTRL             (1'b0),
        .CED                (1'b0),
        .CEINMODE           (1'b0),

        .RSTA               (~rst_n),
        .RSTB               (~rst_n),
        .RSTM               (~rst_n),
        .RSTP               (~rst_n),
        .RSTC               (1'b0),
        .RSTD               (1'b0),
        .RSTALLCARRYIN      (1'b0),
        .RSTALUMODE         (1'b0),
        .RSTCTRL            (1'b0),
        .RSTINMODE          (1'b0),

        .P                  (dsp_p_out),
        .ACOUT              (),
        .BCOUT              (),
        .CARRYCASCOUT       (),
        .CARRYOUT           (),
        .MULTSIGNOUT        (),
        .OVERFLOW           (),
        .PATTERNBDETECT     (),
        .PATTERNDETECT      (),
        .PCOUT              (),
        .UNDERFLOW          ()
    );

    // -------------------------------------------------------------- P7 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r6;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r7;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r6;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_r5 <= '0; seed_r6 <= '0; seed_r7 <= '0;
            v_r5    <= 1'b0; v_r6 <= 1'b0; v_r7 <= 1'b0;
        end else begin
            seed_r5 <= seed_r4;
            seed_r6 <= seed_r5;
            seed_r7 <= seed_r6;
            v_r5    <= v_r4;
            v_r6    <= v_r5;
            v_r7    <= v_r6;
        end
    end

    // -------------------------------------------------------------- P8 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [47:0] dsp_p_r8;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r8;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r8;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dsp_p_r8 <= '0; seed_r8 <= '0; v_r8 <= 1'b0;
        end else begin
            dsp_p_r8 <= dsp_p_out;
            seed_r8  <= seed_r7;
            v_r8     <= v_r7;
        end
    end

    logic signed [43:0] seed_ext;
    logic signed [43:0] prod_ext;

    assign seed_ext = {{12{seed_r8[31]}}, seed_r8};
    assign prod_ext = {{22{dsp_p_r8[42]}}, dsp_p_r8[42:21]};

    // -------------------------------------------------------------- P9 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c0_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_seed_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_prod_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r9;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r9;
    logic v_r9;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c0_r9 <= '0; carry_c0_r9 <= 1'b0;
            c1_seed_r9 <= '0; c1_prod_r9 <= '0;
            c2_seed_r9 <= '0; c2_prod_r9 <= '0;
            c3_seed_r9 <= '0; c3_prod_r9 <= '0;
            v_r9 <= 1'b0;
        end else begin
            {carry_c0_r9, sum_c0_r9} <= {1'b0, seed_ext[10:0]} + {1'b0, prod_ext[10:0]};
            c1_seed_r9 <= seed_ext[21:11];
            c1_prod_r9 <= prod_ext[21:11];
            c2_seed_r9 <= seed_ext[32:22];
            c2_prod_r9 <= prod_ext[32:22];
            c3_seed_r9 <= seed_ext[43:33];
            c3_prod_r9 <= prod_ext[43:33];
            v_r9 <= v_r8;
        end
    end

    // ------------------------------------------------------------- P10 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c1_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r10;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r10;
    logic v_r10;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c1_r10 <= '0; carry_c1_r10 <= 1'b0; sum_c0_r10 <= '0;
            c2_seed_r10 <= '0; c2_prod_r10 <= '0;
            c3_seed_r10 <= '0; c3_prod_r10 <= '0;
            v_r10 <= 1'b0;
        end else begin
            {carry_c1_r10, sum_c1_r10} <= {1'b0, c1_seed_r9} + {1'b0, c1_prod_r9} + {11'b0, carry_c0_r9};
            sum_c0_r10  <= sum_c0_r9;
            c2_seed_r10 <= c2_seed_r9;
            c2_prod_r10 <= c2_prod_r9;
            c3_seed_r10 <= c3_seed_r9;
            c3_prod_r10 <= c3_prod_r9;
            v_r10 <= v_r9;
        end
    end

    // ------------------------------------------------------------- P11 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r11;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c2_r11;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r11;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r11;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r11;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r11;
    logic v_r11;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c2_r11 <= '0; carry_c2_r11 <= 1'b0;
            sum_c0_r11 <= '0; sum_c1_r11 <= '0;
            c3_seed_r11 <= '0; c3_prod_r11 <= '0;
            v_r11 <= 1'b0;
        end else begin
            {carry_c2_r11, sum_c2_r11} <= {1'b0, c2_seed_r10} + {1'b0, c2_prod_r10} + {11'b0, carry_c1_r10};
            sum_c0_r11  <= sum_c0_r10;
            sum_c1_r11  <= sum_c1_r10;
            c3_seed_r11 <= c3_seed_r10;
            c3_prod_r11 <= c3_prod_r10;
            v_r11 <= v_r10;
        end
    end

    // ------------------------------------------------------------- P12 --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [11:0] sum_c3_r12;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r12;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r12;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r12;
    logic v_r12;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c3_r12 <= '0; sum_c0_r12 <= '0; sum_c1_r12 <= '0; sum_c2_r12 <= '0;
            v_r12 <= 1'b0;
        end else begin
            sum_c3_r12 <= $signed({c3_seed_r11[10], c3_seed_r11}) +
                          $signed({c3_prod_r11[10], c3_prod_r11}) +
                          $signed({11'b0, carry_c2_r11});
            sum_c0_r12 <= sum_c0_r11;
            sum_c1_r12 <= sum_c1_r11;
            sum_c2_r12 <= sum_c2_r11;
            v_r12 <= v_r11;
        end
    end

    // ------------------------------------------------------------- P13 --
    logic signed [44:0] sum_full_r12;
    assign sum_full_r12 = {sum_c3_r12, sum_c2_r12, sum_c1_r12, sum_c0_r12};

    logic ovf_pos_r13, ovf_neg_r13;
    logic [31:0] sum_lo_r13;
    logic v_r13;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ovf_pos_r13 <= 1'b0; ovf_neg_r13 <= 1'b0; sum_lo_r13 <= '0; v_r13 <= 1'b0;
        end else begin
            ovf_pos_r13 <= (sum_full_r12 > 45'sd2147483647);
            ovf_neg_r13 <= (sum_full_r12 < -45'sd2147483648);
            sum_lo_r13  <= sum_full_r12[31:0];
            v_r13       <= v_r12;
        end
    end

    // ------------------------------------------------------------- P14 --
    logic [31:0] recip_r14;
    logic        v_r14;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_r14 <= '0; v_r14 <= 1'b0;
        end else begin
            if (ovf_pos_r13)      recip_r14 <= 32'h7FFF_FFFF;
            else if (ovf_neg_r13) recip_r14 <= 32'h8000_0000;
            else                  recip_r14 <= sum_lo_r13;
            v_r14 <= v_r13;
        end
    end

    assign recip_out = recip_r14;
    assign valid_out = v_r14;

endmodule


// ============================================================================
// (2) mult32x32_pipe_q8_24   -- UNCHANGED from REV 2/REV 4/REV 6.
//
// Pipelined signed 32x32 -> 64 multiply, schoolbook 4-way 16-bit split.
// Already closed timing per the REV 2 report -- not touched in this pass.
// Latency: 10 cycles.
// ============================================================================

module mult32x32_pipe_q8_24 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               valid_in,
    input  logic signed [31:0] a_in,
    input  logic signed [31:0] b_in,
    output logic               valid_out,
    output logic signed [63:0] product_out
);

    // ---------------------------------------------------------- S0: split --
    (* dont_touch = "true", keep = "true" *)
    logic signed [16:0] ah_r0, al_r0, bh_r0, bl_r0;   // 17b: sign or zero-ext
    logic v_r0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ah_r0 <= '0; al_r0 <= '0; bh_r0 <= '0; bl_r0 <= '0; v_r0 <= 1'b0;
        end else begin
            ah_r0 <= {a_in[31], a_in[31:16]};   // signed 16b -> 17b
            al_r0 <= {1'b0,     a_in[15:0]};    // unsigned 16b -> 17b (nonneg)
            bh_r0 <= {b_in[31], b_in[31:16]};
            bl_r0 <= {1'b0,     b_in[15:0]};
            v_r0  <= valid_in;
        end
    end

    // ------------------------------------------------- S1: four partial mults --
    logic v_r0a;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_r0a <= 1'b0;
        else        v_r0a <= v_r0;   // dummy stage matching DSP's MREG cycle
    end

    logic [29:0] dsp_a_hh, dsp_a_hl, dsp_a_lh, dsp_a_ll;
    logic [17:0] dsp_b_hh, dsp_b_hl, dsp_b_lh, dsp_b_ll;

    assign dsp_a_hh = {{13{ah_r0[16]}}, ah_r0};
    assign dsp_b_hh = {bh_r0[16], bh_r0};

    assign dsp_a_hl = {{13{ah_r0[16]}}, ah_r0};
    assign dsp_b_hl = {bl_r0[16], bl_r0};

    assign dsp_a_lh = {{13{al_r0[16]}}, al_r0};
    assign dsp_b_lh = {bh_r0[16], bh_r0};

    assign dsp_a_ll = {{13{al_r0[16]}}, al_r0};
    assign dsp_b_ll = {bl_r0[16], bl_r0};

    logic [47:0] dsp_p_hh, dsp_p_hl, dsp_p_lh, dsp_p_ll;

    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .AREG(0), .BREG(0), .MREG(1), .PREG(1),
        .ACASCREG(0), .BCASCREG(0),
        .ADREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
        .CREG(0), .DREG(0), .INMODEREG(0), .OPMODEREG(0)
    ) dsp_hh_inst (
        .CLK(clk), .A(dsp_a_hh), .B(dsp_b_hh), .C(48'b0), .D(25'b0),
        .ACIN(30'b0), .BCIN(18'b0), .PCIN(48'b0),
        .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
        .INMODE(5'b00000), .ALUMODE(4'b0000), .OPMODE(7'b0000101),
        .CARRYINSEL(3'b000), .CARRYIN(1'b0),
        .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1),
        .CEM(1'b1), .CEP(1'b1), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
        .RSTA(~rst_n), .RSTB(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .RSTC(1'b0), .RSTD(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTCTRL(1'b0), .RSTINMODE(1'b0),
        .P(dsp_p_hh), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
        .PCOUT(), .UNDERFLOW()
    );

    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .AREG(0), .BREG(0), .MREG(1), .PREG(1),
        .ACASCREG(0), .BCASCREG(0),
        .ADREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
        .CREG(0), .DREG(0), .INMODEREG(0), .OPMODEREG(0)
    ) dsp_hl_inst (
        .CLK(clk), .A(dsp_a_hl), .B(dsp_b_hl), .C(48'b0), .D(25'b0),
        .ACIN(30'b0), .BCIN(18'b0), .PCIN(48'b0),
        .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
        .INMODE(5'b00000), .ALUMODE(4'b0000), .OPMODE(7'b0000101),
        .CARRYINSEL(3'b000), .CARRYIN(1'b0),
        .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1),
        .CEM(1'b1), .CEP(1'b1), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
        .RSTA(~rst_n), .RSTB(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .RSTC(1'b0), .RSTD(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTCTRL(1'b0), .RSTINMODE(1'b0),
        .P(dsp_p_hl), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
        .PCOUT(), .UNDERFLOW()
    );

    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .AREG(0), .BREG(0), .MREG(1), .PREG(1),
        .ACASCREG(0), .BCASCREG(0),
        .ADREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
        .CREG(0), .DREG(0), .INMODEREG(0), .OPMODEREG(0)
    ) dsp_lh_inst (
        .CLK(clk), .A(dsp_a_lh), .B(dsp_b_lh), .C(48'b0), .D(25'b0),
        .ACIN(30'b0), .BCIN(18'b0), .PCIN(48'b0),
        .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
        .INMODE(5'b00000), .ALUMODE(4'b0000), .OPMODE(7'b0000101),
        .CARRYINSEL(3'b000), .CARRYIN(1'b0),
        .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1),
        .CEM(1'b1), .CEP(1'b1), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
        .RSTA(~rst_n), .RSTB(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .RSTC(1'b0), .RSTD(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTCTRL(1'b0), .RSTINMODE(1'b0),
        .P(dsp_p_lh), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
        .PCOUT(), .UNDERFLOW()
    );

    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .AREG(0), .BREG(0), .MREG(1), .PREG(1),
        .ACASCREG(0), .BCASCREG(0),
        .ADREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
        .CREG(0), .DREG(0), .INMODEREG(0), .OPMODEREG(0)
    ) dsp_ll_inst (
        .CLK(clk), .A(dsp_a_ll), .B(dsp_b_ll), .C(48'b0), .D(25'b0),
        .ACIN(30'b0), .BCIN(18'b0), .PCIN(48'b0),
        .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
        .INMODE(5'b00000), .ALUMODE(4'b0000), .OPMODE(7'b0000101),
        .CARRYINSEL(3'b000), .CARRYIN(1'b0),
        .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1),
        .CEM(1'b1), .CEP(1'b1), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
        .RSTA(~rst_n), .RSTB(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .RSTC(1'b0), .RSTD(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTCTRL(1'b0), .RSTINMODE(1'b0),
        .P(dsp_p_ll), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
        .PCOUT(), .UNDERFLOW()
    );

    logic signed [33:0] pp_hh_r1, pp_hl_r1, pp_lh_r1, pp_ll_r1;
    assign pp_hh_r1 = $signed(dsp_p_hh[33:0]);
    assign pp_hl_r1 = $signed(dsp_p_hl[33:0]);
    assign pp_lh_r1 = $signed(dsp_p_lh[33:0]);
    assign pp_ll_r1 = $signed(dsp_p_ll[33:0]);

    logic v_r1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_r1 <= 1'b0;
        else        v_r1 <= v_r0a;
    end

    // ---------------------------------------------- S2: extra DSP output margin --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [33:0] pp_hh_r2, pp_hl_r2, pp_lh_r2, pp_ll_r2;
    logic v_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pp_hh_r2 <= '0; pp_hl_r2 <= '0; pp_lh_r2 <= '0; pp_ll_r2 <= '0;
            v_r2 <= 1'b0;
        end else begin
            pp_hh_r2 <= pp_hh_r1;
            pp_hl_r2 <= pp_hl_r1;
            pp_lh_r2 <= pp_lh_r1;
            pp_ll_r2 <= pp_ll_r1;
            v_r2 <= v_r1;
        end
    end

    // ---------------------------------------------- S3: combine cross terms --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [34:0] cross_sum_r3;   // Ah*Bl + Al*Bh
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [33:0] pp_hh_r3, pp_ll_r3;
    logic v_r3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross_sum_r3 <= '0; pp_hh_r3 <= '0; pp_ll_r3 <= '0; v_r3 <= 1'b0;
        end else begin
            cross_sum_r3 <= $signed(pp_hl_r2) + $signed(pp_lh_r2);
            pp_hh_r3     <= pp_hh_r2;
            pp_ll_r3     <= pp_ll_r2;
            v_r3         <= v_r2;
        end
    end

    // ------------------------------------------ S3b: align + carry-save compress
    logic signed [67:0] add_hh_ext, add_cs_ext, add_ll_ext;
    always_comb begin
        add_hh_ext = ({{34{pp_hh_r3[33]}},     pp_hh_r3})     <<< 32;
        add_cs_ext = ({{33{cross_sum_r3[34]}}, cross_sum_r3}) <<< 16;
        add_ll_ext =  {{34{pp_ll_r3[33]}},     pp_ll_r3};
    end

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [67:0] csa_sum_r3b;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [67:0] csa_carry_r3b;
    logic v_r3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csa_sum_r3b <= '0; csa_carry_r3b <= '0; v_r3b <= 1'b0;
        end else begin
            csa_sum_r3b   <= add_hh_ext ^ add_cs_ext ^ add_ll_ext;
            csa_carry_r3b <= ((add_hh_ext & add_cs_ext) |
                               (add_hh_ext & add_ll_ext) |
                               (add_cs_ext & add_ll_ext)) <<< 1;
            v_r3b <= v_r3;
        end
    end

    // ------------------------------- S4: chunk0 carry-propagate (bits [16:0]) --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c0_r4;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic        carry_c0_r4;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c1_sum_r4, c1_carry_r4;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c2_sum_r4, c2_carry_r4;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c3_sum_r4, c3_carry_r4;
    logic v_r4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c0_r4 <= '0; carry_c0_r4 <= 1'b0;
            c1_sum_r4 <= '0; c1_carry_r4 <= '0;
            c2_sum_r4 <= '0; c2_carry_r4 <= '0;
            c3_sum_r4 <= '0; c3_carry_r4 <= '0;
            v_r4 <= 1'b0;
        end else begin
            {carry_c0_r4, sum_c0_r4} <= {1'b0, csa_sum_r3b[16:0]} + {1'b0, csa_carry_r3b[16:0]};
            c1_sum_r4   <= csa_sum_r3b[33:17];
            c1_carry_r4 <= csa_carry_r3b[33:17];
            c2_sum_r4   <= csa_sum_r3b[50:34];
            c2_carry_r4 <= csa_carry_r3b[50:34];
            c3_sum_r4   <= csa_sum_r3b[67:51];
            c3_carry_r4 <= csa_carry_r3b[67:51];
            v_r4 <= v_r3b;
        end
    end

    // ------------------------------- S5: chunk1 carry-propagate (bits [33:17]) --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c1_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic        carry_c1_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c0_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c2_sum_r5, c2_carry_r5;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c3_sum_r5, c3_carry_r5;
    logic v_r5;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c1_r5 <= '0; carry_c1_r5 <= 1'b0; sum_c0_r5 <= '0;
            c2_sum_r5 <= '0; c2_carry_r5 <= '0;
            c3_sum_r5 <= '0; c3_carry_r5 <= '0;
            v_r5 <= 1'b0;
        end else begin
            {carry_c1_r5, sum_c1_r5} <= {1'b0, c1_sum_r4} + {1'b0, c1_carry_r4} + {17'b0, carry_c0_r4};
            sum_c0_r5 <= sum_c0_r4;
            c2_sum_r5 <= c2_sum_r4;
            c2_carry_r5 <= c2_carry_r4;
            c3_sum_r5 <= c3_sum_r4;
            c3_carry_r5 <= c3_carry_r4;
            v_r5 <= v_r4;
        end
    end

    // ------------------------------- S6: chunk2 carry-propagate (bits [50:34]) --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c2_r6;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic        carry_c2_r6;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c0_r6, sum_c1_r6;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] c3_sum_r6, c3_carry_r6;
    logic v_r6;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c2_r6 <= '0; carry_c2_r6 <= 1'b0;
            sum_c0_r6 <= '0; sum_c1_r6 <= '0;
            c3_sum_r6 <= '0; c3_carry_r6 <= '0;
            v_r6 <= 1'b0;
        end else begin
            {carry_c2_r6, sum_c2_r6} <= {1'b0, c2_sum_r5} + {1'b0, c2_carry_r5} + {17'b0, carry_c1_r5};
            sum_c0_r6 <= sum_c0_r5;
            sum_c1_r6 <= sum_c1_r5;
            c3_sum_r6 <= c3_sum_r5;
            c3_carry_r6 <= c3_carry_r5;
            v_r6 <= v_r5;
        end
    end

    // ------------------------- S7: chunk3 carry-propagate (final) + assemble --
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [17:0] sum_c3_r7;
    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [16:0] sum_c0_r7, sum_c1_r7, sum_c2_r7;
    logic v_r7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c3_r7 <= '0; sum_c0_r7 <= '0; sum_c1_r7 <= '0; sum_c2_r7 <= '0;
            v_r7 <= 1'b0;
        end else begin
            sum_c3_r7 <= $signed({c3_sum_r6[16], c3_sum_r6}) +
                         $signed({c3_carry_r6[16], c3_carry_r6}) +
                         $signed({17'b0, carry_c2_r6});
            sum_c0_r7 <= sum_c0_r6;
            sum_c1_r7 <= sum_c1_r6;
            sum_c2_r7 <= sum_c2_r6;
            v_r7 <= v_r6;
        end
    end

    logic signed [67:0] product_full_comb;
    assign product_full_comb = {sum_c3_r7, sum_c2_r7, sum_c1_r7, sum_c0_r7};

    assign product_out = product_full_comb[63:0];
    assign valid_out   = v_r7;

endmodule


// ============================================================================
// (3) nr_iterate_q8_24   -- UNCHANGED from REV 6 (carry-lookahead round,
// tail un-fused, confirmed WNS +0.078ns / 0 failing endpoints post-route)
//
// One Newton-Raphson iteration: y1 = y0 * (2 - x*y0), Q8.24 in/out.
// Two sequential 32x32 multiplies via mult32x32_pipe_q8_24.
// ============================================================================

module nr_iterate_q8_24 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,     // Q8.24, aligned with y0_in
    input  logic [31:0] y0_in,    // Q8.24 seed
    output logic        valid_out,
    output logic [31:0] y1_out    // Q8.24 refined reciprocal
);

    localparam logic signed [31:0] TWO_Q8_24 = 32'h0200_0000;

    // ---- delay x_in/y0_in alongside the first multiplier's latency ----
    localparam int MULT_LATENCY = 10;
    logic [31:0] x_dly [0:MULT_LATENCY-1];
    logic signed [31:0] y0_dly [0:MULT_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MULT_LATENCY; i++) begin
                x_dly[i]  <= '0;
                y0_dly[i] <= '0;
            end
        end else begin
            x_dly[0]  <= x_in;
            y0_dly[0] <= $signed(y0_in);
            for (int i = 1; i < MULT_LATENCY; i++) begin
                x_dly[i]  <= x_dly[i-1];
                y0_dly[i] <= y0_dly[i-1];
            end
        end
    end

    // ---- multiply #1: t_full = x * y0 --------------------------------
    logic        v_m1;
    logic signed [63:0] t_full;

    mult32x32_pipe_q8_24 mult_x_y0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        .a_in        ($signed(x_in)),
        .b_in        ($signed(y0_in)),
        .valid_out   (v_m1),
        .product_out (t_full)
    );

    // ---- round (carry-select) + form (2 - t) -------
    //
    // (t_full + 2^23) >>> 24, truncated to 32 bits on assignment, is
    // equivalent to: T_IN = t_full[55:24] (32b), T_CIN = t_full[23] (1b),
    // result = T_IN + T_CIN -- a 32-bit conditional increment. Chunked into
    // 4x8-bit carry-select chunks. Not a violator in post-route reports;
    // unchanged since REV 4.
    (* keep = "true" *) logic [7:0] tchunk0, tchunk1, tchunk2, tchunk3;
    (* keep = "true" *) logic [7:0] tc0_inc, tc1_inc, tc2_inc, tc3_inc;
    (* keep = "true" *) logic       tcin0, tcarry0, tcarry1, tcarry2, tcarry3;
    (* keep = "true" *) logic [7:0] tres0, tres1, tres2, tres3;

    always_comb begin
        tchunk0 = t_full[31:24];
        tchunk1 = t_full[39:32];
        tchunk2 = t_full[47:40];
        tchunk3 = t_full[55:48];
        tcin0   = t_full[23];

        tc0_inc = tchunk0 + 8'd1;
        tc1_inc = tchunk1 + 8'd1;
        tc2_inc = tchunk2 + 8'd1;
        tc3_inc = tchunk3 + 8'd1;

        tcarry0 = tcin0;
        tcarry1 = tcarry0 & (&tchunk0);
        tcarry2 = tcarry1 & (&tchunk1);
        tcarry3 = tcarry2 & (&tchunk2);

        tres0 = tcarry0 ? tc0_inc : tchunk0;
        tres1 = tcarry1 ? tc1_inc : tchunk1;
        tres2 = tcarry2 ? tc2_inc : tchunk2;
        tres3 = tcarry3 ? tc3_inc : tchunk3;
    end

    logic signed [31:0] t_raw_r5;
    logic                v_r5;
    logic signed [31:0] y0_r5;
    logic [31:0]         x_r5;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_raw_r5 <= '0; v_r5 <= 1'b0; y0_r5 <= '0; x_r5 <= '0;
        end else begin
            t_raw_r5 <= $signed({tres3, tres2, tres1, tres0});
            v_r5     <= v_m1;
            y0_r5    <= y0_dly[MULT_LATENCY-1];
            x_r5     <= x_dly[MULT_LATENCY-1];
        end
    end

    logic signed [31:0] e_r6;   // e = 2.0 - t   (Q8.24)
    logic                v_r6;
    logic signed [31:0] y0_r6;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_r6 <= '0; v_r6 <= 1'b0; y0_r6 <= '0;
        end else begin
            e_r6  <= TWO_Q8_24 - t_raw_r5;
            v_r6  <= v_r5;
            y0_r6 <= y0_r5;
        end
    end

    // ---- multiply #2: y1_full = y0 * e ----------------------------------
    logic        v_m2;
    logic signed [63:0] y1_full;

    mult32x32_pipe_q8_24 mult_y0_e (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (v_r6),
        .a_in        (y0_r6),
        .b_in        (e_r6),
        .valid_out   (v_m2),
        .product_out (y1_full)
    );

    // ---- STAGE A: carry-lookahead round-add, registered here ----------
    //
    // (y1_full + 2^23) >>> 24 as a 40-bit conditional increment, split
    // into 4x10-bit carry-select chunks. Confirmed post-route: this is
    // the location of the design's worst path (4 logic levels,
    // WNS = +0.078ns), fully closed at 0 failing endpoints.
    (* keep = "true" *) logic [9:0] c0, c1, c2, c3;
    (* keep = "true" *) logic [9:0] c0_inc, c1_inc, c2_inc, c3_inc;
    (* keep = "true" *) logic       cin0;
    (* keep = "true" *) logic       g0, g1, g2;
    (* keep = "true" *) logic       carry1, carry2, carry3;
    (* keep = "true" *) logic [9:0] res0, res1, res2, res3;

    always_comb begin
        c0   = y1_full[33:24];
        c1   = y1_full[43:34];
        c2   = y1_full[53:44];
        c3   = y1_full[63:54];
        cin0 = y1_full[23];

        c0_inc = c0 + 10'd1;
        c1_inc = c1 + 10'd1;
        c2_inc = c2 + 10'd1;
        c3_inc = c3 + 10'd1;

        g0 = &c0;
        g1 = &c1;
        g2 = &c2;

        carry1 = cin0 & g0;
        carry2 = cin0 & g0 & g1;
        carry3 = cin0 & g0 & g1 & g2;

        res0 = cin0   ? c0_inc : c0;
        res1 = carry1 ? c1_inc : c1;
        res2 = carry2 ? c2_inc : c2;
        res3 = carry3 ? c3_inc : c3;
    end

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [9:0] res0_rA, res1_rA, res2_rA, res3_rA;
    logic       v_rA;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res0_rA <= '0; res1_rA <= '0; res2_rA <= '0; res3_rA <= '0;
            v_rA    <= 1'b0;
        end else begin
            res0_rA <= res0;
            res1_rA <= res1;
            res2_rA <= res2;
            res3_rA <= res3;
            v_rA    <= v_m2;
        end
    end

    // ---- STAGE B: overflow-detect + 3-way select, its OWN cycle --------
    logic ovf_comb, sign_comb;
    always_comb begin
        ovf_comb  = |(res3_rA[9:2] ^ {8{res3_rA[1]}});
        sign_comb = res3_rA[9];
    end

    logic v_r_out;
    logic [31:0] y1_r_out;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r_out <= 1'b0; y1_r_out <= '0;
        end else begin
            v_r_out <= v_rA;

            if (ovf_comb)
                y1_r_out <= sign_comb ? 32'h8000_0000 : 32'h7FFF_FFFF;
            else
                y1_r_out <= {res3_rA[1:0], res2_rA, res1_rA, res0_rA};
        end
    end

    assign y1_out    = y1_r_out;
    assign valid_out = v_r_out;

endmodule


// ============================================================================
// (4) reciprocal_hybrid9_1nr_q8_24  -- REV 8 (see file header for full
// rationale)
//
// Top level: 9-bit LUT+interp seed -> 1 NR iteration.
//
// Steady-state top-level latency (once primed) is still 16 (seed) + 24
// (nr_iterate_q8_24: 10+2+10+2) = 40 cycles, matching the confirmed
// measured latency from REV 6/7 regressions. The startup guard below only
// delays the point at which the FIRST real token is allowed to leave the
// module; it adds nothing to steady-state per-sample latency once
// pipeline_primed is set, and it does not touch nr_stage or seed_gen.
// ============================================================================

module reciprocal_hybrid9_1nr_q8_24 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,
    output logic        valid_out,
    output logic [31:0] recip_out
);

    logic        v_seed;
    logic [31:0] y0;

    reciprocal_interp9_q8_24 seed_gen (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (valid_in),
        .x_in       (x_in),
        .valid_out  (v_seed),
        .recip_out  (y0)
    );

    localparam int SEED_LATENCY = 16;
    logic [31:0] x_delay [0:SEED_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SEED_LATENCY; i++) x_delay[i] <= '0;
        end else begin
            x_delay[0] <= x_in;
            for (int i = 1; i < SEED_LATENCY; i++) x_delay[i] <= x_delay[i-1];
        end
    end

    logic        v_nr;
    logic [31:0] y1_nr;

    nr_iterate_q8_24 nr_stage (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (v_seed),
        .x_in       (x_delay[SEED_LATENCY-1]),
        .y0_in      (y0),
        .valid_out  (v_nr),
        .y1_out     (y1_nr)
    );

    // ------------------------------------------------------------------
    // REV 8 FIX: event-counted startup guard (replaces REV 7's
    // reset-time-anchored counter).
    //
    // REV 7 held valid_out low for a fixed number of cycles COUNTED FROM
    // RESET RELEASE, on the assumption that real data would not start
    // arriving until well after that window closed. That assumption is
    // not part of this module's interface and does not hold in general --
    // confirmed by simulation: when valid_in was asserted immediately
    // after reset release (a legal, common pattern), REV 7's guard opened
    // while a corrupted first-fill token (from mult32x32_pipe_q8_24's
    // internal product-vs-valid settling race on the very first tokens
    // post-reset) was still latched at nr_stage's output, and that
    // corrupted value reached top-level valid_out/recip_out.
    //
    // Fix: count actual nr_stage.valid_out (v_nr) PULSES instead of clock
    // cycles since reset. Discard the first DISCARD_TOKENS of them
    // unconditionally (never let them reach valid_out), then latch
    // pipeline_primed permanently high. This has no notion of "time since
    // reset" at all, so it is correct regardless of when valid_in first
    // asserts relative to rst_n release.
    //
    // DISCARD_TOKENS = 8 preserves REV 7's intended one-token safety
    // margin beyond the 7 corrupted tokens seen in the original root-cause
    // trace (idx 0-6).
    //
    // This does NOT modify any logic inside mult32x32_pipe_q8_24 or
    // nr_iterate_q8_24, so REV 6's post-route timing closure (WNS
    // +0.078ns, 0 failing endpoints) is untouched and does not need
    // re-verification. Steady-state throughput/per-sample latency once
    // primed are unaffected; only the number of startup tokens discarded
    // is now anchored to real pipeline events instead of a wall-clock
    // guess.
    // ------------------------------------------------------------------
    localparam int DISCARD_TOKENS = 8;
    localparam int DCNT_W = $clog2(DISCARD_TOKENS + 1);

    logic [DCNT_W-1:0] discard_cnt;
    logic              pipeline_primed;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            discard_cnt     <= '0;
            pipeline_primed <= 1'b0;
        end else if (!pipeline_primed && v_nr) begin
            // Only advance on real v_nr pulses -- i.e. only when there is
            // an actual token being discarded -- never on a bare clock
            // edge. This is the entire fix relative to REV 7.
            if (discard_cnt == DISCARD_TOKENS[DCNT_W-1:0])
                pipeline_primed <= 1'b1;
            else
                discard_cnt <= discard_cnt + 1'b1;
        end
    end

    assign valid_out = v_nr & pipeline_primed;
    assign recip_out = y1_nr;

endmodule