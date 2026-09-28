/* Lab-only instrumentation inserted in main, never part of the upstream PR. */
WCHAR ExpectedDll[MAX_PATH], ActualDll[MAX_PATH];
DWORD ExpectedLength = GetEnvironmentVariableW(L"WINFSP_TESTS_EXPECT_DLL",
    ExpectedDll, MAX_PATH);
if (0 == ExpectedLength || MAX_PATH <= ExpectedLength)
    ABORT("expected DLL path missing or too long");
WCHAR *BaseName = wcsrchr(ExpectedDll, L'\\');
HMODULE Module = GetModuleHandleW(BaseName ? BaseName + 1 : ExpectedDll);
DWORD ActualLength = GetModuleFileNameW(Module, ActualDll, MAX_PATH);
if (0 == Module || 0 == ActualLength || MAX_PATH <= ActualLength ||
    0 != _wcsicmp(ExpectedDll, ActualDll))
    ABORT("unexpected WinFsp DLL loaded");
fprintf(stderr, "WINFSP_TEST_DLL:%ls\n", ActualDll);
fflush(stderr);
FspDebugLogSetHandle(GetStdHandle(STD_ERROR_HANDLE));
