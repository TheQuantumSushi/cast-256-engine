# tests/Makefile — host-side logic test build
#
# Usage (from this directory):
#   make        Build and run
#   make build  Build only
#   make clean  Remove binary

CC     := gcc
CFLAGS := -Wall -Wextra -O2 -std=c11 -DCRYPTO_TEST_BUILD -I..

SRCS := test_logic.c ../crypto_driver.c
BIN  := test_logic

.PHONY: all build clean

all: build
	./$(BIN)

build: $(BIN)

$(BIN): $(SRCS) ../crypto_driver.h ../crypto_regs.h ../crypto_errors.h ../crypto_hw_priv.h
	$(CC) $(CFLAGS) $(SRCS) -o $@

clean:
	rm -f $(BIN)
