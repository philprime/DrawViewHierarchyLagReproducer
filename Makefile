SHELL := /bin/bash
.DEFAULT_GOAL := build

APP := DrawViewHierarchyLagReproducer
BUNDLE_ID := io.sentry.bug-report.DrawVewHierarchyLagReproducer
# Use the first booted simulator unless DEVICE=<UDID> is supplied.
DEVICE ?= $(shell xcrun simctl list devices booted -j | jq -r '[.devices[][] | select(.state == "Booted") | .udid][0] // empty')
CONFIGURATION ?= Debug
BUILD_DIR := $(CURDIR)/.build
APP_PATH := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)-iphonesimulator/$(APP).app
DURATION ?= 20s
TEMPLATE ?= CPU Profiler
# Evaluate once so every command in a make invocation uses the same output path.
TRACE_STAMP := $(shell date +%Y%m%d-%H%M%S)
TRACE ?= $(CURDIR)/Traces/capture-$(TRACE_STAMP).trace

.PHONY: help check-device build install run record inspect open format analyze

help:
	@printf '%s\n' \
		'Boot an iOS Simulator first.' \
		'make build     Build the standalone app (no dependencies or signing).' \
		'make run       Build, install, and launch.' \
		'make record    Build, install, and record CPU samples for 20 seconds.' \
		'make inspect TRACE=/path/to/capture.trace   Verify a CPU Profiler recording.' \
		'make open TRACE=/path/to/capture.trace      Open in Instruments.' \
		'make format    Format the Swift sources.' \
		'make analyze   Run the Xcode static analyzer.' \
		'Overrides: DEVICE=<UDID> DURATION=60s TEMPLATE="Time Profiler" CONFIGURATION=Release'

check-device:
	@test -n "$(DEVICE)" || (echo 'No booted simulator. Boot one in Simulator, or set DEVICE=<UDID>.' >&2; exit 1)

build: check-device
	xcodebuild -quiet \
		-project "$(APP).xcodeproj" -scheme "$(APP)" \
		-configuration "$(CONFIGURATION)" \
		-destination 'platform=iOS Simulator,id=$(DEVICE)' \
		-derivedDataPath "$(BUILD_DIR)" CODE_SIGNING_ALLOWED=NO build

format:
	xcrun swift-format format --in-place Sources/ContentView.swift Sources/MyApp.swift

analyze: check-device
	xcodebuild -quiet \
		-project "$(APP).xcodeproj" -scheme "$(APP)" \
		-configuration "$(CONFIGURATION)" \
		-destination 'platform=iOS Simulator,id=$(DEVICE)' \
		-derivedDataPath "$(BUILD_DIR)" CODE_SIGNING_ALLOWED=NO analyze

install: build
	xcrun simctl install "$(DEVICE)" "$(APP_PATH)"

run: install
	xcrun simctl launch "$(DEVICE)" "$(BUNDLE_ID)"

# Unique output names preserve previous recordings. Stop the app before recording if already running.
record: install
	mkdir -p "$(dir $(TRACE))"
	xcrun xctrace record \
		--template "$(TEMPLATE)" --device "$(DEVICE)" \
		--time-limit "$(DURATION)" --output "$(TRACE)" \
		--launch -- "$(APP_PATH)"
	@printf '\nTrace: %s\nInspect: make inspect TRACE="%s"\n' "$(TRACE)" "$(TRACE)"

# CPU samples establish the stack and cadence. Signposts give exact call durations.
# This inspection expects the CPU Profiler template, even if record uses another one.
inspect:
	@test -d "$(TRACE)" || (echo 'Set TRACE to an existing .trace bundle.' >&2; exit 1)
	xcrun xctrace export --input "$(TRACE)" \
		--xpath '/trace-toc/run[@number="1"]/data/table[@schema="cpu-profile"]' \
		--output "$(TRACE).cpu.xml"
	xcrun xctrace export --input "$(TRACE)" \
		--xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' \
		--output "$(TRACE).signposts.xml"
	python3 inspect_trace.py "$(TRACE).cpu.xml" "$(TRACE).signposts.xml"

open:
	open -a Instruments "$(TRACE)"
