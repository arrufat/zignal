zig = zig
zig_version != $(zig) version

.PHONY: clean zig-version

default: debug

zig-version:
	@echo zig-$(zig_version)

all: wasm linux macos windows

debug: zig-version
	$(zig) build -Doptimize=Debug

native: zig-version
	$(zig) build -Doptimize=ReleaseFast

wasm: zig-version
	$(zig) build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

wasm-debug: zig-version
	$(zig) build -Dtarget=wasm32-freestanding -Doptimize=Debug

linux: zig-version
	$(zig) build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast

macos: zig-version
	$(zig) build -Dtarget=aarch64-macos-none -Doptimize=ReleaseFast

windows: zig-version
	$(zig) build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast

test: zig-version
	$(zig) build test --summary all

clean:
	rm -rf zig-out .zig-cache

serve: wasm
	python -m http.server 8000 -b 127.0.0.1 -d zig-out

serve-debug: wasm-debug
	python -m http.server 8000 -b 127.0.0.1 -d zig-out
