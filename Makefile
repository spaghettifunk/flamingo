.PHONY: build test run run-dev perf homebrew-sha clean

build:
	zig build

test:
	zig build test

run:
	zig build run

run-dev:
	zig build run -- --config ./config.local.toml

perf:
	zig build perf

homebrew-sha:
	@test -n "$(VERSION)" || (echo "usage: make homebrew-sha VERSION=1.0.0" && exit 1)
	curl -L -o /tmp/flamingo-v$(VERSION).tar.gz https://github.com/spaghettifunk/flamingo/archive/refs/tags/v$(VERSION).tar.gz
	shasum -a 256 /tmp/flamingo-v$(VERSION).tar.gz

clean:
	rm -rf zig-out .zig-cache
