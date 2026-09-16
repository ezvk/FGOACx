# Compilation croisée de fgostub.dll.
#
# ⚠️ -nostdlib -nodefaultlibs : le mingw de nixpkgs lie par défaut contre
# libmcfgthread, absent. La DLL n'utilise aucune bibliothèque C standard.
CC ?= x86_64-w64-mingw32-gcc

fgostub.dll: fgostub.c
	$(CC) -O2 -shared -nostdlib -nodefaultlibs \
	      -o $@ $< -lkernel32 -luser32 -Wl,--entry=DllMain

clean:
	rm -f fgostub.dll

# Sous NixOS, sans installer de chaîne de compilation :
#   nix shell nixpkgs#pkgsCross.mingwW64.buildPackages.gcc -c make
.PHONY: clean
