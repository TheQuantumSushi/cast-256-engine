-- DMA Write Engine: stores 128-bit blocks (4 x 32-bit AXI4-Lite writes) to DDR.
-- Uses template fifo (w=128, d=2) from the common library.  Big-endian: word 0
-- (bits 127:96) first.  wr_done is sticky.
--
-- Indentation technique: process-local procedures keep each when-clause body
-- to at most two visible if-levels; architecture-level select_word avoids an
-- inline case for wdata_i.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library common;

entity dma_write_engine is
    port (
        aclk              : in  std_ulogic;
        aresetn           : in  std_ulogic;

        m_axi_awaddr      : out std_ulogic_vector(29 downto 0);
        m_axi_awvalid     : out std_ulogic;
        m_axi_awready     : in  std_ulogic;

        m_axi_wdata       : out std_ulogic_vector(31 downto 0);
        m_axi_wstrb       : out std_ulogic_vector( 3 downto 0);
        m_axi_wvalid      : out std_ulogic;
        m_axi_wready      : in  std_ulogic;

        m_axi_bresp       : in  std_ulogic_vector( 1 downto 0);
        m_axi_bvalid      : in  std_ulogic;
        m_axi_bready      : out std_ulogic;

        wr_start          : in  std_ulogic;
        wr_base_addr      : in  std_ulogic_vector(31 downto 0);
        wr_block_count    : in  std_ulogic_vector(23 downto 0);

        wr_block_data     : in  std_ulogic_vector(127 downto 0);
        wr_block_valid    : in  std_ulogic;
        wr_block_accepted : out std_ulogic;

        wr_done           : out std_ulogic;
        wr_error          : out std_ulogic
    );
end entity dma_write_engine;

architecture rtl of dma_write_engine is

    constant RESP_OKAY : std_ulogic_vector(1 downto 0) := "00";

    -- Return the idx-th big-endian 32-bit word of a 128-bit block.
    function select_word(idx : unsigned(1 downto 0);
                         buf : std_ulogic_vector(127 downto 0))
        return std_ulogic_vector is
    begin
        case idx is
            when "00"   => return buf(127 downto 96);
            when "01"   => return buf( 95 downto 64);
            when "10"   => return buf( 63 downto 32);
            when others => return buf( 31 downto  0);
        end case;
    end function;

    ---------------------------------------------------------------------------
    -- Template FIFO interface (w=128, d=2) — replaces hand-rolled ring buffer
    ---------------------------------------------------------------------------
    signal fifo_write_i : std_ulogic;
    signal fifo_read_i  : std_ulogic := '0';
    signal fifo_rdata_i : std_ulogic_vector(127 downto 0);
    signal fifo_empty_i : std_ulogic;
    signal fifo_full_i  : std_ulogic;

    ---------------------------------------------------------------------------
    -- Write engine FSM
    ---------------------------------------------------------------------------
    type state_t is (WR_IDLE, WR_ISSUE_AW_W, WR_WAIT_AW, WR_WAIT_W, WR_WAIT_BRESP);
    signal state : state_t := WR_IDLE;

    signal wr_addr        : unsigned(29 downto 0) := (others => '0');
    signal wr_word_idx    : unsigned(1 downto 0)  := (others => '0');
    signal wr_blocks_done : unsigned(23 downto 0) := (others => '0');
    signal wr_total       : unsigned(23 downto 0) := (others => '0');
    signal wr_buf         : std_ulogic_vector(127 downto 0) := (others => '0');
    signal aw_acked       : std_ulogic := '0';
    signal w_acked        : std_ulogic := '0';

    signal awvalid_i  : std_ulogic := '0';
    signal awaddr_i   : std_ulogic_vector(29 downto 0) := (others => '0');
    signal wvalid_i   : std_ulogic := '0';
    signal wdata_i    : std_ulogic_vector(31 downto 0) := (others => '0');
    signal bready_i   : std_ulogic := '0';
    signal wr_done_i  : std_ulogic := '0';
    signal wr_error_i : std_ulogic := '0';

