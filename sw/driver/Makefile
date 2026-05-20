# Makefile — CAST-256-GCM driver build rules
#
# Targets:
#   make lib        Cross-compile driver static library for Zybo (ARM Cortex-A9)
#   make tests_arm  Cross-compile on-board hardware test binary
#   make test       Build and run host-side logic tests (requires GCC)
#   make clean      Remove all build artefacts
#
# Requirements:
#   ARM cross-compile: arm-linux-gnueabihf-gcc (install via apt or Xilinx SDK)
#   Host tests:        gcc (Linux / MSYS2 MinGW)

CC_ARM  := arm-linux-gnueabihf-gcc
CC_HOST := gcc

CFLAGS_COMMON := -Wall -Wextra -O2 -std=c11
CFLAGS_ARM    := $(CFLAGS_COMMON) -march=armv7-a -mfpu=neon -mfloat-abi=hard
CFLAGS_HOST   := $(CFLAGS_COMMON) -DCRYPTO_TEST_BUILD

DRIVER_SRCS := crypto_driver.c crypto_mem.c
TEST_SRCS   := crypto_driver.c crypto_mem.c crypto_test.c

# ---------------------------------------------------------------------------
# ARM cross-compile targets
# ---------------------------------------------------------------------------

lib: libcrypto_driver.a

libcrypto_driver.a: $(DRIVER_SRCS) crypto_driver.h crypto_regs.h crypto_errors.h crypto_hw_priv.h
	$(CC_ARM) $(CFLAGS_ARM) -c crypto_driver.c -o crypto_driver_arm.o
	$(CC_ARM) $(CFLAGS_ARM) -c crypto_mem.c    -o crypto_mem_arm.o
	ar rcs $@ crypto_driver_arm.o crypto_mem_arm.o

tests_arm: $(TEST_SRCS) crypto_driver.h crypto_regs.h crypto_errors.h crypto_hw_priv.h
	$(CC_ARM) $(CFLAGS_ARM) $(TEST_SRCS) -o crypto_tests_arm

# ---------------------------------------------------------------------------
# Host-side logic tests (no hardware required)
# ---------------------------------------------------------------------------

HOST_TEST_SRCS := tests/test_logic.c crypto_driver.c

test: tests/test_logic
	./tests/test_logic

tests/test_logic: $(HOST_TEST_SRCS) crypto_driver.h crypto_regs.h crypto_errors.h crypto_hw_priv.h
	$(CC_HOST) $(CFLAGS_HOST) -I. $(HOST_TEST_SRCS) -o $@

# ---------------------------------------------------------------------------

clean:
	rm -f *.o libcrypto_driver.a crypto_tests_arm tests/test_logic

.PHONY: lib tests_arm test clean
