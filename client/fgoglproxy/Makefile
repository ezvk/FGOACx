# Proxy opengl32 minimal. Voir docs/MATERIEL.md pour le pourquoi.
#
# ⚠️ fgoglproxy.def est GÉNÉRÉ à partir des exports du opengl32 de votre Proton.
# Le régénérer si la version de Proton change :
#
#   objdump -p <proton>/files/lib/wine/x86_64-windows/opengl32.dll \
#     | sed -n '/\[Ordinal\/Name Pointer\] Table/,$$p' \
#     | grep -E '^\s+\[ *[0-9]+\] \+base\[' | awk '{print $$NF}' | sort -u
#
# puis un .def avec « nom=opengl32real.nom » pour tous sauf wglGetProcAddress.
CC ?= x86_64-w64-mingw32-gcc

opengl32.dll: fgoglproxy.c fgoglproxy.def
	$(CC) -O2 -shared -nostdlib -nodefaultlibs \
	      -o $@ fgoglproxy.c fgoglproxy.def -lkernel32 -Wl,--entry=DllMain

clean:
	rm -f opengl32.dll

# ⚠️ À L'INSTALLATION : copier opengl32.dll dans App/, et le VRAI opengl32 de
# Proton dans App/opengl32real.dll, puis WINEDLLOVERRIDES="opengl32=n,b".
.PHONY: clean
