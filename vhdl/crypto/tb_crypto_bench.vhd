-- tb_crypto_bench -- cycle-accurate performance benchmark for crypto.vhd
--
-- Measures clock cycles for every significant phase.  Uses a free-running
-- cycle counter and a dedicated DMA-monitor process (records timestamps with
-- +/-1 cycle resolution).  IRQ rising-edge is used instead of CSR polling for
-- accurate done-time capture.  sw(0)='0' keeps the IRQ output ungated.
--
-- Sections
--   S1  AXI control-plane latency
--   S2  Key-schedule + H-precompute overhead (cold vs warm)
--   S3  Encrypt throughput: PT=1..16 blocks, AAD=0, warm key
--   S4  Encrypt throughput: PT=1..8  blocks, AAD=0, cold key
--   S5  AAD contribution: fixed PT=4, AAD=0..8, warm
--   S6  Decrypt throughput: PT=1..8 blocks, warm round-trip
--   S7  DMA read bandwidth: AAD-only (no write path)
--   S8  Per-component cycle estimates (derived from S3)
--   S9  Bottleneck analysis
--
-- Column key printed at runtime:
--   total = START-ack -> IRQ in cycles
--   ks+h  = key-schedule + H-precompute (0 when warm/cached)
--   rd    = first AR -> last R   (read-channel active window)
--   wr    = first AW -> last B   (write-channel active window)
--   post  = last AXI activity -> IRQ  (GHASH-final + tag)
--   Mbps  = payload throughput at CLK_MHZ

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_crypto_bench is
    generic (
        CLK_MHZ : positive := 100;
        MEM_LAT : positive := 4       -- dma_mem_model read latency (cycles)
    );
end entity tb_crypto_bench;

