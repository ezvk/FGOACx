/* Remplace, dans la table d imports de ago.exe, le seul
 * USER32!SetWindowFeedbackSetting par un stub inoffensif.
 *
 * Pourquoi : Wine ne l implemente pas et AVORTE le processus sur appel
 * (EXCEPTION_WINE_STUB, 0x80000100). C est une API de retour visuel tactile
 * (Windows 8+), sans effet sur le rendu ni sur la logique du jeu.
 * Import statique, ordinal 0311 : on ne peut pas l eviter autrement. */
#include <windows.h>

static BOOL WINAPI stub_SetWindowFeedbackSetting(HWND h, int t, DWORD f,
                                                 UINT32 s, const void *c)
{
    (void)h; (void)t; (void)f; (void)s; (void)c;
    return TRUE;
}

static void journal(const char *msg)
{
    HANDLE h = CreateFileA("..\\logs\\fgostub.log", FILE_APPEND_DATA,
                           FILE_SHARE_READ, NULL, OPEN_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w; WriteFile(h, msg, lstrlenA(msg), &w, NULL); CloseHandle(h);
    }
}

static void patch_iat(HMODULE base)
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((BYTE *)base + dos->e_lfanew);
    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) { journal("pas de table d imports\r\n"); return; }
    IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)((BYTE *)base + rva);
    for (; imp->Name; imp++) {
        const char *dll = (const char *)base + imp->Name;
        if (lstrcmpiA(dll, "USER32.dll") != 0) continue;
        IMAGE_THUNK_DATA *orig  = (IMAGE_THUNK_DATA *)((BYTE *)base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *first = (IMAGE_THUNK_DATA *)((BYTE *)base + imp->FirstThunk);
        for (; orig->u1.AddressOfData; orig++, first++) {
            if (IMAGE_SNAP_BY_ORDINAL(orig->u1.Ordinal)) continue;
            IMAGE_IMPORT_BY_NAME *n = (IMAGE_IMPORT_BY_NAME *)((BYTE *)base + orig->u1.AddressOfData);
            if (lstrcmpA((char *)n->Name, "SetWindowFeedbackSetting") != 0) continue;
            DWORD old;
            if (VirtualProtect(&first->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) {
                first->u1.Function = (ULONGLONG)(ULONG_PTR)stub_SetWindowFeedbackSetting;
                VirtualProtect(&first->u1.Function, sizeof(void *), old, &old);
                journal("SetWindowFeedbackSetting remplace par un stub\r\n");
            } else journal("VirtualProtect a echoue\r\n");
            return;
        }
    }
    journal("import introuvable\r\n");
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        patch_iat(GetModuleHandleA(NULL));
    }
    return TRUE;
}
