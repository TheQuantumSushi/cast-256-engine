-- DMA Read Engine: fetches 128-bit blocks (4 x 32-bit AXI4-Lite reads) from DDR.
-- Uses template fifo (w=128, d=2) as output buffer so the fetch FSM can start
-- the next block immediately after pushing, without waiting for the GCM core.
-- Big-endian assembly: first AXI word -> bits 127:96.
-- rd_done is sticky: asserts when all blocks are pushed, clears on rd_start.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library common;

entity dma_read_engine is
    port (
        aclk              : in  std_ulogic;
        aresetn           : in  std_ulogic;

        m_axi_araddr      : out std_ulogic_vector(29 downto 0);
        m_axi_arvalid     : out std_ulogic;
        m_axi_arready     : in  std_ulogic;

        m_axi_rdata       : in  std_ulogic_vector(31 downto 0);
        m_axi_rresp       : in  std_ulogic_vector( 1 downto 0);
        m_axi_rvalid      : in  std_ulogic;
        m_axi_rready      : out std_ulogic;

        rd_start          : in  std_ulogic;
        rd_base_addr      : in  std_ulogic_vector(31 downto 0);
        rd_block_count    : in  std_ulogic_vector(23 downto 0);

        rd_block_data     : out std_ulogic_vector(127 downto 0);
        rd_block_valid    : out std_ulogic;
        rd_block_consumed : in  std_ulogic;

        rd_done           : out std_ulogic;
        rd_error          : out std_ulogic
    );
end entity dma_read_engine;

architecture rtl of dma_read_engine is

    constant RESP_OKAY : std_ulogic_vector(1 downto 0) := "00";

    ---------------------------------------------------------------------------
    -- Template FIFO interface (w=128, d=2) — decouples fetch from consumption
    ---------------------------------------------------------------------------
    signal fifo_write_i : std_ulogic := '0';
    signal fifo_read_i  : std_ulogic := '0';
    signal fifo_rdata_i : std_ulogic_vector(127 downto 0);
    signal fifo_empty_i : std_ulogic;
    signal fifo_full_i  : std_ulogic;

    type state_t is (RD_IDLE, RD_ISSUE_AR, RD_WAIT_RDATA, RD_BLOCK_READY);
    signal state : state_t := RD_IDLE;

    signal rd_addr        : unsigned(29 downto 0) := (others => '0');
    signal rd_word_idx    : unsigned(1 downto 0)  := (others => '0');
    signal rd_blocks_done : unsigned(23 downto 0) := (others => '0');
    signal rd_total       : unsigned(23 downto 0) := (others => '0');
    signal rd_block_buf   : std_ulogic_vector(127 downto 0) := (others => '0');

    signal arvalid_i  : std_ulogic := '0';
    signal araddr_i   : std_ulogic_vector(29 downto 0) := (others => '0');
    signal rready_i   : std_ulogic := '0';
    signal rd_done_i  : std_ulogic := '0';
    signal rd_error_i : std_ulogic := '0';

begin

    ---------------------------------------------------------------------------
    -- FIFO instance: fetch FSM pushes assembled blocks; GCM datapath pops.
    ---------------------------------------------------------------------------
    u_fifo : entity common.fifo(rtl)
        generic map(w => 128, d => 2)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            write   => fifo_write_i,
            wdata   => rd_block_buf,
            read    => fifo_read_i,
            rdata   => fifo_rdata_i,
            empty   => fifo_empty_i,
            full    => fifo_full_i
        );

    -- FIFO output drives the block interface directly.
    rd_block_data  <= fifo_rdata_i;
    rd_block_valid <= not fifo_empty_i;

    m_axi_arvalid <= arvalid_i;
    m_axi_araddr  <= araddr_i;
    m_axi_rready  <= rready_i;
    rd_done       <= rd_done_i;
    rd_error      <= rd_error_i;

    ---------------------------------------------------------------------------
    -- Pop FIFO when GCM signals consumption.
    ---------------------------------------------------------------------------
    p_pop : process(aclk)
    begin
        if rising_edge(aclk) then
            fifo_read_i <= '0';
            if aresetn = '1' and rd_block_consumed = '1' and fifo_empty_i = '0' then
                fifo_read_i <= '1';
            end if;
        end if;
    end process p_pop;

    ---------------------------------------------------------------------------
    -- Fetch FSM (AR + R channels + block assembly)
    ---------------------------------------------------------------------------
    p_read : process(aclk)

        procedure latch_word is
        begin
            case rd_word_idx is
                when "00"   => rd_block_buf(127 downto 96) <= m_axi_rdata;
                when "01"   => rd_block_buf( 95 downto 64) <= m_axi_rdata;
                when "10"   => rd_block_buf( 63 downto 32) <= m_axi_rdata;
                when others => rd_block_buf( 31 downto  0) <= m_axi_rdata;
            end case;
        end procedure;

    begin
        if rising_edge(aclk) then
            fifo_write_i <= '0';  -- default: no push
            if aresetn = '0' then
                state            <= RD_IDLE;
                arvalid_i        <= '0';
                rready_i         <= '0';
                rd_done_i        <= '0';
                rd_error_i       <= '0';
                rd_addr          <= (others => '0');
                rd_word_idx      <= (others => '0');
                rd_blocks_done   <= (others => '0');
                rd_total         <= (others => '0');
                rd_block_buf     <= (others => '0');
            else
                case state is

                    when RD_IDLE =>
                        arvalid_i <= '0';
                        if rd_start = '1' then
                            rd_done_i      <= '0';
                            rd_error_i     <= '0';
                            rd_addr        <= unsigned(rd_base_addr(29 downto 0));
                            rd_total       <= unsigned(rd_block_count);
                            rd_blocks_done <= (others => '0');
                            rd_word_idx    <= (others => '0');
                            if unsigned(rd_block_count) = 0 then
                                rd_done_i <= '1';
                            else
                                state <= RD_ISSUE_AR;
                            end if;
                        end if;

                    when RD_ISSUE_AR =>
                        arvalid_i <= '1';
                        araddr_i  <= std_ulogic_vector(rd_addr);
                        if m_axi_arready = '1' then
                            arvalid_i <= '0';
                            rready_i  <= '1';
                            state     <= RD_WAIT_RDATA;
                        end if;

                    when RD_WAIT_RDATA =>
                        if m_axi_rvalid = '1' then
                            rready_i <= '0';
                            if m_axi_rresp /= RESP_OKAY then
                                rd_error_i <= '1';
                                state      <= RD_IDLE;
                            else
                                latch_word;
                                rd_addr     <= rd_addr + 4;
                                rd_word_idx <= rd_word_idx + 1;
                                if rd_word_idx = "11" then
                                    state <= RD_BLOCK_READY;
                                else
                                    state <= RD_ISSUE_AR;
                                end if;
                            end if;
                        end if;

                    -- Try to push the assembled block into the FIFO.
                    -- If full, stay here until there is room.
                    when RD_BLOCK_READY =>
                        if fifo_full_i = '0' then
                            fifo_write_i   <= '1';
                            rd_blocks_done <= rd_blocks_done + 1;
                            if rd_blocks_done + 1 = rd_total then
                                rd_done_i <= '1';
                                state     <= RD_IDLE;
                            else
                                rd_word_idx <= (others => '0');
                                state       <= RD_ISSUE_AR;
                            end if;
                        end if;

                    when others =>
                        state <= RD_IDLE;
                end case;
            end if;
        end if;
    end process p_read;

end architecture rtl;
