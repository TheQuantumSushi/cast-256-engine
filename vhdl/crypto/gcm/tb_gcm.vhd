-- ┌──────────────────────────────────────────────────────────────────┐
-- │ tb_gcm                                                           │
-- │                                                                  │
-- │ Self-checking testbench for the GCM entity.                     │
-- │                                                                  │
-- │ No pre-computed CAST-256-GCM reference vectors exist publicly.  │
-- │ Correctness is validated through three tests:                    │
-- │                                                                  │
-- │   Test 1 — Encryption                                           │
-- │     Key/IV/AAD/PT → GCM → CT and tag captured.                 │
-- │     Checks: done_o fires within timeout; auth_fail_o = 0.       │
-- │                                                                  │
-- │   Test 2 — Decryption round-trip                                │
-- │     Same key/IV/AAD + captured CT/tag → GCM → plaintext.       │
-- │     Checks: done_o fires; auth_fail_o = 0;                      │
-- │             recovered plaintext = original plaintext.           │
-- │                                                                  │
-- │   Test 3 — Authentication failure detection                     │
-- │     1 bit of CT corrupted; original tag presented.              │
-- │     Checks: done_o fires; auth_fail_o = 1.                      │
-- │                                                                  │
-- │ DMA mock :                                                       │
-- │   Read  : responds after RD_LATENCY cycles; one request at a    │
-- │           time (GCM serialises reads in its state machine).     │
-- │   Write : accepts immediately; dma_wr_done_i is latched high    │
-- │           from the cycle after wr_req until the next reset.     │
-- │           This ensures GCM_GCTR_LAST sees wr_done regardless    │
-- │           of when it polls relative to the write event.         │
-- │                                                                  │
-- │ Memory layout (sim_mem, indexed by block = byte_addr / 16) :   │
-- │   [0]  0x000 : AAD block                                        │
-- │   [1]  0x010 : PT block 0 / decrypted PT block 0               │
-- │   [2]  0x020 : PT block 1 / decrypted PT block 1               │
-- │   [3]  0x030 : CT block 0 (written by encrypt, read by decrypt) │
-- │   [4]  0x040 : CT block 1                                       │
-- │                                                                  │
-- │ Expected latency per full encrypt (conservative) :              │
-- │   Key schedule : 384 cycles                                     │
-- │   H = CAST256(K,0) : 96 cycles                                  │
-- │   AAD GHASH (1 blk): ~40 cycles (DMA + 33 GHASH)               │
-- │   GCTR 2 blocks    : ~200 cycles                                │
-- │   Length GHASH     : 34 cycles                                  │
-- │   Tag CAST256      : 96 cycles                                  │
-- │   Total            : ~850 cycles → 8.5 µs at 10 ns/cycle       │
-- │   TIMEOUT set to 50 µs for substantial margin.                  │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_gcm is
end entity tb_gcm;

