-- ┌──────────────────────────────────────────────────────────────────┐
-- │ tb_crypto_integration                                            │
-- │                                                                  │
-- │ Integration testbench: exercises crypto.vhd top-level by        │
-- │ driving the AXI4-Lite slave interface with a behavioural AXI    │
-- │ master, and responding to the AXI4-Lite master (DMA) bus with   │
-- │ a simple memory model.                                           │
-- │                                                                  │
-- │ Tests run unconditionally:                                       │
-- │   T0        – Reset: CSR reads zero after hardware reset         │
-- │   T1        – Config write: write KEY / IV / addresses via AXI   │
-- │   T2        – Bounds check: PT_ADDR bits[31:30] set → SLVERR     │
-- │   T3        – Encrypt, zero-length: START → DONE; tag stable     │
-- │   T4        – Decrypt, correct tag: DONE; auth_fail = 0          │
-- │   T5        – Decrypt, corrupted tag: DONE; CSR.ERROR = 1        │
-- │   T6        – Soft reset: SOFT_RESET clears DONE/TAG_VALID       │
-- │   T_SWB     – START while BUSY: second START pulse → SLVERR      │
-- │   T_SRESET_MID – SOFT_RESET mid-op: BUSY clears immediately      │
-- │                                                                  │
-- │ Tests gated by STEP3_IMPLEMENTED (default true):                 │
-- │   T7          – Encrypt 1-block AAD + 2-block PT, verify TAG    │
-- │   T8a         – Decrypt round-trip → PT recovered               │
-- │   T8b         – Tampered CT → CSR.ERROR = 1                     │
-- │   T9          – Back-to-back encrypt (key cache, adapter re-arm)│
-- │   T10         – AAD=0, PT=1 block (GCTR-only DMA path)          │
-- │   T11         – 4-block PT burst, no AAD; round-trip            │
-- │   T_DMA_RD_ERR – Read SLVERR from memory → csr_error=1          │
-- │   T_DMA_WR_ERR – Write SLVERR from memory → csr_error=1         │
-- │                                                                  │
-- │ CSR register (0x058) bit layout:                                 │
-- │   [0]  START      (W)                                            │
-- │   [1]  SOFT_RESET (W)                                            │
-- │   [2]  MODE       (R/W: 0=encrypt, 1=decrypt)                   │
-- │   [8]  BUSY       (R)                                            │
-- │   [9]  DONE       (R)                                            │
-- │   [10] TAG_VALID  (R)                                            │
-- │   [11] ERROR      (R)                                            │
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
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_crypto_integration is
    generic (
        STEP3_IMPLEMENTED : boolean := true
    );
end entity tb_crypto_integration;

architecture bench of tb_crypto_integration is

    constant CLK_PERIOD    : time    := 10 ns;
    constant TIMEOUT_SHORT : time    := 15 us;
    constant TIMEOUT_LONG  : time    := 200 us;
    constant DMA_RD_LATENCY : integer := 4;

    -- 256-bit key (CAST-256 RFC 2612 Appendix A vector)
    constant KEY : std_ulogic_vector(255 downto 0) :=
        x"2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604";

    -- 96-bit IV
    constant IV : std_ulogic_vector(95 downto 0) :=
        x"cafebabe1234567800000001";

    -- Second IV for T9 back-to-back test (different from IV to detect reuse bugs)
    constant IV2 : std_ulogic_vector(95 downto 0) :=
        x"deadbeef0102030400000002";

    -- Step3 payload constants
    constant AAD_BLOCK  : std_ulogic_vector(127 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f";
    constant PT_BLOCK_0 : std_ulogic_vector(127 downto 0) :=
        x"101112131415161718191a1b1c1d1e1f";
    constant PT_BLOCK_1 : std_ulogic_vector(127 downto 0) :=
        x"202122232425262728292a2b2c2d2e2f";
    -- T10: single PT block, no AAD
    constant PT_BLOCK_T10 : std_ulogic_vector(127 downto 0) :=
        x"aabbccdd11223344aabbccdd11223344";

    -- T11: 4-block PT burst (64 bytes, base 0x070 = block 7; CT base 0x0B0 = block 11)
    constant PT_BLOCK_2 : std_ulogic_vector(127 downto 0) :=
        x"303132333435363738393a3b3c3d3e3f";
    constant PT_BLOCK_3 : std_ulogic_vector(127 downto 0) :=
        x"404142434445464748494a4b4c4d4e4f";
    constant ADDR_PT4   : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(112, 30));  -- 0x070 = block 7
    constant ADDR_CT4   : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(176, 30));  -- 0x0B0 = block 11
    constant LEN_PT4    : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned( 64, 30));  -- 4 × 16 bytes

    -- Memory layout (byte addresses, 16-byte aligned):
    --   0x000 : AAD block
    --   0x010 : PT block 0  / recovered PT[0]
    --   0x020 : PT block 1  / recovered PT[1]
    --   0x030 : CT block 0
    --   0x040 : CT block 1
    --   0x050 : T10 PT block
    --   0x060 : T10 CT block
    constant ADDR_AAD   : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned(  0, 30));
    constant ADDR_PT    : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 16, 30));
    constant ADDR_CT    : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 48, 30));
    constant ADDR_PT_T10: std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 80, 30));
    constant ADDR_CT_T10: std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 96, 30));
    constant LEN_AAD    : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 16, 30));
    constant LEN_PT     : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 32, 30));
    constant LEN_PT_T10 : std_ulogic_vector(29 downto 0) := std_ulogic_vector(to_unsigned( 16, 30));

    -- Simulation memory (indexed by 128-bit block)
    type mem_t is array (0 to 15) of std_ulogic_vector(127 downto 0);
    shared variable sim_mem : mem_t := (others => (others => '0'));

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

    signal sw  : std_ulogic_vector(3 downto 0) := "0001";
    signal btn : std_ulogic_vector(3 downto 0) := "0000";
    signal led : std_ulogic_vector(3 downto 0);
    signal irq : std_ulogic;

    signal enc_tag   : std_ulogic_vector(127 downto 0) := (others => '0');
    signal enc_tag_t9: std_ulogic_vector(127 downto 0) := (others => '0');

    -- DMA error injection: when set, dma_mem_model returns non-OKAY responses
    signal dma_inject_rd_error : std_ulogic := '0';
    signal dma_inject_wr_error : std_ulogic := '0';

