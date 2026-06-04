-- ┌──────────────────────────────────────────────────────────────────┐
-- │ gcm                                                              │
-- │                                                                  │
-- │ GCM authenticated encryption / decryption engine.               │
-- │ Implements NIST SP 800-38D Algorithms 4 (AE) and 5 (AD)        │
-- │ using CAST-256 as the underlying block cipher.                  │
-- │                                                                  │
-- │ Project constraints :                                            │
-- │   - IV  : exactly 96 bits                                       │
-- │   - AAD : 0..1 GB, multiples of 128 bits (u = v = 0)           │
-- │   - PT  : 0..1 GB, multiples of 128 bits                       │
-- │   - Tag : 128 bits                                              │
-- │                                                                  │
-- │ Pipeline strategy :                                             │
-- │   In the GCTR loop, CAST-256(CB_i) and the DMA read of P_i are │
-- │   issued in parallel. GHASH(C_{i-1}) runs concurrently with    │
-- │   CAST-256(CB_i). Since GHASH latency (33 cycles) << CAST-256  │
-- │   latency (96 cycles), GHASH always finishes before the next   │
-- │   ciphertext block is ready. Net throughput: 1 block/~96 cyc.  │
-- │                                                                  │
-- │ DMA interface :                                                  │
-- │   Read  : dma_rd_req_o (pulse) + dma_rd_addr_o (byte addr)     │
-- │           → dma_rd_data_i / dma_rd_valid_i (response)          │
-- │   Write : dma_wr_req_o (pulse) + dma_wr_addr_o + dma_wr_data_o │
-- │           → dma_wr_done_i (acknowledgement, not waited on in   │
-- │              the GCTR loop — only in GCTR_LAST for the final   │
-- │              block, to ensure the last write completes before   │
-- │              done_o is asserted)                                 │
-- │                                                                  │
-- │ State sequence (encryption) :                                   │
-- │   Key miss:                                                     │
-- │     IDLE → KS_START → KS_WAIT → H_START → H_WAIT →            │
-- │   Key hit (same key as previous call):                          │
-- │     IDLE →                                                      │
-- │   AAD_CHECK → [AAD_REQ → AAD_WAIT → AAD_HASH] ×n →            │
-- │   GCTR_INIT → PT_CHECK →                                       │
-- │   [GCTR_ENC → GCTR_WAIT] ×(n-1) → GCTR_WAIT → GCTR_LAST →   │
-- │   LEN_HASH (also starts ch1 CAST256(J0)) →                     │
-- │   LEN_WAIT (waits for GHASH + ch1 done) → TAG_OUT → DONE       │
-- │                                                                  │
-- │ Decryption is identical except src/dst addresses are swapped   │
-- │ and GHASH is fed the ciphertext (read data) rather than the    │
-- │ XOR result. The tag is verified in TAG_OUT; auth_fail_o is     │
-- │ asserted if the computed tag does not match tag_i.             │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gcm_pkg.all;

entity gcm is
    port (
        aclk           : in  std_ulogic;
        aresetn        : in  std_ulogic;

        -- ── Control interface (from s0_axi register file) ────────────
        mode_i         : in  std_ulogic;                       -- 0=encrypt 1=decrypt
        key_i          : in  std_ulogic_vector(255 downto 0);
        iv_i           : in  std_ulogic_vector(95 downto 0);
        aad_addr_i     : in  std_ulogic_vector(29 downto 0);   -- byte address
        aad_len_i      : in  std_ulogic_vector(29 downto 0);   -- byte length, multiple of 16
        pt_addr_i      : in  std_ulogic_vector(29 downto 0);   -- plaintext byte address
        pt_len_i       : in  std_ulogic_vector(29 downto 0);   -- plaintext byte length, multiple of 16
        ct_addr_i      : in  std_ulogic_vector(29 downto 0);   -- ciphertext byte address
        tag_i          : in  std_ulogic_vector(127 downto 0);  -- expected tag (decryption)
        start_i        : in  std_ulogic;                       -- single-cycle start pulse

        -- ── Status outputs (to s0_axi CSR / tag register) ────────────
        tag_o          : out std_ulogic_vector(127 downto 0);
        done_o         : out std_ulogic;
        auth_fail_o    : out std_ulogic;

        -- ── DMA read interface ────────────────────────────────────────
        dma_rd_addr_o  : out std_ulogic_vector(29 downto 0);
        dma_rd_req_o   : out std_ulogic;
        dma_rd_data_i  : in  std_ulogic_vector(127 downto 0);
        dma_rd_valid_i : in  std_ulogic;

        -- ── DMA write interface ───────────────────────────────────────
        dma_wr_addr_o  : out std_ulogic_vector(29 downto 0);
        dma_wr_data_o  : out std_ulogic_vector(127 downto 0);
        dma_wr_req_o   : out std_ulogic;
        dma_wr_done_i  : in  std_ulogic
    );
