-- DMA Engine top-level (Milestone 4)
-- Instantiates dma_read_engine and dma_write_engine in parallel.
-- The AXI4-Lite read and write channels are fully independent.

library ieee;
use ieee.std_logic_1164.all;

entity dma_engine is
    port (
        aclk               : in  std_ulogic;
        aresetn            : in  std_ulogic;

        -- AXI4-Lite master read address channel
        m0_axi_araddr      : out std_ulogic_vector(29 downto 0);
        m0_axi_arvalid     : out std_ulogic;
        m0_axi_arready     : in  std_ulogic;

        -- AXI4-Lite master read data channel
        m0_axi_rdata       : in  std_ulogic_vector(31 downto 0);
        m0_axi_rresp       : in  std_ulogic_vector( 1 downto 0);
        m0_axi_rvalid      : in  std_ulogic;
        m0_axi_rready      : out std_ulogic;

        -- AXI4-Lite master write address channel
        m0_axi_awaddr      : out std_ulogic_vector(29 downto 0);
        m0_axi_awvalid     : out std_ulogic;
        m0_axi_awready     : in  std_ulogic;

        -- AXI4-Lite master write data channel
        m0_axi_wdata       : out std_ulogic_vector(31 downto 0);
        m0_axi_wstrb       : out std_ulogic_vector( 3 downto 0);
        m0_axi_wvalid      : out std_ulogic;
        m0_axi_wready      : in  std_ulogic;

        -- AXI4-Lite master write response channel
        m0_axi_bresp       : in  std_ulogic_vector( 1 downto 0);
        m0_axi_bvalid      : in  std_ulogic;
        m0_axi_bready      : out std_ulogic;

        -- Control from GCM FSM
        rd_start           : in  std_ulogic;
        rd_base_addr       : in  std_ulogic_vector(31 downto 0);
        rd_block_count     : in  std_ulogic_vector(23 downto 0);

        wr_start           : in  std_ulogic;
        wr_base_addr       : in  std_ulogic_vector(31 downto 0);
        wr_block_count     : in  std_ulogic_vector(23 downto 0);

        -- Data interface to/from GCM datapath
        rd_block_data      : out std_ulogic_vector(127 downto 0);
        rd_block_valid     : out std_ulogic;
        rd_block_consumed  : in  std_ulogic;

        wr_block_data      : in  std_ulogic_vector(127 downto 0);
        wr_block_valid     : in  std_ulogic;
        wr_block_accepted  : out std_ulogic;

        -- Status
        rd_done            : out std_ulogic;
        wr_done            : out std_ulogic;
        dma_error          : out std_ulogic
    );
end entity dma_engine;

architecture rtl of dma_engine is

    signal rd_error : std_ulogic;
    signal wr_error : std_ulogic;

begin

    dma_error <= rd_error or wr_error;

    u_read : entity work.dma_read_engine
        port map (
            aclk              => aclk,
            aresetn           => aresetn,
            m_axi_araddr      => m0_axi_araddr,
            m_axi_arvalid     => m0_axi_arvalid,
            m_axi_arready     => m0_axi_arready,
            m_axi_rdata       => m0_axi_rdata,
            m_axi_rresp       => m0_axi_rresp,
            m_axi_rvalid      => m0_axi_rvalid,
            m_axi_rready      => m0_axi_rready,
            rd_start          => rd_start,
            rd_base_addr      => rd_base_addr,
            rd_block_count    => rd_block_count,
            rd_block_data     => rd_block_data,
            rd_block_valid    => rd_block_valid,
            rd_block_consumed => rd_block_consumed,
            rd_done           => rd_done,
            rd_error          => rd_error
        );

    u_write : entity work.dma_write_engine
        port map (
            aclk              => aclk,
            aresetn           => aresetn,
            m_axi_awaddr      => m0_axi_awaddr,
            m_axi_awvalid     => m0_axi_awvalid,
            m_axi_awready     => m0_axi_awready,
            m_axi_wdata       => m0_axi_wdata,
            m_axi_wstrb       => m0_axi_wstrb,
            m_axi_wvalid      => m0_axi_wvalid,
            m_axi_wready      => m0_axi_wready,
            m_axi_bresp       => m0_axi_bresp,
            m_axi_bvalid      => m0_axi_bvalid,
            m_axi_bready      => m0_axi_bready,
            wr_start          => wr_start,
            wr_base_addr      => wr_base_addr,
            wr_block_count    => wr_block_count,
            wr_block_data     => wr_block_data,
            wr_block_valid    => wr_block_valid,
            wr_block_accepted => wr_block_accepted,
            wr_done           => wr_done,
            wr_error          => wr_error
        );

end architecture rtl;
