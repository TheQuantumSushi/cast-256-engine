-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_pkg                                                      │
-- │                                                                  │
-- │ Package for the CAST-256 block cipher (RFC 2612).                │
-- │ Contains all types, S-box constants, key-schedule constants,     │
-- │ and the pure functions used by both the key schedule and the     │
-- │ encryption core.                                                 │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ┌─────────────────────────────────┐
-- │ Package declaration             │
-- └─────────────────────────────────┘
package cast256_pkg is

    -- ── Base types ────────────────────────────────────────────────────
    subtype word32_t is std_ulogic_vector(31 downto 0);
    subtype word5_t  is std_ulogic_vector(4  downto 0);

    -- S-box: 256 entries of 32 bits
    type sbox_t is array(0 to 255) of word32_t;

    -- KAPPA: 256-bit key state, split into 8 x 32-bit words A..H (MSB=A)
    type kappa_t is record
        a, b, c, d, e, f, g, h : word32_t;
    end record;

    -- BETA: 128-bit data state, split into 4 x 32-bit words A..D (MSB=A)
    type beta_t is record
        a, b, c, d : word32_t;
    end record;

    -- ── Subkey arrays ─────────────────────────────────────────────────
    -- 12 rounds, 4 rotation keys + 4 masking keys per round
    type kr_set_t   is array(0 to 3) of word5_t;
    type km_set_t   is array(0 to 3) of word32_t;
    type kr_array_t is array(0 to 11) of kr_set_t;
    type km_array_t is array(0 to 11) of km_set_t;

    -- ── Key-schedule round constants ──────────────────────────────────
    -- 24 octaves x 8 values each (Tm masking, Tr rotation)
    type tm_row_t   is array(0 to 7) of word32_t;
    type tr_row_t   is array(0 to 7) of word5_t;
    type tm_array_t is array(0 to 23) of tm_row_t;
    type tr_array_t is array(0 to 23) of tr_row_t;

    -- ── Constant declarations ─────────────────────────────────────────
    -- Values deferred to package body
    constant SBOX1 : sbox_t;
    constant SBOX2 : sbox_t;
    constant SBOX3 : sbox_t;
    constant SBOX4 : sbox_t;

    -- ── Synthesis attribute : map S-boxes to block RAM ────────────────
    -- Instructs Vivado to implement the four S-boxes as BRAM rather than
    -- distributed LUT RAM.  Each S-box is 256 × 32 bits = 8 kbit, so all
    -- four together occupy 4 × 0.5 = 2 RAMB18 (or 1 RAMB36) resources
    -- rather than thousands of LUT6 + MUXF7 / MUXF8 cells.
    --
    -- NOTE: 7-series Block RAMs have a registered (1-cycle latency) output.
    -- The current f1/f2/f3 functions read the S-boxes combinatorially, so
    -- Vivado may warn about asynchronous BRAM access and partially fall back
    -- to LUT.  Full benefit requires restructuring the S-box reads to be
    -- synchronous (registered address) — that is the planned second step.
    -- This attribute is added now so the inference fires automatically once
    -- that restructuring is in place.
    attribute rom_style : string;
    attribute rom_style of SBOX1 : constant is "block";
    attribute rom_style of SBOX2 : constant is "block";
    attribute rom_style of SBOX3 : constant is "block";
    attribute rom_style of SBOX4 : constant is "block";

    constant TM : tm_array_t;   -- 96 masking constants derived from sqrt(2)
    constant TR : tr_array_t;   -- 96 rotation constants derived from sqrt(3)

    -- ── Function prototypes ───────────────────────────────────────────
    function rotate_left32(val : word32_t; n   : word5_t)  return word32_t;

    -- Round functions (Type 1/2/3 from RFC 2612 Section 2.1)
    function f1(d : word32_t; kr : word5_t; km : word32_t) return word32_t;
    function f2(d : word32_t; kr : word5_t; km : word32_t) return word32_t;
    function f3(d : word32_t; kr : word5_t; km : word32_t) return word32_t;

    -- One W-octave step (key schedule mixing)
    function w_octave(kap : kappa_t; i : integer range 0 to 23) return kappa_t;

    -- Forward quad-round Q(i) and reverse quad-round QBAR(i)
    function q_round   (b : beta_t; i : integer range 0 to 11;
                        kr : kr_array_t; km : km_array_t) return beta_t;
    function qbar_round(b : beta_t; i : integer range 0 to 11;
                        kr : kr_array_t; km : km_array_t) return beta_t;

end package cast256_pkg;