end entity gcm;

architecture rtl of gcm is

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ State machine                                                    │
    -- └─────────────────────────────────────────────────────────────────┘
    type gcm_state_t is (
        GCM_IDLE,
        GCM_KS_START,   -- pulse key_valid to CAST-256
        GCM_KS_WAIT,    -- wait for key schedule done
        GCM_H_START,    -- start CAST256(K, 0^128) to compute H
        GCM_H_WAIT,     -- wait for H; cache H+key; reset GHASH accumulator
        GCM_AAD_CHECK,  -- more AAD blocks?
        GCM_AAD_REQ,    -- issue DMA read for next AAD block
        GCM_AAD_WAIT,   -- wait for DMA read valid; feed to GHASH
        GCM_AAD_HASH,   -- wait for GHASH done; loop or proceed
        GCM_GCTR_INIT,  -- build J0 = IV||0^31||1 and CB_1 = inc32(J0)
        GCM_PT_CHECK,   -- more PT/CT blocks?
        GCM_GCTR_ENC,   -- launch CAST256(CB_i) and DMA read in parallel
        GCM_GCTR_WAIT,  -- wait for enc_done + dma_rd_valid; dispatch results
        GCM_GCTR_LAST,  -- wait for final GHASH done (+ last DMA write done)
        GCM_LEN_HASH,   -- feed len block to GHASH; start ch1 CAST256(J0)
        GCM_LEN_WAIT,   -- wait for GHASH done AND ch1 enc_done; latch S
        GCM_TAG_OUT,    -- T = S XOR ch1_ct; output tag or verify
        GCM_DONE        -- pulse done_o for one cycle
    );
    signal state_r : gcm_state_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Latched parameters (captured from inputs when start_i fires)    │
    -- └─────────────────────────────────────────────────────────────────┘
    signal mode_r    : std_ulogic;
    signal key_r     : std_ulogic_vector(255 downto 0);
    signal iv_r      : std_ulogic_vector(95 downto 0);
    signal aad_len_r : unsigned(29 downto 0);   -- byte length
    signal pt_len_r  : unsigned(29 downto 0);   -- byte length
    signal tag_in_r  : std_ulogic_vector(127 downto 0);

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Address pointers and block counters                             │
    -- └─────────────────────────────────────────────────────────────────┘
    signal aad_ptr_r     : unsigned(29 downto 0);  -- current AAD read byte addr
    signal src_ptr_r     : unsigned(29 downto 0);  -- plaintext (enc) / CT (dec) byte addr
    signal dst_ptr_r     : unsigned(29 downto 0);  -- CT (enc) / plaintext (dec) byte addr
    -- Block counts: len (bytes) / 16 → max (2^30-16)/16 = 2^26-1, 26 bits
    signal aad_blk_rem_r : unsigned(25 downto 0);
    signal pt_blk_rem_r  : unsigned(25 downto 0);

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ GCM intermediate values                                         │
    -- └─────────────────────────────────────────────────────────────────┘
    signal H_r  : std_ulogic_vector(127 downto 0);  -- hash subkey
    signal J0_r : std_ulogic_vector(127 downto 0);  -- pre-counter block
    signal CB_r : std_ulogic_vector(127 downto 0);  -- current GCTR counter block
    signal S_r  : std_ulogic_vector(127 downto 0);  -- GHASH output (= S before tag enc)

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Key / H cache                                                   │
    -- │                                                                 │
    -- │ H = CAST256(K, 0^128) depends only on K. When the same key     │
    -- │ is reused across GCM calls, both the 396-cycle key schedule    │
    -- │ and the 50-cycle H encryption can be skipped entirely.         │
    -- └─────────────────────────────────────────────────────────────────┘
    signal key_cached_r : std_ulogic;
    signal key_reg_r    : std_ulogic_vector(255 downto 0);
    signal H_cached_r   : std_ulogic_vector(127 downto 0);

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ CAST-256 interface wires                                        │
    -- │                                                                 │
    -- │ Channel 0 : GCTR counter-block encryption (CB_i)               │
    -- │ Channel 1 : J0 encryption for tag derivation, runs in          │
    -- │             parallel with the LEN_HASH GHASH round.            │
    -- │                                                                 │
    -- │ bc_done / bc_done_1 are combinatorial: '1' iff the respective  │
    -- │ cast256_enc instance is in ST_DONE and start is not asserted.  │
    -- └─────────────────────────────────────────────────────────────────┘
    signal bc_key_valid : std_ulogic;
    signal bc_key_ready : std_ulogic;
    signal bc_pt        : std_ulogic_vector(127 downto 0);
    signal bc_start     : std_ulogic;
    signal bc_ct        : std_ulogic_vector(127 downto 0);
    signal bc_done      : std_ulogic;
    signal bc_start_1   : std_ulogic;
    signal bc_ct_1      : std_ulogic_vector(127 downto 0);
    signal bc_done_1    : std_ulogic;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ GCTR iteration sticky flags                                     │
    -- │                                                                 │
    -- │ bc_done and dma_rd_valid may arrive in different cycles.        │
    -- │ These flags latch each event so the state machine can wait for  │
    -- │ whichever arrives later, then proceed when both are ready.     │
    -- └─────────────────────────────────────────────────────────────────┘
    signal bc_done_flag : std_ulogic;
    signal pt_got_flag  : std_ulogic;
    signal pt_data_r    : std_ulogic_vector(127 downto 0);  -- latched DMA read data

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ LEN_WAIT sticky flag                                            │
    -- │                                                                 │
    -- │ gh_done is a single-cycle pulse; bc_done_1 is a level signal.  │
    -- │ len_gh_done_r latches the GHASH pulse so the state machine can  │
    -- │ exit LEN_WAIT when the channel-1 cipher finishes later.        │
    -- └─────────────────────────────────────────────────────────────────┘
    signal len_gh_done_r : std_ulogic;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ GHASH interface wires                                           │
    -- └─────────────────────────────────────────────────────────────────┘
    signal gh_blk   : std_ulogic_vector(127 downto 0);
    signal gh_valid : std_ulogic;
    signal gh_clear : std_ulogic;
    signal gh_Y     : std_ulogic_vector(127 downto 0);
    signal gh_done  : std_ulogic;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Length block (combinatorial)                                    │
    -- │ [len(A)]_64 || [len(C)]_64  (bit lengths, 64 bits each)        │
    -- └─────────────────────────────────────────────────────────────────┘
    signal len_block : std_ulogic_vector(127 downto 0);

