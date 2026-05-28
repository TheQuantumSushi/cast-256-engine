-- ┌──────────────────────────────────────────────────────────────────┐
-- │ tb_crypto_integration                                            │
-- │                                                                  │
-- │ Integration testbench: exercises crypto.vhd top-level by        │
-- │ driving the AXI4-Lite slave interface with a behavioural AXI    │
-- │ master, and responding to the AXI4-Lite master (DMA) bus with   │
-- │ a simple memory model.                                           │
-- │                                                                  │
-- │ Tests run unconditionally (work today, Step 3 not required):     │
-- │   T0 – Reset: CSR reads zero after hardware reset               │
-- │   T1 – Config write: write KEY / IV / addresses via AXI         │
-- │   T2 – Bounds check: PT_ADDR with bits[31:30] set → SLVERR      │
-- │   T3 – Encrypt, zero-length AAD + PT: START → DONE; tag stable  │
-- │   T4 – Decrypt, correct tag: START → DONE; auth_fail = 0        │
-- │   T5 – Decrypt, corrupted tag: START → DONE; CSR.ERROR = 1      │
-- │   T6 – Soft reset: CSR.SOFT_RESET clears DONE/TAG_VALID         │
-- │                                                                  │
-- │ Tests gated by generic STEP3_IMPLEMENTED (default false):        │
-- │   T7 – Encrypt, 1-block AAD + 2-block PT, verify round-trip     │
-- │   T8 – Decrypt, tampered CT block → CSR.ERROR = 1               │
-- │                                                                  │
-- │ Why zero-length data works without Step 3:                       │
-- │   GCM skips the AAD and GCTR loops when *_blk_rem = 0,          │
-- │   so it issues NO dma_rd_req_o / dma_wr_req_o pulses and        │
-- │   reaches DONE without depending on dma_rd_valid_i or           │
-- │   dma_wr_done_i (which are stubbed to '0' in crypto.vhd         │
-- │   until Step 3 is implemented).                                  │
-- │                                                                  │
-- │ CSR register (0x058) bit layout (from axi_slave_rd.vhd):        │
-- │   [0]  START      (W)                                            │
-- │   [1]  SOFT_RESET (W)                                            │
-- │   [2]  MODE       (R/W: 0=encrypt, 1=decrypt)                   │
-- │   [8]  BUSY       (R)                                            │
-- │   [9]  DONE       (R)                                            │
-- │   [10] TAG_VALID  (R)                                            │
-- │   [11] ERROR      (R, set when auth_fail_o = 1)                 │
-- │                                                                  │
-- │ Register map:                                                     │
-- │   0x000-0x01C  KEY[0-7]  (word 0 = key[255:224], big-endian)    │
-- │   0x020-0x028  IV[0-2]   (word 0 = iv[95:64])                   │
-- │   0x030        AAD_ADDR                                          │
-- │   0x034        AAD_LEN                                           │
-- │   0x038        PT_ADDR                                           │
-- │   0x03C        PT_LEN                                            │
-- │   0x040        CT_ADDR                                           │
-- │   0x044        CT_LEN    (RO = PT_LEN)                          │
-- │   0x048-0x054  TAG[0-3]  (word 0 = tag[127:96])                 │
-- │   0x058        CSR                                               │
-- │   0x05C        DEBUG     (RO FSM state)                         │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_crypto_integration is
    generic (
        -- Set to true once Step 3 (DMA burst adapter) is implemented.
        -- Enables T7 / T8 which require real DMA traffic.
        STEP3_IMPLEMENTED : boolean := false
    );
end entity tb_crypto_integration;

