// ============================================================================
// reciprocal_hybrid9_1nr_q16_16.sv
//
// Q16.16 port of reciprocal_hybrid9_1nr_q8_24 REV 8. Architecture (9-bit
// LUT + linear interp seed, one NR iteration) and pipeline depths are
// UNCHANGED. Only the fixed-point interpretation changes.
//
// Derivation used for the port (QFRAC = number of fractional bits of the
// I/O format; was 24, is now 16):
//
//  - X_LO/X_HI, the offset register width, SHIFT and FRAC_BITS (the
//    LUT-segment index/remainder split) all scale with QFRAC:
//        SHIFT = FRAC_BITS = log2((X_HI-X_LO)*2^QFRAC / N)
//    which for N=512 (IDX_BITS=9), X_LO=0.5, X_HI=2.5, QFRAC=16 gives
//    SHIFT = FRAC_BITS = 8 (down from 16 at QFRAC=24). idx(9b)+frac(8b)
//    still exactly reconstructs the 17-bit offset needed for QFRAC=16, so
//    x is represented to full format precision with no bits lost -- only
//    the interpolation model's own (unchanged) linear-approximation error
//    remains, since the segment width in real x-units (2.0/512) is
//    unchanged by this port.
//
//  - SLOPE_FRAC_BITS (=21) and SLOPE_BITS (=25) are UNCHANGED and the
//    slope ROM contents are numerically IDENTICAL to the Q8.24 design.
//    Proof: with frac_raw the low FRAC_BITS bits of the offset (so
//    frac_raw/2^QFRAC is the true residual x-offset within the segment)
//    and slope_raw = slope_actual * 2^SLOPE_FRAC_BITS (slope_actual is
//    the real-valued d(1/x)/dx, a property of the function alone, not of
//    QFRAC), the delta needed in the output's own QFRAC format is
//        delta_y_raw = slope_actual * (frac_raw/2^QFRAC) * 2^QFRAC
//                    = slope_raw * frac_raw >> SLOPE_FRAC_BITS
//    which has no QFRAC term in it at all. The P9-P14 seed-assembly adder
//    (reciprocal_interp9) is likewise QFRAC-agnostic (it just adds two
//    sign-extended 32-bit Q-format numbers) and is bit-for-bit unchanged
//    below.
//
//  - Everything downstream of a raw 64-bit multiply product must have its
//    round/extract bit positions shifted down by (24-16)=8 to track the
//    new QFRAC=16 binary point: rounding bit moves from bit 23 to bit 15,
//    and every extraction window/chunk boundary in nr_iterate_q16_16
//    shifts down by 8 accordingly. Chunk widths, carry-select structure,
//    and the overflow-guard bit count are unchanged.
//
//  - TWO_Q8_24 (=2.0 at Q8.24) becomes TWO_Q16_16 (=2.0 at Q16.16).
//
//  - mult32x32_pipe_* is a generic signed 32x32->64 multiply pipeline; it
//    has no format-specific content and is carried over unchanged apart
//    from its name.
//
//  - The top-level event-counted startup guard (pipeline_primed /
//    DISCARD_TOKENS) is format-agnostic and is carried over unchanged.
//
// Steady-state top-level latency is unchanged at 40 cycles (16 seed + 24
// NR: 10+2+10+2), since no pipeline stages were added or removed -- only
// bit positions within existing registers changed.
// ============================================================================


// ============================================================================
// (1) reciprocal_interp9_q16_16
//
// 9-bit LUT + linear interpolation reciprocal seed for x in [0.5, 2.5),
// Q16.16.
// ============================================================================