-- ┌─────────────────────────────────┐
-- │ Package body                    │
-- └─────────────────────────────────┘
package body cast256_pkg is

    -- ── S-box S1 (RFC 2612 Section 2.1.1) ────────────────────────────
    -- 256 entries, read left-to-right, top-to-bottom
    constant SBOX1 : sbox_t := (
        x"30fb40d4", x"9fa0ff0b", x"6beccd2f", x"3f258c7a",
        x"1e213f2f", x"9c004dd3", x"6003e540", x"cf9fc949",
        x"bfd4af27", x"88bbbdb5", x"e2034090", x"98d09675",
        x"6e63a0e0", x"15c361d2", x"c2e7661d", x"22d4ff8e",
        x"28683b6f", x"c07fd059", x"ff2379c8", x"775f50e2",
        x"43c340d3", x"df2f8656", x"887ca41a", x"a2d2bd2d",
        x"a1c9e0d6", x"346c4819", x"61b76d87", x"22540f2f",
        x"2abe32e1", x"aa54166b", x"22568e3a", x"a2d341d0",
        x"66db40c8", x"a784392f", x"004dff2f", x"2db9d2de",
        x"97943fac", x"4a97c1d8", x"527644b7", x"b5f437a7",
        x"b82cbaef", x"d751d159", x"6ff7f0ed", x"5a097a1f",
        x"827b68d0", x"90ecf52e", x"22b0c054", x"bc8e5935",
        x"4b6d2f7f", x"50bb64a2", x"d2664910", x"bee5812d",
        x"b7332290", x"e93b159f", x"b48ee411", x"4bff345d",
        x"fd45c240", x"ad31973f", x"c4f6d02e", x"55fc8165",
        x"d5b1caad", x"a1ac2dae", x"a2d4b76d", x"c19b0c50",
        x"882240f2", x"0c6e4f38", x"a4e4bfd7", x"4f5ba272",
        x"564c1d2f", x"c59c5319", x"b949e354", x"b04669fe",
        x"b1b6ab8a", x"c71358dd", x"6385c545", x"110f935d",
        x"57538ad5", x"6a390493", x"e63d37e0", x"2a54f6b3",
        x"3a787d5f", x"6276a0b5", x"19a6fcdf", x"7a42206a",
        x"29f9d4d5", x"f61b1891", x"bb72275e", x"aa508167",
        x"38901091", x"c6b505eb", x"84c7cb8c", x"2ad75a0f",
        x"874a1427", x"a2d1936b", x"2ad286af", x"aa56d291",
        x"d7894360", x"425c750d", x"93b39e26", x"187184c9",
        x"6c00b32d", x"73e2bb14", x"a0bebc3c", x"54623779",
        x"64459eab", x"3f328b82", x"7718cf82", x"59a2cea6",
        x"04ee002e", x"89fe78e6", x"3fab0950", x"325ff6c2",
        x"81383f05", x"6963c5c8", x"76cb5ad6", x"d49974c9",
        x"ca180dcf", x"380782d5", x"c7fa5cf6", x"8ac31511",
        x"35e79e13", x"47da91d0", x"f40f9086", x"a7e2419e",
        x"31366241", x"051ef495", x"aa573b04", x"4a805d8d",
        x"548300d0", x"00322a3c", x"bf64cddf", x"ba57a68e",
        x"75c6372b", x"50afd341", x"a7c13275", x"915a0bf5",
        x"6b54bfab", x"2b0b1426", x"ab4cc9d7", x"449ccd82",
        x"f7fbf265", x"ab85c5f3", x"1b55db94", x"aad4e324",
        x"cfa4bd3f", x"2deaa3e2", x"9e204d02", x"c8bd25ac",
        x"eadf55b3", x"d5bd9e98", x"e31231b2", x"2ad5ad6c",
        x"954329de", x"adbe4528", x"d8710f69", x"aa51c90f",
        x"aa786bf6", x"22513f1e", x"aa51a79b", x"2ad344cc",
        x"7b5a41f0", x"d37cfbad", x"1b069505", x"41ece491",
        x"b4c332e6", x"032268d4", x"c9600acc", x"ce387e6d",
        x"bf6bb16c", x"6a70fb78", x"0d03d9c9", x"d4df39de",
        x"e01063da", x"4736f464", x"5ad328d8", x"b347cc96",
        x"75bb0fc3", x"98511bfb", x"4ffbcc35", x"b58bcf6a",
        x"e11f0abc", x"bfc5fe4a", x"a70aec10", x"ac39570a",
        x"3f04442f", x"6188b153", x"e0397a2e", x"5727cb79",
        x"9ceb418f", x"1cacd68d", x"2ad37c96", x"0175cb9d",
        x"c69dff09", x"c75b65f0", x"d9db40d8", x"ec0e7779",
        x"4744ead4", x"b11c3274", x"dd24cb9e", x"7e1c54bd",
        x"f01144f9", x"d2240eb1", x"9675b3fd", x"a3ac3755",
        x"d47c27af", x"51c85f4d", x"56907596", x"a5bb15e6",
        x"580304f0", x"ca042cf1", x"011a37ea", x"8dbfaadb",
        x"35ba3e4a", x"3526ffa0", x"c37b4d09", x"bc306ed9",
        x"98a52666", x"5648f725", x"ff5e569d", x"0ced63d0",
        x"7c63b2cf", x"700b45e1", x"d5ea50f1", x"85a92872",
        x"af1fbda7", x"d4234870", x"a7870bf3", x"2d3b4d79",
        x"42e04198", x"0cd0ede7", x"26470db8", x"f881814c",
        x"474d6ad7", x"7c0c5e5c", x"d1231959", x"381b7298",
        x"f5d2f4db", x"ab838653", x"6e2f1e23", x"83719c9e",
        x"bd91e046", x"9a56456e", x"dc39200c", x"20c8c571",
        x"962bda1c", x"e1e696ff", x"b141ab08", x"7cca89b9",
        x"1a69e783", x"02cc4843", x"a2f7c579", x"429ef47d",
        x"427b169c", x"5ac9f049", x"dd8f0f00", x"5c8165bf"
    );

    -- ── S-box S2 ──────────────────────────────────────────────────────
    constant SBOX2 : sbox_t := (
        x"1f201094", x"ef0ba75b", x"69e3cf7e", x"393f4380",
        x"fe61cf7a", x"eec5207a", x"55889c94", x"72fc0651",
        x"ada7ef79", x"4e1d7235", x"d55a63ce", x"de0436ba",
        x"99c430ef", x"5f0c0794", x"18dcdb7d", x"a1d6eff3",
        x"a0b52f7b", x"59e83605", x"ee15b094", x"e9ffd909",
        x"dc440086", x"ef944459", x"ba83ccb3", x"e0c3cdfb",
        x"d1da4181", x"3b092ab1", x"f997f1c1", x"a5e6cf7b",
        x"01420ddb", x"e4e7ef5b", x"25a1ff41", x"e180f806",
        x"1fc41080", x"179bee7a", x"d37ac6a9", x"fe5830a4",
        x"98de8b7f", x"77e83f4e", x"79929269", x"24fa9f7b",
        x"e113c85b", x"acc40083", x"d7503525", x"f7ea615f",
        x"62143154", x"0d554b63", x"5d681121", x"c866c359",
        x"3d63cf73", x"cee234c0", x"d4d87e87", x"5c672b21",
        x"071f6181", x"39f7627f", x"361e3084", x"e4eb573b",
        x"602f64a4", x"d63acd9c", x"1bbc4635", x"9e81032d",
        x"2701f50c", x"99847ab4", x"a0e3df79", x"ba6cf38c",
        x"10843094", x"2537a95e", x"f46f6ffe", x"a1ff3b1f",
        x"208cfb6a", x"8f458c74", x"d9e0a227", x"4ec73a34",
        x"fc884f69", x"3e4de8df", x"ef0e0088", x"3559648d",
        x"8a45388c", x"1d804366", x"721d9bfd", x"a58684bb",
        x"e8256333", x"844e8212", x"128d8098", x"fed33fb4",
        x"ce280ae1", x"27e19ba5", x"d5a6c252", x"e49754bd",
        x"c5d655dd", x"eb667064", x"77840b4d", x"a1b6a801",
        x"84db26a9", x"e0b56714", x"21f043b7", x"e5d05860",
        x"54f03084", x"066ff472", x"a31aa153", x"dadc4755",
        x"b5625dbf", x"68561be6", x"83ca6b94", x"2d6ed23b",
        x"eccf01db", x"a6d3d0ba", x"b6803d5c", x"af77a709",
        x"33b4a34c", x"397bc8d6", x"5ee22b95", x"5f0e5304",
        x"81ed6f61", x"20e74364", x"b45e1378", x"de18639b",
        x"881ca122", x"b96726d1", x"8049a7e8", x"22b7da7b",
        x"5e552d25", x"5272d237", x"79d2951c", x"c60d894c",
        x"488cb402", x"1ba4fe5b", x"a4b09f6b", x"1ca815cf",
        x"a20c3005", x"8871df63", x"b9de2fcb", x"0cc6c9e9",
        x"0beeff53", x"e3214517", x"b4542835", x"9f63293c",
        x"ee41e729", x"6e1d2d7c", x"50045286", x"1e6685f3",
        x"f33401c6", x"30a22c95", x"31a70850", x"60930f13",
        x"73f98417", x"a1269859", x"ec645c44", x"52c877a9",
        x"cdff33a6", x"a02b1741", x"7cbad9a2", x"2180036f",
        x"50d99c08", x"cb3f4861", x"c26bd765", x"64a3f6ab",
        x"80342676", x"25a75e7b", x"e4e6d1fc", x"20c710e6",
        x"cdf0b680", x"17844d3b", x"31eef84d", x"7e0824e4",
        x"2ccb49eb", x"846a3bae", x"8ff77888", x"ee5d60f6",
        x"7af75673", x"2fdd5cdb", x"a11631c1", x"30f66f43",
        x"b3faec54", x"157fd7fa", x"ef8579cc", x"d152de58",
        x"db2ffd5e", x"8f32ce19", x"306af97a", x"02f03ef8",
        x"99319ad5", x"c242fa0f", x"a7e3ebb0", x"c68e4906",
        x"b8da230c", x"80823028", x"dcdef3c8", x"d35fb171",
        x"088a1bc8", x"bec0c560", x"61a3c9e8", x"bca8f54d",
        x"c72feffa", x"22822e99", x"82c570b4", x"d8d94e89",
        x"8b1c34bc", x"301e16e6", x"273be979", x"b0ffeaa6",
        x"61d9b8c6", x"00b24869", x"b7ffce3f", x"08dc283b",
        x"43daf65a", x"f7e19798", x"7619b72f", x"8f1c9ba4",
        x"dc8637a0", x"16a7d3b1", x"9fc393b7", x"a7136eeb",
        x"c6bcc63e", x"1a513742", x"ef6828bc", x"520365d6",
        x"2d6a77ab", x"3527ed4b", x"821fd216", x"095c6e2e",
        x"db92f2fb", x"5eea29cb", x"145892f5", x"91584f7f",
        x"5483697b", x"2667a8cc", x"85196048", x"8c4bacea",
        x"833860d4", x"0d23e0f9", x"6c387e8a", x"0ae6d249",
        x"b284600c", x"d835731d", x"dcb1c647", x"ac4c56ea",
        x"3ebd81b3", x"230eabb0", x"6438bc87", x"f0b5b1fa",
        x"8f5ea2b3", x"fc184642", x"0a036b7a", x"4fb089bd",
        x"649da589", x"a345415e", x"5c038323", x"3e5d3bb9",
        x"43d79572", x"7e6dd07c", x"06dfdf1e", x"6c6cc4ef",
        x"7160a539", x"73bfbe70", x"83877605", x"4523ecf1"
    );

    -- ── S-box S3 ──────────────────────────────────────────────────────
    constant SBOX3 : sbox_t := (
        x"8defc240", x"25fa5d9f", x"eb903dbf", x"e810c907",
        x"47607fff", x"369fe44b", x"8c1fc644", x"aececa90",
        x"beb1f9bf", x"eefbcaea", x"e8cf1950", x"51df07ae",
        x"920e8806", x"f0ad0548", x"e13c8d83", x"927010d5",
        x"11107d9f", x"07647db9", x"b2e3e4d4", x"3d4f285e",
        x"b9afa820", x"fade82e0", x"a067268b", x"8272792e",
        x"553fb2c0", x"489ae22b", x"d4ef9794", x"125e3fbc",
        x"21fffcee", x"825b1bfd", x"9255c5ed", x"1257a240",
        x"4e1a8302", x"bae07fff", x"528246e7", x"8e57140e",
        x"3373f7bf", x"8c9f8188", x"a6fc4ee8", x"c982b5a5",
        x"a8c01db7", x"579fc264", x"67094f31", x"f2bd3f5f",
        x"40fff7c1", x"1fb78dfc", x"8e6bd2c1", x"437be59b",
        x"99b03dbf", x"b5dbc64b", x"638dc0e6", x"55819d99",
        x"a197c81c", x"4a012d6e", x"c5884a28", x"ccc36f71",
        x"b843c213", x"6c0743f1", x"8309893c", x"0feddd5f",
        x"2f7fe850", x"d7c07f7e", x"02507fbf", x"5afb9a04",
        x"a747d2d0", x"1651192e", x"af70bf3e", x"58c31380",
        x"5f98302e", x"727cc3c4", x"0a0fb402", x"0f7fef82",
        x"8c96fdad", x"5d2c2aae", x"8ee99a49", x"50da88b8",
        x"8427f4a0", x"1eac5790", x"796fb449", x"8252dc15",
        x"efbd7d9b", x"a672597d", x"ada840d8", x"45f54504",
        x"fa5d7403", x"e83ec305", x"4f91751a", x"925669c2",
        x"23efe941", x"a903f12e", x"60270df2", x"0276e4b6",
        x"94fd6574", x"927985b2", x"8276dbcb", x"02778176",
        x"f8af918d", x"4e48f79e", x"8f616ddf", x"e29d840e",
        x"842f7d83", x"340ce5c8", x"96bbb682", x"93b4b148",
        x"ef303cab", x"984faf28", x"779faf9b", x"92dc560d",
        x"224d1e20", x"8437aa88", x"7d29dc96", x"2756d3dc",
        x"8b907cee", x"b51fd240", x"e7c07ce3", x"e566b4a1",
        x"c3e9615e", x"3cf8209d", x"6094d1e3", x"cd9ca341",
        x"5c76460e", x"00ea983b", x"d4d67881", x"fd47572c",
        x"f76cedd9", x"bda8229c", x"127dadaa", x"438a074e",
        x"1f97c090", x"081bdb8a", x"93a07ebe", x"b938ca15",
        x"97b03cff", x"3dc2c0f8", x"8d1ab2ec", x"64380e51",
        x"68cc7bfb", x"d90f2788", x"12490181", x"5de5ffd4",
        x"dd7ef86a", x"76a2e214", x"b9a40368", x"925d958f",
        x"4b39fffa", x"ba39aee9", x"a4ffd30b", x"faf7933b",
        x"6d498623", x"193cbcfa", x"27627545", x"825cf47a",
        x"61bd8ba0", x"d11e42d1", x"cead04f4", x"127ea392",
        x"10428db7", x"8272a972", x"9270c4a8", x"127de50b",
        x"285ba1c8", x"3c62f44f", x"35c0eaa5", x"e805d231",
        x"428929fb", x"b4fcdf82", x"4fb66a53", x"0e7dc15b",
        x"1f081fab", x"108618ae", x"fcfd086d", x"f9ff2889",
        x"694bcc11", x"236a5cae", x"12deca4d", x"2c3f8cc5",
        x"d2d02dfe", x"f8ef5896", x"e4cf52da", x"95155b67",
        x"494a488c", x"b9b6a80c", x"5c8f82bc", x"89d36b45",
        x"3a609437", x"ec00c9a9", x"44715253", x"0a874b49",
        x"d773bc40", x"7c34671c", x"02717ef6", x"4feb5536",
        x"a2d02fff", x"d2bf60c4", x"d43f03c0", x"50b4ef6d",
        x"07478cd1", x"006e1888", x"a2e53f55", x"b9e6d4bc",
        x"a2048016", x"97573833", x"d7207d67", x"de0f8f3d",
        x"72f87b33", x"abcc4f33", x"7688c55d", x"7b00a6b0",
        x"947b0001", x"570075d2", x"f9bb88f8", x"8942019e",
        x"4264a5ff", x"856302e0", x"72dbd92b", x"ee971b69",
        x"6ea22fde", x"5f08ae2b", x"af7a616d", x"e5c98767",
        x"cf1febd2", x"61efc8c2", x"f1ac2571", x"cc8239c2",
        x"67214cb8", x"b1e583d1", x"b7dc3e62", x"7f10bdce",
        x"f90a5c38", x"0ff0443d", x"606e6dc6", x"60543a49",
        x"5727c148", x"2be98a1d", x"8ab41738", x"20e1be24",
        x"af96da0f", x"68458425", x"99833be5", x"600d457d",
        x"282f9350", x"8334b362", x"d91d1120", x"2b6d8da0",
        x"642b1e31", x"9c305a00", x"52bce688", x"1b03588a",
        x"f7baefd5", x"4142ed9c", x"a4315c11", x"83323ec5",
        x"dfef4636", x"a133c501", x"e9d3531c", x"ee353783"
    );

    -- ── S-box S4 ──────────────────────────────────────────────────────
    constant SBOX4 : sbox_t := (
        x"9db30420", x"1fb6e9de", x"a7be7bef", x"d273a298",
        x"4a4f7bdb", x"64ad8c57", x"85510443", x"fa020ed1",
        x"7e287aff", x"e60fb663", x"095f35a1", x"79ebf120",
        x"fd059d43", x"6497b7b1", x"f3641f63", x"241e4adf",
        x"28147f5f", x"4fa2b8cd", x"c9430040", x"0cc32220",
        x"fdd30b30", x"c0a5374f", x"1d2d00d9", x"24147b15",
        x"ee4d111a", x"0fca5167", x"71ff904c", x"2d195ffe",
        x"1a05645f", x"0c13fefe", x"081b08ca", x"05170121",
        x"80530100", x"e83e5efe", x"ac9af4f8", x"7fe72701",
        x"d2b8ee5f", x"06df4261", x"bb9e9b8a", x"7293ea25",
        x"ce84ffdf", x"f5718801", x"3dd64b04", x"a26f263b",
        x"7ed48400", x"547eebe6", x"446d4ca0", x"6cf3d6f5",
        x"2649abdf", x"aea0c7f5", x"36338cc1", x"503f7e93",
        x"d3772061", x"11b638e1", x"72500e03", x"f80eb2bb",
        x"abe0502e", x"ec8d77de", x"57971e81", x"e14f6746",
        x"c9335400", x"6920318f", x"081dbb99", x"ffc304a5",
        x"4d351805", x"7f3d5ce3", x"a6c866c6", x"5d5bcca9",
        x"daec6fea", x"9f926f91", x"9f46222f", x"3991467d",
        x"a5bf6d8e", x"1143c44f", x"43958302", x"d0214eeb",
        x"022083b8", x"3fb6180c", x"18f8931e", x"281658e6",
        x"26486e3e", x"8bd78a70", x"7477e4c1", x"b506e07c",
        x"f32d0a25", x"79098b02", x"e4eabb81", x"28123b23",
        x"69dead38", x"1574ca16", x"df871b62", x"211c40b7",
        x"a51a9ef9", x"0014377b", x"041e8ac8", x"09114003",
        x"bd59e4d2", x"e3d156d5", x"4fe876d5", x"2f91a340",
        x"557be8de", x"00eae4a7", x"0ce5c2ec", x"4db4bba6",
        x"e756bdff", x"dd3369ac", x"ec17b035", x"06572327",
        x"99afc8b0", x"56c8c391", x"6b65811c", x"5e146119",
        x"6e85cb75", x"be07c002", x"c2325577", x"893ff4ec",
        x"5bbfc92d", x"d0ec3b25", x"b7801ab7", x"8d6d3b24",
        x"20c763ef", x"c366a5fc", x"9c382880", x"0ace3205",
        x"aac9548a", x"eca1d7c7", x"041afa32", x"1d16625a",
        x"6701902c", x"9b757a54", x"31d477f7", x"9126b031",
        x"36cc6fdb", x"c70b8b46", x"d9e66a48", x"56e55a79",
        x"026a4ceb", x"52437eff", x"2f8f76b4", x"0df980a5",
        x"8674cde3", x"edda04eb", x"17a9be04", x"2c18f4df",
        x"b7747f9d", x"ab2af7b4", x"efc34d20", x"2e096b7c",
        x"1741a254", x"e5b6a035", x"213d42f6", x"2c1c7c26",
        x"61c2f50f", x"6552daf9", x"d2c231f8", x"25130f69",
        x"d8167fa2", x"0418f2c8", x"001a96a6", x"0d1526ab",
        x"63315c21", x"5e0a72ec", x"49bafefd", x"187908d9",
        x"8d0dbd86", x"311170a7", x"3e9b640c", x"cc3e10d7",
        x"d5cad3b6", x"0caec388", x"f73001e1", x"6c728aff",
        x"71eae2a1", x"1f9af36e", x"cfcbd12f", x"c1de8417",
        x"ac07be6b", x"cb44a1d8", x"8b9b0f56", x"013988c3",
        x"b1c52fca", x"b4be31cd", x"d8782806", x"12a3a4e2",
        x"6f7de532", x"58fd7eb6", x"d01ee900", x"24adffc2",
        x"f4990fc5", x"9711aac5", x"001d7b95", x"82e5e7d2",
        x"109873f6", x"00613096", x"c32d9521", x"ada121ff",
        x"29908415", x"7fbb977f", x"af9eb3db", x"29c9ed2a",
        x"5ce2a465", x"a730f32c", x"d0aa3fe8", x"8a5cc091",
        x"d49e2ce7", x"0ce454a9", x"d60acd86", x"015f1919",
        x"77079103", x"dea03af6", x"78a8565e", x"dee356df",
        x"21f05cbe", x"8b75e387", x"b3c50651", x"b8a5c3ef",
        x"d8eeb6d2", x"e523be77", x"c2154529", x"2f69efdf",
        x"afe67afb", x"f470c4b2", x"f3e0eb5b", x"d6cc9876",
        x"39e4460c", x"1fda8538", x"1987832f", x"ca007367",
        x"a99144f8", x"296b299e", x"492fc295", x"9266beab",
        x"b5676e69", x"9bd3ddda", x"df7e052f", x"db25701c",
        x"1b5e51ee", x"f65324e6", x"6afce36c", x"0316cc04",
        x"8644213e", x"b7dc59d0", x"7965291f", x"ccd6fd43",
        x"41823979", x"932bcdf6", x"b657c34d", x"4edfd282",
        x"7ae5290c", x"3cb9536b", x"851e20fe", x"9833557e",
        x"13ecf0b0", x"d3ffb372", x"3f85c5c1", x"0aef7ed2"
    );

    -- ── Tm / Tr computation ───────────────────────────────────────────
    -- Tm : masking constants, seeded from Cm = 2^30*sqrt(2) = 0x5A827999
    --      incremented by Mm = 2^30*sqrt(3) = 0x6ED9EBA1 each step
    -- Tr : rotation constants, seeded from Cr = 19, incremented by Mr = 17 mod 32
    function compute_tm return tm_array_t is
        variable result : tm_array_t;
        variable cm     : unsigned(31 downto 0) := x"5A827999";
        constant mm     : unsigned(31 downto 0) := x"6ED9EBA1";
    begin
        for i in 0 to 23 loop
            for j in 0 to 7 loop
                result(i)(j) := std_ulogic_vector(cm);
                cm := cm + mm;   -- wraps naturally at 2^32
            end loop;
        end loop;
        return result;
    end function;

    function compute_tr return tr_array_t is
        variable result : tr_array_t;
        variable cr     : integer := 19;
    begin
        for i in 0 to 23 loop
            for j in 0 to 7 loop
                result(i)(j) := std_ulogic_vector(to_unsigned(cr, 5));
                cr := (cr + 17) mod 32;
            end loop;
        end loop;
        return result;
    end function;

    constant TM : tm_array_t := compute_tm;
    constant TR : tr_array_t := compute_tr;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ rotate_left32                                                    │
    -- │                                                                  │
    -- │ Rotates a 32-bit value left by n positions (n in 0..31).         │
    -- │ Implemented as shift_left OR shift_right to avoid variable-range │
    -- │ slicing.                                                         │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - val [word32_t] : input value to rotate                       │
    -- │   - n   [word5_t]  : rotation amount (0..31)                     │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - word32_t : rotated value                                     │
    -- └──────────────────────────────────────────────────────────────────┘
    function rotate_left32(val : word32_t; n : word5_t) return word32_t is
        variable ni : integer range 0 to 31;
        variable uv : unsigned(31 downto 0);
    begin
        ni := to_integer(unsigned(n));
        uv := unsigned(val);
        if ni = 0 then
            return val;
        end if;
        return std_ulogic_vector(shift_left(uv, ni) or shift_right(uv, 32 - ni));
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ f1  —  Round function Type 1 (RFC 2612 Section 2.1)              │
    -- │                                                                  │
    -- │   I = ((Km + D) <<< Kr)                                          │
    -- │   O = ((S1[Ia] ^ S2[Ib]) - S3[Ic]) + S4[Id]                      │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - d  [word32_t] : data input                                   │
    -- │   - kr [word5_t]  : rotation subkey                              │
    -- │   - km [word32_t] : masking subkey                               │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - word32_t : round function output                             │
    -- └──────────────────────────────────────────────────────────────────┘
    function f1(d : word32_t; kr : word5_t; km : word32_t) return word32_t is
        variable i_val          : word32_t;
        variable ia, ib, ic, id : integer range 0 to 255;
        variable s1v, s2v, s3v, s4v : unsigned(31 downto 0);
    begin
        i_val := rotate_left32(std_ulogic_vector(unsigned(km) + unsigned(d)), kr);
        ia := to_integer(unsigned(i_val(31 downto 24)));
        ib := to_integer(unsigned(i_val(23 downto 16)));
        ic := to_integer(unsigned(i_val(15 downto  8)));
        id := to_integer(unsigned(i_val( 7 downto  0)));
        s1v := unsigned(SBOX1(ia));
        s2v := unsigned(SBOX2(ib));
        s3v := unsigned(SBOX3(ic));
        s4v := unsigned(SBOX4(id));
        return std_ulogic_vector((s1v xor s2v) - s3v + s4v);
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ f2  —  Round function Type 2 (RFC 2612 Section 2.1)              │
    -- │                                                                  │
    -- │   I = ((Km ^ D) <<< Kr)                                          │
    -- │   O = ((S1[Ia] - S2[Ib]) + S3[Ic]) ^ S4[Id]                      │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - d  [word32_t] : data input                                   │
    -- │   - kr [word5_t]  : rotation subkey                              │
    -- │   - km [word32_t] : masking subkey                               │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - word32_t : round function output                             │
    -- └──────────────────────────────────────────────────────────────────┘
    function f2(d : word32_t; kr : word5_t; km : word32_t) return word32_t is
        variable i_val          : word32_t;
        variable ia, ib, ic, id : integer range 0 to 255;
        variable s1v, s2v, s3v, s4v : unsigned(31 downto 0);
    begin
        i_val := rotate_left32(km xor d, kr);
        ia := to_integer(unsigned(i_val(31 downto 24)));
        ib := to_integer(unsigned(i_val(23 downto 16)));
        ic := to_integer(unsigned(i_val(15 downto  8)));
        id := to_integer(unsigned(i_val( 7 downto  0)));
        s1v := unsigned(SBOX1(ia));
        s2v := unsigned(SBOX2(ib));
        s3v := unsigned(SBOX3(ic));
        s4v := unsigned(SBOX4(id));
        return std_ulogic_vector((s1v - s2v + s3v) xor s4v);
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ f3  —  Round function Type 3 (RFC 2612 Section 2.1)              │
    -- │                                                                  │
    -- │   I = ((Km - D) <<< Kr)                                          │
    -- │   O = ((S1[Ia] + S2[Ib]) ^ S3[Ic]) - S4[Id]                      │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - d  [word32_t] : data input                                   │
    -- │   - kr [word5_t]  : rotation subkey                              │
    -- │   - km [word32_t] : masking subkey                               │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - word32_t : round function output                             │
    -- └──────────────────────────────────────────────────────────────────┘
    function f3(d : word32_t; kr : word5_t; km : word32_t) return word32_t is
        variable i_val          : word32_t;
        variable ia, ib, ic, id : integer range 0 to 255;
        variable s1v, s2v, s3v, s4v : unsigned(31 downto 0);
    begin
        i_val := rotate_left32(std_ulogic_vector(unsigned(km) - unsigned(d)), kr);
        ia := to_integer(unsigned(i_val(31 downto 24)));
        ib := to_integer(unsigned(i_val(23 downto 16)));
        ic := to_integer(unsigned(i_val(15 downto  8)));
        id := to_integer(unsigned(i_val( 7 downto  0)));
        s1v := unsigned(SBOX1(ia));
        s2v := unsigned(SBOX2(ib));
        s3v := unsigned(SBOX3(ic));
        s4v := unsigned(SBOX4(id));
        return std_ulogic_vector(((s1v + s2v) xor s3v) - s4v);
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ w_octave                                                         │
    -- │                                                                  │
    -- │ One W-octave step of the key schedule (RFC 2612 Section 2.4).    │
    -- │ Updates all 8 KAPPA words using round functions and Tm/Tr        │
    -- │ constants for octave index i. Each step depends on the previous  │
    -- │ update, so variables propagate changes within the same call.     │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - kap [kappa_t]          : current KAPPA state                 │
    -- │   - i   [integer 0 to 23]  : octave index                        │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - kappa_t : updated KAPPA state                                │
    -- └──────────────────────────────────────────────────────────────────┘
    function w_octave(kap : kappa_t; i : integer range 0 to 23) return kappa_t is
        variable k : kappa_t;
    begin
        k   := kap;
        k.g := k.g xor f1(k.h, TR(i)(0), TM(i)(0));
        k.f := k.f xor f2(k.g, TR(i)(1), TM(i)(1));
        k.e := k.e xor f3(k.f, TR(i)(2), TM(i)(2));
        k.d := k.d xor f1(k.e, TR(i)(3), TM(i)(3));
        k.c := k.c xor f2(k.d, TR(i)(4), TM(i)(4));
        k.b := k.b xor f3(k.c, TR(i)(5), TM(i)(5));
        k.a := k.a xor f1(k.b, TR(i)(6), TM(i)(6));
        k.h := k.h xor f2(k.a, TR(i)(7), TM(i)(7));
        return k;
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ q_round  —  Forward quad-round Q(i)                              │
    -- │                                                                  │
    -- │   C = C ^ f1(D, Kr0(i), Km0(i))                                  │
    -- │   B = B ^ f2(C, Kr1(i), Km1(i))                                  │
    -- │   A = A ^ f3(B, Kr2(i), Km2(i))                                  │
    -- │   D = D ^ f1(A, Kr3(i), Km3(i))                                  │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - b  [beta_t]             : current data state (A,B,C,D)       │
    -- │   - i  [integer 0 to 11]    : round index                        │
    -- │   - kr [kr_array_t]         : rotation subkey array              │
    -- │   - km [km_array_t]         : masking subkey array               │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - beta_t : data state after the forward quad-round             │
    -- └──────────────────────────────────────────────────────────────────┘
    function q_round(b : beta_t; i : integer range 0 to 11;
                     kr : kr_array_t; km : km_array_t) return beta_t is
        variable bv : beta_t;
    begin
        bv   := b;
        bv.c := bv.c xor f1(bv.d, kr(i)(0), km(i)(0));
        bv.b := bv.b xor f2(bv.c, kr(i)(1), km(i)(1));
        bv.a := bv.a xor f3(bv.b, kr(i)(2), km(i)(2));
        bv.d := bv.d xor f1(bv.a, kr(i)(3), km(i)(3));
        return bv;
    end function;

    -- ┌──────────────────────────────────────────────────────────────────┐
    -- │ qbar_round  —  Reverse quad-round QBAR(i)                        │
    -- │                                                                  │
    -- │   D = D ^ f1(A, Kr3(i), Km3(i))                                  │
    -- │   A = A ^ f3(B, Kr2(i), Km2(i))                                  │
    -- │   B = B ^ f2(C, Kr1(i), Km1(i))                                  │
    -- │   C = C ^ f1(D, Kr0(i), Km0(i))                                  │
    -- │                                                                  │
    -- │ Args :                                                           │
    -- │   - b  [beta_t]             : current data state (A,B,C,D)       │
    -- │   - i  [integer 0 to 11]    : round index                        │
    -- │   - kr [kr_array_t]         : rotation subkey array              │
    -- │   - km [km_array_t]         : masking subkey array               │
    -- │                                                                  │
    -- │ Returns :                                                        │
    -- │   - beta_t : data state after the reverse quad-round             │
    -- └──────────────────────────────────────────────────────────────────┘
    function qbar_round(b : beta_t; i : integer range 0 to 11;
                        kr : kr_array_t; km : km_array_t) return beta_t is
        variable bv : beta_t;
    begin
        bv   := b;
        bv.d := bv.d xor f1(bv.a, kr(i)(3), km(i)(3));
        bv.a := bv.a xor f3(bv.b, kr(i)(2), km(i)(2));
        bv.b := bv.b xor f2(bv.c, kr(i)(1), km(i)(1));
        bv.c := bv.c xor f1(bv.d, kr(i)(0), km(i)(0));
        return bv;
    end function;

end package body cast256_pkg;