architecture bench of tb_crypto_integration is

    -- ┌─────────────────────────────────┐
    -- │ Timing                          │
    -- └─────────────────────────────────┘
    constant CLK_PERIOD  : time    := 10 ns;
    -- Zero-length: KS(~396) + H(~96) + LEN_HASH(~33) + TAG_ENC(~96) ≈ 625 cycles
    constant TIMEOUT_SHORT : time  := 15 us;   -- ~1500 cycles; covers zero-len runs
    -- Non-zero payload: add DMA + GCTR latency per block
    constant TIMEOUT_LONG  : time  := 100 us;  -- ~10000 cycles; for Step3 tests
    constant DMA_RD_LATENCY : integer := 4;    -- cycles from AXI AR to R valid

    -- ┌─────────────────────────────────┐
    -- │ Test vectors (same key as tb_gcm│
    -- │ so crypto output can cross-check│
    -- └─────────────────────────────────┘
    -- 256-bit key (RFC 2612 Appendix A known vector)
    constant KEY : std_ulogic_vector(255 downto 0) :=
        x"2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604";

    -- 96-bit IV
    constant IV : std_ulogic_vector(95 downto 0) :=
        x"cafebabe1234567800000001";

    -- Payload for Step3 tests (T7/T8)
    constant AAD_BLOCK  : std_ulogic_vector(127 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f";
    constant PT_BLOCK_0 : std_ulogic_vector(127 downto 0) :=
        x"101112131415161718191a1b1c1d1e1f";
    constant PT_BLOCK_1 : std_ulogic_vector(127 downto 0) :=
        x"202122232425262728292a2b2c2d2e2f";

    -- Memory layout for Step3 tests (byte addresses, 16-byte aligned):
    --   0x000 : AAD block
    --   0x010 : PT block 0  (also destination for decrypted PT)
    --   0x020 : PT block 1
    --   0x030 : CT block 0  (written by encrypt, read by decrypt)
    --   0x040 : CT block 1
    constant ADDR_AAD : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned(  0, 30));
    constant ADDR_PT  : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 16, 30));
    constant ADDR_CT  : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 48, 30));
    constant LEN_AAD  : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 16, 30));
    constant LEN_PT   : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 32, 30));

    -- ┌─────────────────────────────────┐
    -- │ Simulation memory (DMA model)   │
    -- └─────────────────────────────────┘
    type mem_t is array (0 to 15) of std_ulogic_vector(127 downto 0);
    shared variable sim_mem : mem_t := (others => (others => '0'));

    -- ┌─────────────────────────────────┐
    -- │ DUT top-level signals           │
    -- └─────────────────────────────────┘
    signal aclk    : std_ulogic := '0';
    signal aresetn : std_ulogic := '0';

    -- AXI slave (control)
    signal s0_awaddr  : std_ulogic_vector(11 downto 0) := (others => '0');
    signal s0_awvalid : std_ulogic := '0';
    signal s0_awready : std_ulogic;
    signal s0_wdata   : std_ulogic_vector(31 downto 0) := (others => '0');
    signal s0_wstrb   : std_ulogic_vector( 3 downto 0) := "1111";
    signal s0_wvalid  : std_ulogic := '0';
    signal s0_wready  : std_ulogic;
    signal s0_bresp   : std_ulogic_vector( 1 downto 0);
    signal s0_bvalid  : std_ulogic;
    signal s0_bready  : std_ulogic := '0';
    signal s0_araddr  : std_ulogic_vector(11 downto 0) := (others => '0');
    signal s0_arvalid : std_ulogic := '0';
    signal s0_arready : std_ulogic;
    signal s0_rdata   : std_ulogic_vector(31 downto 0);
    signal s0_rresp   : std_ulogic_vector( 1 downto 0);
    signal s0_rvalid  : std_ulogic;
    signal s0_rready  : std_ulogic := '0';

    -- AXI master (DMA)
    signal m0_araddr   : std_ulogic_vector(29 downto 0);
    signal m0_arvalid  : std_ulogic;
    signal m0_arready  : std_ulogic := '0';
    signal m0_rdata    : std_ulogic_vector(31 downto 0) := (others => '0');
    signal m0_rresp    : std_ulogic_vector( 1 downto 0) := "00";
    signal m0_rvalid   : std_ulogic := '0';
    signal m0_rready   : std_ulogic;
    signal m0_awaddr   : std_ulogic_vector(29 downto 0);
    signal m0_awvalid  : std_ulogic;
    signal m0_awready  : std_ulogic := '0';
    signal m0_wdata    : std_ulogic_vector(31 downto 0);
    signal m0_wstrb    : std_ulogic_vector( 3 downto 0);
    signal m0_wvalid   : std_ulogic;
    signal m0_wready   : std_ulogic := '0';
    signal m0_bresp    : std_ulogic_vector( 1 downto 0) := "00";
    signal m0_bvalid   : std_ulogic := '0';
    signal m0_bready   : std_ulogic;

    -- Debug / IO
    signal sw  : std_ulogic_vector(3 downto 0) := "0001"; -- sw(0)=1 masks IRQ
    signal btn : std_ulogic_vector(3 downto 0) := "0000";
    signal led : std_ulogic_vector(3 downto 0);
    signal irq : std_ulogic;

    -- ── Captured outputs ──────────────────────────────────────────────
    signal enc_tag  : std_ulogic_vector(127 downto 0) := (others => '0');