begin

    -- ── len_block: byte lengths converted to bit lengths ─────────────
    -- max bit-length = (2^30 - 16) × 8 = 2^33 - 128 < 2^64, fits in 64 bits
    len_block <= std_ulogic_vector(resize(aad_len_r, 64) sll 3) &
                 std_ulogic_vector(resize(pt_len_r,  64) sll 3);

    -- ── CAST-256 instance ─────────────────────────────────────────────
    u_cast : entity work.cast256
        port map (
            aclk            => aclk,
            aresetn         => aresetn,
            key             => key_r,
            key_valid       => bc_key_valid,
            key_ready       => bc_key_ready,
            -- ── channel 0: GCTR counter-block encryption ─────────────
            plaintext_0     => bc_pt,
            encrypt_start_0 => bc_start,
            ciphertext_0    => bc_ct,
            enc_done_0      => bc_done,
            -- ── channel 1: J0 encryption for tag (parallel with GHASH)
            plaintext_1     => J0_r,
            encrypt_start_1 => bc_start_1,
            ciphertext_1    => bc_ct_1,
            enc_done_1      => bc_done_1
        );

    -- ── GHASH instance ────────────────────────────────────────────────
    u_ghash : entity work.ghash
        port map (
            aclk    => aclk,
            aresetn => aresetn,
            H       => H_r,
            blk_i   => gh_blk,
            valid_i => gh_valid,
            clear_i => gh_clear,
            Y_o     => gh_Y,
            done_o  => gh_done
        );

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ gcm_fsm                                                         ║
    -- ║                                                                 ║
    -- ║ All single-cycle control pulses are deasserted at the top of   ║
    -- ║ each clock to prevent unintended retriggering.                  ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    gcm_fsm : process (aclk) is
        variable dma_v : std_ulogic_vector(127 downto 0);  -- DMA read data mux
        variable xor_v : std_ulogic_vector(127 downto 0);  -- P XOR CAST256(CB)
        variable T_v   : std_ulogic_vector(127 downto 0);  -- computed tag
    begin
        if rising_edge(aclk) then
            -- Default: deassert all single-cycle pulses
            bc_key_valid <= '0';
            bc_start     <= '0';
            bc_start_1   <= '0';
            gh_valid     <= '0';
            gh_clear     <= '0';
            dma_rd_req_o <= '0';
            dma_wr_req_o <= '0';
            done_o       <= '0';

            if aresetn = '0' then
                state_r       <= GCM_IDLE;
                auth_fail_o   <= '0';
                tag_o         <= (others => '0');
                bc_done_flag  <= '0';
                pt_got_flag   <= '0';
                len_gh_done_r <= '0';
                key_cached_r  <= '0';
                bc_pt         <= (others => '0');
                gh_blk        <= (others => '0');
            else
                case state_r is

                    -- ── IDLE ──────────────────────────────────────────────
                    when GCM_IDLE =>
                        auth_fail_o <= '0';
                        if start_i = '1' then
                            -- Latch all input parameters
                            mode_r    <= mode_i;
                            key_r     <= key_i;
                            iv_r      <= iv_i;
                            aad_len_r <= unsigned(aad_len_i);
                            pt_len_r  <= unsigned(pt_len_i);
                            tag_in_r  <= tag_i;
                            -- Derive block counts from byte lengths (÷16 = >>4)
                            aad_blk_rem_r <= unsigned(aad_len_i(29 downto 4));
                            pt_blk_rem_r  <= unsigned(pt_len_i(29 downto 4));
                            -- Initialise address pointers
                            aad_ptr_r <= unsigned(aad_addr_i);
                            if mode_i = '0' then  -- encrypt
                                src_ptr_r <= unsigned(pt_addr_i);
                                dst_ptr_r <= unsigned(ct_addr_i);
                            else                  -- decrypt
                                src_ptr_r <= unsigned(ct_addr_i);
                                dst_ptr_r <= unsigned(pt_addr_i);
                            end if;
                            report "[TIMING] START      " & integer'image(now / 1 ns) & " ns";
                            -- ── Key / H cache check ───────────────────────────
                            -- H = CAST256(K, 0^128) depends only on the key.
                            -- Skip the 396-cycle KS and 50-cycle H encryption
                            -- when the same key is reused across calls.
                            if key_cached_r = '1' and key_i = key_reg_r then
                                report "[TIMING] CACHE HIT  " & integer'image(now / 1 ns) & " ns";
                                H_r      <= H_cached_r;
                                gh_clear <= '1';
                                state_r  <= GCM_AAD_CHECK;
                            else
                                state_r  <= GCM_KS_START;
                            end if;
                        end if;

                    -- ── KS_START ──────────────────────────────────────────
                    -- Trigger CAST-256 key schedule. Runs ~396 cycles.
                    when GCM_KS_START =>
                        bc_key_valid <= '1';
                        state_r      <= GCM_KS_WAIT;

                    -- ── KS_WAIT ───────────────────────────────────────────
                    when GCM_KS_WAIT =>
                        if bc_key_ready = '1' then
                            state_r <= GCM_H_START;
                        end if;

                    -- ── H_START ───────────────────────────────────────────
                    -- Encrypt the zero block: H = CAST256(K, 0^128).
                    when GCM_H_START =>
                        report "[TIMING] H_START    " & integer'image(now / 1 ns) & " ns";
                        bc_pt    <= (others => '0');
                        bc_start <= '1';
                        state_r  <= GCM_H_WAIT;

                    -- ── H_WAIT ────────────────────────────────────────────
                    -- Latch H, populate the key/H cache, and reset the GHASH
                    -- accumulator. Cache is valid for all subsequent calls
                    -- with the same key.
                    when GCM_H_WAIT =>
                        if bc_done = '1' then
                            H_r          <= bc_ct;
                            H_cached_r   <= bc_ct;
                            key_reg_r    <= key_r;
                            key_cached_r <= '1';
                            gh_clear     <= '1';
                            state_r      <= GCM_AAD_CHECK;
                        end if;

                    -- ── AAD_CHECK ─────────────────────────────────────────
                    when GCM_AAD_CHECK =>
                        if aad_blk_rem_r = 0 then
                            state_r <= GCM_GCTR_INIT;
                        else
                            state_r <= GCM_AAD_REQ;
                        end if;

                    -- ── AAD_REQ ───────────────────────────────────────────
                    -- Issue a DMA read for the current AAD block.
                    when GCM_AAD_REQ =>
                        dma_rd_addr_o <= std_ulogic_vector(aad_ptr_r);
                        dma_rd_req_o  <= '1';
                        aad_ptr_r     <= aad_ptr_r + 16;
                        aad_blk_rem_r <= aad_blk_rem_r - 1;
                        state_r       <= GCM_AAD_WAIT;

                    -- ── AAD_WAIT ──────────────────────────────────────────
                    -- Wait for DMA data, then immediately feed to GHASH.
                    when GCM_AAD_WAIT =>
                        if dma_rd_valid_i = '1' then
                            gh_blk  <= dma_rd_data_i;
                            gh_valid <= '1';
                            state_r <= GCM_AAD_HASH;
                        end if;

                    -- ── AAD_HASH ──────────────────────────────────────────
                    -- Wait for GHASH to finish, then loop or proceed.
                    when GCM_AAD_HASH =>
                        if gh_done = '1' then
                            if aad_blk_rem_r = 0 then
                                state_r <= GCM_GCTR_INIT;
                            else
                                state_r <= GCM_AAD_REQ;
                            end if;
                        end if;

                    -- ── GCTR_INIT ─────────────────────────────────────────
                    -- Build J0 = IV || 0^31 || 1  (NIST §7.1 Step 2, 96-bit IV)
                    -- CB_1 = inc32(J0) = IV || 0^30 || 10  (rightmost 32 bits = 2)
                    when GCM_GCTR_INIT =>
                        report "[TIMING] GCTR_INIT  " & integer'image(now / 1 ns) & " ns";
                        J0_r    <= iv_r & x"00000001";
                        CB_r    <= iv_r & x"00000002";
                        state_r <= GCM_PT_CHECK;

                    -- ── PT_CHECK ──────────────────────────────────────────
                    when GCM_PT_CHECK =>
                        if pt_blk_rem_r = 0 then
                            state_r <= GCM_LEN_HASH;
                        else
                            state_r <= GCM_GCTR_ENC;
                        end if;

                    -- ── GCTR_ENC ──────────────────────────────────────────
                    -- Launch CAST256(K, CB_i) and the DMA read of the source
                    -- block in parallel. Both take multiple cycles; whichever
                    -- arrives last unblocks GCTR_WAIT.
                    when GCM_GCTR_ENC =>
                        bc_pt         <= CB_r;
                        bc_start      <= '1';
                        dma_rd_addr_o <= std_ulogic_vector(src_ptr_r);
                        dma_rd_req_o  <= '1';
                        src_ptr_r     <= src_ptr_r + 16;
                        bc_done_flag  <= '0';
                        pt_got_flag   <= '0';
                        state_r       <= GCM_GCTR_WAIT;

                    -- ── GCTR_WAIT ─────────────────────────────────────────
                    -- Wait for both enc_done and dma_rd_valid (sticky flags).
                    -- bc_done (cast256_enc) is combinatorial in ST_DONE and
                    -- drops to '0' on the same cycle bc_start is asserted,
                    -- so there is no stale '1' risk on the first cycle here.
                    when GCM_GCTR_WAIT =>
                        -- Latch enc result (flag stays set; bc_ct persists)
                        if bc_done = '1' then
                            bc_done_flag <= '1';
                        end if;
                        -- Latch DMA read data on arrival
                        if dma_rd_valid_i = '1' then
                            pt_got_flag <= '1';
                            pt_data_r   <= dma_rd_data_i;
                        end if;

                        -- Proceed once both results are available
                        if (bc_done_flag = '1' or bc_done = '1') and
                           (pt_got_flag  = '1' or dma_rd_valid_i = '1') then

                            -- Select freshest DMA data (same-cycle arrival takes priority)
                            if dma_rd_valid_i = '1' then
                                dma_v := dma_rd_data_i;
                            else
                                dma_v := pt_data_r;
                            end if;
                            -- bc_ct is always valid here (persists after enc_done)
                            xor_v := dma_v xor bc_ct;

                            -- GHASH always receives the ciphertext:
                            --   encrypt → xor_v is the ciphertext
                            --   decrypt → dma_v is the ciphertext (what we read)
                            if mode_r = '0' then
                                gh_blk <= xor_v;
                            else
                                gh_blk <= dma_v;
                            end if;
                            gh_valid <= '1';

                            -- DMA write: output block (CT for enc, PT for dec)
                            dma_wr_addr_o <= std_ulogic_vector(dst_ptr_r);
                            dma_wr_data_o <= xor_v;
                            dma_wr_req_o  <= '1';
                            dst_ptr_r     <= dst_ptr_r + 16;

                            -- Advance counter block and decrement remaining count
                            CB_r         <= inc32(CB_r);
                            pt_blk_rem_r <= pt_blk_rem_r - 1;

                            -- Reset flags for the next iteration
                            bc_done_flag <= '0';
                            pt_got_flag  <= '0';

                            if pt_blk_rem_r = 1 then
                                -- Last block: wait for GHASH to finish before
                                -- the length block, and for the DMA write to
                                -- complete before asserting done_o.
                                state_r <= GCM_GCTR_LAST;
                            else
                                -- Pipeline: start the next block immediately.
                                -- GHASH (17 cyc) will finish long before the
                                -- next enc_done (50 cyc), so no conflict.
                                state_r <= GCM_GCTR_ENC;
                            end if;
                        end if;

                    -- ── GCTR_LAST ─────────────────────────────────────────
                    -- Wait for GHASH to finish the last CT block, and ensure
                    -- the last DMA write has been acknowledged.
                    when GCM_GCTR_LAST =>
                        if gh_done = '1' and dma_wr_done_i = '1' then
                            state_r <= GCM_LEN_HASH;
                        end if;

                    -- ── LEN_HASH ──────────────────────────────────────────
                    -- Feed [len(A)]_64 || [len(C)]_64 to GHASH to close S,
                    -- and simultaneously start CAST256(J0) on channel 1.
                    -- Both take multiple cycles; LEN_WAIT waits for both.
                    when GCM_LEN_HASH =>
                        report "[TIMING] LEN_HASH   " & integer'image(now / 1 ns) & " ns";
                        gh_blk        <= len_block;
                        gh_valid      <= '1';
                        bc_start_1    <= '1';          -- CAST256(K, J0) on channel 1
                        len_gh_done_r <= '0';          -- clear before entering LEN_WAIT
                        state_r       <= GCM_LEN_WAIT;

                    -- ── LEN_WAIT ──────────────────────────────────────────
                    -- Wait for both:
                    --   (a) GHASH done (single-cycle pulse) → latch S = gh_Y
                    --   (b) channel-1 enc_done (level) → CAST256(K, J0) ready
                    -- GHASH takes 33 cycles; the cipher takes 96 cycles.
                    -- Typically GHASH fires first; len_gh_done_r holds the
                    -- event until bc_done_1 arrives ~63 cycles later.
                    when GCM_LEN_WAIT =>
                        if gh_done = '1' then
                            len_gh_done_r <= '1';
                            S_r           <= gh_Y;
                        end if;
                        if (len_gh_done_r = '1' or gh_done = '1') and bc_done_1 = '1' then
                            state_r <= GCM_TAG_OUT;
                        end if;

                    -- ── TAG_OUT ───────────────────────────────────────────
                    -- bc_ct_1 holds CAST256(K, J0) from channel 1 (level,
                    -- persists in ST_DONE). S_r was latched when GHASH fired.
                    when GCM_TAG_OUT =>
                        T_v   := S_r xor bc_ct_1;
                        tag_o <= T_v;
                        if mode_r = '0' then
                            -- Encryption: output T; no authentication failure
                            auth_fail_o <= '0';
                        else
                            -- Decryption: verify T against received tag
                            if T_v = tag_in_r then
                                auth_fail_o <= '0';
                            else
                                auth_fail_o <= '1';
                            end if;
                        end if;
                        state_r <= GCM_DONE;

                    -- ── DONE ──────────────────────────────────────────────
                    when GCM_DONE =>
                        report "[TIMING] DONE       " & integer'image(now / 1 ns) & " ns";
                        done_o  <= '1';
                        state_r <= GCM_IDLE;

                end case;
            end if;
        end if;
    end process gcm_fsm;

end architecture rtl;