architecture bench of tb_crypto_bench is

    constant CLK_PERIOD : time := (1000 / CLK_MHZ) * 1 ns;
    constant TIMEOUT    : time := 2 ms;

    constant KEY  : std_ulogic_vector(255 downto 0) :=
        x"2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604";
    constant KEY2 : std_ulogic_vector(255 downto 0) :=
        x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    constant IV   : std_ulogic_vector(95 downto 0) :=
        x"cafebabe1234567800000001";

    -- Memory regions (30-bit byte addresses)
    -- blocks  0-15 (0x000-0x0F0) : AAD source
    -- blocks 16-31 (0x100-0x1F0) : PT source
    -- blocks 32-47 (0x200-0x2F0) : CT destination
    -- blocks 48-63 (0x300-0x3F0) : decrypt-output destination
    constant ADDR_AAD : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned( 0 * 16, 30));
    constant ADDR_PT  : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(16 * 16, 30));
    constant ADDR_CT  : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(32 * 16, 30));
    constant ADDR_DEC : std_ulogic_vector(29 downto 0) :=
        std_ulogic_vector(to_unsigned(48 * 16, 30));

    type mem_t is array(0 to 63) of std_ulogic_vector(127 downto 0);
    shared variable sim_mem : mem_t := (others => (others => '0'));

    -- DUT signals
    signal aclk    : std_ulogic := '0';
    signal aresetn : std_ulogic := '0';

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

    signal m0_araddr  : std_ulogic_vector(29 downto 0);
    signal m0_arvalid : std_ulogic;
    signal m0_arready : std_ulogic := '0';
    signal m0_rdata   : std_ulogic_vector(31 downto 0) := (others => '0');
    signal m0_rresp   : std_ulogic_vector( 1 downto 0) := "00";
    signal m0_rvalid  : std_ulogic := '0';
    signal m0_rready  : std_ulogic;
    signal m0_awaddr  : std_ulogic_vector(29 downto 0);
    signal m0_awvalid : std_ulogic;
    signal m0_awready : std_ulogic := '0';
    signal m0_wdata   : std_ulogic_vector(31 downto 0);
    signal m0_wstrb   : std_ulogic_vector( 3 downto 0);
    signal m0_wvalid  : std_ulogic;
    signal m0_wready  : std_ulogic := '0';
    signal m0_bresp   : std_ulogic_vector( 1 downto 0) := "00";
    signal m0_bvalid  : std_ulogic := '0';
    signal m0_bready  : std_ulogic;

    signal sw  : std_ulogic_vector(3 downto 0) := "0000"; -- sw(0)=0: IRQ ungated
    signal btn : std_ulogic_vector(3 downto 0) := "0000";
    signal led : std_ulogic_vector(3 downto 0);
    signal irq : std_ulogic;

    -- Free-running cycle counter
    signal cyc_ctr : natural := 0;

    -- DMA monitor outputs (driven exclusively by p_dma_monitor)
    signal bench_armed    : std_ulogic := '0';
    signal bench_reset_s  : std_ulogic := '0';
    signal bench_rd_first : natural := 0; -- cyc_ctr at first AR valid
    signal bench_rd_last  : natural := 0; -- cyc_ctr at last  R  valid+ready
    signal bench_wr_first : natural := 0; -- cyc_ctr at first AW valid
    signal bench_wr_last  : natural := 0; -- cyc_ctr at last  B  valid+ready
    signal bench_rd_words : natural := 0; -- total AXI R  completions seen
    signal bench_wr_words : natural := 0; -- total AXI B  completions seen

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    p_cyc : process(aclk) is
    begin
        if rising_edge(aclk) then cyc_ctr <= cyc_ctr + 1; end if;
    end process p_cyc;

    u_dut : entity work.crypto
        port map (
            aclk             => aclk,            aresetn          => aresetn,
            s0_axi_awaddr    => s0_awaddr,        s0_axi_awvalid   => s0_awvalid,
            s0_axi_awready   => s0_awready,       s0_axi_wdata     => s0_wdata,
            s0_axi_wstrb     => s0_wstrb,         s0_axi_wvalid    => s0_wvalid,
            s0_axi_wready    => s0_wready,        s0_axi_bresp     => s0_bresp,
            s0_axi_bvalid    => s0_bvalid,        s0_axi_bready    => s0_bready,
            s0_axi_araddr    => s0_araddr,        s0_axi_arvalid   => s0_arvalid,
            s0_axi_arready   => s0_arready,       s0_axi_rdata     => s0_rdata,
            s0_axi_rresp     => s0_rresp,         s0_axi_rvalid    => s0_rvalid,
            s0_axi_rready    => s0_rready,
            m0_axi_araddr    => m0_araddr,        m0_axi_arvalid   => m0_arvalid,
            m0_axi_arready   => m0_arready,       m0_axi_rdata     => m0_rdata,
            m0_axi_rresp     => m0_rresp,         m0_axi_rvalid    => m0_rvalid,
            m0_axi_rready    => m0_rready,
            m0_axi_awaddr    => m0_awaddr,        m0_axi_awvalid   => m0_awvalid,
            m0_axi_awready   => m0_awready,       m0_axi_wdata     => m0_wdata,
            m0_axi_wstrb     => m0_wstrb,         m0_axi_wvalid    => m0_wvalid,
            m0_axi_wready    => m0_wready,        m0_axi_bresp     => m0_bresp,
            m0_axi_bvalid    => m0_bvalid,        m0_axi_bready    => m0_bready,
            sw => sw, btn => btn, led => led, irq => irq
        );

    -- Behavioural DDR memory: 64 blocks, AR->R latency = MEM_LAT cycles
    dma_mem_model : process(aclk) is
        variable rd_pend  : boolean := false;
        variable rd_blk, rd_word, rd_cnt_v : integer := 0;
        variable wr_blk, wr_word           : integer := 0;
        variable wr_buf : std_ulogic_vector(127 downto 0);
    begin
        if rising_edge(aclk) then
            m0_arready <= '0'; m0_rvalid  <= '0';
            m0_awready <= '0'; m0_wready  <= '0'; m0_bvalid  <= '0';
            if aresetn = '0' then
                rd_pend := false;
            else
                if m0_arvalid = '1' and not rd_pend then
                    m0_arready <= '1';
                    rd_blk     := to_integer(unsigned(m0_araddr(29 downto 4)));
                    rd_word    := to_integer(unsigned(m0_araddr( 3 downto 2)));
                    rd_cnt_v   := MEM_LAT;
                    rd_pend    := true;
                end if;
                if rd_pend then
                    rd_cnt_v := rd_cnt_v - 1;
                    if rd_cnt_v = 0 then
                        case rd_word is
                            when 0 => m0_rdata <= sim_mem(rd_blk)(127 downto 96);
                            when 1 => m0_rdata <= sim_mem(rd_blk)( 95 downto 64);
                            when 2 => m0_rdata <= sim_mem(rd_blk)( 63 downto 32);
                            when 3 => m0_rdata <= sim_mem(rd_blk)( 31 downto  0);
                            when others => m0_rdata <= (others => '0');
                        end case;
                        m0_rresp  <= "00"; m0_rvalid <= '1'; rd_pend := false;
                    end if;
                end if;
                if m0_awvalid = '1' and m0_wvalid = '1' then
                    m0_awready <= '1'; m0_wready <= '1';
                    wr_blk  := to_integer(unsigned(m0_awaddr(29 downto 4)));
                    wr_word := to_integer(unsigned(m0_awaddr( 3 downto 2)));
                    wr_buf  := sim_mem(wr_blk);
                    case wr_word is
                        when 0 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_buf(127-i*8 downto 120-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 1 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_buf(95-i*8 downto 88-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 2 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_buf(63-i*8 downto 56-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when 3 =>
                            for i in 0 to 3 loop
                                if m0_wstrb(3-i) = '1' then
                                    wr_buf(31-i*8 downto 24-i*8) := m0_wdata(31-i*8 downto 24-i*8);
                                end if;
                            end loop;
                        when others => null;
                    end case;
                    sim_mem(wr_blk) := wr_buf;
                    m0_bresp <= "00"; m0_bvalid <= '1';
                end if;
                if m0_bvalid = '1' and m0_bready = '1' then m0_bvalid <= '0'; end if;
            end if;
        end if;
    end process dma_mem_model;

    -- DMA event monitor: latches cyc_ctr on first/last AR and first/last B
    p_dma_monitor : process(aclk) is
        variable rd_w_v : natural := 0;
        variable wr_w_v : natural := 0;
    begin
        if rising_edge(aclk) then
            if bench_reset_s = '1' then
                bench_rd_first <= 0; bench_rd_last  <= 0;
                bench_wr_first <= 0; bench_wr_last  <= 0;
                bench_rd_words <= 0; bench_wr_words <= 0;
                rd_w_v := 0; wr_w_v := 0;
            elsif bench_armed = '1' then
                if m0_arvalid = '1' and rd_w_v = 0 then
                    bench_rd_first <= cyc_ctr;
                end if;
                if m0_rvalid = '1' and m0_rready = '1' then
                    bench_rd_last  <= cyc_ctr;
                    rd_w_v := rd_w_v + 1;
                    bench_rd_words <= rd_w_v;
                end if;
                if m0_awvalid = '1' and wr_w_v = 0 then
                    bench_wr_first <= cyc_ctr;
                end if;
                if m0_bvalid = '1' and m0_bready = '1' then
                    bench_wr_last  <= cyc_ctr;
                    wr_w_v := wr_w_v + 1;
                    bench_wr_words <= wr_w_v;
                end if;
            end if;
        end if;
    end process p_dma_monitor;

    -- =========================================================================
    stimulus : process is

        -- AXI BFM
        procedure axi_write (
            addr : in  std_ulogic_vector(11 downto 0);
            data : in  std_ulogic_vector(31 downto 0);
            resp : out std_ulogic_vector( 1 downto 0)
        ) is
        begin
            wait until rising_edge(aclk);
            s0_awaddr <= addr;  s0_awvalid <= '1';
            s0_wdata  <= data;  s0_wstrb   <= "1111";  s0_wvalid <= '1';
            loop
                wait until rising_edge(aclk);
                if s0_awready = '1' then s0_awvalid <= '0'; end if;
                if s0_wready  = '1' then s0_wvalid  <= '0'; end if;
                exit when s0_awready = '1' and s0_wready = '1';
            end loop;
            s0_awvalid <= '0';  s0_wvalid <= '0';  s0_bready <= '1';
            wait until rising_edge(aclk) and s0_bvalid = '1';
            resp := s0_bresp;
            s0_bready <= '0';
        end procedure;

        procedure axi_wr (addr : in std_ulogic_vector(11 downto 0);
                          data : in std_ulogic_vector(31 downto 0)) is
            variable d : std_ulogic_vector(1 downto 0);
        begin axi_write(addr, data, d); end procedure;

        procedure axi_read (addr : in  std_ulogic_vector(11 downto 0);
                            data : out std_ulogic_vector(31 downto 0)) is
        begin
            wait until rising_edge(aclk);
            s0_araddr <= addr;  s0_arvalid <= '1';
            wait until rising_edge(aclk) and s0_arready = '1';
            s0_arvalid <= '0';  s0_rready  <= '1';
            wait until rising_edge(aclk) and s0_rvalid  = '1';
            data := s0_rdata;   s0_rready  <= '0';
        end procedure;

        procedure write_key (k : in std_ulogic_vector(255 downto 0)) is
        begin
            axi_wr(x"000", k(255 downto 224)); axi_wr(x"004", k(223 downto 192));
            axi_wr(x"008", k(191 downto 160)); axi_wr(x"00C", k(159 downto 128));
            axi_wr(x"010", k(127 downto  96)); axi_wr(x"014", k( 95 downto  64));
            axi_wr(x"018", k( 63 downto  32)); axi_wr(x"01C", k( 31 downto   0));
        end procedure;

        procedure write_iv (iv_v : in std_ulogic_vector(95 downto 0)) is
        begin
            axi_wr(x"020", iv_v(95 downto 64));
            axi_wr(x"024", iv_v(63 downto 32));
            axi_wr(x"028", iv_v(31 downto  0));
        end procedure;

        procedure read_tag (tag : out std_ulogic_vector(127 downto 0)) is
            variable w : std_ulogic_vector(31 downto 0);
        begin
            axi_read(x"048", w); tag(127 downto 96) := w;
            axi_read(x"04C", w); tag( 95 downto 64) := w;
            axi_read(x"050", w); tag( 63 downto 32) := w;
            axi_read(x"054", w); tag( 31 downto  0) := w;
        end procedure;

        procedure start_op (mode : in std_ulogic) is
            variable v : std_ulogic_vector(31 downto 0) := (others => '0');
        begin
            v(2) := mode;  v(0) := '1';
            axi_wr(x"058", v);
        end procedure;

        procedure soft_rst is
        begin
            axi_wr(x"058", x"00000002");
            wait for 3 * CLK_PERIOD;
        end procedure;

        -- Arm the monitor and record start cycle
        procedure bench_arm (variable sc : out natural) is
        begin
            bench_reset_s <= '1';
            wait until rising_edge(aclk);
            bench_reset_s <= '0';
            wait until rising_edge(aclk);
            bench_armed   <= '1';
            sc := cyc_ctr;
        end procedure;

        -- Wait for IRQ (accurate done-time), disarm monitor, read CSR
        procedure bench_wait (
            variable dc    : out natural;
            variable csr_v : out std_ulogic_vector(31 downto 0)
        ) is
        begin
            wait until rising_edge(aclk) and irq = '1';
            dc := cyc_ctr;
            bench_armed <= '0';
            wait for 2 * CLK_PERIOD;
            axi_read(x"058", csr_v);
        end procedure;

        -- Standard encrypt configuration
        procedure cfg_enc (n_aad : in natural; n_pt : in natural;
                           k     : in std_ulogic_vector(255 downto 0)) is
        begin
            write_key(k);  write_iv(IV);
            axi_wr(x"030", "00" & ADDR_AAD);
            axi_wr(x"034", std_ulogic_vector(to_unsigned(n_aad * 16, 32)));
            axi_wr(x"038", "00" & ADDR_PT);
            axi_wr(x"03C", std_ulogic_vector(to_unsigned(n_pt  * 16, 32)));
            axi_wr(x"040", "00" & ADDR_CT);
        end procedure;

        -- Decrypt configuration (CT->DEC, provide expected tag)
        procedure cfg_dec (n_aad : in natural;  n_pt : in natural;
                           tag_v : in std_ulogic_vector(127 downto 0);
                           k     : in std_ulogic_vector(255 downto 0)) is
        begin
            write_key(k);  write_iv(IV);
            axi_wr(x"030", "00" & ADDR_AAD);
            axi_wr(x"034", std_ulogic_vector(to_unsigned(n_aad * 16, 32)));
            axi_wr(x"038", "00" & ADDR_DEC);
            axi_wr(x"03C", std_ulogic_vector(to_unsigned(n_pt  * 16, 32)));
            axi_wr(x"040", "00" & ADDR_CT);
            axi_wr(x"048", tag_v(127 downto 96));
            axi_wr(x"04C", tag_v( 95 downto 64));
            axi_wr(x"050", tag_v( 63 downto 32));
            axi_wr(x"054", tag_v( 31 downto  0));
        end procedure;

        -- Prime the key cache: zero-length encrypt, fire-and-forget
        procedure warm_up (k : in std_ulogic_vector(255 downto 0)) is
        begin
            write_key(k);  write_iv(IV);
            axi_wr(x"030", x"00000000");  axi_wr(x"034", x"00000000");
            axi_wr(x"038", x"00000000");  axi_wr(x"03C", x"00000000");
            axi_wr(x"040", x"00000000");
            start_op('0');
            wait until rising_edge(aclk) and irq = '1';
            wait for 2 * CLK_PERIOD;
        end procedure;

        -- Right-pad integer to width w
        function pad (v : integer; w : positive) return string is
            constant s : string := integer'image(v);
        begin
            if s'length >= w then return s; end if;
            return (1 to w - s'length => ' ') & s;
        end function;

        -- Print one benchmark row.
        -- Computes breakdown from monitor signals and parameters.
        procedure bench_report (
            lbl   : in string;
            n_aad : in natural;
            n_pt  : in natural;
            sc    : in natural;
            dc    : in natural
        ) is
            variable total_c, ks_h_c, rd_span, wr_span   : integer;
            variable dma_start, last_axi, post_c          : integer;
            variable payload, tput_mbps                   : integer;
            variable rd_f, rd_l, wr_f, wr_l               : integer;
        begin
            total_c := dc - sc;
            rd_f    := bench_rd_first;
            rd_l    := bench_rd_last;
            wr_f    := bench_wr_first;
            wr_l    := bench_wr_last;

            if bench_rd_words > 0 then
                ks_h_c   := rd_f - sc;
                rd_span  := rd_l - rd_f;
                dma_start := rd_f;
                if bench_wr_words > 0 then
                    wr_span := wr_l - wr_f;
                    if rd_l > wr_l then
                        last_axi := rd_l;
                    else
                        last_axi := wr_l;
                    end if;
                else
                    wr_span  := 0;
                    last_axi := rd_l;
                end if;
                post_c := dc - last_axi;
            else
                -- No DMA: entire cost is crypto init (KS+H+tag)
                ks_h_c   := total_c;
                rd_span  := 0;
                wr_span  := 0;
                post_c   := 0;
            end if;

            payload := (n_aad + n_pt) * 16;
            if total_c > 0 then
                tput_mbps := (payload * 8 * CLK_MHZ) / total_c;
            else
                tput_mbps := 0;
            end if;

            report
                "  " & lbl &
                "  total=" & pad(total_c,   5) & " cy" &
                "  ks+h="  & pad(ks_h_c,    4) &
                "  rd="    & pad(rd_span,    4) &
                "  wr="    & pad(wr_span,    4) &
                "  post="  & pad(post_c,     4) &
                "  "       & pad(payload,    4) & "B" &
                "  "       & pad(tput_mbps,  5) & " Mbps" &
                "  [rw=" & integer'image(bench_rd_words) &
                "/"      & integer'image(bench_wr_words) & "]";
        end procedure;

        -- Run one operation and report; asserts no CSR.ERROR
        procedure bench_op (
            lbl   : in string;
            n_aad : in natural;
            n_pt  : in natural;
            mode  : in std_ulogic;
            variable sc : out natural;
            variable dc : out natural
        ) is
            variable csr_v : std_ulogic_vector(31 downto 0);
        begin
            bench_arm(sc);
            start_op(mode);
            bench_wait(dc, csr_v);
            assert csr_v(11) = '0'
                report "BENCH FAIL " & lbl & ": CSR.ERROR set, CSR=" &
                       to_hstring(csr_v)
                severity failure;
            bench_report(lbl, n_aad, n_pt, sc, dc);
        end procedure;

        -- Scratch variables
        variable sc, dc        : natural;
        variable sc2, dc2      : natural;
        variable rdata         : std_ulogic_vector(31 downto 0);
        variable tag_v         : std_ulogic_vector(127 downto 0);
        variable t0, t1        : natural;
        variable v_cold, v_warm, v_diff, v_marginal : integer;
        variable v_tot1, v_tot4, v_tot8             : integer;
        variable v_rd_span8, v_wr_span8             : integer;
        variable v_post        : integer;
        variable v_rdpw, v_wrpw                     : integer;

    begin

        report "================================================";
        report "  tb_crypto_bench  --  crypto.vhd";
        report "  Clock: " & integer'image(CLK_MHZ) & " MHz"
             & "   Mem-lat: " & integer'image(MEM_LAT) & " cy";
        report "================================================";
        report "  Columns: total ks+h rd wr post payload Mbps [r-words/w-words]";
        report "================================================";

        aresetn <= '0';
        wait for 10 * CLK_PERIOD;
        aresetn <= '1';
        wait for  2 * CLK_PERIOD;

        -- Initialise PT and AAD memory regions
        for b in 0 to 15 loop
            sim_mem(16 + b) :=
                std_ulogic_vector(to_unsigned((b * 17 + 1) mod 256, 8)) &
                std_ulogic_vector(to_unsigned( b,                    8)) &
                x"02030405060708090a0b0c0d0e0f";
            sim_mem(b) :=
                x"aad0" &
                std_ulogic_vector(to_unsigned(b, 8)) &
                x"00000000000000000000000000";
        end loop;

        -- ================================================================
        -- S1  AXI control-plane latency
        -- ================================================================
        report "------------------------------------------------";
        report "  S1: AXI control-plane latency";
        report "------------------------------------------------";

        t0 := cyc_ctr;
        write_key(KEY);     -- 8 writes
        t1 := cyc_ctr;
        report "  Write x8 (KEY regs) : " & integer'image(t1 - t0)
             & " cy  (" & integer'image((t1 - t0) / 8) & " cy/write)";

        t0 := cyc_ctr;
        for i in 0 to 7 loop axi_read(x"058", rdata); end loop;
        t1 := cyc_ctr;
        report "  Read  x8 (CSR)      : " & integer'image(t1 - t0)
             & " cy  (" & integer'image((t1 - t0) / 8) & " cy/read)";

        -- ================================================================
        -- S2  Key-schedule + H-precompute overhead
        -- ================================================================
        report "------------------------------------------------";
        report "  S2: Key-schedule + H overhead (zero-length)";
        report "  cold = soft-reset before each; warm = same key";
        report "------------------------------------------------";

        for trial in 1 to 3 loop
            soft_rst;
            write_key(KEY);  write_iv(IV);
            axi_wr(x"030", x"00000000");  axi_wr(x"034", x"00000000");
            axi_wr(x"038", x"00000000");  axi_wr(x"03C", x"00000000");
            axi_wr(x"040", x"00000000");
            bench_arm(sc);
            start_op('0');
            bench_wait(dc, rdata);
            bench_report("cold #" & integer'image(trial), 0, 0, sc, dc);
        end loop;

        warm_up(KEY);
        for trial in 1 to 3 loop
            write_key(KEY);  write_iv(IV);
            axi_wr(x"030", x"00000000");  axi_wr(x"034", x"00000000");
            axi_wr(x"038", x"00000000");  axi_wr(x"03C", x"00000000");
            axi_wr(x"040", x"00000000");
            bench_arm(sc);
            start_op('0');
            bench_wait(dc, rdata);
            bench_report("warm #" & integer'image(trial), 0, 0, sc, dc);
        end loop;

        -- ================================================================
        -- S3  Encrypt throughput -- AAD=0, PT=1..16 blocks, warm key
        -- ================================================================
        report "------------------------------------------------";
        report "  S3: Encrypt throughput (AAD=0, warm key)";
        report "------------------------------------------------";

        warm_up(KEY);
        for n in 1 to 8 loop
            cfg_enc(0, n, KEY);
            bench_op("enc PT=" & integer'image(n) & " warm",
                     0, n, '0', sc, dc);
        end loop;
        cfg_enc(0, 12, KEY);
        bench_op("enc PT=12  warm", 0, 12, '0', sc, dc);
        cfg_enc(0, 16, KEY);
        bench_op("enc PT=16  warm", 0, 16, '0', sc, dc);

        -- ================================================================
        -- S4  Encrypt throughput -- AAD=0, PT=1..8 blocks, cold key
        -- ================================================================
        report "------------------------------------------------";
        report "  S4: Encrypt throughput (AAD=0, cold key)";
        report "  Shows KS+H amortisation over payload";
        report "------------------------------------------------";

        for n in 1 to 8 loop
            soft_rst;
            cfg_enc(0, n, KEY);
            bench_op("enc PT=" & integer'image(n) & " cold",
                     0, n, '0', sc, dc);
        end loop;

        -- ================================================================
        -- S5  Effect of AAD length -- PT=4 fixed, warm
        -- ================================================================
        report "------------------------------------------------";
        report "  S5: AAD contribution (PT=4 fixed, warm)";
        report "------------------------------------------------";

        warm_up(KEY);
        for n_aad in 0 to 8 loop
            cfg_enc(n_aad, 4, KEY);
            bench_op("enc AAD=" & integer'image(n_aad) & " PT=4 warm",
                     n_aad, 4, '0', sc, dc);
        end loop;

        -- ================================================================
        -- S6  Decrypt throughput -- warm, round-trip
        -- ================================================================
        report "------------------------------------------------";
        report "  S6: Decrypt throughput (warm, round-trip)";
        report "------------------------------------------------";

        warm_up(KEY);
        for n in 1 to 8 loop
            cfg_enc(0, n, KEY);
            bench_arm(sc);
            start_op('0');
            bench_wait(dc, rdata);
            read_tag(tag_v);

            cfg_dec(0, n, tag_v, KEY);
            bench_op("dec PT=" & integer'image(n) & " warm",
                     0, n, '1', sc, dc);
        end loop;

        -- ================================================================
        -- S7  DMA read bandwidth -- AAD-only (zero writes)
        -- ================================================================
        report "------------------------------------------------";
        report "  S7: DMA read BW (AAD-only, no write path)";
        report "------------------------------------------------";

        warm_up(KEY);
        for n in 1 to 8 loop
            write_key(KEY);  write_iv(IV);
            axi_wr(x"030", "00" & ADDR_AAD);
            axi_wr(x"034", std_ulogic_vector(to_unsigned(n * 16, 32)));
            axi_wr(x"038", x"00000000");  axi_wr(x"03C", x"00000000");
            axi_wr(x"040", x"00000000");
            bench_op("rd-only AAD=" & integer'image(n) & " PT=0",
                     n, 0, '0', sc, dc);
        end loop;

        -- ================================================================
        -- S8  Per-component estimates (8-block warm reference)
        -- ================================================================
        report "------------------------------------------------";
        report "  S8: Per-component estimates (warm, 8-block)";
        report "------------------------------------------------";

        warm_up(KEY);
        cfg_enc(0, 1, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_tot1 := dc - sc;

        warm_up(KEY);
        cfg_enc(0, 4, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_tot4 := dc - sc;

        warm_up(KEY);
        cfg_enc(0, 8, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_tot8    := dc - sc;
        v_rd_span8 := bench_rd_last  - bench_rd_first;
        v_wr_span8 := bench_wr_last  - bench_wr_first;
        if bench_wr_words > 0 then
            if bench_rd_last > bench_wr_last then
                v_post := dc - bench_rd_last;
            else
                v_post := dc - bench_wr_last;
            end if;
        else
            v_post := dc - bench_rd_last;
        end if;

        -- Per-word timings from 8-block run (32 R-words, 32 B-words)
        if bench_rd_words > 0 then
            v_rdpw := v_rd_span8 / bench_rd_words;
        else
            v_rdpw := 0;
        end if;
        if bench_wr_words > 0 then
            v_wrpw := v_wr_span8 / bench_wr_words;
        else
            v_wrpw := 0;
        end if;

        report "  1-blk warm  = " & integer'image(v_tot1) & " cy";
        report "  4-blk warm  = " & integer'image(v_tot4) & " cy"
             & "  marginal(1->4) = " & integer'image((v_tot4-v_tot1)/3) & " cy/blk";
        report "  8-blk warm  = " & integer'image(v_tot8) & " cy"
             & "  marginal(4->8) = " & integer'image((v_tot8-v_tot4)/4) & " cy/blk";
        report "  8-blk rd_span=" & integer'image(v_rd_span8)
             & " wr_span=" & integer'image(v_wr_span8)
             & " post=" & integer'image(v_post);
        report "  DMA read : ~" & integer'image(v_rdpw)
             & " cy/AXI-word  (~" & integer'image(v_rdpw * 4)
             & " cy/128b-blk)";
        report "  DMA write: ~" & integer'image(v_wrpw)
             & " cy/AXI-word  (~" & integer'image(v_wrpw * 4)
             & " cy/128b-blk)";
        if v_rdpw > 0 then
            report "  Read  BW: ~" & integer'image(32 * CLK_MHZ / v_rdpw) & " MB/s";
        end if;
        if v_wrpw > 0 then
            report "  Write BW: ~" & integer'image(32 * CLK_MHZ / v_wrpw) & " MB/s";
        end if;

        -- ================================================================
        -- S9  Bottleneck analysis
        -- ================================================================
        report "------------------------------------------------";
        report "  S9: Bottleneck analysis";
        report "------------------------------------------------";

        -- KS+H overhead: cold vs warm on 1-block payload
        soft_rst;
        cfg_enc(0, 1, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_cold := dc - sc;

        warm_up(KEY);
        cfg_enc(0, 1, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_warm := dc - sc;

        v_diff := v_cold - v_warm;
        report "  Cold 1-blk = " & integer'image(v_cold) & " cy"
             & "   warm 1-blk = " & integer'image(v_warm) & " cy"
             & "   KS+H overhead = " & integer'image(v_diff) & " cy";
        if v_warm > 0 then
            report "  Break-even: KS amortised at payload >"
                 & integer'image(v_diff * 16 / v_warm) & " B";
        end if;

        -- Marginal cost per block (1->4 warm): pure per-block crypto+DMA cost
        warm_up(KEY);
        cfg_enc(0, 1, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_tot1 := dc - sc;

        warm_up(KEY);
        cfg_enc(0, 4, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_tot4 := dc - sc;

        v_marginal := (v_tot4 - v_tot1) / 3;
        report "  Marginal cost/block (1->4 warm) = "
             & integer'image(v_marginal) & " cy/blk";
        if v_marginal > 0 then
            report "  Steady-state throughput = "
                 & integer'image(128 * CLK_MHZ / v_marginal) & " Mbps"
                 & "  (" & integer'image(16 * CLK_MHZ / v_marginal) & " MB/s)";
        end if;

        -- GHASH-final isolation (zero-len warm vs 1-blk warm post-DMA)
        warm_up(KEY);
        write_key(KEY);  write_iv(IV);
        axi_wr(x"030", x"00000000");  axi_wr(x"034", x"00000000");
        axi_wr(x"038", x"00000000");  axi_wr(x"03C", x"00000000");
        axi_wr(x"040", x"00000000");
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_cold := dc - sc;   -- zero-len warm = fixed overhead

        warm_up(KEY);
        cfg_enc(0, 1, KEY);
        bench_arm(sc);  start_op('0');  bench_wait(dc, rdata);
        v_warm := dc - sc;
        if bench_wr_words > 0 then
            if bench_rd_last > bench_wr_last then
                v_post := dc - bench_rd_last;
            else
                v_post := dc - bench_wr_last;
            end if;
        else
            v_post := dc - bench_rd_last;
        end if;

        report "  Zero-len warm (fixed overhead) = " & integer'image(v_cold) & " cy";
        report "  1-blk warm post-DMA (GHASH-final + tag) = "
             & integer'image(v_post) & " cy";
        report "  Per-block DMA+CAST256 = "
             & integer'image(v_warm - v_cold) & " cy";

        report "================================================";
        report "  Benchmark complete.";
        report "================================================";
        std.env.finish;

    end process stimulus;

end architecture bench;
