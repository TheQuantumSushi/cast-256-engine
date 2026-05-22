-- Splits a 128-bit block into 4 sequential 32-bit words.
-- Incoming blocks are stored in an internal FIFO (width=128, depth=d).
-- A load stage copies the FIFO head into four offset registers (regs[0..3]).
-- A 2-bit counter (cnt) selects which register to present on m_data.
-- The next block is loaded immediately when the last word is consumed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity block_split is
    generic(d : positive := 4);
    port(
        aclk    : in  std_ulogic;
        aresetn : in  std_ulogic;
        -- 128-bit block input
        s_data  : in  std_ulogic_vector(127 downto 0);
        s_valid : in  std_ulogic;
        s_ready : out std_ulogic;
        -- 32-bit word output
        m_data  : out std_ulogic_vector(31 downto 0);
        m_valid : out std_ulogic;
        m_ready : in  std_ulogic
    );
end entity block_split;

architecture rtl of block_split is

    signal fifo_write : std_ulogic;
    signal fifo_read  : std_ulogic := '0';
    signal fifo_rdata : std_ulogic_vector(127 downto 0);
    signal fifo_empty : std_ulogic;
    signal fifo_full  : std_ulogic;

    type reg_array_t is array(0 to 3) of std_ulogic_vector(31 downto 0);
    signal regs     : reg_array_t := (others => (others => '0'));
    signal cnt      : unsigned(1 downto 0) := (others => '0');
    signal has_data : std_ulogic := '0';

begin

    u_fifo : entity work.fifo(rtl)
        generic map(w => 128, d => d)
        port map(
            aclk    => aclk,
            aresetn => aresetn,
            write   => fifo_write,
            wdata   => s_data,
            read    => fifo_read,
            rdata   => fifo_rdata,
            empty   => fifo_empty,
            full    => fifo_full
        );

    fifo_write <= s_valid and not fifo_full;
    s_ready    <= not fifo_full;

    -- Combinatorial word select from offset registers.
    m_data  <= regs(to_integer(cnt));
    m_valid <= has_data;

    p_split : process(aclk)

        -- Load the FIFO head into offset registers and advance the read pointer.
        procedure load_block is
        begin
            regs(0)   <= fifo_rdata(127 downto 96);
            regs(1)   <= fifo_rdata( 95 downto 64);
            regs(2)   <= fifo_rdata( 63 downto 32);
            regs(3)   <= fifo_rdata( 31 downto  0);
            fifo_read <= '1';
            cnt       <= (others => '0');
            has_data  <= '1';
        end procedure;

    begin
        if rising_edge(aclk) then
            fifo_read <= '0';
            if aresetn = '0' then
                cnt      <= (others => '0');
                has_data <= '0';
                regs     <= (others => (others => '0'));
            else
                if has_data = '0' then
                    -- Idle: load next block as soon as one is available.
                    if fifo_empty = '0' then
                        load_block;
                    end if;
                elsif m_ready = '1' then
                    if cnt = "11" then
                        -- Last word consumed; immediately load next block if ready.
                        has_data <= '0';
                        if fifo_empty = '0' then
                            load_block;
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_split;

end architecture rtl;
