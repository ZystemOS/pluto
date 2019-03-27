BIN = ../../bin/boot

INCLUDES = ./

1stSTAGE_SOURCE = bootloader.asm
1stSTAGE_BINARY = bootloader.bin

2ndSTAGE_SOURCE = 2ndstage.asm
2ndSTAGE_BINARY = 2ndstage.bin

ASM = nasm
ASMFLAGS = -f bin

all: clean $(BIN)/$(2ndSTAGE_BINARY) $(BIN)/$(1stSTAGE_BINARY) | $(BIN)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/$(2ndSTAGE_BINARY): $(2ndSTAGE_SOURCE) | $(BIN)
	@echo "\nMaking 2nd stage bootloader\n"
	$(ASM) $< -o $@ $(ASMFLAGS)

$(BIN)/$(1stSTAGE_BINARY): $(1stSTAGE_SOURCE) | $(BIN)
	@echo "\nMaking bootloader\n"
	$(ASM) $< -o $@ $(ASMFLAGS)

clean:
	@echo "\nCleanning the workspace\n"
	rm -f $(BIN)/*.bin