begin

    aclk <= not aclk after CLK_PERIOD / 2;

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
    -- ║ Behavioural AXI4-Lite memory slave on m0_axi_*.                ║
    -- ║ Addresses are 30-bit byte addresses; each 128-bit block        ║
    -- ║ occupies 4 consecutive 32-bit words at indices blk*4 .. blk*4+3║
    -- ║ (big-endian: word 0 = bits 127:96).                            ║
    -- ║                                                                 ║
    -- ║ Read: latency DMA_RD_LATENCY cycles from AR to R valid.        ║
    -- ║ Write: accepts AW+W simultaneously; sends OKAY on B.           ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    dma_mem_model : process (aclk) is
        variable rd_pending   : boolean  := false;
        variable rd_blk       : integer  := 0;
        variable rd_word      : integer  := 0;
        variable rd_countdown : integer  := 0;
        variable wr_blk       : integer  := 0;
        variable wr_word      : integer  := 0;
        variable wr_data_buf  : std_ulogic_vector(127 downto 0);
    begin
        if rising_edge(aclk) then
            m0_arready <= '0';
            m0_rvalid  <= '0';
            m0_awready <= '0';
            m0_wready  <= '0';
            m0_bvalid  <= '0';

            if aresetn = '0' then
                rd_pending := false;
                m0_rvalid  <= '0';
            else
                -- ── Read ────────────────────────────────────────────────
                if m0_arvalid = '1' and not rd_pending then
                    m0_arready   <= '1';
                    rd_blk       := to_integer(unsigned(m0_araddr(29 downto 4)));
                    rd_word      := to_integer(unsigned(m0_araddr( 3 downto 2)));
                    rd_countdown := DMA_RD_LATENCY;
                    rd_pending   := true;
                end if;

                if rd_pending then
                    rd_countdown := rd_countdown - 1;
                    if rd_countdown = 0 then
                        case rd_word is
                            when 0 => m0_rdata <= sim_mem(rd_blk)(127 downto 96);
                            when 1 => m0_rdata <= sim_mem(rd_blk)( 95 downto 64);
                            when 2 => m0_rdata <= sim_mem(rd_blk)( 63 downto 32);
                            when 3 => m0_rdata <= sim_mem(rd_blk)( 31 downto  0);
                            when others => m0_rdata <= (others => '0');
                        end case;
                        if dma_inject_rd_error = '1' then
                            m0_rresp <= "10";
                        else
                            m0_rresp <= "00";
                        end if;
                        m0_rvalid  <= '1';
                        rd_pending := false;
                    end if;
                end if;

                -- ── Write ───────────────────────────────────────────────
                if m0_awvalid = '1' and m0_wvalid = '1' then
                    m0_awready  <= '1';
                    m0_wready   <= '1';
                    wr_blk  := to_integer(unsigned(m0_awaddr(29 downto 4)));
                    wr_word := to_integer(unsigned(m0_awaddr( 3 downto 2)));
                    wr_data_buf := sim_mem(wr_blk);
                    case wr_word is
                        when 0 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(127-i*8 downto 120-i*8)
                                        := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 1 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(95-i*8 downto 88-i*8)
                                        := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 2 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(63-i*8 downto 56-i*8)
                                        := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 3 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_data_buf(31-i*8 downto 24-i*8)
                                        := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when others => null;
                    end case;
                    sim_mem(wr_blk) := wr_data_buf;
                    if dma_inject_wr_error = '1' then
                        m0_bresp <= "10";
                    else
                        m0_bresp <= "00";
                    end if;
                    m0_bvalid <= '1';
                end if;

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
            loop
                wait until rising_edge(aclk);
                if s0_awready = '1' then s0_awvalid <= '0'; end if;
                if s0_wready  = '1' then s0_wvalid  <= '0'; end if;
                exit when s0_awready = '1' and s0_wready = '1';
            end loop;
            s0_awvalid <= '0';
            s0_wvalid  <= '0';
            s0_bready  <= '1';
            wait until rising_edge(aclk) and s0_bvalid = '1';
            resp       := s0_bresp;
            s0_bready  <= '0';
        end procedure axi_write;

        procedure axi_wr (
            addr : in std_ulogic_vector(11 downto 0);
            data : in std_ulogic_vector(31 downto 0)
        ) is
            variable dummy : std_ulogic_vector(1 downto 0);
        begin
            axi_write(addr, data, dummy);
        end procedure axi_wr;

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
            data       := s0_rdata;
            s0_rready  <= '0';
        end procedure axi_read;

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

        procedure write_iv (iv : in std_ulogic_vector(95 downto 0)) is
        begin
            axi_wr(x"020", iv(95 downto 64));
            axi_wr(x"024", iv(63 downto 32));
            axi_wr(x"028", iv(31 downto  0));
        end procedure write_iv;

        procedure read_tag (tag : out std_ulogic_vector(127 downto 0)) is
            variable w : std_ulogic_vector(31 downto 0);
        begin
            axi_read(x"048", w); tag(127 downto 96) := w;
            axi_read(x"04C", w); tag( 95 downto 64) := w;
            axi_read(x"050", w); tag( 63 downto 32) := w;
            axi_read(x"054", w); tag( 31 downto  0) := w;
        end procedure read_tag;

        procedure start_engine (mode : in std_ulogic) is
            variable csr_val : std_ulogic_vector(31 downto 0);
        begin
            csr_val    := (others => '0');
            csr_val(2) := mode;
            csr_val(0) := '1';
            axi_wr(x"058", csr_val);
        end procedure start_engine;

        procedure wait_done (test_name : in string;
                              timeout   : in time;
                              csr_out   : out std_ulogic_vector(31 downto 0)) is
            variable t_start : time;
            variable rdata   : std_ulogic_vector(31 downto 0);
        begin
            t_start := now;
            loop
                axi_read(x"058", rdata);
                exit when rdata(9) = '1' or rdata(11) = '1';
                assert now - t_start < timeout
                    report test_name & " TIMEOUT" severity failure;
            end loop;
            csr_out := rdata;
        end procedure wait_done;

        procedure configure_zero_length is
        begin
            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000000");
            axi_wr(x"038", x"00000000");
            axi_wr(x"03C", x"00000000");
            axi_wr(x"040", x"00000000");
        end procedure configure_zero_length;

        variable bresp  : std_ulogic_vector( 1 downto 0);
        variable rdata  : std_ulogic_vector(31 downto 0);
        variable csr    : std_ulogic_vector(31 downto 0);
        variable rd_tag : std_ulogic_vector(127 downto 0);

    begin

        report "##################################################";
        report "  Integration Testbench - crypto.vhd";
        report "##################################################";
        report "  DUT: AXI slave + GCM (CAST-256 + GHASH) + DMA";
        report "  Step 3 (DMA bridge): " & boolean'image(STEP3_IMPLEMENTED);
        report "##################################################";

        aresetn <= '0';
        wait for 8 * CLK_PERIOD;
        aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -- ══════════════════════════════════════════════════════════════
        -- T0 — Reset state
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
        -- T1 — Config write / readback
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T1 : Config write / CSR mode readback";
        report "--------------------------------------------------";

        write_key(KEY);
        write_iv(IV);
        axi_wr(x"030", x"00000010");
        axi_wr(x"034", x"00000020");
        axi_wr(x"038", x"00000040");
        axi_wr(x"03C", x"00000060");
        axi_wr(x"040", x"00000080");

        axi_read(x"044", rdata);
        assert rdata = x"00000060"
            report "T1 FAIL: CT_LEN mismatch, got " & to_hstring(rdata)
            severity failure;
        report "  CT_LEN = " & to_hstring(rdata) & "  (expect 00000060)";

        axi_wr(x"058", x"00000004");
        axi_read(x"058", rdata);
        assert rdata(2) = '1'
            report "T1 FAIL: MODE not set"
            severity failure;
        report "  CSR mode = " & std_ulogic'image(rdata(2)) & "  (expect 1)";

        axi_wr(x"058", x"00000000");
        report "  PASS: T1 config write / mode readback";

        -- ══════════════════════════════════════════════════════════════
        -- T2 — Address bounds check (SLVERR)
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T2 : Address bounds (SLVERR on > 30-bit address)";
        report "--------------------------------------------------";

        axi_write(x"038", x"C0000000", bresp);
        assert bresp = "10"
            report "T2 FAIL: expected SLVERR, got " & to_hstring("00" & bresp)
            severity failure;
        report "  PT_ADDR OOB -> BRESP = " & to_hstring("00" & bresp) &
               "  (expect 10)";

        axi_write(x"038", x"00000000", bresp);
        assert bresp = "00"
            report "T2 FAIL: valid PT_ADDR got " & to_hstring("00" & bresp)
            severity failure;
        report "  PASS: T2 address bounds check";

        -- ══════════════════════════════════════════════════════════════
        -- T3 — Encrypt, zero-length (no DMA)
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T3 : Encrypt, zero-length (no DMA required)";
        report "--------------------------------------------------";

        configure_zero_length;
        axi_read(x"058", rdata);
        assert rdata(8) = '0' report "T3 FAIL: BUSY before START" severity failure;
        start_engine('0');
        axi_read(x"058", rdata);
        assert rdata(8) = '1'
            report "T3 FAIL: BUSY not set after START"
            severity failure;
        report "  BUSY after START: " & std_ulogic'image(rdata(8));

        wait_done("T3", TIMEOUT_SHORT, csr);
        assert csr(11) = '0' report "T3 FAIL: ERROR on zero-len encrypt" severity failure;
        assert csr(10) = '1' report "T3 FAIL: TAG_VALID not set"         severity failure;
        assert csr(9)  = '1' report "T3 FAIL: DONE not set"              severity failure;
        assert csr(8)  = '0' report "T3 FAIL: BUSY after done"           severity failure;

        read_tag(rd_tag);
        enc_tag <= rd_tag;
        wait for CLK_PERIOD;
        report "  Tag = " & to_hstring(enc_tag);
        report "  CSR = " & to_hstring(csr) & "  (expect bits 9+10)";
        report "  PASS: T3 encrypt zero-length";

        -- ══════════════════════════════════════════════════════════════
        -- T4 — Decrypt, correct tag
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T4 : Decrypt, correct tag (auth_fail = 0)";
        report "--------------------------------------------------";

        wait for 3 * CLK_PERIOD;
        configure_zero_length;
        axi_wr(x"048", enc_tag(127 downto 96));
        axi_wr(x"04C", enc_tag( 95 downto 64));
        axi_wr(x"050", enc_tag( 63 downto 32));
        axi_wr(x"054", enc_tag( 31 downto  0));
        start_engine('1');

        wait_done("T4", TIMEOUT_SHORT, csr);
        assert csr(11) = '0'
            report "T4 FAIL: auth_fail on correct tag, CSR = " & to_hstring(csr)
            severity failure;
        assert csr(9) = '1' report "T4 FAIL: DONE not set" severity failure;
        report "  CSR = " & to_hstring(csr) & "  (expect bit9=DONE, bit11=0)";
        report "  PASS: T4 decrypt correct tag";

        -- ══════════════════════════════════════════════════════════════
        -- T5 — Decrypt, corrupted tag
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T5 : Decrypt, corrupted tag (CSR.ERROR = 1)";
        report "--------------------------------------------------";

        wait for 3 * CLK_PERIOD;
        configure_zero_length;
        axi_wr(x"048", enc_tag(127 downto 96));
        axi_wr(x"04C", enc_tag( 95 downto 64));
        axi_wr(x"050", enc_tag( 63 downto 32));
        axi_wr(x"054", enc_tag(31 downto 1) & not enc_tag(0));
        start_engine('1');

        wait_done("T5", TIMEOUT_SHORT, csr);
        assert csr(11) = '1'
            report "T5 FAIL: ERROR not set on bad tag, CSR = " & to_hstring(csr)
            severity failure;
        report "  CSR = " & to_hstring(csr) & "  (expect bit11=ERROR)";
        report "  PASS: T5 corrupted tag rejected";

        -- ══════════════════════════════════════════════════════════════
        -- T6 — Soft reset
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T6 : Soft reset clears status";
        report "--------------------------------------------------";

        axi_wr(x"058", x"00000006");
        wait for 3 * CLK_PERIOD;
        axi_read(x"058", rdata);
        assert rdata(9)  = '0' report "T6 FAIL: DONE after soft reset"  severity failure;
        assert rdata(11) = '0' report "T6 FAIL: ERROR after soft reset" severity failure;
        assert rdata(8)  = '0' report "T6 FAIL: BUSY after soft reset"  severity failure;
        report "  CSR after SOFT_RESET = " & to_hstring(rdata);
        report "  PASS: T6 soft reset";

        -- ══════════════════════════════════════════════════════════════
        -- T_SWB — START while BUSY (Step 4 validation)
        -- Key schedule runs ~500 cycles; second START must be rejected.
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T_SWB: START while BUSY -> SLVERR";
        report "--------------------------------------------------";

        configure_zero_length;
        start_engine('0');
        axi_write(x"058", x"00000001", bresp);
        assert bresp = "10"
            report "T_SWB FAIL: expected SLVERR on START while BUSY, got " &
                   to_hstring("00" & bresp)
            severity failure;
        report "  BRESP = " & to_hstring("00" & bresp) & "  (expect 10 = SLVERR)";
        wait_done("T_SWB", TIMEOUT_SHORT, csr);
        assert csr(9) = '1'
            report "T_SWB FAIL: original operation did not complete"
            severity failure;
        report "  PASS: T_SWB START while BUSY rejected";

        -- ══════════════════════════════════════════════════════════════
        -- T_SRESET_MID — SOFT_RESET while operation in progress
        -- p_status clears csr_busy on the same edge csr_soft_reset='1'.
        -- ══════════════════════════════════════════════════════════════
        report "--------------------------------------------------";
        report "  T_SRESET_MID: SOFT_RESET while BUSY -> BUSY clears";
        report "--------------------------------------------------";

        wait for 3 * CLK_PERIOD;
        configure_zero_length;
        start_engine('0');
        axi_read(x"058", rdata);
        assert rdata(8) = '1'
            report "T_SRESET_MID FAIL: BUSY not seen after START"
            severity failure;
        axi_wr(x"058", x"00000002");
        wait for 5 * CLK_PERIOD;
        axi_read(x"058", rdata);
        assert rdata(8) = '0'
            report "T_SRESET_MID FAIL: BUSY not cleared after mid-op SOFT_RESET"
            severity failure;
        assert rdata(9) = '0'
            report "T_SRESET_MID FAIL: DONE unexpectedly set after SOFT_RESET"
            severity failure;
        report "  CSR after mid-op SOFT_RESET = " & to_hstring(rdata);
        report "  PASS: T_SRESET_MID mid-operation soft reset";

        -- ══════════════════════════════════════════════════════════════
        -- T7 / T8 / T9 / T10 — DMA payload tests
        -- ══════════════════════════════════════════════════════════════
        if STEP3_IMPLEMENTED then

            wait for 5 * CLK_PERIOD;

            -- ── T7 : Encrypt 1-block AAD + 2-block PT ─────────────────
            report "--------------------------------------------------";
            report "  T7 : Encrypt 1-block AAD + 2-block PT (DMA)";
            report "--------------------------------------------------";

            sim_mem(0) := AAD_BLOCK;
            sim_mem(1) := PT_BLOCK_0;
            sim_mem(2) := PT_BLOCK_1;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR = 0
            axi_wr(x"034", x"00000010");  -- AAD_LEN  = 16 B
            axi_wr(x"038", x"00000010");  -- PT_ADDR  = 0x10
            axi_wr(x"03C", x"00000020");  -- PT_LEN   = 32 B
            axi_wr(x"040", x"00000030");  -- CT_ADDR  = 0x30

            start_engine('0');
            wait_done("T7", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T7 FAIL: ERROR during encrypt, CSR = " & to_hstring(csr)
                severity failure;
            assert csr(10) = '1'
                report "T7 FAIL: TAG_VALID not set"
                severity failure;

            read_tag(rd_tag);
            enc_tag <= rd_tag;
            wait for CLK_PERIOD;

            report "  CT[0] = " & to_hstring(sim_mem(3));
            report "  CT[1] = " & to_hstring(sim_mem(4));
            report "  Tag   = " & to_hstring(enc_tag);
            report "  PASS: T7 encrypt with DMA";

            -- ── T8a : Decrypt round-trip ───────────────────────────────
            report "--------------------------------------------------";
            report "  T8a: Decrypt round-trip (CT -> PT)";
            report "--------------------------------------------------";

            wait for 3 * CLK_PERIOD;

            -- Decrypt: CT_ADDR = ciphertext source (gcm reads from ct_addr_i)
            --          PT_ADDR = plaintext dest  (gcm writes to pt_addr_i)
            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR = 0
            axi_wr(x"034", x"00000010");  -- AAD_LEN
            axi_wr(x"038", x"00000010");  -- PT_ADDR = 0x10 (plaintext dest)
            axi_wr(x"03C", x"00000020");  -- LEN = 32 B
            axi_wr(x"040", x"00000030");  -- CT_ADDR = 0x30 (ciphertext source)
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
                report "T8a FAIL: PT[0] mismatch after decrypt"
                severity failure;
            assert sim_mem(2) = PT_BLOCK_1
                report "T8a FAIL: PT[1] mismatch after decrypt"
                severity failure;

            report "  PT[0] = " & to_hstring(sim_mem(1)) &
                   "  (expect " & to_hstring(PT_BLOCK_0) & ")";
            report "  PT[1] = " & to_hstring(sim_mem(2)) &
                   "  (expect " & to_hstring(PT_BLOCK_1) & ")";
            report "  PASS: T8a round-trip decrypt";

            -- ── T8b : Tampered CT ──────────────────────────────────────
            report "--------------------------------------------------";
            report "  T8b: Tampered CT -> CSR.ERROR";
            report "--------------------------------------------------";

            wait for 3 * CLK_PERIOD;

            sim_mem(3) := sim_mem(3) xor x"00000000000000000000000000000001";

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000010");
            axi_wr(x"038", x"00000010");  -- PT_ADDR = plaintext dest
            axi_wr(x"03C", x"00000020");
            axi_wr(x"040", x"00000030");  -- CT_ADDR = ciphertext source (tampered)
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

            -- ── T9 : Back-to-back encrypt (tests adapter re-arm + key cache) ──
            report "--------------------------------------------------";
            report "  T9 : Back-to-back encrypt (same key, new IV)";
            report "--------------------------------------------------";

            wait for 5 * CLK_PERIOD;

            -- Re-load plaintext (T8b decrypt may have overwritten sim_mem(1/2))
            sim_mem(0) := AAD_BLOCK;
            sim_mem(1) := PT_BLOCK_0;
            sim_mem(2) := PT_BLOCK_1;

            -- Use a different IV to ensure we produce a different CT/tag
            write_key(KEY);
            write_iv(IV2);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000010");
            axi_wr(x"038", x"00000010");
            axi_wr(x"03C", x"00000020");
            axi_wr(x"040", x"00000030");

            start_engine('0');
            wait_done("T9", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T9 FAIL: ERROR during second encrypt"
                severity failure;
            assert csr(10) = '1'
                report "T9 FAIL: TAG_VALID not set"
                severity failure;

            read_tag(rd_tag);
            enc_tag_t9 <= rd_tag;
            wait for CLK_PERIOD;

            -- Tags must differ (different IV)
            assert enc_tag_t9 /= enc_tag
                report "T9 FAIL: tag identical to T7 (IV was not applied)"
                severity failure;

            -- Decrypt with IV2 tag to verify correctness
            wait for 3 * CLK_PERIOD;

            write_key(KEY);
            write_iv(IV2);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000010");
            axi_wr(x"038", x"00000010");  -- PT_ADDR = plaintext dest (0x10)
            axi_wr(x"03C", x"00000020");
            axi_wr(x"040", x"00000030");  -- CT_ADDR = ciphertext source (0x30)
            axi_wr(x"048", enc_tag_t9(127 downto 96));
            axi_wr(x"04C", enc_tag_t9( 95 downto 64));
            axi_wr(x"050", enc_tag_t9( 63 downto 32));
            axi_wr(x"054", enc_tag_t9( 31 downto  0));

            start_engine('1');
            wait_done("T9-dec", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T9 FAIL: auth_fail on T9 round-trip"
                severity failure;
            assert sim_mem(1) = PT_BLOCK_0
                report "T9 FAIL: PT[0] mismatch"
                severity failure;
            assert sim_mem(2) = PT_BLOCK_1
                report "T9 FAIL: PT[1] mismatch"
                severity failure;

            report "  T9 Tag (IV2) = " & to_hstring(enc_tag_t9);
            report "  PASS: T9 back-to-back encrypt/decrypt";

            -- ── T10 : AAD=0, PT=1 block (GCTR-only DMA path) ──────────
            report "--------------------------------------------------";
            report "  T10: Encrypt AAD=0, PT=1 block (no AAD DMA)";
            report "--------------------------------------------------";

            wait for 5 * CLK_PERIOD;

            sim_mem(5) := PT_BLOCK_T10;  -- block index 5 = byte addr 0x050

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR (irrelevant)
            axi_wr(x"034", x"00000000");  -- AAD_LEN  = 0
            axi_wr(x"038", x"00000050");  -- PT_ADDR  = 0x50
            axi_wr(x"03C", x"00000010");  -- PT_LEN   = 16 B
            axi_wr(x"040", x"00000060");  -- CT_ADDR  = 0x60

            start_engine('0');
            wait_done("T10", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T10 FAIL: ERROR during AAD=0 encrypt"
                severity failure;
            assert csr(10) = '1'
                report "T10 FAIL: TAG_VALID not set"
                severity failure;

            read_tag(rd_tag);
            enc_tag <= rd_tag;
            wait for CLK_PERIOD;

            -- Round-trip decrypt
            wait for 3 * CLK_PERIOD;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0
            axi_wr(x"038", x"00000050");  -- PT_ADDR = 0x50 (plaintext dest)
            axi_wr(x"03C", x"00000010");
            axi_wr(x"040", x"00000060");  -- CT_ADDR = 0x60 (ciphertext source)
            axi_wr(x"048", enc_tag(127 downto 96));
            axi_wr(x"04C", enc_tag( 95 downto 64));
            axi_wr(x"050", enc_tag( 63 downto 32));
            axi_wr(x"054", enc_tag( 31 downto  0));

            start_engine('1');
            wait_done("T10-dec", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T10 FAIL: auth_fail on T10 round-trip"
                severity failure;
            assert sim_mem(5) = PT_BLOCK_T10
                report "T10 FAIL: PT mismatch after AAD=0 decrypt"
                severity failure;

            report "  T10 Tag = " & to_hstring(enc_tag);
            report "  T10 PT recovered = " & to_hstring(sim_mem(5));
            report "  PASS: T10 AAD=0, PT=1 block";

            -- ── T11 : 4-block PT burst, no AAD ────────────────────────
            -- Stresses burst counter, block_join/split FIFOs, and
            -- address generation across 4 consecutive 128-bit blocks.
            report "--------------------------------------------------";
            report "  T11: 4-block PT burst, AAD=0 (DMA stress)";
            report "--------------------------------------------------";

            wait for 5 * CLK_PERIOD;

            sim_mem(7)  := PT_BLOCK_0;
            sim_mem(8)  := PT_BLOCK_1;
            sim_mem(9)  := PT_BLOCK_2;
            sim_mem(10) := PT_BLOCK_3;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");  -- AAD_ADDR (irrelevant)
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0
            axi_wr(x"038", "00" & ADDR_PT4);
            axi_wr(x"03C", "00" & LEN_PT4);
            axi_wr(x"040", "00" & ADDR_CT4);

            start_engine('0');
            wait_done("T11", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T11 FAIL: ERROR during 4-block encrypt, CSR = " & to_hstring(csr)
                severity failure;
            assert csr(10) = '1'
                report "T11 FAIL: TAG_VALID not set"
                severity failure;

            read_tag(rd_tag);
            enc_tag <= rd_tag;
            wait for CLK_PERIOD;

            report "  CT[0] = " & to_hstring(sim_mem(11));
            report "  CT[1] = " & to_hstring(sim_mem(12));
            report "  CT[2] = " & to_hstring(sim_mem(13));
            report "  CT[3] = " & to_hstring(sim_mem(14));
            report "  Tag   = " & to_hstring(enc_tag);

            -- Decrypt round-trip
            wait for 3 * CLK_PERIOD;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0
            axi_wr(x"038", "00" & ADDR_PT4);
            axi_wr(x"03C", "00" & LEN_PT4);
            axi_wr(x"040", "00" & ADDR_CT4);
            axi_wr(x"048", enc_tag(127 downto 96));
            axi_wr(x"04C", enc_tag( 95 downto 64));
            axi_wr(x"050", enc_tag( 63 downto 32));
            axi_wr(x"054", enc_tag( 31 downto  0));

            start_engine('1');
            wait_done("T11-dec", TIMEOUT_LONG, csr);

            assert csr(11) = '0'
                report "T11 FAIL: auth_fail on 4-block round-trip"
                severity failure;
            assert sim_mem(7)  = PT_BLOCK_0
                report "T11 FAIL: PT[0] mismatch after decrypt" severity failure;
            assert sim_mem(8)  = PT_BLOCK_1
                report "T11 FAIL: PT[1] mismatch after decrypt" severity failure;
            assert sim_mem(9)  = PT_BLOCK_2
                report "T11 FAIL: PT[2] mismatch after decrypt" severity failure;
            assert sim_mem(10) = PT_BLOCK_3
                report "T11 FAIL: PT[3] mismatch after decrypt" severity failure;

            report "  PASS: T11 4-block burst encrypt/decrypt round-trip";

            -- ── T_DMA_RD_ERR : read SLVERR aborts transfer → csr_error ─
            -- dma_read_engine sets rd_error on non-OKAY rresp; GCM stalls
            -- forever (dma_rd_valid never fires); p_status sets csr_error
            -- via the elsif branch.  wait_done exits on ERROR, not DONE.
            report "--------------------------------------------------";
            report "  T_DMA_RD_ERR: DMA read SLVERR -> csr_error";
            report "--------------------------------------------------";

            wait for 5 * CLK_PERIOD;

            sim_mem(1) := PT_BLOCK_0;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0
            axi_wr(x"038", x"00000010");  -- PT_ADDR = 0x10
            axi_wr(x"03C", x"00000010");  -- PT_LEN  = 16 B
            axi_wr(x"040", x"00000030");  -- CT_ADDR = 0x30

            dma_inject_rd_error <= '1';
            start_engine('0');
            wait_done("T_DMA_RD_ERR", TIMEOUT_SHORT, csr);
            dma_inject_rd_error <= '0';

            assert csr(11) = '1'
                report "T_DMA_RD_ERR FAIL: csr_error not set, CSR = " & to_hstring(csr)
                severity failure;
            assert csr(9) = '0'
                report "T_DMA_RD_ERR FAIL: DONE set (should stall on rd error)"
                severity failure;
            report "  CSR = " & to_hstring(csr) & "  (expect bit11=ERROR, bit9=0)";
            -- GCM is stuck; recover with soft reset
            axi_wr(x"058", x"00000002");
            wait for 5 * CLK_PERIOD;
            report "  PASS: T_DMA_RD_ERR read error propagated to csr_error";

            -- ── T_DMA_WR_ERR : write SLVERR after block accepted → csr_error
            -- block_split accepts the block (wr_block_accepted → dma_wr_done)
            -- so GCM can complete; write engine then sees SLVERR on B channel
            -- and asserts wr_error.  p_status sets csr_error via done branch
            -- (if error fires simultaneously) or via elsif (if after done).
            -- Verified by reading CSR after a short settle window.
            report "--------------------------------------------------";
            report "  T_DMA_WR_ERR: DMA write SLVERR -> csr_error";
            report "--------------------------------------------------";

            wait for 5 * CLK_PERIOD;

            sim_mem(1) := PT_BLOCK_0;

            write_key(KEY);
            write_iv(IV);
            axi_wr(x"030", x"00000000");
            axi_wr(x"034", x"00000000");  -- AAD_LEN = 0
            axi_wr(x"038", x"00000010");  -- PT_ADDR = 0x10
            axi_wr(x"03C", x"00000010");  -- PT_LEN  = 16 B
            axi_wr(x"040", x"00000030");  -- CT_ADDR = 0x30

            dma_inject_wr_error <= '1';
            start_engine('0');
            wait_done("T_DMA_WR_ERR", TIMEOUT_SHORT, csr);
            dma_inject_wr_error <= '0';
            -- wait_done exits on DONE or ERROR; write error may fire slightly
            -- after gcm_done, so give p_status one more poll cycle to latch it
            wait for 10 * CLK_PERIOD;
            axi_read(x"058", rdata);

            assert rdata(11) = '1'
                report "T_DMA_WR_ERR FAIL: csr_error not set, CSR = " & to_hstring(rdata)
                severity failure;
            report "  CSR = " & to_hstring(rdata) & "  (expect bit11=ERROR)";
            axi_wr(x"058", x"00000002");
            wait for 5 * CLK_PERIOD;
            report "  PASS: T_DMA_WR_ERR write error propagated to csr_error";

        else
            report "--------------------------------------------------";
            report "  T7-T11 + T_DMA_RD_ERR/WR_ERR SKIPPED: STEP3_IMPLEMENTED = false";
            report "--------------------------------------------------";
        end if;

        report "--------------------------------------------------";
        report "  ALL TESTS PASSED";
        report "--------------------------------------------------";
        std.env.finish;

    end process stimulus;

end architecture bench;
