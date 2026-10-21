CC = x86_64-w64-mingw32-gcc
CFLAGS = -O2 -Wall -mwindows

repro.exe: repro.c
	$(CC) $(CFLAGS) -o $@ $< -luser32 -lgdi32

clean:
	rm -f repro.exe
	rm -rf out

.PHONY: clean