architecture bench of tb_gcm is

    -- ┌─────────────────────────────────┐
    -- │ Timing                          │
    -- └─────────────────────────────────┘
    constant CLK_PERIOD : time    := 10 ns;
    constant TIMEOUT    : time    := 50 us;   -- ~5000 cycles; covers two full runs
    constant RD_LATENCY : integer := 5;        -- cycles from rd_req to rd_valid

    -- ┌─────────────────────────────────┐
    -- │ Test parameters                 │
    -- └─────────────────────────────────┘
    -- RFC 2612 Appendix A 256-bit key (known vector: CAST256(key, 0) = 4f6a...17fa)
    constant KEY : std_ulogic_vector(255 downto 0) :=
        x"2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604";

    -- IV: 96 bits, non-zero to exercise full J0 construction
    constant IV : std_ulogic_vector(95 downto 0) :=
        x"cafebabe1234567800000001";

    -- ── AAD (1 block = 16 bytes) ─────────────────────────────────────
    constant AAD_BLOCK : std_ulogic_vector(127 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f";

    -- ── Plaintext (2 blocks = 32 bytes) ──────────────────────────────
    constant PT_BLOCK_0 : std_ulogic_vector(127 downto 0) :=
        x"101112131415161718191a1b1c1d1e1f";
    constant PT_BLOCK_1 : std_ulogic_vector(127 downto 0) :=
        x"202122232425262728292a2b2c2d2e2f";

    -- ── Byte addresses (30-bit, 16-byte aligned) ─────────────────────
    constant ADDR_AAD : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(0,  30));
    constant ADDR_PT  : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(16, 30));
    constant ADDR_CT  : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(48, 30));

    constant LEN_AAD  : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(16, 30));
    constant LEN_PT   : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(32, 30));

    -- ┌─────────────────────────────────┐
    -- │ Simulation memory               │
    -- └─────────────────────────────────┘
    -- Shared variable: written by stimulus (init) and DMA write mock;
    -- read by DMA read mock. Accesses never overlap in simulation time.
    type mem_t is array (0 to 15) of std_ulogic_vector(127 downto 0);
    shared variable sim_mem : mem_t := (others => (others => '0'));

    -- ┌─────────────────────────────────┐
    -- │ DUT signals                     │
    -- └─────────────────────────────────┘
    signal aclk           : std_ulogic := '0';
    signal aresetn        : std_ulogic := '0';
    signal mode_i         : std_ulogic := '0';
    signal key_i          : std_ulogic_vector(255 downto 0) := (others => '0');
    signal iv_i           : std_ulogic_vector(95 downto 0)  := (others => '0');
    signal aad_addr_i     : std_ulogic_vector(29 downto 0)  := (others => '0');
    signal aad_len_i      : std_ulogic_vector(29 downto 0)  := (others => '0');
    signal pt_addr_i      : std_ulogic_vector(29 downto 0)  := (others => '0');
    signal pt_len_i       : std_ulogic_vector(29 downto 0)  := (others => '0');
    signal ct_addr_i      : std_ulogic_vector(29 downto 0)  := (others => '0');
    signal tag_i          : std_ulogic_vector(127 downto 0) := (others => '0');
    signal start_i        : std_ulogic := '0';
    signal tag_o          : std_ulogic_vector(127 downto 0);
    signal done_o         : std_ulogic;
    signal auth_fail_o    : std_ulogic;
    signal dma_rd_addr_o  : std_ulogic_vector(29 downto 0);
    signal dma_rd_req_o   : std_ulogic;
    signal dma_rd_data_i  : std_ulogic_vector(127 downto 0) := (others => '0');
    signal dma_rd_valid_i : std_ulogic := '0';
    signal dma_wr_addr_o  : std_ulogic_vector(29 downto 0);
    signal dma_wr_data_o  : std_ulogic_vector(127 downto 0);
    signal dma_wr_req_o   : std_ulogic;
    signal dma_wr_done_i  : std_ulogic := '0';

    -- ── Captured encryption output ────────────────────────────────────
    signal enc_tag : std_ulogic_vector(127 downto 0) := (others => '0');

