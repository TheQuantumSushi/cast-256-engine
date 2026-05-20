-- Testbench for dma_engine (Milestone 4)
-- Uses a behavioral memory model with 2-cycle read latency / 1-cycle write latency.
-- Tests: single-block read, multi-block read, single-block write,
--        parallel read+write, RRESP error injection, BRESP error injection.
--
-- Hanging fix: rd_done and wr_done are now sticky level signals (not one-shot pulses),
-- so all "wait until done" patterns work correctly across delta-cycle boundaries.
-- Every blocking wait has an explicit timeout to catch design-level deadlocks.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dma_engine is
end entity tb_dma_engine;

architecture sim of tb_dma_engine is

    component dma_engine is
        port (
            aclk               : in  std_ulogic;
            aresetn            : in  std_ulogic;
            m0_axi_araddr      : out std_ulogic_vector(29 downto 0);
            m0_axi_arvalid     : out std_ulogic;
            m0_axi_arready     : in  std_ulogic;
            m0_axi_rdata       : in  std_ulogic_vector(31 downto 0);
            m0_axi_rresp       : in  std_ulogic_vector( 1 downto 0);
            m0_axi_rvalid      : in  std_ulogic;
            m0_axi_rready      : out std_ulogic;
            m0_axi_awaddr      : out std_ulogic_vector(29 downto 0);
            m0_axi_awvalid     : out std_ulogic;
            m0_axi_awready     : in  std_ulogic;
            m0_axi_wdata       : out std_ulogic_vector(31 downto 0);
            m0_axi_wstrb       : out std_ulogic_vector( 3 downto 0);
            m0_axi_wvalid      : out std_ulogic;
            m0_axi_wready      : in  std_ulogic;
            m0_axi_bresp       : in  std_ulogic_vector( 1 downto 0);
            m0_axi_bvalid      : in  std_ulogic;
            m0_axi_bready      : out std_ulogic;
            rd_start           : in  std_ulogic;
            rd_base_addr       : in  std_ulogic_vector(31 downto 0);
            rd_block_count     : in  std_ulogic_vector(23 downto 0);
            wr_start           : in  std_ulogic;
            wr_base_addr       : in  std_ulogic_vector(31 downto 0);
            wr_block_count     : in  std_ulogic_vector(23 downto 0);
            rd_block_data      : out std_ulogic_vector(127 downto 0);
            rd_block_valid     : out std_ulogic;
            rd_block_consumed  : in  std_ulogic;
            wr_block_data      : in  std_ulogic_vector(127 downto 0);
            wr_block_valid     : in  std_ulogic;
            wr_block_accepted  : out std_ulogic;
            rd_done            : out std_ulogic;
            wr_done            : out std_ulogic;
            dma_error          : out std_ulogic
        );
    end component;

    constant CLK_PERIOD : time    := 10 ns;
    constant TIMEOUT    : time    := 500 * CLK_PERIOD;  -- 5 us safety net per wait
    constant MEM_SIZE   : integer := 1024;

    signal aclk    : std_ulogic := '0';
    signal aresetn : std_ulogic := '0';

    -- AXI read address
    signal araddr  : std_ulogic_vector(29 downto 0);
    signal arvalid : std_ulogic;
    signal arready : std_ulogic := '0';
    -- AXI read data
    signal rdata   : std_ulogic_vector(31 downto 0) := (others => '0');
    signal rresp   : std_ulogic_vector( 1 downto 0) := "00";
    signal rvalid  : std_ulogic := '0';
    signal rready  : std_ulogic;
    -- AXI write address
    signal awaddr  : std_ulogic_vector(29 downto 0);
    signal awvalid : std_ulogic;
    signal awready : std_ulogic := '0';
    -- AXI write data
    signal wdata   : std_ulogic_vector(31 downto 0);
    signal wstrb   : std_ulogic_vector( 3 downto 0);
    signal wvalid  : std_ulogic;
    signal wready  : std_ulogic := '0';
    -- AXI write response
    signal bresp   : std_ulogic_vector( 1 downto 0) := "00";
    signal bvalid  : std_ulogic := '0';
    signal bready  : std_ulogic;

    -- Free-running cycle counter for throughput measurement
    signal cycle_count : natural := 0;

    -- DMA control
    signal rd_start     : std_ulogic := '0';
    signal rd_base      : std_ulogic_vector(31 downto 0) := (others => '0');
    signal rd_blk_count : std_ulogic_vector(23 downto 0) := (others => '0');
    signal wr_start     : std_ulogic := '0';
    signal wr_base      : std_ulogic_vector(31 downto 0) := (others => '0');
    signal wr_blk_count : std_ulogic_vector(23 downto 0) := (others => '0');

    signal rd_block_data  : std_ulogic_vector(127 downto 0);
    signal rd_block_valid : std_ulogic;
    signal rd_consumed    : std_ulogic := '0';
    signal wr_block_data  : std_ulogic_vector(127 downto 0) := (others => '0');
    signal wr_block_valid : std_ulogic := '0';
    signal wr_accepted    : std_ulogic;
    signal rd_done        : std_ulogic;
    signal wr_done        : std_ulogic;
    signal dma_error      : std_ulogic;

    -- Behavioral memory (byte-addressed), initialised with pattern i mod 256
    type mem_t is array (0 to MEM_SIZE-1) of std_ulogic_vector(7 downto 0);
    function init_mem return mem_t is
        variable m : mem_t;
    begin
        for i in 0 to MEM_SIZE-1 loop
            m(i) := std_ulogic_vector(to_unsigned(i mod 256, 8));
        end loop;
        return m;
    end function;
    signal mem : mem_t := init_mem;

    -- Error injection
    signal inject_rresp_err   : std_ulogic := '0';
    signal inject_bresp_err   : std_ulogic := '0';
    signal inject_word_target : integer    := -1;
    signal read_word_count    : integer    := 0;
    signal write_word_count   : integer    := 0;
    signal rd_count_reset     : std_ulogic := '0';
    signal wr_count_reset     : std_ulogic := '0';

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    p_cycle : process(aclk)
    begin
        if rising_edge(aclk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process p_cycle;

    u_dut : dma_engine
        port map (
            aclk => aclk, aresetn => aresetn,
            m0_axi_araddr  => araddr,  m0_axi_arvalid => arvalid,
            m0_axi_arready => arready,
            m0_axi_rdata   => rdata,   m0_axi_rresp  => rresp,
            m0_axi_rvalid  => rvalid,  m0_axi_rready => rready,
            m0_axi_awaddr  => awaddr,  m0_axi_awvalid => awvalid,
            m0_axi_awready => awready,
            m0_axi_wdata   => wdata,   m0_axi_wstrb  => wstrb,
            m0_axi_wvalid  => wvalid,  m0_axi_wready => wready,
            m0_axi_bresp   => bresp,   m0_axi_bvalid => bvalid,
            m0_axi_bready  => bready,
            rd_start       => rd_start,  rd_base_addr   => rd_base,
            rd_block_count => rd_blk_count,
            wr_start       => wr_start,  wr_base_addr   => wr_base,
            wr_block_count => wr_blk_count,
            rd_block_data  => rd_block_data,  rd_block_valid    => rd_block_valid,
            rd_block_consumed => rd_consumed,
            wr_block_data  => wr_block_data,  wr_block_valid    => wr_block_valid,
            wr_block_accepted => wr_accepted,
            rd_done => rd_done, wr_done => wr_done, dma_error => dma_error
        );

    ---------------------------------------------------------------------------
    -- Behavioral memory model — read channel (2-cycle latency)
    ---------------------------------------------------------------------------
    p_mem_read : process(aclk)
        variable lat   : integer    := 0;
        variable pend  : std_ulogic := '0';
        variable paddr : integer    := 0;
    begin
        if rising_edge(aclk) then
            if rd_count_reset = '1' then read_word_count <= 0; end if;
            arready <= '0';
            rvalid  <= '0';

            if arvalid = '1' and pend = '0' then
                arready <= '1';
                paddr   := to_integer(unsigned(araddr));
                pend    := '1';
                lat     := 0;
            end if;

            if pend = '1' then
                lat := lat + 1;
                if lat >= 2 then
                    pend  := '0';
                    rdata <= mem(paddr) & mem(paddr+1) & mem(paddr+2) & mem(paddr+3);
                    if inject_rresp_err = '1' and read_word_count = inject_word_target then
                        rresp <= "10";
                    else
                        rresp <= "00";
                    end if;
                    if rd_count_reset = '0' then
                        read_word_count <= read_word_count + 1;
                    end if;
                    rvalid <= '1';
                end if;
            end if;

            if rvalid = '1' and rready = '1' then
                rvalid <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Behavioral memory model — write channel (1-cycle latency)
    ---------------------------------------------------------------------------
    p_mem_write : process(aclk)
        variable pend_aw : std_ulogic := '0';
        variable pend_w  : std_ulogic := '0';
        variable paddr   : integer    := 0;
        variable pdata   : std_ulogic_vector(31 downto 0);
        variable pstrb   : std_ulogic_vector( 3 downto 0);
    begin
        if rising_edge(aclk) then
            if wr_count_reset = '1' then write_word_count <= 0; end if;
            awready <= '0';
            wready  <= '0';
            bvalid  <= '0';

            if awvalid = '1' and pend_aw = '0' then
                awready <= '1';
                paddr   := to_integer(unsigned(awaddr));
                pend_aw := '1';
            end if;

            if wvalid = '1' and pend_w = '0' then
                wready <= '1';
                pdata  := wdata;
                pstrb  := wstrb;
                pend_w := '1';
            end if;

            if pend_aw = '1' and pend_w = '1' then
                pend_aw := '0';
                pend_w  := '0';
                for i in 0 to 3 loop
                    if pstrb(3-i) = '1' then
                        mem(paddr + i) <= pdata(31 - i*8 downto 24 - i*8);
                    end if;
                end loop;
                if inject_bresp_err = '1' and write_word_count = inject_word_target then
                    bresp <= "10";
                else
                    bresp <= "00";
                end if;
                if wr_count_reset = '0' then
                    write_word_count <= write_word_count + 1;
                end if;
                bvalid <= '1';
            end if;

            if bvalid = '1' and bready = '1' then
                bvalid <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    p_stim : process
        variable t0 : natural := 0;   -- cycle-count snapshot for throughput tests
    begin
        aresetn <= '0';
        wait for 4 * CLK_PERIOD;
        aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 1: Single-block read (16 bytes from offset 0)
        -----------------------------------------------------------------------
        rd_base      <= x"00000000";
        rd_blk_count <= x"000001";
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        wait until rd_block_valid = '1' for TIMEOUT;
        assert rd_block_valid = '1'
            report "TEST1: timeout waiting for rd_block_valid" severity failure;

        assert rd_block_data(127 downto 96) = x"00010203"
            report "TEST1: block MSW mismatch" severity failure;
        assert rd_block_data( 31 downto  0) = x"0C0D0E0F"
            report "TEST1: block LSW mismatch" severity failure;

        rd_consumed <= '1';
        wait for CLK_PERIOD;
        rd_consumed <= '0';

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST1: timeout waiting for rd_done" severity failure;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 2: Multi-block read (4 blocks = 64 bytes)
        -----------------------------------------------------------------------
        rd_base      <= x"00000000";
        rd_blk_count <= x"000004";
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        for blk in 0 to 3 loop
            wait until rd_block_valid = '1' for TIMEOUT;
            assert rd_block_valid = '1'
                report "TEST2: timeout waiting for block " & integer'image(blk)
                severity failure;

            assert rd_block_data(127 downto 96) =
                std_ulogic_vector(to_unsigned(blk * 16,     8) &
                                  to_unsigned(blk * 16 + 1, 8) &
                                  to_unsigned(blk * 16 + 2, 8) &
                                  to_unsigned(blk * 16 + 3, 8))
                report "TEST2: block " & integer'image(blk) & " MSW mismatch"
                severity failure;

            rd_consumed <= '1';
            wait for CLK_PERIOD;
            rd_consumed <= '0';
            -- Let rd_block_valid deassert before the next loop iteration
            wait until rd_block_valid = '0' for TIMEOUT;
        end loop;

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST2: timeout waiting for rd_done" severity failure;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 3: Single-block write (16 bytes to offset 256)
        -----------------------------------------------------------------------
        wr_base       <= x"00000100";
        wr_blk_count  <= x"000001";
        wr_block_data <= x"AABBCCDD112233445566778899AABBCC";
        wr_start      <= '1';
        wait for CLK_PERIOD;
        wr_start <= '0';

        wr_block_valid <= '1';
        wait until wr_accepted = '1' for TIMEOUT;
        assert wr_accepted = '1' report "TEST3: timeout waiting for wr_accepted" severity failure;
        wait for CLK_PERIOD;
        wr_block_valid <= '0';

        wait until wr_done = '1' for TIMEOUT;
        assert wr_done = '1' report "TEST3: timeout waiting for wr_done" severity failure;
        wait for 2 * CLK_PERIOD;

        assert mem(256) = x"AA" report "TEST3: byte 0 mismatch" severity failure;
        assert mem(257) = x"BB" report "TEST3: byte 1 mismatch" severity failure;
        assert mem(271) = x"CC" report "TEST3: byte 15 mismatch" severity failure;

        -----------------------------------------------------------------------
        -- Test 4: Parallel read + write (3 blocks: read from 0, write to 512)
        -----------------------------------------------------------------------
        rd_count_reset <= '1'; wr_count_reset <= '1';
        wait until rising_edge(aclk);
        rd_count_reset <= '0'; wr_count_reset <= '0';

        rd_base      <= x"00000000";
        rd_blk_count <= x"000003";
        wr_base      <= x"00000200";
        wr_blk_count <= x"000003";
        rd_start     <= '1';
        wr_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';
        wr_start <= '0';

        for blk in 0 to 2 loop
            wait until rd_block_valid = '1' for TIMEOUT;
            assert rd_block_valid = '1'
                report "TEST4: timeout waiting for read block " & integer'image(blk)
                severity failure;

            wr_block_data  <= rd_block_data;
            rd_consumed    <= '1';
            wait for CLK_PERIOD;
            rd_consumed    <= '0';

            wr_block_valid <= '1';
            wait until wr_accepted = '1' for TIMEOUT;
            assert wr_accepted = '1'
                report "TEST4: timeout waiting for wr_accepted (block " &
                        integer'image(blk) & ")" severity failure;
            wait for CLK_PERIOD;
            wr_block_valid <= '0';

            -- Let rd_block_valid deassert before the next loop iteration
            if blk < 2 then
                wait until rd_block_valid = '0' for TIMEOUT;
            end if;
        end loop;

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST4: timeout waiting for rd_done" severity failure;
        wait until wr_done = '1' for TIMEOUT;
        assert wr_done = '1' report "TEST4: timeout waiting for wr_done" severity failure;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 5: RRESP error injection on word 6 (block 1, word 2)
        -----------------------------------------------------------------------
        rd_count_reset <= '1';
        wait until rising_edge(aclk);
        rd_count_reset <= '0';

        inject_rresp_err   <= '1';
        inject_word_target <= 6;
        rd_base            <= x"00000000";
        rd_blk_count       <= x"000002";
        rd_start           <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        -- Consume block 0 normally
        wait until rd_block_valid = '1' for TIMEOUT;
        assert rd_block_valid = '1'
            report "TEST5: timeout waiting for block 0" severity failure;
        rd_consumed <= '1';
        wait for CLK_PERIOD;
        rd_consumed <= '0';

        -- Block 1 word 2 will error; dma_error must assert before rd_done
        wait until dma_error = '1' or rd_done = '1' for TIMEOUT;
        assert dma_error = '1'
            report "TEST5: dma_error not asserted on RRESP error" severity failure;

        inject_rresp_err <= '0';
        aresetn <= '0'; wait for 2 * CLK_PERIOD; aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 6: BRESP error injection on write word 3
        -----------------------------------------------------------------------
        wr_count_reset <= '1';
        wait until rising_edge(aclk);
        wr_count_reset <= '0';

        inject_bresp_err   <= '1';
        inject_word_target <= 3;
        wr_base            <= x"00000000";
        wr_blk_count       <= x"000001";
        wr_block_data      <= (others => '1');
        wr_start           <= '1';
        wait for CLK_PERIOD;
        wr_start <= '0';

        wr_block_valid <= '1';
        wait until wr_accepted = '1' for TIMEOUT;
        assert wr_accepted = '1' report "TEST6: timeout waiting for wr_accepted" severity failure;
        wait for CLK_PERIOD;
        wr_block_valid <= '0';

        wait until dma_error = '1' or wr_done = '1' for TIMEOUT;
        assert dma_error = '1'
            report "TEST6: dma_error not asserted on BRESP error" severity failure;

        inject_bresp_err <= '0';

        -----------------------------------------------------------------------
        -- Test 7: Read throughput — 16 blocks, consumer keeps up every cycle
        -- Reports cycles elapsed so cycles/block = elapsed / 16
        -----------------------------------------------------------------------
        rd_base      <= x"00000000";
        rd_blk_count <= x"000010";   -- 16 blocks = 256 bytes
        t0           := cycle_count;
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        for blk in 0 to 15 loop
            wait until rd_block_valid = '1' for TIMEOUT;
            assert rd_block_valid = '1'
                report "TEST7: timeout on block " & integer'image(blk) severity failure;
            rd_consumed <= '1';
            wait for CLK_PERIOD;
            rd_consumed <= '0';
            if blk < 15 then
                wait until rd_block_valid = '0' for TIMEOUT;
            end if;
        end loop;

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST7: timeout waiting for rd_done" severity failure;

        report "TEST7 READ  THROUGHPUT: 16 blocks in " &
               natural'image(cycle_count - t0) & " cycles  (" &
               natural'image((cycle_count - t0) / 16) & " cycles/block)" severity note;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 8: Write throughput — 16 blocks fed as fast as FIFO accepts.
        -- Expects ~8 cycles/block minimum (4 words x 2 cycles each, WR_BLOCK_DONE gone).
        -----------------------------------------------------------------------
        wr_base       <= x"00000000";
        wr_blk_count  <= x"000010";   -- 16 blocks
        wr_block_data <= x"DEADBEEFCAFEBABEDEADBEEFCAFEBABE";
        t0            := cycle_count;
        wr_start      <= '1';
        wait for CLK_PERIOD;
        wr_start <= '0';

        for blk in 0 to 15 loop
            wr_block_valid <= '1';
            wait until wr_accepted = '1' for TIMEOUT;
            assert wr_accepted = '1'
                report "TEST8: timeout wr_accepted block " & integer'image(blk) severity failure;
            wait for CLK_PERIOD;
            wr_block_valid <= '0';
            wait for CLK_PERIOD;   -- one cycle gap so FIFO can drain if full
        end loop;

        wait until wr_done = '1' for TIMEOUT;
        assert wr_done = '1' report "TEST8: timeout waiting for wr_done" severity failure;

        report "TEST8 WRITE THROUGHPUT: 16 blocks in " &
               natural'image(cycle_count - t0) & " cycles  (" &
               natural'image((cycle_count - t0) / 16) & " cycles/block)" severity note;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        report "DMA ENGINE: ALL TESTS PASSED" severity note;
        std.env.stop;
    end process p_stim;

end architecture sim;
