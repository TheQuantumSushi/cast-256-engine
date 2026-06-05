-- DMA Write Engine: stores 128-bit blocks (4 x 32-bit AXI4-Lite writes) to DDR.
-- Incoming 128-bit blocks feed block_split, which buffers them in a 4-deep FIFO
-- and streams them as 32-bit words.  The FSM consumes one word per AXI write
-- transaction and tracks word index for block-boundary detection.
-- Big-endian: word 0 (bits 127:96) first.  wr_done is sticky.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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

    ---------------------------------------------------------------------------
    -- block_split: buffers 128-bit blocks and streams them as 32-bit words
    ---------------------------------------------------------------------------
    signal split_s_ready : std_ulogic;
    signal split_m_data  : std_ulogic_vector(31 downto 0);
    signal split_m_valid : std_ulogic;
    signal split_m_ready : std_ulogic := '0';

    ---------------------------------------------------------------------------
    -- Write engine FSM
    ---------------------------------------------------------------------------
    type state_t is (WR_IDLE, WR_ISSUE_AW_W, WR_WAIT_AW, WR_WAIT_W,
                     WR_WAIT_BRESP, WR_WAIT_SPLIT);
    signal state : state_t := WR_IDLE;

    signal wr_addr        : unsigned(29 downto 0) := (others => '0');
    signal wr_word_idx    : unsigned( 1 downto 0) := (others => '0');
    signal wr_blocks_done : unsigned(23 downto 0) := (others => '0');
    signal wr_total       : unsigned(23 downto 0) := (others => '0');
    signal wr_word_latch  : std_ulogic_vector(31 downto 0) := (others => '0');
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

    u_split : entity work.block_split(rtl)
        generic map(d => 4)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            s_data  => wr_block_data,
            s_valid => wr_block_valid,
            s_ready => split_s_ready,
            m_data  => split_m_data,
            m_valid => split_m_valid,
            m_ready => split_m_ready
        );

    wr_block_accepted <= split_s_ready;

    m_axi_awvalid <= awvalid_i;
    m_axi_awaddr  <= awaddr_i;
    m_axi_wvalid  <= wvalid_i;
    m_axi_wdata   <= wdata_i;
    m_axi_wstrb   <= "1111";
    m_axi_bready  <= bready_i;
    wr_done       <= wr_done_i;
    wr_error      <= wr_error_i;

    ---------------------------------------------------------------------------
    -- Write FSM
    ---------------------------------------------------------------------------
    p_write : process(aclk)

        -- Latch the current word from split and start an AW+W transaction.
        -- wr_word_idx must be set by the caller before invoking this.
        procedure pop_and_start is
        begin
            wr_word_latch <= split_m_data;
            split_m_ready <= '1';
            aw_acked      <= '0';
            w_acked       <= '0';
            state         <= WR_ISSUE_AW_W;
        end procedure;

        -- Track simultaneous AW and W handshakes; move to BRESP when both done.
        -- Both VALID and READY must be high simultaneously for a proper AXI handshake.
        -- Reading awvalid_i/wvalid_i here uses their registered (pre-clock-edge) values:
        -- on the first cycle of WR_ISSUE_AW_W they are still '0' (held low by WR_IDLE),
        -- so a slave that keeps AWREADY/WREADY permanently high cannot cause a false ack
        -- before AWVALID/WVALID have actually been driven high.
        procedure check_aw_w_acks is
            variable aw_done : std_ulogic;
            variable w_done  : std_ulogic;
        begin
            aw_done  := aw_acked or (awvalid_i and m_axi_awready);
            w_done   := w_acked  or (wvalid_i  and m_axi_wready);
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

        -- Advance after a successful BRESP.
        procedure on_bresp_ok is
        begin
            bready_i <= '0';
            wr_addr  <= wr_addr + 4;
            if wr_word_idx /= "11" then
                -- More words remain in this block.
                wr_word_idx <= wr_word_idx + 1;
                if split_m_valid = '1' then
                    pop_and_start;
                else
                    state <= WR_WAIT_SPLIT;
                end if;
            else
                -- Block complete.
                wr_word_idx    <= (others => '0');
                wr_blocks_done <= wr_blocks_done + 1;
                if wr_blocks_done + 1 = wr_total then
                    wr_done_i <= '1';
                    state     <= WR_IDLE;
                elsif split_m_valid = '1' then
                    pop_and_start;
                else
                    state <= WR_IDLE;
                end if;
            end if;
        end procedure;

    begin
        if rising_edge(aclk) then
            split_m_ready <= '0';  -- default: one-cycle pulse only
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
                            wr_word_idx    <= (others => '0');
                            if unsigned(wr_block_count) = 0 then
                                wr_done_i <= '1';
                            end if;
                        elsif wr_total > 0 and split_m_valid = '1' then
                            wr_word_idx <= (others => '0');
                            pop_and_start;
                        end if;

                    when WR_ISSUE_AW_W =>
                        awvalid_i <= '1';
                        awaddr_i  <= std_ulogic_vector(wr_addr);
                        wvalid_i  <= '1';
                        wdata_i   <= wr_word_latch;
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

                    -- Waiting for block_split to have the next word ready.
                    when WR_WAIT_SPLIT =>
                        if split_m_valid = '1' then
                            pop_and_start;
                        end if;

                    when others =>
                        state <= WR_IDLE;
                end case;
            end if;
        end if;
    end process p_write;

end architecture rtl;
