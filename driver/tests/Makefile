# tests/Makefile - driver unit tests and end-to-end tests
#
# Targets
#   all   : build and run both test suites
#   unit  : build and run test_logic (driver unit tests, no hardware model)
#   e2e   : build and run test_e2e  (driver ↔ hardware model)
#   build : build both binaries without running
#   clean : remove built binaries and temporary cast build directory

CC     := gcc
CFLAGS := -Wall -Wextra -O2 -std=c11 -DCRYPTO_TEST_BUILD

DRIVER_DIR  := ..
TEST_SUITE  := ../../vhdl/crypto/cast256/test_suite

DRIVER_HDRS := $(DRIVER_DIR)/crypto_driver.h \
               $(DRIVER_DIR)/crypto_regs.h    \
               $(DRIVER_DIR)/crypto_errors.h  \
               $(DRIVER_DIR)/crypto_hw_priv.h

# ── cast256_standalone.c: self-contained CAST-256, no std_defs.h dependency.
#    cast.c (Brian Gladman original) expands macros with switch-statements at
#    file scope, which is invalid C11.  cast256_standalone.c avoids this.
CAST_SRC := $(TEST_SUITE)/cast256_standalone.c

# ── Unit tests (test_logic) ───────────────────────────────────────────────────
UNIT_BIN  := test_logic
UNIT_SRCS := test_logic.c $(DRIVER_DIR)/crypto_driver.c
UNIT_INC  := -I$(DRIVER_DIR)

$(UNIT_BIN): $(UNIT_SRCS) $(DRIVER_HDRS)
	$(CC) $(CFLAGS) $(UNIT_INC) $(UNIT_SRCS) -o $@

# ── End-to-end tests (test_e2e) ───────────────────────────────────────────────
E2E_BIN  := test_e2e
E2E_SRCS := test_e2e.c \
            hw_model.c \
            $(DRIVER_DIR)/crypto_driver.c \
            $(TEST_SUITE)/gcm_ref.c \
            $(CAST_SRC)
E2E_INC  := -I$(DRIVER_DIR) -I$(TEST_SUITE) -I.

$(E2E_BIN): $(E2E_SRCS) hw_model.h $(DRIVER_HDRS) $(TEST_SUITE)/gcm_ref.h
	$(CC) $(CFLAGS) $(E2E_INC) $(E2E_SRCS) -o $@

# ── Phony targets ─────────────────────────────────────────────────────────────

.PHONY: all unit e2e build clean

all: unit e2e

unit: $(UNIT_BIN)
	./$(UNIT_BIN)

e2e: $(E2E_BIN)
	./$(E2E_BIN)

build: $(UNIT_BIN) $(E2E_BIN)

clean:
	rm -f $(UNIT_BIN) $(E2E_BIN)
