-- DMA Read Engine: fetches 128-bit blocks (4 x 32-bit AXI4-Lite reads) from DDR.
-- Raw 32-bit words are forwarded to block_join, which assembles them into
-- 128-bit blocks and buffers them in a 4-deep FIFO.
-- m_axi_rready is gated on block_join.s_ready to provide backpressure.
-- rd_done asserts after the last word has been accepted by block_join.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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
    -- block_join: assembles 32-bit words into 128-bit blocks
    ---------------------------------------------------------------------------
    signal join_s_data  : std_ulogic_vector( 31 downto 0);
    signal join_s_valid : std_ulogic;
    signal join_s_ready : std_ulogic;
    signal join_m_data  : std_ulogic_vector(127 downto 0);
    signal join_m_valid : std_ulogic;

    type state_t is (RD_IDLE, RD_ISSUE_AR, RD_WAIT_RDATA);
    signal state : state_t := RD_IDLE;

    signal rd_addr        : unsigned(29 downto 0) := (others => '0');
    signal rd_word_idx    : unsigned( 1 downto 0) := (others => '0');
    signal rd_blocks_done : unsigned(23 downto 0) := (others => '0');
    signal rd_total       : unsigned(23 downto 0) := (others => '0');

    signal arvalid_i  : std_ulogic := '0';
    signal araddr_i   : std_ulogic_vector(29 downto 0) := (others => '0');
    signal rd_done_i  : std_ulogic := '0';
    signal rd_error_i : std_ulogic := '0';

begin

    u_join : entity work.block_join(rtl)
        generic map(d => 4)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            s_data  => join_s_data,
            s_valid => join_s_valid,
            s_ready => join_s_ready,
            m_data  => join_m_data,
            m_valid => join_m_valid,
            m_ready => rd_block_consumed
        );

    ---------------------------------------------------------------------------
    -- AXI R channel wired to block_join input.
    -- rready is gated on join.s_ready so the slave stalls until join can accept.
    -- On RESP error the word is not forwarded (join_s_valid='0') but rready
    -- remains tied to join_s_ready so the handshake still completes.
    ---------------------------------------------------------------------------
    join_s_data  <= m_axi_rdata;
    join_s_valid <= m_axi_rvalid
                    when (state = RD_WAIT_RDATA and m_axi_rresp = RESP_OKAY)
                    else '0';
    m_axi_rready <= join_s_ready when state = RD_WAIT_RDATA else '0';

    rd_block_data  <= join_m_data;
    rd_block_valid <= join_m_valid;
    m_axi_arvalid  <= arvalid_i;
    m_axi_araddr   <= araddr_i;
    rd_done        <= rd_done_i;
    rd_error       <= rd_error_i;

    ---------------------------------------------------------------------------
    -- Fetch FSM (AR channel + R channel forwarding)
    ---------------------------------------------------------------------------
    p_read : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state          <= RD_IDLE;
                arvalid_i      <= '0';
                rd_done_i      <= '0';
                rd_error_i     <= '0';
                rd_addr        <= (others => '0');
                rd_word_idx    <= (others => '0');
                rd_blocks_done <= (others => '0');
                rd_total       <= (others => '0');
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
                        if arvalid_i = '1' and m_axi_arready = '1' then
                            arvalid_i <= '0';
                            state     <= RD_WAIT_RDATA;
                        end if;

                    -- rready = join_s_ready (combinatorial); handshake fires when
                    -- both m_axi_rvalid and join_s_ready are '1'.
                    when RD_WAIT_RDATA =>
                        if m_axi_rvalid = '1' and join_s_ready = '1' then
                            if m_axi_rresp /= RESP_OKAY then
                                rd_error_i <= '1';
                                state      <= RD_IDLE;
                            else
                                rd_addr     <= rd_addr + 4;
                                rd_word_idx <= rd_word_idx + 1;
                                if rd_word_idx = "11" then
                                    -- All four words of this block forwarded to join.
                                    rd_blocks_done <= rd_blocks_done + 1;
                                    if rd_blocks_done + 1 = rd_total then
                                        rd_done_i <= '1';
                                        state     <= RD_IDLE;
                                    else
                                        state <= RD_ISSUE_AR;
                                    end if;
                                else
                                    state <= RD_ISSUE_AR;
                                end if;
                            end if;
                        end if;

                    when others =>
                        state <= RD_IDLE;
                end case;
            end if;
        end if;
    end process p_read;

end architecture rtl;
