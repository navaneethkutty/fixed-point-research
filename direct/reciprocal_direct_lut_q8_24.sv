// ============================================================================
// reciprocal_direct_lut_q8_24  (min-period / WPWS fix, post-uniformity-fix)
//
// Direct-LUT reciprocal approximation for x in [0.5, 2.5], Q8.24 signed.
// Same pipeline shape as the previous revision (6 cycles latency, 1/cycle
// throughput). This revision addresses a DIFFERENT failing check than the
// one the previous comments were chasing.
//
// ----------------------------------------------------------------------
// WHAT ACTUALLY FAILED IN THE LAST TIMING REPORT
// ----------------------------------------------------------------------
// Design Timing Summary:
//     WNS = +0.032 ns   (setup, MET - idx_r2 -> BRAM address path)
//     WPWS = -0.076 ns  (pulse width / min period, FAILING, 4 endpoints)
//     TPWS = -0.304 ns
//
// The setup path (idx_r2 -> RAMB36E1 address pin) is fine. The actual
// failure is a "Min Period" check on RAMB36E1/CLKARDCLK itself:
//     Required 2.576 ns, Actual 2.500 ns, Slack -0.076 ns
// on ALL FOUR lanes (TPWS Failing Endpoints = 4). This is a minimum
// clock-period requirement of the BRAM primitive's internal read
// pipeline in its current configuration - a property of *which template
// XPM instantiates*, not of routing/placement. Improving the address
// net's routing does nothing to this number.
//
// Note the earlier b0/b1/b2-vs-b3 primitive-mismatch bug (previous
// revision) IS confirmed fixed here: 4 uniform failing endpoints across
// 4 uniform RAMB36E1 lanes, not the old 3-vs-1 split.
//
// ----------------------------------------------------------------------
// ROOT CAUSE: READ_DATA_WIDTH_A=8 is not a native RAMB36E1 width
// ----------------------------------------------------------------------
// Per AMD's 7-series memory resources documentation, RAMB36E1's
// parity-capable primary widths are x9/x18/x36 (x1/x2/x4/x36-cascade
// round out the primitive's native aspect ratios). x8 as a *symmetric*
// read=write width is not one of them - it's only reachable as an
// asymmetric read width paired with a x1/x2/x4 write width. For our
// case (symmetric 8-bit read-only ROM), XPM has to route the request
// through a non-native template - visible directly in the previous
// timing report's hierarchy path:
//     ...gen_rd_a.gen_rd_a_synth_template.gen_rf_narrow_pipe...
// "narrow_pipe" is the tell: this is extra internal muxing/pipeline
// logic layered onto the primitive to synthesize a width the hardware
// doesn't natively offer, and it is the most likely source of the
// degraded (slower) minimum period spec, independent of placement.
//
// FIX: widen each byte lane's read width to 9 bits (the true native
// aspect ratio at 4096 depth: 4096 x 9 = 36864 = exactly one RAMB36E1),
// and simply drop the unused 9th bit downstream. This should route
// through the native wide-pipe template instead of gen_rf_narrow_pipe
// and recover the primitive's normal (faster) minimum-period spec.
//
// ACTION REQUIRED (not automatic): the four .mem init files must be
// regenerated as 9-bit-wide values (existing 8-bit byte values,
// zero-extended into bit 8) - e.g. a byte value 0xA5 becomes 9-bit
// 0_1010_0101. Do not just repoint MEMORY_SIZE at the old 8-bit-per-word
// files; the word width itself changes.
//
// VERIFY AFTER RESYNTH (both parts - don't assume from source alone):
//   foreach c [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}] {
//       puts "$c : [get_property REF_NAME $c] : DOA_REG=[get_property DOA_REG $c]"
//   }
//   report_timing -delay_type min_period \
//       -through [get_pins -hierarchical *douta_reg_reg/CLKARDCLK] \
//       -max_paths 8
// Confirm (a) all four still report the same REF_NAME/DOA_REG=1, and
// (b) the min-period required-time number has dropped below 2.500 ns.
// If it hasn't, the narrow-pipe hypothesis was wrong for this Vivado/
// part combination and the next thing to try is forcing
// MEMORY_PRIMITIVE="block" with an explicit 18Kb pair (2x RAMB18E1 in
// x9 native mode each, cascaded) instead of a single RAMB36E1 - i.e.
// swap organization rather than width.
//
// ----------------------------------------------------------------------
// SECONDARY CHANGE: idx_r2 fanout replication (address routing margin)
// ----------------------------------------------------------------------
// Not required by the failing check above, but WNS is only +0.032 ns and
// the critical path is dominated by routing (1.275 ns route vs 0.518 ns
// logic) from a single idx_r2 register fanning out to 4 separate BRAM
// address ports across the die. Replicating idx_r2 into one register per
// lane lets the placer pack each copy near its own BRAM instead of
// routing one net to 4 physically separate destinations. This is cheap
// (3 extra 12-bit FFs) and attacks the real post-route critical path
// without touching arithmetic. Kept as a plain per-lane register (not a
// LOC/RLOC pin) so the placer/router remains free to choose the best
// physical location for each copy relative to its own BRAM.
// ============================================================================
module reciprocal_direct_lut_q8_24 #(
    parameter int IDX_BITS = 12,
    parameter int SHIFT    = 13                  // 25 - IDX_BITS
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic         valid_in,
    input  logic [31:0]  x_in,        // Q8.24 signed, expected in [0.5, 2.5]
    output logic         valid_out,
    output logic [31:0]  recip_out    // Q8.24 signed, ~1/x_in
);

    localparam logic [31:0] X_LO = 32'h0080_0000; // 0.5 in Q8.24
    localparam logic [31:0] X_HI = 32'h0280_0000; // 2.5 in Q8.24 - documentation only
    localparam int          N    = (1 << IDX_BITS);

    // -------------------------------------------------------------- P0 --
    logic [31:0] x_r0;
    logic        v_r0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r0 <= '0;
            v_r0 <= 1'b0;
        end else begin
            x_r0 <= x_in;
            v_r0 <= valid_in;
        end
    end

    // -------------------------------------------------------------- P1 --
    // Unchanged from the prior revision - this stage was not implicated
    // in either the setup path (which is met) or the min-period failure.
    localparam int LO_SHIFTED = int'(X_LO >> SHIFT); // 1024 for default params

    logic        below_r0;
    logic        way_above;
    logic [IDX_BITS:0] idx_raw_comb;
    always_comb begin
        below_r0     = (x_r0 < X_LO);
        way_above    = |x_r0[31:(SHIFT+IDX_BITS+1)];
        idx_raw_comb = x_r0[(SHIFT+IDX_BITS) -: (IDX_BITS+1)] - (IDX_BITS+1)'(LO_SHIFTED);
    end

    logic [IDX_BITS:0] idx_raw_r1;
    logic               below_r0_r1;
    logic               way_above_r1;
    logic               v_r1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_raw_r1   <= '0;
            below_r0_r1  <= 1'b0;
            way_above_r1 <= 1'b0;
            v_r1         <= 1'b0;
        end else begin
            idx_raw_r1   <= idx_raw_comb;
            below_r0_r1  <= below_r0;
            way_above_r1 <= way_above;
            v_r1         <= v_r0;
        end
    end

    // -------------------------------------------------------------- P2 --
    logic [IDX_BITS-1:0] idx_comb, idx_r2;
    logic                v_r2;
    always_comb begin
        if (below_r0_r1)
            idx_comb = '0;
        else if (way_above_r1 || idx_raw_r1[IDX_BITS])
            idx_comb = N-1;
        else
            idx_comb = idx_raw_r1[IDX_BITS-1:0];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2 <= '0;
            v_r2   <= 1'b0;
        end else begin
            idx_r2 <= idx_comb;
            v_r2   <= v_r1;
        end
    end

    // idx_r2 fanout replication: one physical copy per BRAM lane instead
    // of one register driving all four addra ports. Plain registers, no
    // placement pragma - lets the placer site each copy near its own
    // BRAM rather than routing a single 4-fanout net across the die.
    logic [IDX_BITS-1:0] idx_r2_b0, idx_r2_b1, idx_r2_b2, idx_r2_b3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2_b0 <= '0;
            idx_r2_b1 <= '0;
            idx_r2_b2 <= '0;
            idx_r2_b3 <= '0;
        end else begin
            idx_r2_b0 <= idx_comb;
            idx_r2_b1 <= idx_comb;
            idx_r2_b2 <= idx_comb;
            idx_r2_b3 <= idx_comb;
        end
    end

    // -------------------------------------------------------------- P3 --
    // Four independent 9-bit-wide byte-lane ROMs (native RAMB36E1 x9
    // aspect ratio at 4096 depth), all through identical xpm_memory_sprom
    // parameterizations. Only the read width changed vs. the previous
    // revision (8 -> 9); everything else that fixed the b0-b2-vs-b3
    // primitive mismatch is retained unchanged.
    logic [8:0] rom_dout_b0, rom_dout_b1, rom_dout_b2, rom_dout_b3;

    xpm_memory_sprom #(
        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("direct_lut_b0_x9.mem"),   // regenerated, 9-bit words
        .MEMORY_INIT_PARAM   (""),
        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),
        .MEMORY_SIZE         (9*N),
        .MESSAGE_CONTROL     (0),
        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),
        .RST_MODE_A          ("SYNC"),
        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),
        .WAKEUP_TIME         ("disable_sleep")
    ) u_rom_b0 (
        .douta            (rom_dout_b0),
        .clka             (clk),
        .addra            (idx_r2_b0),
        .ena              (1'b1),
        .regcea           (1'b1),
        .rsta             (1'b0),
        .sleep            (1'b0),
        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)
    );

    xpm_memory_sprom #(
        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("direct_lut_b1_x9.mem"),
        .MEMORY_INIT_PARAM   (""),
        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),
        .MEMORY_SIZE         (9*N),
        .MESSAGE_CONTROL     (0),
        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),
        .RST_MODE_A          ("SYNC"),
        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),
        .WAKEUP_TIME         ("disable_sleep")
    ) u_rom_b1 (
        .douta            (rom_dout_b1),
        .clka             (clk),
        .addra            (idx_r2_b1),
        .ena              (1'b1),
        .regcea           (1'b1),
        .rsta             (1'b0),
        .sleep            (1'b0),
        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)
    );

    xpm_memory_sprom #(
        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("direct_lut_b2_x9.mem"),
        .MEMORY_INIT_PARAM   (""),
        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),
        .MEMORY_SIZE         (9*N),
        .MESSAGE_CONTROL     (0),
        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),
        .RST_MODE_A          ("SYNC"),
        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),
        .WAKEUP_TIME         ("disable_sleep")
    ) u_rom_b2 (
        .douta            (rom_dout_b2),
        .clka             (clk),
        .addra            (idx_r2_b2),
        .ena              (1'b1),
        .regcea           (1'b1),
        .rsta             (1'b0),
        .sleep            (1'b0),
        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)
    );

    xpm_memory_sprom #(
        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("direct_lut_b3_x9.mem"),
        .MEMORY_INIT_PARAM   (""),
        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),
        .MEMORY_SIZE         (9*N),
        .MESSAGE_CONTROL     (0),
        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),
        .RST_MODE_A          ("SYNC"),
        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),
        .WAKEUP_TIME         ("disable_sleep")
    ) u_rom_b3 (
        .douta            (rom_dout_b3),
        .clka             (clk),
        .addra            (idx_r2_b3),
        .ena              (1'b1),
        .regcea           (1'b1),
        .rsta             (1'b0),
        .sleep            (1'b0),
        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)
    );

    // Only the lower 8 bits of each 9-bit native lane feed the final
    // Q8.24 result; the 9th bit exists solely to hit the native aspect
    // ratio and is discarded here.
    logic [31:0] rom_dout;
    assign rom_dout = {rom_dout_b3[7:0], rom_dout_b2[7:0], rom_dout_b1[7:0], rom_dout_b0[7:0]};

    // v_r2 -> v_r3 delay matches READ_LATENCY_A = 2 cycles.
    logic v_r3a, v_r3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r3a <= 1'b0;
            v_r3  <= 1'b0;
        end else begin
            v_r3a <= v_r2;
            v_r3  <= v_r3a;
        end
    end

    // -------------------------------------------------------------- P4 --
    logic [31:0] recip_r4;
    logic        v_r4;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_r4 <= '0;
            v_r4     <= 1'b0;
        end else begin
            recip_r4 <= rom_dout;
            v_r4     <= v_r3;
        end
    end

    assign recip_out = recip_r4;
    assign valid_out  = v_r4;

endmodule