begin

    ---------------------------------------------------------------------------
    -- FIFO instance: GCM datapath pushes ciphertext blocks; FSM pops them.
    ---------------------------------------------------------------------------
    u_fifo : entity common.fifo(rtl)
        generic map(w => 128, d => 2)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            write   => fifo_write_i,
            wdata   => wr_block_data,
            read    => fifo_read_i,
            rdata   => fifo_rdata_i,
            empty   => fifo_empty_i,
            full    => fifo_full_i
        );

    -- Accept a new block whenever FIFO has room; both signals are combinatorial.
    fifo_write_i    <= wr_block_valid and not fifo_full_i;
    wr_block_accepted <= fifo_write_i;

    m_axi_awvalid <= awvalid_i;
    m_axi_awaddr  <= awaddr_i;
    m_axi_wvalid  <= wvalid_i;
    m_axi_wdata   <= wdata_i;
    m_axi_wstrb   <= "1111";
    m_axi_bready  <= bready_i;
    wr_done       <= wr_done_i;
    wr_error      <= wr_error_i;

    ---------------------------------------------------------------------------
    -- Write engine FSM
    ---------------------------------------------------------------------------
    p_write : process(aclk)

        -- Pop the next FIFO entry into wr_buf and begin AW+W arbitration.
        procedure pop_and_start is
        begin
            wr_buf      <= fifo_rdata_i;  -- snapshot combinatorial FIFO head
            fifo_read_i <= '1';           -- advance rdptr next cycle
            wr_word_idx <= (others => '0');
            aw_acked    <= '0';
            w_acked     <= '0';
            state       <= WR_ISSUE_AW_W;
        end procedure;

        -- Track simultaneous AW and W handshakes; advance state when both done.
        procedure check_aw_w_acks is
            variable aw_done : std_ulogic;
            variable w_done  : std_ulogic;
        begin
            aw_done  := aw_acked or m_axi_awready;
            w_done   := w_acked  or m_axi_wready;
            aw_acked <= aw_done;
            w_acked  <= w_done;
            if m_axi_awready = '1' then awvalid_i <= '0'; end if;
            if m_axi_wready  = '1' then wvalid_i  <= '0'; end if;
            if aw_done = '1' and w_done = '1' then
                awvalid_i <= '0';
                wvalid_i  <= '0';
                bready_i  <= '1';
                state     <= WR_WAIT_BRESP;
            elsif aw_done = '1' then
                awvalid_i <= '0';
                state     <= WR_WAIT_W;
            elsif w_done = '1' then
                wvalid_i  <= '0';
                state     <= WR_WAIT_AW;
            end if;
        end procedure;

        -- Process a successful BRESP: advance within block or complete block.
        procedure on_bresp_ok is
        begin
            bready_i <= '0';
            wr_addr  <= wr_addr + 4;
            if wr_word_idx /= "11" then
                wr_word_idx <= wr_word_idx + 1;
                aw_acked    <= '0';
                w_acked     <= '0';
                state       <= WR_ISSUE_AW_W;
            else
                wr_blocks_done <= wr_blocks_done + 1;
                if wr_blocks_done + 1 = wr_total then
                    wr_done_i <= '1';
                    state     <= WR_IDLE;
                elsif fifo_empty_i = '0' then
                    pop_and_start;
                else
                    state <= WR_IDLE;
                end if;
            end if;
        end procedure;

    begin
        if rising_edge(aclk) then
            fifo_read_i <= '0';  -- default: no pop; overridden by pop_and_start
            if aresetn = '0' then
                state          <= WR_IDLE;
                awvalid_i      <= '0';
                wvalid_i       <= '0';
                bready_i       <= '0';
                wr_done_i      <= '0';
                wr_error_i     <= '0';
                wr_addr        <= (others => '0');
                wr_word_idx    <= (others => '0');
                wr_blocks_done <= (others => '0');
                wr_total       <= (others => '0');
                aw_acked       <= '0';
                w_acked        <= '0';
            else
                case state is

                    when WR_IDLE =>
                        awvalid_i <= '0';
                        wvalid_i  <= '0';
                        if wr_start = '1' then
                            wr_done_i      <= '0';
                            wr_error_i     <= '0';
                            wr_addr        <= unsigned(wr_base_addr(29 downto 0));
                            wr_total       <= unsigned(wr_block_count);
                            wr_blocks_done <= (others => '0');
                            if unsigned(wr_block_count) = 0 then
                                wr_done_i <= '1';
                            end if;
                        elsif wr_total > 0 and fifo_empty_i = '0' then
                            pop_and_start;
                        end if;

                    when WR_ISSUE_AW_W =>
                        awvalid_i <= '1';
                        awaddr_i  <= std_ulogic_vector(wr_addr);
                        wvalid_i  <= '1';
                        wdata_i   <= select_word(wr_word_idx, wr_buf);
                        check_aw_w_acks;

                    when WR_WAIT_AW =>
                        if m_axi_awready = '1' then
                            awvalid_i <= '0';
                            bready_i  <= '1';
                            state     <= WR_WAIT_BRESP;
                        end if;

                    when WR_WAIT_W =>
                        if m_axi_wready = '1' then
                            wvalid_i  <= '0';
                            bready_i  <= '1';
                            state     <= WR_WAIT_BRESP;
                        end if;

                    when WR_WAIT_BRESP =>
                        if m_axi_bvalid = '1' then
                            if m_axi_bresp /= RESP_OKAY then
                                bready_i   <= '0';
                                wr_error_i <= '1';
                                state      <= WR_IDLE;
                            else
                                on_bresp_ok;
                            end if;
                        end if;

                    when others =>
                        state <= WR_IDLE;
                end case;
            end if;
        end if;
    end process p_write;

end architecture rtl;
