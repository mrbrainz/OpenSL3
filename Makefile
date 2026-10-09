# Build with: brew install libusb pkg-config && make
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
USB     := $(shell pkg-config --cflags --libs libusb-1.0)
BUILD   := build

PROGS := $(BUILD)/sl3bridge $(BUILD)/sl3probe $(BUILD)/sl3play $(BUILD)/sl3ctl $(BUILD)/sl3usbtiming

all: $(PROGS)

$(BUILD):
	mkdir -p $@

$(BUILD)/sl3bridge: src/sl3bridge.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< $(USB) -framework CoreAudio -framework CoreFoundation -lpthread

$(BUILD)/%: tools/%.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< $(USB) -lm

$(BUILD)/sl3usbtiming: tools/sl3usbtiming.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< $(USB) -framework Foundation -framework IOKit -framework IOUSBHost

clean:
	rm -rf $(BUILD)

.PHONY: all clean
