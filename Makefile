.PHONY: build test run run-dev perf clean

build:
	zig build

test:
	zig build test

run:
	zig build run

run-dev:
	zig build run -- --config ./config.toml

perf:
	zig build perf

clean:
	rm -rf zig-out .zig-cache