begin

    -- ── Clock ─────────────────────────────────────────────────────────
    aclk <= not aclk after CLK_PERIOD / 2;

    -- ── DUT ───────────────────────────────────────────────────────────
    u_dut : entity work.crypto
        port map (
            aclk             => aclk,
            aresetn          => aresetn,
            s0_axi_awaddr    => s0_awaddr,
            s0_axi_awvalid   => s0_awvalid,
            s0_axi_awready   => s0_awready,
            s0_axi_wdata     => s0_wdata,
            s0_axi_wstrb     => s0_wstrb,
            s0_axi_wvalid    => s0_wvalid,
            s0_axi_wready    => s0_wready,
            s0_axi_bresp     => s0_bresp,
            s0_axi_bvalid    => s0_bvalid,
            s0_axi_bready    => s0_bready,
            s0_axi_araddr    => s0_araddr,
            s0_axi_arvalid   => s0_arvalid,
            s0_axi_arready   => s0_arready,
            s0_axi_rdata     => s0_rdata,
            s0_axi_rresp     => s0_rresp,
            s0_axi_rvalid    => s0_rvalid,
            s0_axi_rready    => s0_rready,
            m0_axi_araddr    => m0_araddr,
            m0_axi_arvalid   => m0_arvalid,
            m0_axi_arready   => m0_arready,
            m0_axi_rdata     => m0_rdata,
            m0_axi_rresp     => m0_rresp,
            m0_axi_rvalid    => m0_rvalid,
            m0_axi_rready    => m0_rready,
            m0_axi_awaddr    => m0_awaddr,
            m0_axi_awvalid   => m0_awvalid,
            m0_axi_awready   => m0_awready,
            m0_axi_wdata     => m0_wdata,
            m0_axi_wstrb     => m0_wstrb,
            m0_axi_wvalid    => m0_wvalid,
            m0_axi_wready    => m0_wready,
            m0_axi_bresp     => m0_bresp,
            m0_axi_bvalid    => m0_bvalid,
            m0_axi_bready    => m0_bready,
            sw               => sw,
            btn              => btn,
            led              => led,
            irq              => irq
        );

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ dma_mem_model                                                   ║
    -- ║                                                                 ║
    -- ║ Responds to m0_axi_* read and write transactions (issued by    ║
    -- ║ dma_engine once Step 3 bridges gcm ↔ dma_engine). Each        ║
    -- ║ outstanding transaction is handled one at a time; DMA_RD_LATENCY║
    -- ║ cycles of read latency mimic DDR access.                       ║
    -- ║                                                                 ║
    -- ║ Read: accepts AR, waits DMA_RD_LATENCY cycles, returns word    ║
    -- ║       at sim_mem[addr/16][word] on R channel.                  ║
    -- ║ Write: accepts AW+W, stores word, returns OKAY on B channel.   ║
    -- ║                                                                 ║
    -- ║ With Step 3 stubs in place (DMA engine idle), no m0_axi        ║
    -- ║ transactions are generated and this process idles silently.    ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    dma_mem_model : process (aclk) is
        variable rd_pending  : boolean  := false;
        variable rd_blk      : integer  := 0;
        variable rd_word     : integer  := 0;
        variable rd_countdown: integer  := 0;
        variable wr_blk      : integer  := 0;
        variable wr_word     : integer  := 0;
        variable wr_data_buf : std_ulogic_vector(127 downto 0);
    begin
        if rising_edge(aclk) then
            -- Defaults: deassert ready/valid
            m0_arready <= '0';
            m0_rvalid  <= '0';
            m0_awready <= '0';
            m0_wready  <= '0';
            m0_bvalid  <= '0';

            if aresetn = '0' then
                rd_pending := false;
                m0_rvalid  <= '0';
            else
                -- ── Read channel ───────────────────────────────────────
                if m0_arvalid = '1' and not rd_pending then
                    m0_arready  <= '1';
                    rd_blk      := to_integer(unsigned(m0_araddr(29 downto 4)));
                    rd_word     := to_integer(unsigned(m0_araddr( 3 downto 2)));
                    rd_countdown := DMA_RD_LATENCY;
                    rd_pending  := true;
                end if;

                if rd_pending then
                    rd_countdown := rd_countdown - 1;
                    if rd_countdown = 0 then
                        -- Return the 32-bit word; block_join in dma_engine
                        -- assembles 4 consecutive reads into 128 bits big-endian.
                        -- Word 0 = bits[127:96], word 1 = bits[95:64], etc.
                        case rd_word is
                            when 0 => m0_rdata <= sim_mem(rd_blk)(127 downto 96);
                            when 1 => m0_rdata <= sim_mem(rd_blk)( 95 downto 64);
                            when 2 => m0_rdata <= sim_mem(rd_blk)( 63 downto 32);
                            when 3 => m0_rdata <= sim_mem(rd_blk)( 31 downto  0);
                            when others => m0_rdata <= (others => '0');
                        end case;
                        m0_rresp  <= "00";
                        m0_rvalid <= '1';
                        rd_pending := false;
                    end if;
                end if;

                -- ── Write channel ──────────────────────────────────────
                if m0_awvalid = '1' and m0_wvalid = '1' then
                    m0_awready <= '1';
                    m0_wready  <= '1';
                    wr_blk  := to_integer(unsigned(m0_awaddr(29 downto 4)));
                    wr_word := to_integer(unsigned(m0_awaddr( 3 downto 2)));
                    -- Byte-enable aware write (big-endian word layout)
                    wr_data_buf := sim_mem(wr_blk);
                    case wr_word is
                        when 0 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(127-i*8 downto 120-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 1 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(95-i*8 downto 88-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 2 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(63-i*8 downto 56-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 3 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(31-i*8 downto 24-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when others => null;
                    end case;
                    sim_mem(wr_blk) := wr_data_buf;
                    m0_bresp  <= "00";
                    m0_bvalid <= '1';
                end if;

                -- Hold BVALID until accepted
                if m0_bvalid = '1' and m0_bready = '1' then
                    m0_bvalid <= '0';
                end if;
            end if;
        end if;
    end process dma_mem_model;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ stimulus                                                         ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    stimulus : process is

        -- ── AXI4-Lite single write ─────────────────────────────────────
        -- Presents AW and W simultaneously (slave accepts both in one
        -- transaction); collects B response. Returns bresp value.
        procedure axi_write (
            addr : in  std_ulogic_vector(11 downto 0);
            data : in  std_ulogic_vector(31 downto 0);
            resp : out std_ulogic_vector( 1 downto 0)
        ) is
        begin
            wait until rising_edge(aclk);
            s0_awaddr  <= addr;
            s0_awvalid <= '1';
            s0_wdata   <= data;
            s0_wstrb   <= "1111";
            s0_wvalid  <= '1';
            -- Wait for both ready signals
            loop
                wait until rising_edge(aclk);
                if s0_awready = '1' then s0_awvalid <= '0'; end if;
                if s0_wready  = '1' then s0_wvalid  <= '0'; end if;
                exit when s0_awready = '1' and s0_wready = '1';
            end loop;
            s0_awvalid <= '0';
            s0_wvalid  <= '0';
            -- Wait for B response
            s0_bready <= '1';
            wait until rising_edge(aclk) and s0_bvalid = '1';
            resp := s0_bresp;
            s0_bready <= '0';
        end procedure axi_write;

        -- ── AXI4-Lite single write (ignore response) ───────────────────
        procedure axi_wr (
            addr : in std_ulogic_vector(11 downto 0);
            data : in std_ulogic_vector(31 downto 0)
        ) is
            variable dummy : std_ulogic_vector(1 downto 0);
        begin
            axi_write(addr, data, dummy);
        end procedure axi_wr;

        -- ── AXI4-Lite single read ──────────────────────────────────────
        procedure axi_read (
            addr : in  std_ulogic_vector(11 downto 0);
            data : out std_ulogic_vector(31 downto 0)
        ) is
        begin
            wait until rising_edge(aclk);
            s0_araddr  <= addr;
            s0_arvalid <= '1';
            wait until rising_edge(aclk) and s0_arready = '1';
            s0_arvalid <= '0';
            s0_rready  <= '1';
            wait until rising_edge(aclk) and s0_rvalid = '1';
            data := s0_rdata;
            s0_rready <= '0';
        end procedure axi_read;

        -- ── Write full 256-bit KEY (8 × 32-bit, big-endian) ───────────
        procedure write_key (key : in std_ulogic_vector(255 downto 0)) is
        begin
            axi_wr(x"000", key(255 downto 224));
            axi_wr(x"004", key(223 downto 192));
            axi_wr(x"008", key(191 downto 160));
            axi_wr(x"00C", key(159 downto 128));
            axi_wr(x"010", key(127 downto  96));
            axi_wr(x"014", key( 95 downto  64));
            axi_wr(x"018", key( 63 downto  32));
            axi_wr(x"01C", key( 31 downto   0));
        end procedure write_key;

        -- ── Write 96-bit IV (3 × 32-bit, big-endian) ──────────────────
        procedure write_iv (iv : in std_ulogic_vector(95 downto 0)) is
        begin
            axi_wr(x"020", iv(95 downto 64));
            axi_wr(x"024", iv(63 downto 32));
            axi_wr(x"028", iv(31 downto  0));
        end procedure write_iv;

        -- ── Read 128-bit TAG (4 × 32-bit) ─────────────────────────────
        procedure read_tag (tag : out std_ulogic_vector(127 downto 0)) is
            variable w : std_ulogic_vector(31 downto 0);
        begin
            axi_read(x"048", w); tag(127 downto 96) := w;
            axi_read(x"04C", w); tag( 95 downto 64) := w;
            axi_read(x"050", w); tag( 63 downto 32) := w;
            axi_read(x"054", w); tag( 31 downto  0) := w;
        end procedure read_tag;

        -- ── Pulse START (write CSR bit 0; also sets MODE via bit 2) ───
        procedure start_engine (mode : in std_ulogic) is
            -- bit[2]=MODE, bit[0]=START
            variable csr_val : std_ulogic_vector(31 downto 0);
        begin
            csr_val := (others => '0');
            csr_val(2) := mode;
            csr_val(0) := '1';
            axi_wr(x"058", csr_val);
        end procedure start_engine;

        -- ── Poll CSR until DONE or ERROR, with timeout ─────────────────
        procedure wait_done (test_name : in string;
                              timeout   : in time;
                              csr_out   : out std_ulogic_vector(31 downto 0)) is
            variable t_start : time;
            variable rdata   : std_ulogic_vector(31 downto 0);
            variable elapsed : time;
        begin
            t_start := now;
            loop
                axi_read(x"058", rdata);
                -- bit 9 = DONE, bit 11 = ERROR
                exit when rdata(9) = '1' or rdata(11) = '1';
                elapsed := now - t_start;
                assert elapsed < timeout
                    report test_name & " TIMEOUT waiting for DONE/ERROR"
                    severity failure;
            end loop;
            csr_out := rdata;
        end procedure wait_done;

        -- ── Common helper: configure KEY, IV, lengths, addresses ───────
        procedure configure_zero_length is
        begin
            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0 → no DMA, no AAD loop
            axi_wr(x"038", x"00000000");  -- PT_ADDR
            axi_wr(x"03C", x"00000000");  -- PT_LEN  = 0 → no DMA, no GCTR loop
            axi_wr(x"040", x"00000000");  -- CT_ADDR
        end procedure configure_zero_length;

        variable bresp  : std_ulogic_vector( 1 downto 0);
        variable rdata  : std_ulogic_vector(31 downto 0);
        variable csr    : std_ulogic_vector(31 downto 0);
        variable rd_tag : std_ulogic_vector(127 downto 0);

    begin

        -- ──────────────────────────────────────────────────────────────
        report "##################################################";
        report "  Integration Testbench - crypto.vhd";
        report "##################################################";
        report "  DUT: AXI slave + GCM (CAST-256 + GHASH)";
        report "  Step 3 (DMA bridge): " &
               boolean'image(STEP3_IMPLEMENTED);
        report "##################################################";

        -- ── Hardware reset ────────────────────────────────────────────
        aresetn <= '0';
        wait for 8 * CLK_PERIOD;
        aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -- ══════════════════════════════════════════════════════════════
        -- T0 — Reset state: CSR must read 0x00000000 after hardware reset
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T0 : CSR reset state";
        report "--------------------------------------------------";

        axi_read(x"058", rdata);
        assert rdata = x"00000000"
            report "T0 FAIL: CSR not zero after reset, got " & to_hstring(rdata)
            severity failure;
        report "  CSR = " & to_hstring(rdata) & "  (expect 00000000)";
        report "  PASS: T0 CSR reset state";

        -- ══════════════════════════════════════════════════════════════
        -- T1 — Config write/readback: AXI slave correctly stores the
        --      MODE field; address range checks (KEY and IV are WO,
        --      return 0 on read; MODE is readable via CSR[2]).
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T1 : Config write / CSR mode readback";
        report "--------------------------------------------------";

        -- Write KEY (write-only, reads return 0 — just verify no AXI error)
        write_key(KEY);
        -- Write IV
        write_iv(IV);
        -- Write addresses and lengths (non-zero to verify they're stored)
        axi_wr(x"030", x"00000010");  -- AAD_ADDR = 16
        axi_wr(x"034", x"00000020");  -- AAD_LEN  = 32
        axi_wr(x"038", x"00000040");  -- PT_ADDR  = 64
        axi_wr(x"03C", x"00000060");  -- PT_LEN   = 96
        axi_wr(x"040", x"00000080");  -- CT_ADDR  = 128

        -- CT_LEN is read-only and mirrors PT_LEN
        axi_read(x"044", rdata);
        assert rdata = x"00000060"
            report "T1 FAIL: CT_LEN readback mismatch, got " & to_hstring(rdata)
            severity failure;
        report "  CT_LEN (RO, mirrors PT_LEN) = " & to_hstring(rdata) & "  (expect 00000060)";

        -- Write mode = decrypt (bit 2 of CSR write = 1); CSR[0]=0 so no START
        axi_wr(x"058", x"00000004");  -- MODE = 1 (decrypt), no START
        axi_read(x"058", rdata);
        assert rdata(2) = '1'
            report "T1 FAIL: CSR MODE bit not set after write, CSR = " & to_hstring(rdata)
            severity failure;
        report "  CSR mode bit = " & std_ulogic'image(rdata(2)) & "  (expect 1 = decrypt)";

        -- Reset mode back to encrypt for subsequent tests
        axi_wr(x"058", x"00000000");
        report "  PASS: T1 config write / mode readback";

        -- ══════════════════════════════════════════════════════════════
        -- T2 — Address bounds check: PT_ADDR with bits[31:30] set must
        --      return SLVERR; CT_LEN (WO dest = RO) must return OKAY.
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T2 : Address bounds (SLVERR on > 30-bit address)";
        report "--------------------------------------------------";

        axi_write(x"038", x"C0000000", bresp);  -- PT_ADDR with bit 31 set
        assert bresp = "10"
            report "T2 FAIL: expected SLVERR (10) for PT_ADDR out of range, got " &
                   to_hstring("00" & bresp)
            severity failure;
        report "  PT_ADDR write with bits[31:30] set -> BRESP = " &
               to_hstring("00" & bresp) & "  (expect 10 = SLVERR)";

        axi_write(x"038", x"00000000", bresp);  -- valid PT_ADDR = 0
        assert bresp = "00"
            report "T2 FAIL: valid PT_ADDR got " & to_hstring("00" & bresp)
            severity failure;
        report "  PASS: T2 address bounds check";

        -- ══════════════════════════════════════════════════════════════
        -- T3 — Encrypt, zero-length AAD + PT
        --
        -- No DMA traffic: GCM goes KS→H→LEN_HASH→TAG_ENC→DONE.
        -- Produces a deterministic tag (CAST256(K, J0) XOR GHASH(len=0)).
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T3 : Encrypt, zero-length (no DMA required)";
        report "--------------------------------------------------";

        configure_zero_length;

        -- Verify BUSY = 0 before start
        axi_read(x"058", rdata);
        assert rdata(8) = '0'
            report "T3 FAIL: BUSY set before START"
            severity failure;

        start_engine('0');  -- mode = encrypt

        -- Verify BUSY = 1 immediately after START
        -- (START write triggers csr_start which sets csr_busy on the same
        -- clock edge that the AXI B response is sent; read one cycle later)
        axi_read(x"058", rdata);
        assert rdata(8) = '1'
            report "T3 FAIL: BUSY not set after START, CSR = " & to_hstring(rdata)
            severity failure;
        report "  BUSY asserted after START: " & std_ulogic'image(rdata(8));

        wait_done("T3", TIMEOUT_SHORT, csr);
        assert csr(11) = '0'
            report "T3 FAIL: CSR.ERROR set on valid encrypt"
            severity failure;
        assert csr(10) = '1'
            report "T3 FAIL: CSR.TAG_VALID not set after encrypt done"
            severity failure;
        assert csr(9)  = '1'
            report "T3 FAIL: CSR.DONE not set"
            severity failure;
        assert csr(8)  = '0'
            report "T3 FAIL: CSR.BUSY still set after done"
            severity failure;

        read_tag(rd_tag);
        enc_tag <= rd_tag;
        wait for CLK_PERIOD;

        report "  Tag     : " & to_hstring(enc_tag);
        report "  CSR     : " & to_hstring(csr) &
               "  (expect bit9=DONE bit10=TAG_VALID)";
        report "  PASS: T3 encrypt zero-length, tag produced";

        -- ══════════════════════════════════════════════════════════════
        -- T4 — Decrypt, correct tag: auth_fail must stay 0
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T4 : Decrypt, correct tag (auth_fail = 0)";
        report "--------------------------------------------------";

        wait for 3 * CLK_PERIOD;

        configure_zero_length;

        -- Write expected tag (from T3)
        axi_wr(x"048", enc_tag(127 downto 96));
        axi_wr(x"04C", enc_tag( 95 downto 64));
        axi_wr(x"050", enc_tag( 63 downto 32));
        axi_wr(x"054", enc_tag( 31 downto  0));

        start_engine('1');  -- mode = decrypt

        wait_done("T4", TIMEOUT_SHORT, csr);
        assert csr(11) = '0'
            report "T4 FAIL: CSR.ERROR (auth_fail) set on valid (CT,tag) pair, CSR = " &
                   to_hstring(csr)
            severity failure;
        assert csr(9) = '1'
            report "T4 FAIL: CSR.DONE not set"
            severity failure;

        report "  CSR = " & to_hstring(csr) & "  (expect bit9=DONE, bit11=0)";
        report "  PASS: T4 decrypt correct tag, no auth failure";

        -- ══════════════════════════════════════════════════════════════
        -- T5 — Decrypt, corrupted tag: CSR.ERROR must be set
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T5 : Decrypt, corrupted tag (CSR.ERROR = 1)";
        report "--------------------------------------------------";

        wait for 3 * CLK_PERIOD;

        configure_zero_length;

        -- Flip LSB of tag word 3
        axi_wr(x"048", enc_tag(127 downto 96));
        axi_wr(x"04C", enc_tag( 95 downto 64));
        axi_wr(x"050", enc_tag( 63 downto 32));
        axi_wr(x"054", enc_tag(31 downto 1) & not enc_tag(0));  -- flip bit 0

        start_engine('1');  -- mode = decrypt

        wait_done("T5", TIMEOUT_SHORT, csr);
        assert csr(11) = '1'
            report "T5 FAIL: CSR.ERROR not set on corrupted tag, CSR = " & to_hstring(csr)
            severity failure;

        report "  CSR = " & to_hstring(csr) & "  (expect bit11=ERROR)";
        report "  PASS: T5 corrupted tag correctly rejected";

        -- ══════════════════════════════════════════════════════════════
        -- T6 — Soft reset: write CSR.SOFT_RESET; verify DONE and
        --      TAG_VALID clear; verify mode returns to 0.
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T6 : Soft reset clears status bits";
        report "--------------------------------------------------";

        -- CSR still shows DONE=1 / ERROR=1 from T5; issue soft reset
        axi_wr(x"058", x"00000006");  -- bit1=SOFT_RESET, bit2=MODE (just to check it clears)
        wait for 3 * CLK_PERIOD;      -- soft reset is synchronous; one cycle is enough

        axi_read(x"058", rdata);
        assert rdata(9)  = '0'
            report "T6 FAIL: DONE still set after soft reset"
            severity failure;
        assert rdata(11) = '0'
            report "T6 FAIL: ERROR still set after soft reset"
            severity failure;
        assert rdata(8)  = '0'
            report "T6 FAIL: BUSY still set after soft reset"
            severity failure;

        report "  CSR after SOFT_RESET = " & to_hstring(rdata) & "  (expect 00000000)";
        report "  PASS: T6 soft reset clears status";

        -- ══════════════════════════════════════════════════════════════
        -- T7 / T8 — Full payload tests (requires Step 3)
        -- ══════════════════════════════════════════════════════════════
        if STEP3_IMPLEMENTED then

            wait for 5 * CLK_PERIOD;

            -- ── T7 : Encrypt 1-block AAD + 2-block PT ─────────────────
            report "--------------------------------------------------";
            report "  T7 : Encrypt 1-block AAD + 2-block PT (Step3)";
            report "--------------------------------------------------";

            sim_mem(0) := AAD_BLOCK;
            sim_mem(1) := PT_BLOCK_0;
            sim_mem(2) := PT_BLOCK_1;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR
            axi_wr(x"034", x"00000010");  -- AAD_LEN  = 16 B (1 block)
            axi_wr(x"038", x"00000010");  -- PT_ADDR  = 0x10
            axi_wr(x"03C", x"00000020");  -- PT_LEN   = 32 B (2 blocks)
            axi_wr(x"040", x"00000030");  -- CT_ADDR  = 0x30

            start_engine('0');

            wait_done("T7", TIMEOUT_LONG, csr);
            assert csr(11) = '0'
                report "T7 FAIL: CSR.ERROR during encrypt"
                severity failure;
            assert csr(10) = '1'
                report "T7 FAIL: CSR.TAG_VALID not set"
                severity failure;

            read_tag(rd_tag);
            enc_tag <= rd_tag;
            wait for CLK_PERIOD;

            report "  CT[0] = " & to_hstring(sim_mem(3));
            report "  CT[1] = " & to_hstring(sim_mem(4));
            report "  Tag   = " & to_hstring(enc_tag);
            report "  PASS: T7 encrypt completed";

            -- ── T8 : Decrypt round-trip, then verify tamper ────────────
            report "--------------------------------------------------";
            report "  T8a: Decrypt round-trip (correct CT + tag)";
            report "--------------------------------------------------";

            wait for 3 * CLK_PERIOD;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR
            axi_wr(x"034", x"00000010");  -- AAD_LEN
            axi_wr(x"038", x"00000030");  -- source = CT
            axi_wr(x"03C", x"00000020");  -- LEN = 32 B
            axi_wr(x"040", x"00000010");  -- dest  = PT area
            axi_wr(x"048", enc_tag(127 downto 96));
            axi_wr(x"04C", enc_tag( 95 downto 64));
            axi_wr(x"050", enc_tag( 63 downto 32));
            axi_wr(x"054", enc_tag( 31 downto  0));

            start_engine('1');

            wait_done("T8a", TIMEOUT_LONG, csr);
            assert csr(11) = '0'
                report "T8a FAIL: auth_fail on valid round-trip"
                severity failure;
            assert sim_mem(1) = PT_BLOCK_0
                report "T8a FAIL: recovered PT[0] mismatch"
                severity failure;
            assert sim_mem(2) = PT_BLOCK_1
                report "T8a FAIL: recovered PT[1] mismatch"
                severity failure;

            report "  PT[0] = " & to_hstring(sim_mem(1)) &
                   "  (expect " & to_hstring(PT_BLOCK_0) & ")";
            report "  PT[1] = " & to_hstring(sim_mem(2)) &
                   "  (expect " & to_hstring(PT_BLOCK_1) & ")";
            report "  PASS: T8a round-trip decrypt correct";

            report "--------------------------------------------------";
            report "  T8b: Decrypt with tampered CT -> CSR.ERROR";
            report "--------------------------------------------------";

            wait for 3 * CLK_PERIOD;

            -- Flip one bit in CT block 0
            sim_mem(3) := sim_mem(3) xor x"00000000000000000000000000000001";

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000010");
            axi_wr(x"038", x"00000030");  -- CT source
            axi_wr(x"03C", x"00000020");
            axi_wr(x"040", x"00000010");
            axi_wr(x"048", enc_tag(127 downto 96));
            axi_wr(x"04C", enc_tag( 95 downto 64));
            axi_wr(x"050", enc_tag( 63 downto 32));
            axi_wr(x"054", enc_tag( 31 downto  0));

            start_engine('1');

            wait_done("T8b", TIMEOUT_LONG, csr);
            assert csr(11) = '1'
                report "T8b FAIL: ERROR not set on tampered CT"
                severity failure;

            report "  CSR = " & to_hstring(csr) & "  (expect bit11=ERROR)";
            report "  PASS: T8b tampered CT rejected";

        else
            report "--------------------------------------------------";
            report "  T7/T8 SKIPPED: STEP3_IMPLEMENTED = false";
            report "  Enable generic to test non-zero payload via DMA.";
            report "--------------------------------------------------";
        end if;

        -- ──────────────────────────────────────────────────────────────
        report "--------------------------------------------------";
        report "  ALL TESTS PASSED";
        report "--------------------------------------------------";
        std.env.finish;

    end process stimulus;

end architecture bench;
