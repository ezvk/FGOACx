/* Proxy opengl32 minimal pour FGO Arcade sous Wine.
 *
 * ⚠️ POURQUOI : ago.exe resout TOUTES ses fonctions GL par wglGetProcAddress,
 * y compris le coeur OpenGL 1.1. La specification autorise NULL pour celles-la
 * -- elles sont exportees directement par opengl32.dll -- et Wine respecte la
 * spec. Le pilote NVIDIA sous Windows, lui, les renvoie quand meme. D ou un
 * appel vers l adresse 0 sur toute pile qui n est pas NVIDIA : mesure sur
 * Intel Arc B390 ET sur Radeon 780M, meme adresse ago.exe+0xBE1E06.
 *
 * ⚠️ POURQUOI PAS LE SHIM DE FLUPHUS : il corrige bien ce point, mais il
 * intercepte AUSSI la compilation des shaders, meme quand il n a rien a
 * emuler. Preuve : sur NVIDIA sans shim, App/shader-cache-r2/ reste VIDE et le
 * jeu tourne ; sur Radeon avec shim, 109 shaders y sont caches (dont zero avec
 * _amdshim_, l extension bindless etant native) et le jeu plante a
 * ago.exe+0xC084F7 sur une ressource nulle. Mesa ne signale aucune erreur GL :
 * le probleme est dans le proxy, pas dans le pilote.
 *
 * Ce proxy ne fait donc QUE corriger wglGetProcAddress. Tout le reste est
 * forwarde intact par le .def vers opengl32real.dll, une copie du vrai
 * opengl32 de Wine posee a cote.
 */
#include <windows.h>

typedef PROC (WINAPI *wglGetProcAddress_t)(LPCSTR);

static HMODULE reel;
static wglGetProcAddress_t reel_wglGetProcAddress;

static void journal(const char *msg)
{
    HANDLE h = CreateFileA("..\\logs\\fgoglproxy.log", FILE_APPEND_DATA,
                           FILE_SHARE_READ, NULL, OPEN_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w; WriteFile(h, msg, lstrlenA(msg), &w, NULL); CloseHandle(h);
    }
}

PROC WINAPI wglGetProcAddress(LPCSTR nom)
{
    PROC p;

    if (!reel) return NULL;

    /* 1. la voie normale */
    if (reel_wglGetProcAddress) {
        p = reel_wglGetProcAddress(nom);
        if (p) return p;
    }

    /* 2. ⚠️ LE CORRECTIF : les fonctions du coeur GL 1.1 sont exportees
     * directement par opengl32.dll. wglGetProcAddress a le droit de renvoyer
     * NULL pour elles ; GetProcAddress, lui, les trouve. */
    p = (PROC)GetProcAddress(reel, nom);
    if (p) return p;

    /* 3. ⚠️ LE VRAI CORRECTIF POUR AMD ET INTEL, mesure le 2026-09-16 :
     * ago.exe demande les fonctions de GL_NV_bindless_texture -- suffixe NV,
     * la variante NVIDIA. Mesa implemente GL_ARB_bindless_texture, suffixe
     * ARB, fonctionnellement equivalente : l ARB derive de la NV. Sans cette
     * traduction, glGetTextureHandleNV renvoie NULL et le jeu appelle
     * l adresse 0 (ago.exe+0xBE1E06). C est la raison REELLE du
     * « NVIDIA seulement » de l amont.
     *
     * On remplace le suffixe NV final par ARB et on retente les deux voies. */
    {
        int n = 0;
        while (nom[n]) n++;
        if (n >= 3 && nom[n-2] == 78 && nom[n-1] == 86) {
            char arb[128];
            int i;
            if (n + 2 < (int)sizeof(arb)) {
                for (i = 0; i < n - 2; i++) arb[i] = nom[i];
                arb[i++] = 65; arb[i++] = 82; arb[i++] = 66; arb[i] = 0;
                if (reel_wglGetProcAddress) {
                    p = reel_wglGetProcAddress(arb);
                    if (p) return p;
                }
                p = (PROC)GetProcAddress(reel, arb);
                if (p) return p;
            }
        }
    }

    if (!p) {
        /* Journalise ce qu AUCUNE des deux voies ne resout : c est ce que le
         * jeu appellera a l adresse 0. */
        char ligne[256];
        int i = 0;
        const char *prefixe = "NON RESOLU: ";
        while (prefixe[i] && i < 200) { ligne[i] = prefixe[i]; i++; }
        int j = 0;
        while (nom[j] && i < 250) ligne[i++] = nom[j++];
        ligne[i++] = 13; ligne[i++] = 10; ligne[i] = 0;
        journal(ligne);
    }
    return p;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD raison, LPVOID reserve)
{
    (void)reserve;
    if (raison == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        /* opengl32real.dll est charge par les forwarders du .def ; on prend
         * son handle pour GetProcAddress. */
        reel = GetModuleHandleA("opengl32real.dll");
        if (!reel) reel = LoadLibraryA("opengl32real.dll");
        if (!reel) { journal("opengl32real.dll introuvable\r\n"); return FALSE; }
        reel_wglGetProcAddress =
            (wglGetProcAddress_t)GetProcAddress(reel, "wglGetProcAddress");
        journal(reel_wglGetProcAddress
                ? "proxy actif, wglGetProcAddress reel resolu\r\n"
                : "proxy actif, mais wglGetProcAddress reel INTROUVABLE\r\n");
    }
    return TRUE;
}
