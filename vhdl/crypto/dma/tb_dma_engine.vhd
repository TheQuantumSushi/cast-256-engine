-- Testbench for dma_engine (Milestone 4)
-- Memory model: common.axi_memory (na=10, nb=2 → 1 KB, init from dma_mem_init.hex).
-- Reference checker: common.soft_fifo_pkg instantiated for 128-bit blocks.
-- Error injection: thin override layer between axi_memory and DMA.
-- Tests: single-block read, multi-block read, single-block write,
--        parallel read+write, RRESP error injection, BRESP error injection,
--        read throughput, write throughput.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library common;

entity tb_dma_engine is
end entity tb_dma_engine;

architecture sim of tb_dma_engine is

    -- Instantiate soft_fifo_pkg for 128-bit block reference model.
    package blk_fifo_pkg is new common.soft_fifo_pkg
        generic map(t => std_ulogic_vector(127 downto 0));
    use blk_fifo_pkg.all;

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

    constant CLK_PERIOD  : time    := 10 ns;
    constant TIMEOUT     : time    := 500 * CLK_PERIOD;
    constant MEM_ADDR_W  : integer := 10;  -- 2^10 = 1 KB axi_memory

    signal aclk    : std_ulogic := '0';
    signal aresetn : std_ulogic := '0';

    -- DMA ↔ memory AXI signals (30-bit DMA addresses, 10-bit memory addresses)
    signal araddr  : std_ulogic_vector(29 downto 0);
    signal arvalid : std_ulogic;
    signal arready : std_ulogic;
    signal rdata   : std_ulogic_vector(31 downto 0);
    signal rvalid  : std_ulogic;
    signal rready  : std_ulogic;

    signal awaddr  : std_ulogic_vector(29 downto 0);
    signal awvalid : std_ulogic;
    signal awready : std_ulogic;
    signal wdata   : std_ulogic_vector(31 downto 0);
    signal wstrb   : std_ulogic_vector( 3 downto 0);
    signal wvalid  : std_ulogic;
    signal wready  : std_ulogic;
    signal bvalid  : std_ulogic;
    signal bready  : std_ulogic;

    -- Error injection: intercept rresp/bresp between memory and DMA.
    signal mem_rresp : std_ulogic_vector(1 downto 0);
    signal mem_bresp : std_ulogic_vector(1 downto 0);
    signal rresp     : std_ulogic_vector(1 downto 0);  -- DMA receives this
    signal bresp     : std_ulogic_vector(1 downto 0);  -- DMA receives this

    signal inject_rresp_err   : std_ulogic := '0';
    signal inject_bresp_err   : std_ulogic := '0';
    signal inject_word_target : integer    := -1;
    signal read_word_count    : integer    := 0;
    signal write_word_count   : integer    := 0;
    signal rd_count_reset     : std_ulogic := '0';
    signal wr_count_reset     : std_ulogic := '0';

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

    signal dump : std_ulogic := '0';

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    p_cycle : process(aclk)
    begin
        if rising_edge(aclk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process p_cycle;

    ---------------------------------------------------------------------------
    -- DMA engine under test
    ---------------------------------------------------------------------------
    u_dut : dma_engine
        port map (
            aclk => aclk, aresetn => aresetn,
            m0_axi_araddr  => araddr,  m0_axi_arvalid => arvalid,
            m0_axi_arready => arready,
            m0_axi_rdata   => rdata,   m0_axi_rresp   => rresp,
            m0_axi_rvalid  => rvalid,  m0_axi_rready  => rready,
            m0_axi_awaddr  => awaddr,  m0_axi_awvalid => awvalid,
            m0_axi_awready => awready,
            m0_axi_wdata   => wdata,   m0_axi_wstrb   => wstrb,
            m0_axi_wvalid  => wvalid,  m0_axi_wready  => wready,
            m0_axi_bresp   => bresp,   m0_axi_bvalid  => bvalid,
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
    -- AXI memory model (1 KB, initialised from dma_mem_init.hex)
    -- Address: lower MEM_ADDR_W bits of DMA 30-bit address.
    ---------------------------------------------------------------------------
    u_mem : entity common.axi_memory(rtl)
        generic map(
            na   => MEM_ADDR_W,
            nb   => 2,
            fin  => "dma_mem_init.hex",
            fout => "dma_mem_out.hex"
        )
        port map(
            aclk           => aclk,
            aresetn        => aresetn,
            dump           => dump,
            s0_axi_araddr  => araddr(MEM_ADDR_W - 1 downto 0),
            s0_axi_arvalid => arvalid,
            s0_axi_arready => arready,
            s0_axi_awaddr  => awaddr(MEM_ADDR_W - 1 downto 0),
            s0_axi_awvalid => awvalid,
            s0_axi_awready => awready,
            s0_axi_wdata   => wdata,
            s0_axi_wstrb   => wstrb,
            s0_axi_wvalid  => wvalid,
            s0_axi_wready  => wready,
            s0_axi_rdata   => rdata,
            s0_axi_rresp   => mem_rresp,
            s0_axi_rvalid  => rvalid,
            s0_axi_rready  => rready,
            s0_axi_bresp   => mem_bresp,
            s0_axi_bvalid  => bvalid,
            s0_axi_bready  => bready
        );

    ---------------------------------------------------------------------------
    -- Error injection: override rresp/bresp on the target transaction index.
    ---------------------------------------------------------------------------
    rresp <= "10" when inject_rresp_err = '1' and read_word_count  = inject_word_target
             else mem_rresp;
    bresp <= "10" when inject_bresp_err = '1' and write_word_count = inject_word_target
             else mem_bresp;

    p_rd_count : process(aclk)
    begin
        if rising_edge(aclk) then
            if rd_count_reset = '1' then
                read_word_count <= 0;
            elsif rvalid = '1' and rready = '1' then
                read_word_count <= read_word_count + 1;
            end if;
        end if;
    end process p_rd_count;

    p_wr_count : process(aclk)
    begin
        if rising_edge(aclk) then
            if wr_count_reset = '1' then
                write_word_count <= 0;
            elsif bvalid = '1' and bready = '1' then
                write_word_count <= write_word_count + 1;
            end if;
        end if;
    end process p_wr_count;

    ---------------------------------------------------------------------------
    -- Stimulus + reference checker (soft_fifo_pkg)
    ---------------------------------------------------------------------------
    p_stim : process
        variable t0      : natural := 0;
        variable ref     : blk_fifo_pkg.soft_fifo_t;
        variable exp_blk : std_ulogic_vector(127 downto 0);

        -- Build the expected 128-bit block for a given byte offset in the
        -- i-mod-256 memory pattern.
        impure function expected_block(base_byte : natural) return std_ulogic_vector is
            variable blk : std_ulogic_vector(127 downto 0);
        begin
            for i in 0 to 15 loop
                blk(127 - i*8 downto 120 - i*8) :=
                    std_ulogic_vector(to_unsigned((base_byte + i) mod 256, 8));
            end loop;
            return blk;
        end function;

        -- Consume one block from the DMA output and compare against ref_fifo.
        procedure consume_and_check(label : string) is
        begin
            wait until rd_block_valid = '1' for TIMEOUT;
            assert rd_block_valid = '1'
                report label & ": timeout waiting for rd_block_valid" severity failure;
            if not ref.empty then
                exp_blk := ref.pop;
                assert rd_block_data = exp_blk
                    report label & ": block data mismatch" severity failure;
            end if;
            rd_consumed <= '1';
            wait for CLK_PERIOD;
            rd_consumed <= '0';
            wait until rd_block_valid = '0' for TIMEOUT;
        end procedure;

    begin
        aresetn <= '0';
        wait for 4 * CLK_PERIOD;
        aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 1: Single-block read (16 bytes from offset 0)
        -----------------------------------------------------------------------
        ref.push(expected_block(0));

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

        exp_blk := ref.pop;
        assert rd_block_data = exp_blk
            report "TEST1: soft_fifo reference mismatch" severity failure;

        rd_consumed <= '1';
        wait for CLK_PERIOD;
        rd_consumed <= '0';

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST1: timeout waiting for rd_done" severity failure;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 2: Multi-block read (4 blocks = 64 bytes from offset 0)
        -----------------------------------------------------------------------
        for blk in 0 to 3 loop
            ref.push(expected_block(blk * 16));
        end loop;

        rd_base      <= x"00000000";
        rd_blk_count <= x"000004";
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        for blk in 0 to 3 loop
            consume_and_check("TEST2 blk " & integer'image(blk));
        end loop;

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST2: timeout waiting for rd_done" severity failure;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 3: Single-block write (16 bytes to offset 256 = 0x100)
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

        -- Verify write by reading back the written block via DMA.
        ref.push(x"AABBCCDD112233445566778899AABBCC");
        rd_base      <= x"00000100";
        rd_blk_count <= x"000001";
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';
        consume_and_check("TEST3 readback");
        wait until rd_done = '1' for TIMEOUT;
        wait for 2 * CLK_PERIOD;

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

        -- Consume block 0 normally.
        wait until rd_block_valid = '1' for TIMEOUT;
        assert rd_block_valid = '1'
            report "TEST5: timeout waiting for block 0" severity failure;
        rd_consumed <= '1';
        wait for CLK_PERIOD;
        rd_consumed <= '0';

        -- Block 1 word 2 errors; dma_error must assert.
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
        aresetn <= '0'; wait for 2 * CLK_PERIOD; aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 7: Read throughput — 16 blocks, consumer keeps up every cycle.
        -----------------------------------------------------------------------
        for blk in 0 to 15 loop
            ref.push(expected_block(blk * 16));
        end loop;

        rd_base      <= x"00000000";
        rd_blk_count <= x"000010";
        t0           := cycle_count;
        rd_start     <= '1';
        wait for CLK_PERIOD;
        rd_start <= '0';

        for blk in 0 to 15 loop
            consume_and_check("TEST7 blk " & integer'image(blk));
        end loop;

        wait until rd_done = '1' for TIMEOUT;
        assert rd_done = '1' report "TEST7: timeout waiting for rd_done" severity failure;

        report "TEST7 READ  THROUGHPUT: 16 blocks in " &
               natural'image(cycle_count - t0) & " cycles  (" &
               natural'image((cycle_count - t0) / 16) & " cycles/block)" severity note;
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 8: Write throughput — 16 blocks fed as fast as FIFO accepts.
        -----------------------------------------------------------------------
        wr_base       <= x"00000000";
        wr_blk_count  <= x"000010";
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
            wait for CLK_PERIOD;
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
