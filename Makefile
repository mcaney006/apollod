# apollod: assembled with as, linked with ld. No clang driver, no crt objects, no libc code.
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)
AS      := as
LD      := ld
ASFLAGS := -arch arm64
# -lSystem: ld requires it for LC_LOAD_DYLINKER; nothing is imported (make verify-imports).
# -static (LC_UNIXTHREAD) is killed at exec on arm64 macOS.
LDFLAGS := -arch arm64 -e _start -lSystem -syslibroot $(SDK)

SRC := $(wildcard src/*.s)
OBJ := $(patsubst src/%.s,build/%.o,$(SRC))

all: apollod

apollod: $(OBJ)
	$(LD) $(LDFLAGS) -o $@ $^

build/%.o: src/%.s | build
	$(AS) $(ASFLAGS) -o $@ $<

build:
	mkdir -p build

run: apollod
	./apollod

test/unit: build/unit.o build/lib.o
	$(LD) $(LDFLAGS) -o $@ $^

build/unit.o: test/unit.s | build
	$(AS) $(ASFLAGS) -o $@ $<

test: apollod test/unit
	./test/unit
	./test/e2e.sh
	$(MAKE) -s verify-imports

bench: apollod
	./test/bench.sh

apollod-min: build/apollod-min.o
	$(LD) $(LDFLAGS) -o $@ $<

build/apollod-min.o: min/apollod-min.s | build
	$(AS) $(ASFLAGS) -o $@ $<

compare: apollod apollod-min
	./test/compare.sh

disasm: apollod
	otool -tv apollod

inspect: apollod
	otool -hv apollod
	otool -l apollod
	otool -L apollod
	nm -m apollod
	size -m apollod

verify-imports: apollod
	@u="$$(nm -u apollod)"; if [ -z "$$u" ]; then echo "verify-imports: no undefined symbols"; else echo "unexpected imports:"; echo "$$u"; exit 1; fi

clean:
	rm -rf build apollod apollod-min test/unit

.PHONY: all run test bench compare disasm inspect verify-imports clean