module reciprocal_interp9_q16_16 #(
    parameter int IDX_BITS        = 9,
    parameter int SHIFT           = 8,
    parameter int FRAC_BITS       = 8,
    parameter int SLOPE_FRAC_BITS = 21
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,
    output logic        valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO = 32'h0000_8000;   // 0.5  in Q16.16
    localparam logic [31:0] X_HI = 32'h0002_8000;   // 2.5  in Q16.16
    localparam int N = (1 << IDX_BITS);

    // -------------------------------------------------------------- P0 --
    logic [31:0] x_r0;
    logic        v_r0;
    logic        above_r0;
    logic        above_comb_p0;

    always_comb begin
        if (x_in[31])
            above_comb_p0 = 1'b1;
        else if (x_in[30:16] > 15'd2)
            above_comb_p0 = 1'b1;
        else if (x_in[30:16] < 15'd2)
            above_comb_p0 = 1'b0;
        else
            above_comb_p0 = (x_in[15:0] > 16'h8000);
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
    logic [17:0] offset_comb;

    always_comb begin
        below_r0    = (x_r0 < X_LO);
        offset_comb = below_r0 ? 18'd0 : (x_r0 - X_LO);
    end

    logic [17:0] offset_r1;
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
        .MEMORY_INIT_FILE   ("interp9_seed_q16_16.mem"),
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
        .MEMORY_INIT_FILE   ("interp9_slope_q16_16.mem"),
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
    assign dsp_b_in = {{(18-FRAC_BITS){1'b0}}, frac_r4};

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
    // (Bit-for-bit unchanged below: seed_ext/prod_ext are already-Q-format
    // 32-bit sign-extended values combined by a plain 32-bit signed adder
    // with saturation; SLOPE_FRAC_BITS=21 is QFRAC-agnostic, see header.)
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
// (2) mult32x32_pipe_q16_16
//
// Pipelined signed 32x32 -> 64 multiply, schoolbook 4-way 16-bit split.
// Purely a generic integer multiply pipeline -- no format-specific
// content, carried over unchanged apart from its name. Latency: 10 cycles.
// ============================================================================

module mult32x32_pipe_q16_16 (
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
// (3) nr_iterate_q16_16
//
// One Newton-Raphson iteration: y1 = y0 * (2 - x*y0), Q16.16 in/out.
// Two sequential 32x32 multiplies via mult32x32_pipe_q16_16.
//
// All round/extract bit windows below are the Q8.24 windows shifted down
// by (24-16)=8 bits to track QFRAC=16's binary point; chunk widths,
// carry-select structure and the 8-bit overflow guard are unchanged from
// the Q8.24 design (see file header for the general derivation).
// ============================================================================

module nr_iterate_q16_16 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,     // Q16.16, aligned with y0_in
    input  logic [31:0] y0_in,    // Q16.16 seed
    output logic        valid_out,
    output logic [31:0] y1_out    // Q16.16 refined reciprocal
);

    localparam logic signed [31:0] TWO_Q16_16 = 32'h0002_0000;

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

    mult32x32_pipe_q16_16 mult_x_y0 (
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
    // (t_full + 2^15) >>> 16, truncated to 32 bits, i.e. T_IN = t_full[47:16]
    // (32b), T_CIN = t_full[15] (1b), result = T_IN + T_CIN -- a 32-bit
    // conditional increment, chunked into 4x8-bit carry-select chunks.
    // Window is the Q8.24 window ([55:24]/[23]) shifted down by 8.
    (* keep = "true" *) logic [7:0] tchunk0, tchunk1, tchunk2, tchunk3;
    (* keep = "true" *) logic [7:0] tc0_inc, tc1_inc, tc2_inc, tc3_inc;
    (* keep = "true" *) logic       tcin0, tcarry0, tcarry1, tcarry2, tcarry3;
    (* keep = "true" *) logic [7:0] tres0, tres1, tres2, tres3;

    always_comb begin
        tchunk0 = t_full[23:16];
        tchunk1 = t_full[31:24];
        tchunk2 = t_full[39:32];
        tchunk3 = t_full[47:40];
        tcin0   = t_full[15];

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

    logic signed [31:0] e_r6;   // e = 2.0 - t   (Q16.16)
    logic                v_r6;
    logic signed [31:0] y0_r6;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_r6 <= '0; v_r6 <= 1'b0; y0_r6 <= '0;
        end else begin
            e_r6  <= TWO_Q16_16 - t_raw_r5;
            v_r6  <= v_r5;
            y0_r6 <= y0_r5;
        end
    end

    // ---- multiply #2: y1_full = y0 * e ----------------------------------
    logic        v_m2;
    logic signed [63:0] y1_full;

    mult32x32_pipe_q16_16 mult_y0_e (
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
    // (y1_full + 2^15) >>> 16 as a 40-bit conditional increment, split
    // into 4x10-bit carry-select chunks. Window is the Q8.24 window
    // ([63:24]/[23]) shifted down by 8.
    (* keep = "true" *) logic [9:0] c0, c1, c2, c3;
    (* keep = "true" *) logic [9:0] c0_inc, c1_inc, c2_inc, c3_inc;
    (* keep = "true" *) logic       cin0;
    (* keep = "true" *) logic       g0, g1, g2;
    (* keep = "true" *) logic       carry1, carry2, carry3;
    (* keep = "true" *) logic [9:0] res0, res1, res2, res3;

    always_comb begin
        c0   = y1_full[25:16];
        c1   = y1_full[35:26];
        c2   = y1_full[45:36];
        c3   = y1_full[55:46];
        cin0 = y1_full[15];

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
// (4) reciprocal_hybrid9_1nr_q16_16
//
// Top level: 9-bit LUT+interp seed -> 1 NR iteration, Q16.16.
//
// Steady-state top-level latency (once primed) is still 16 (seed) + 24
// (nr_iterate_q16_16: 10+2+10+2) = 40 cycles -- identical to the Q8.24
// design, since no pipeline stages were added or removed by this port.
// The event-counted startup guard (pipeline_primed / DISCARD_TOKENS) is
// format-agnostic and is carried over unchanged from REV 8.
// ============================================================================

module reciprocal_hybrid9_1nr_q16_16 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,
    output logic        valid_out,
    output logic [31:0] recip_out
);

    logic        v_seed;
    logic [31:0] y0;

    reciprocal_interp9_q16_16 seed_gen (
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

    nr_iterate_q16_16 nr_stage (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (v_seed),
        .x_in       (x_delay[SEED_LATENCY-1]),
        .y0_in      (y0),
        .valid_out  (v_nr),
        .y1_out     (y1_nr)
    );

    // ------------------------------------------------------------------
    // Event-counted startup guard, carried over unchanged from REV 8
    // (Q8.24 design). Counts actual nr_stage.valid_out (v_nr) PULSES
    // rather than clock cycles since reset, so it is correct regardless
    // of when valid_in first asserts relative to rst_n release. This has
    // no format-specific content and is unaffected by the Q16.16 port.
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
            if (discard_cnt == DISCARD_TOKENS[DCNT_W-1:0])
                pipeline_primed <= 1'b1;
            else
                discard_cnt <= discard_cnt + 1'b1;
        end
    end

    assign valid_out = v_nr & pipeline_primed;
    assign recip_out = y1_nr;

endmodule