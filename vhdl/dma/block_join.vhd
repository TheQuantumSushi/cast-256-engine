-- Joins 4 consecutive 32-bit words into a 128-bit block.
-- Three offset registers (regs[0..2]) accumulate partial blocks; the fourth
-- word is forwarded directly to the FIFO write data to save a register.
-- A 2-bit counter (cnt) selects the target register.
-- Assembled blocks are pushed to a FIFO (width=128, depth=d).
-- s_ready is de-asserted only when cnt="11" and the FIFO is full.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity block_join is
    generic(d : positive := 4);
    port(
        aclk    : in  std_ulogic;
        aresetn : in  std_ulogic;
        -- 32-bit word input
        s_data  : in  std_ulogic_vector( 31 downto 0);
        s_valid : in  std_ulogic;
        s_ready : out std_ulogic;
        -- 128-bit block output
        m_data  : out std_ulogic_vector(127 downto 0);
        m_valid : out std_ulogic;
        m_ready : in  std_ulogic
    );
end entity block_join;

architecture rtl of block_join is

    type reg_array_t is array(0 to 2) of std_ulogic_vector(31 downto 0);
    signal regs      : reg_array_t := (others => (others => '0'));
    signal cnt       : unsigned(1 downto 0) := (others => '0');
    signal s_ready_i : std_ulogic;

    signal fifo_write : std_ulogic := '0';
    signal fifo_wdata : std_ulogic_vector(127 downto 0) := (others => '0');
    signal fifo_read  : std_ulogic;
    signal fifo_rdata : std_ulogic_vector(127 downto 0);
    signal fifo_empty : std_ulogic;
    signal fifo_full  : std_ulogic;

begin

    u_fifo : entity work.fifo(rtl)
        generic map(w => 128, d => d)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            write   => fifo_write,
            wdata   => fifo_wdata,
            read    => fifo_read,
            rdata   => fifo_rdata,
            empty   => fifo_empty,
            full    => fifo_full
        );

    -- Stall input only when waiting to push the fourth word and FIFO is full.
    s_ready_i <= '0' when (cnt = "11" and fifo_full = '1') else '1';
    s_ready   <= s_ready_i;

    m_data    <= fifo_rdata;
    m_valid   <= not fifo_empty;
    fifo_read <= m_ready and not fifo_empty;

    p_join : process(aclk)
    begin
        if rising_edge(aclk) then
            fifo_write <= '0';
            if aresetn = '0' then
                cnt        <= (others => '0');
                regs       <= (others => (others => '0'));
                fifo_wdata <= (others => '0');
            else
                if s_valid = '1' and s_ready_i = '1' then
                    if cnt = "11" then
                        -- Fourth word: assemble block and push to FIFO.
                        fifo_wdata <= regs(0) & regs(1) & regs(2) & s_data;
                        fifo_write <= '1';
                        cnt        <= (others => '0');
                    else
                        regs(to_integer(cnt)) <= s_data;
                        cnt <= cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_join;

end architecture rtl;