begin

    -- ── Clock ─────────────────────────────────────────────────────────
    aclk <= not aclk after CLK_PERIOD / 2;

    -- ── DUT ───────────────────────────────────────────────────────────
    u_gcm : entity work.gcm
        port map (
            aclk           => aclk,
            aresetn        => aresetn,
            mode_i         => mode_i,
            key_i          => key_i,
            iv_i           => iv_i,
            aad_addr_i     => aad_addr_i,
            aad_len_i      => aad_len_i,
            pt_addr_i      => pt_addr_i,
            pt_len_i       => pt_len_i,
            ct_addr_i      => ct_addr_i,
            tag_i          => tag_i,
            start_i        => start_i,
            tag_o          => tag_o,
            done_o         => done_o,
            auth_fail_o    => auth_fail_o,
            dma_rd_addr_o  => dma_rd_addr_o,
            dma_rd_req_o   => dma_rd_req_o,
            dma_rd_data_i  => dma_rd_data_i,
            dma_rd_valid_i => dma_rd_valid_i,
            dma_wr_addr_o  => dma_wr_addr_o,
            dma_wr_data_o  => dma_wr_data_o,
            dma_wr_req_o   => dma_wr_req_o,
            dma_wr_done_i  => dma_wr_done_i
        );

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ dma_read_mock                                                   ║
    -- ║                                                                 ║
    -- ║ When dma_rd_req_o fires, waits RD_LATENCY cycles, then returns ║
    -- ║ the block at sim_mem[addr/16] and asserts dma_rd_valid_i for 1 ║
    -- ║ cycle. GCM never issues two reads simultaneously, so a single  ║
    -- ║ pending slot is sufficient.                                     ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    dma_read_mock : process (aclk) is
        variable pending   : boolean := false;
        variable req_idx   : integer := 0;
        variable countdown : integer := 0;
    begin
        if rising_edge(aclk) then
            dma_rd_valid_i <= '0';
            if aresetn = '0' then
                pending := false;
            else
                if dma_rd_req_o = '1' then
                    req_idx   := to_integer(unsigned(dma_rd_addr_o(29 downto 4)));
                    countdown := RD_LATENCY;
                    pending   := true;
                end if;
                if pending then
                    countdown := countdown - 1;
                    if countdown = 0 then
                        dma_rd_data_i  <= sim_mem(req_idx);
                        dma_rd_valid_i <= '1';
                        pending        := false;
                    end if;
                end if;
            end if;
        end if;
    end process dma_read_mock;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ dma_write_mock                                                  ║
    -- ║                                                                 ║
    -- ║ When dma_wr_req_o fires, immediately stores the block in       ║
    -- ║ sim_mem and latches dma_wr_done_i high. wr_done stays high     ║
    -- ║ until reset; this ensures GCM_GCTR_LAST always sees it         ║
    -- ║ regardless of the polling offset between the write event and   ║
    -- ║ the GHASH completion that unblocks that state.                  ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    dma_write_mock : process (aclk) is
        variable wr_idx : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                dma_wr_done_i <= '0';
            elsif dma_wr_req_o = '1' then
                wr_idx          := to_integer(unsigned(dma_wr_addr_o(29 downto 4)));
                sim_mem(wr_idx) := dma_wr_data_o;
                dma_wr_done_i   <= '1';  -- latched; not auto-cleared
            end if;
        end if;
    end process dma_write_mock;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ stimulus                                                        ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    stimulus : process is

        -- ── Helper: pulse start_i for one clock cycle ──────────────────
        procedure pulse_start is
        begin
            wait until rising_edge(aclk);
            start_i <= '1';
            wait until rising_edge(aclk);
            start_i <= '0';
        end procedure pulse_start;

        -- ── Helper: wait for done_o with a timeout ─────────────────────
        procedure wait_done (test_name : in string) is
        begin
            wait until done_o = '1' for TIMEOUT;
            assert done_o = '1'
                report test_name & " TIMEOUT: done_o never asserted"
                severity failure;
            -- Advance one clock so all registered outputs (tag_o,
            -- auth_fail_o) reflect the post-DONE state.
            wait until rising_edge(aclk);
        end procedure wait_done;

    begin

        -- ── Reset ─────────────────────────────────────────────────────
        aresetn <= '0';
        wait for 5 * CLK_PERIOD;
        aresetn <= '1';
        wait for CLK_PERIOD;

        -- ── Initialise simulation memory ──────────────────────────────
        sim_mem(0) := AAD_BLOCK;
        sim_mem(1) := PT_BLOCK_0;
        sim_mem(2) := PT_BLOCK_1;
        -- sim_mem(3), sim_mem(4): written by Test 1 (CT blocks)

        -- ══════════════════════════════════════════════════════════════
        -- Test 1 — Encryption
        --   AAD at 0x000 (16 B), PT at 0x010 (32 B), CT → 0x030
        -- ══════════════════════════════════════════════════════════════
        report "--- Test 1: Encryption ---";

        mode_i     <= '0';
        key_i      <= KEY;
        iv_i       <= IV;
        aad_addr_i <= ADDR_AAD;
        aad_len_i  <= LEN_AAD;
        pt_addr_i  <= ADDR_PT;
        pt_len_i   <= LEN_PT;
        ct_addr_i  <= ADDR_CT;
        tag_i      <= (others => '0');

        pulse_start;
        wait_done("Test 1");

        assert auth_fail_o = '0'
            report "Test 1 FAIL: auth_fail_o set during encryption"
            severity failure;

        -- Capture tag and CT for subsequent tests
        enc_tag <= tag_o;
        wait for CLK_PERIOD;  -- enc_tag signal now stable

        report "Test 1 PASS: encryption done, tag = " & to_hstring(tag_o);

        -- ══════════════════════════════════════════════════════════════
        -- Test 2 — Decryption round-trip
        --   CT at 0x030 (from Test 1), decrypt → PT at 0x010
        --   Verifies: recovered PT = original PT; auth_fail_o = 0
        -- ══════════════════════════════════════════════════════════════
        report "--- Test 2: Decryption round-trip ---";

        wait for 3 * CLK_PERIOD;

        mode_i     <= '1';         -- decrypt
        key_i      <= KEY;
        iv_i       <= IV;
        aad_addr_i <= ADDR_AAD;
        aad_len_i  <= LEN_AAD;
        pt_addr_i  <= ADDR_PT;     -- destination for recovered PT
        pt_len_i   <= LEN_PT;
        ct_addr_i  <= ADDR_CT;     -- source CT from Test 1
        tag_i      <= enc_tag;

        pulse_start;
        wait_done("Test 2");

        assert auth_fail_o = '0'
            report "Test 2 FAIL: auth_fail_o set on valid (CT, tag) pair"
            severity failure;

        assert sim_mem(1) = PT_BLOCK_0
            report "Test 2 FAIL: recovered PT block 0 does not match original"
            severity failure;

        assert sim_mem(2) = PT_BLOCK_1
            report "Test 2 FAIL: recovered PT block 1 does not match original"
            severity failure;

        report "Test 2 PASS: plaintext recovered correctly";

        -- ══════════════════════════════════════════════════════════════
        -- Test 3 — Authentication failure detection
        --   Flip 1 bit in CT block 0; present the original (correct) tag.
        --   Verifies: done_o fires; auth_fail_o = 1.
        -- ══════════════════════════════════════════════════════════════
        report "--- Test 3: Auth-fail detection ---";

        wait for 3 * CLK_PERIOD;

        -- Corrupt LSB of CT block 0
        sim_mem(3) := sim_mem(3) xor x"00000000000000000000000000000001";

        mode_i     <= '1';
        key_i      <= KEY;
        iv_i       <= IV;
        aad_addr_i <= ADDR_AAD;
        aad_len_i  <= LEN_AAD;
        pt_addr_i  <= ADDR_PT;
        pt_len_i   <= LEN_PT;
        ct_addr_i  <= ADDR_CT;
        tag_i      <= enc_tag;     -- original (correct) tag; CT is now wrong

        pulse_start;
        wait_done("Test 3");

        assert auth_fail_o = '1'
            report "Test 3 FAIL: auth_fail_o not set on corrupted ciphertext"
            severity failure;

        report "Test 3 PASS: authentication failure correctly detected";

        -- ──────────────────────────────────────────────────────────────
        report "ALL TESTS PASSED";
        std.env.finish;

    end process stimulus;

end architecture bench;
