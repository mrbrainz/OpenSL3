# Build with: brew install libusb pkg-config && make
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
USB     := $(shell pkg-config --cflags --libs libusb-1.0)
BUILD   := build

PROGS := $(BUILD)/sl3bridge $(BUILD)/sl3bridge-iousbhost $(BUILD)/sl3probe $(BUILD)/sl3play $(BUILD)/sl3ctl $(BUILD)/sl3usbtiming

all: $(PROGS)

$(BUILD):
	mkdir -p $@

$(BUILD)/sl3bridge: src/sl3bridge.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< $(USB) -framework CoreAudio -framework CoreFoundation -lpthread

$(BUILD)/sl3bridge-iousbhost: src/sl3bridge.c src/iousbhost_streams.m | $(BUILD)
	$(CC) $(CFLAGS) -x objective-c -fobjc-arc -DSL3_IOUSBHOST -o $@ $< -framework CoreAudio -framework CoreFoundation -framework Foundation -framework IOKit -framework IOUSBHost -lpthread

$(BUILD)/%: tools/%.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< $(USB) -lm

$(BUILD)/sl3usbtiming: tools/sl3usbtiming.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< $(USB) -framework Foundation -framework IOKit -framework IOUSBHost

PROBE := $(BUILD)/SL3Probe.driver
probe-plugin: $(PROBE)
$(PROBE): plugin/SL3Probe.m plugin/Info.plist | $(BUILD)
	mkdir -p $@/Contents/MacOS
	cp plugin/Info.plist $@/Contents/
	$(CC) $(CFLAGS) -fobjc-arc -bundle -o $@/Contents/MacOS/SL3Probe $< -framework Foundation -framework CoreFoundation -framework IOKit -framework IOUSBHost
	codesign -s - -f $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean probe-plugin
