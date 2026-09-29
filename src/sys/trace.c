/**
 * @file sys/trace.c
 *
 * @copyright 2015-2025 Bill Zissimopoulos
 */
/*
 * This file is part of WinFsp.
 *
 * You can redistribute it and/or modify it under the terms of the GNU
 * General Public License version 3 as published by the Free Software
 * Foundation.
 *
 * Licensees holding a valid commercial license may use this software
 * in accordance with the commercial license agreement provided in
 * conjunction with the software.  The terms and conditions of any such
 * commercial license agreement shall govern, supersede, and render
 * ineffective any application of the GPLv3 license to this software,
 * notwithstanding of any reference thereto in the software or
 * associated repository.
 */

#include <sys/driver.h>

#if FSP_REPARSE_DIAGNOSTICS
/* Enable only in isolated test-signed builds. Addresses are diagnostic data,
 * not a public event contract. No foreign FsContext is dereferenced here. */
static const GUID FspReparseDiagnosticProvider =
    { 0x77769d82, 0x1374, 0x4d50, { 0xb8, 0xda, 0x56, 0x87, 0x15, 0xc1, 0xa8, 0x45 } };
static REGHANDLE FspReparseDiagnosticHandle;

NTSTATUS FspReparseDiagnosticInitialize(VOID)
{
    return EtwRegister(&FspReparseDiagnosticProvider, 0, 0, &FspReparseDiagnosticHandle);
}

VOID FspReparseDiagnosticFinalize(VOID)
{
    if (0 != FspReparseDiagnosticHandle)
    {
        EtwUnregister(FspReparseDiagnosticHandle);
        FspReparseDiagnosticHandle = 0;
    }
}

VOID FspReparseDiagnostic(PCWSTR Format, ...)
{
    WCHAR Buffer[512];
    va_list Args;

    if (0 == FspReparseDiagnosticHandle ||
        !EtwProviderEnabled(FspReparseDiagnosticHandle, 4, 1))
        return;
    va_start(Args, Format);
    NTSTATUS Status = RtlStringCchVPrintfW(Buffer, sizeof Buffer / sizeof Buffer[0], Format, Args);
    va_end(Args);
    if (NT_SUCCESS(Status))
        EtwWriteString(FspReparseDiagnosticHandle, 4, 1, 0, Buffer);
}
#endif

#if FSP_TRACE_ENABLED

#undef STATUS_INSUFFICIENT_RESOURCES
#define STATUS_INSUFFICIENT_RESOURCES   ((NTSTATUS)0xC000009AL)

static struct
{
    HANDLE Handle;
    PKEVENT Event;
} FspLowMemoryCondition, FspLowNonPagedPoolCondition, FspLowPagedPoolCondition;

VOID FspTrace(const char *file, int line, const char *func)
{
    for (const char *p = file; '\0' != *p; p++)
        if ('\\' == *p)
            file = p + 1;

    ASSERT(DISPATCH_LEVEL >= KeGetCurrentIrql());
    DbgPrintEx(DPFLTR_DEFAULT_ID, DPFLTR_TRACE_LEVEL,
        DRIVER_NAME ": %s[%s:%d]\n", func, file, line);
}

VOID FspTraceNtStatus(const char *file, int line, const char *func, NTSTATUS Status)
{
    for (const char *p = file; '\0' != *p; p++)
        if ('\\' == *p)
            file = p + 1;

    ASSERT(DISPATCH_LEVEL >= KeGetCurrentIrql());
    BOOLEAN LowMemoryCondition, LowNonPagedPoolCondition, LowPagedPoolCondition;
    switch (Status)
    {
    case STATUS_INSUFFICIENT_RESOURCES:
        LowMemoryCondition = 0 != FspLowMemoryCondition.Event &&
            !!KeReadStateEvent(FspLowMemoryCondition.Event);
        LowNonPagedPoolCondition = 0 != FspLowNonPagedPoolCondition.Event &&
            !!KeReadStateEvent(FspLowNonPagedPoolCondition.Event);
        LowPagedPoolCondition = 0 != FspLowPagedPoolCondition.Event &&
            !!KeReadStateEvent(FspLowPagedPoolCondition.Event);
        DbgPrintEx(DPFLTR_DEFAULT_ID, DPFLTR_TRACE_LEVEL,
            DRIVER_NAME ": %s[%s:%d]: STATUS_INSUFFICIENT_RESOURCES (Memory=%c%c%c)\n",
            func, file, line,
            LowMemoryCondition ? 'M' : '-',
            LowNonPagedPoolCondition ? 'N' : '-',
            LowPagedPoolCondition ? 'P' : '-');
        break;
    default:
        DbgPrintEx(DPFLTR_DEFAULT_ID, DPFLTR_TRACE_LEVEL,
            DRIVER_NAME ": %s[%s:%d]: Status=%lx\n",
            func, file, line,
            Status);
        break;
    }
}

static PKEVENT FspOpenEvent(PWSTR Name, PHANDLE PHandle)
{
    UNICODE_STRING ObjectName;
    OBJECT_ATTRIBUTES ObjectAttributes;
    HANDLE Handle;
    PKEVENT Event;
    NTSTATUS Result;

    *PHandle = 0;

    RtlInitUnicodeString(&ObjectName, Name);
    InitializeObjectAttributes(&ObjectAttributes,
        &ObjectName, OBJ_KERNEL_HANDLE, 0, 0);
    Result = ZwOpenEvent(&Handle,
        EVENT_ALL_ACCESS, &ObjectAttributes);
    if (!NT_SUCCESS(Result))
        return 0;

    Result = ObReferenceObjectByHandle(Handle,
        0, *ExEventObjectType, KernelMode, &Event, 0);
    if (!NT_SUCCESS(Result))
    {
        ZwClose(Handle);
        return 0;
    }

    *PHandle = Handle;

    return Event;
}

static VOID FspCloseEvent(PKEVENT Event, HANDLE Handle)
{
    if (0 != Event)
        ObDereferenceObject(Event);

    if (0 != Handle)
        ZwClose(Handle);
}

VOID FspTraceInitialize(VOID)
{
#define OPEN_EVENT(NAME)                \
    (Fsp ## NAME.Event = FspOpenEvent(L"\\KernelObjects\\" #NAME, &Fsp ## NAME.Handle))

    OPEN_EVENT(LowMemoryCondition);
    OPEN_EVENT(LowNonPagedPoolCondition);
    OPEN_EVENT(LowPagedPoolCondition);

#undef OPEN_EVENT

    FSP_TRACE();
}

VOID FspTraceFinalize(VOID)
{
    FSP_TRACE();

#define CLOSE_EVENT(NAME)               \
    (FspCloseEvent(Fsp ## NAME.Event, Fsp ## NAME.Handle), Fsp ## NAME.Event = 0, Fsp ## NAME.Handle = 0)

    CLOSE_EVENT(LowMemoryCondition);
    CLOSE_EVENT(LowNonPagedPoolCondition);
    CLOSE_EVENT(LowPagedPoolCondition);

#undef CLOSE_EVENT
}
#endif
