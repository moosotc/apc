#include <caml/fail.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/signals.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

#include <math.h>
#include <stdio.h>
#include <stdarg.h>

enum {
    LINUX_TAG,
    WINDOWS_TAG,
    SOLARIS_TAG,
    MACOSX_TAG
};

#ifdef _MSC_VER
#define vsnprintf _vsnprintf
#endif

static void failwith_fmt (const char *fmt, ...) Noreturn;
static void failwith_fmt (const char *fmt, ...)
{
    va_list ap;
    char buf[1024];

    va_start (ap, fmt);
    vsnprintf (buf, sizeof (buf), fmt, ap);
    va_end (ap);

    failwith (buf);
}

#if defined __linux__
#define _GNU_SOURCE
#include <alloca.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/time.h>
#include <sys/sysinfo.h>
#include <signal.h>
#include <string.h>
#include <errno.h>

CAMLprim value ml_sysinfo (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLlocal2 (res_v, loads_v);
    struct sysinfo si;

    if (sysinfo (&si)) {
        failwith_fmt ("sysinfo: %s", strerror (errno));
    }

    loads_v = caml_alloc_tuple (3);
    Store_field (loads_v, 0, caml_copy_int64 (si.loads[0]));
    Store_field (loads_v, 1, caml_copy_int64 (si.loads[1]));
    Store_field (loads_v, 2, caml_copy_int64 (si.loads[2]));

    res_v = caml_alloc_tuple (9);
    Store_field (res_v, 0, caml_copy_int64 (si.uptime));
    Store_field (res_v, 1, loads_v);
    Store_field (res_v, 2, caml_copy_int64 (si.totalram));
    Store_field (res_v, 3, caml_copy_int64 (si.freeram));
    Store_field (res_v, 4, caml_copy_int64 (si.sharedram));
    Store_field (res_v, 5, caml_copy_int64 (si.bufferram));
    Store_field (res_v, 6, caml_copy_int64 (si.totalswap));
    Store_field (res_v, 7, caml_copy_int64 (si.freeswap));
    Store_field (res_v, 8, caml_copy_int64 (si.procs));

    CAMLreturn (res_v);
}

CAMLprim value ml_get_nprocs (value unit_v)
{
    CAMLparam1 (unit_v);
    int nprocs;

    nprocs = get_nprocs ();
    if (nprocs <= 0) {
        failwith_fmt ("get_nprocs: %s", strerror (errno));
    }

    CAMLreturn (Val_int (nprocs));
}

CAMLprim value ml_idletimeofday (value fd_v, value nprocs_v)
{
    CAMLparam2 (fd_v, nprocs_v);
    CAMLlocal1 (res_v);
    struct timeval tv;
    int fd = Int_val (fd_v);
    int nprocs = Int_val (nprocs_v);
    size_t n = nprocs * sizeof (tv);
    ssize_t m;
    struct timeval *buf;
    int i;

    buf = alloca (n);
    if (!buf) {
        failwith_fmt ("alloca failed");
    }

    m = read (fd, buf, n);
    if (n - m) {
        failwith_fmt ("read [n=%zu, m=%zi]: %s", n, m, strerror (errno));
    }

    res_v = caml_alloc (nprocs * Double_wosize, Double_array_tag);
    for (i = 0; i < nprocs; ++i) {
        double d;

        d = buf[i].tv_sec + buf[i].tv_usec * 1e-6;
        Store_double_field (res_v, i, d);
    }
    CAMLreturn (res_v);
}

CAMLprim value ml_os_type (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (LINUX_TAG));
}

#elif defined _WIN32

#pragma warning (disable:4152 4127 4189)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define DDKFASTAPI __fastcall
#define NTSTATUS long
#define BOOLEAN int

/* Following (mildly modified) structure definitions, macros, enums,
   etc are taken from binutils w32api (http://sourceware.org/binutils/)
   Headers claim:
 */
/*
 * ntpoapi.h
 * ntddk.h
 ...
 * This file is part of the w32api package.
 *
 * Contributors:
 *   Created by Casper S. Hornstrup <chorns@users.sourceforge.net>
 *
 * THIS SOFTWARE IS NOT COPYRIGHTED
 *
 * This source code is offered for use in the public domain. You may
 * use, modify or distribute it freely.
 *
 * This code is distributed in the hope that it will be useful but
 * WITHOUT ANY WARRANTY. ALL WARRANTIES, EXPRESS OR IMPLIED ARE HEREBY
 * DISCLAIMED. This includes but is not limited to warranties of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 */

typedef struct _SYSTEM_BASIC_INFORMATION {
    ULONG  Unknown;
    ULONG  MaximumIncrement;
    ULONG  PhysicalPageSize;
    ULONG  NumberOfPhysicalPages;
    ULONG  LowestPhysicalPage;
    ULONG  HighestPhysicalPage;
    ULONG  AllocationGranularity;
    ULONG  LowestUserAddress;
    ULONG  HighestUserAddress;
    ULONG  ActiveProcessors;
    UCHAR  NumberProcessors;
} SYSTEM_BASIC_INFORMATION, *PSYSTEM_BASIC_INFORMATION;

typedef struct _SYSTEM_PROCESSOR_TIMES {
    LARGE_INTEGER  IdleTime;
    LARGE_INTEGER  KernelTime;
    LARGE_INTEGER  UserTime;
    LARGE_INTEGER  DpcTime;
    LARGE_INTEGER  InterruptTime;
    ULONG  InterruptCount;
} SYSTEM_PROCESSOR_TIMES, *PSYSTEM_PROCESSOR_TIMES;

typedef long (__stdcall *QuerySystemInformationProc)
    (SYSTEM_INFORMATION_CLASS, PVOID, ULONG, PULONG);

static struct {
    HMODULE hmod;
    QuerySystemInformationProc QuerySystemInformation;
    ULONG nprocs;
    double prevtime;
    struct {
        double clocks;
        double unhalted;
        double total;
    } prev[64];
} glob;

static double gettime (void)
{
    FILETIME ft;
    uint64 tmp;

    GetSystemTimeAsFileTime (&ft);
    tmp = ft.dwHighDateTime;
    tmp <<= 32;
    tmp |= ft.dwLowDateTime;
    return tmp * 1e-7;
}

static void init (void)
{
    if (!glob.hmod) {
        glob.hmod = LoadLibrary ("ntdll.dll");
        if (!glob.hmod) {
            failwith_fmt ("could not load ntdll.dll: %#lx", GetLastError ());
        }

        *(void **) &glob.QuerySystemInformation =
            GetProcAddress (glob.hmod, "ZwQuerySystemInformation");
        if (!glob.QuerySystemInformation) {
            failwith_fmt (
                "could not obtain ZwQuerySystemInformation entry point: %#lx",
                GetLastError ());
        }
        glob.prevtime = gettime ();
    }
}

static void qsi (int c, PVOID buf, ULONG size)
{
    ULONG retsize = 0;
    long status;

    init ();
    status = glob.QuerySystemInformation (c, buf, size, &retsize);
    if (status < 0) {
        failwith_fmt ("could not query system information %ld retsize %ld",
                      c, retsize);
    }
    if (retsize != size) {
        fprintf (stderr, "class=%d status=%ld size=%d retsize=%d\n",
                 c, status, size, retsize);
    }
#ifdef DEBUG
    printf ("class=%d status=%ld size=%d retsize=%d\n",
            c, status, size, retsize);
#endif
}

CAMLprim value ml_waitalrm (value unit_v)
{
    CAMLparam1 (unit_v);

    failwith ("waitalrm not supported on Windows");
    CAMLreturn (Val_unit);
}

static void pmc (int nproc, double *clocksp, double *unhaltedp)
{
    unsigned int h1, l1, h2, l2, p;
    uint64 tmp;
    DWORD prevmask;

    prevmask = SetThreadAffinityMask (GetCurrentThread (), 1 << nproc);
    if (!prevmask) {
        failwith_fmt ("SetThreadAffinityMask failed: %ld\n", GetLastError ());
    }

#ifndef _MSC_VER
#error Not yet written
#endif

    _asm {
        pushad;
        mov eax, 1;
        cpuid;
        mov p, ebx;
        rdtsc;
        mov l1, eax;
        mov h1, edx;
        xor ecx, ecx;
        rdpmc;
        mov l2, eax;
        mov h2, edx;
        popad;
    }

    tmp = h1;
    tmp <<= 32;
    tmp |= l1;
    *clocksp = tmp;

    tmp = h2;
    tmp <<= 32;
    tmp |= l2;
    *unhaltedp = tmp;
    /* printf ("[%d] = %f %f %x\n", p >> 24, *clocksp, *unhaltedp, prevmask); */
}

static void get_nprocs (void)
{
    SYSTEM_BASIC_INFORMATION sbi;

    qsi (0, &sbi, sizeof (sbi));
    glob.nprocs = sbi.NumberProcessors;
    if (glob.nprocs > 64) {
        failwith_fmt ("Hmm... the future is now, but i'm not ready %d",
                      glob.nprocs);
    }
}

CAMLprim value ml_get_nprocs (value unit_v)
{
    CAMLparam1 (unit_v);

    get_nprocs ();
    CAMLreturn (Val_int (glob.nprocs));
}

CAMLprim value ml_windows_processor_times (value nprocs_v)
{
    CAMLparam1 (nprocs_v);
    CAMLlocal1 (res_v);
    int nprocs = Int_val (nprocs_v);
    PSYSTEM_PROCESSOR_TIMES buf, b;
    size_t n = nprocs * sizeof (*buf);
    int i, j;

    buf = _alloca (n);
    if (!buf) {
        failwith_fmt ("alloca: %s", strerror (errno));
    }

    qsi (8, buf, n);

    res_v = caml_alloc (nprocs * 5 * Double_wosize, Double_array_tag);
    b = buf;
    for (i = 0, j = 0; i < nprocs; ++i, ++b) {
        double d = b->IdleTime.QuadPart * 1e-7;

        Store_double_field (res_v, j, d); j += 1;

        d = b->KernelTime.QuadPart * 1e-7 - d;
        Store_double_field (res_v, j, d); j += 1;

        Store_double_field (res_v, j, b->UserTime.QuadPart * 1e-7); j += 1;
        Store_double_field (res_v, j, b->DpcTime.QuadPart * 1e-7); j += 1;
        Store_double_field (res_v, j, b->InterruptTime.QuadPart * 1e-7); j += 1;
    }
    CAMLreturn (res_v);
}

CAMLprim value ml_get_hz (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (100));
}

CAMLprim value ml_nice (value nice_v)
{
    CAMLparam1 (nice_v);
    int niceval = Int_val (nice_v);

    failwith_fmt ("nice: not implemented on Windows");
    CAMLreturn (Val_unit);
}

CAMLprim value ml_seticon (value data_v)
{
    CAMLparam1 (data_v);
    CAMLreturn (Val_unit);
}

CAMLprim value ml_delay (value secs_v)
{
    CAMLparam1 (secs_v);
    DWORD millis = (DWORD) (Double_val (secs_v) * 1e4);

    caml_enter_blocking_section ();
    {
        Sleep (millis);
    }
    caml_leave_blocking_section ();
    CAMLreturn (Val_unit);
}

CAMLprim value ml_os_type (value unit_v)
{
    CAMLparam1 (unit_v);
    OSVERSIONINFO ovi;

    ovi.dwOSVersionInfoSize = sizeof (ovi);
    if (!GetVersionEx (&ovi)) {
        failwith_fmt ("Could not get version information: %#lx",
                      GetLastError ());
    }

    if (ovi.dwPlatformId != VER_PLATFORM_WIN32_NT) {
        caml_failwith ("Only NT family of Windows is supported by APC");
    }

    CAMLreturn (Val_int (WINDOWS_TAG));
}

CAMLprim value ml_idletimeofday (value fd_v, value nprocs_v)
{
    CAMLparam2 (fd_v, nprocs_v);
    CAMLlocal1 (res_v);
    double now, delta;
    int i;

    now = gettime ();
    delta = now - glob.prevtime;
    glob.prevtime = now;

    res_v = caml_alloc (glob.nprocs * Double_wosize, Double_array_tag);
    for (i = 0; i < glob.nprocs; ++i) {
        double d;
        double clocks, unhalted;
        double dc, du;

        pmc (i, &clocks, &unhalted);
        dc = clocks - glob.prev[i].clocks;
        du = unhalted - glob.prev[i].unhalted;
        d = delta * (1.0 - du / dc);
        glob.prev[i].clocks = clocks;
        glob.prev[i].unhalted = unhalted;
        glob.prev[i].total += d;
        Store_double_field (res_v, i, glob.prev[i].total);
    }
    CAMLreturn (res_v);
}
#elif defined __sun__
#define _POSIX_PTHREAD_SEMANTICS
#include <alloca.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/time.h>
#include <sys/sysinfo.h>
#include <kstat.h>
#include <sys/stat.h>
#include <signal.h>
#include <string.h>
#include <errno.h>

static long get_nprocs (void)
{
    long nprocs = sysconf (_SC_NPROCESSORS_CONF);
    if (nprocs <= 0) {
        failwith_fmt ("sysconf (_SC_NPROCESSORS_CONF) = %ld: %s",
                      nprocs, strerror (errno));
    }
    return nprocs;
}

CAMLprim value ml_get_nprocs (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (get_nprocs ()));
}

CAMLprim value ml_solaris_kstat (value nprocs_v)
{
    /* Based on lib/cpustat.cc from sinfo package by Juergen Rinas */
    CAMLparam1 (nprocs_v);
    CAMLlocal1 (res_v);
    int i = 0, j = 0;
    int nprocs = Int_val (nprocs_v);
    struct kstat_ctl *kc;
    kstat_t *ksp;

    kc = kstat_open ();
    if (!kc) {
        failwith_fmt ("kstat_open failed: %s", strerror (errno));
    }

    res_v = caml_alloc (nprocs * 4 * Double_wosize, Double_array_tag);
    for (ksp = kc->kc_chain; ksp; ksp = ksp->ks_next) {
        if (!strncmp (ksp->ks_name, "cpu_stat", 8)) {
            cpu_stat_t cstat;

            i += 1;
            if (i > nprocs) {
                failwith_fmt ("number of processors changed?");
            }

            if (kstat_read (kc, ksp, 0) == -1) {
                failwith_fmt ("kstat_read (update) failed: %s", strerror (errno));
            }

            if (kstat_read (kc, ksp, &cstat) == -1) {
                failwith_fmt ("kstat_read (read) failed: %s", strerror (errno));
            }

            Store_double_field (res_v, j, cstat.cpu_sysinfo.cpu[0]); j += 1;
            Store_double_field (res_v, j, cstat.cpu_sysinfo.cpu[1]); j += 1;
            Store_double_field (res_v, j, cstat.cpu_sysinfo.cpu[2]); j += 1;
            Store_double_field (res_v, j, cstat.cpu_sysinfo.cpu[3]); j += 1;
        }
    }

    kstat_close (kc);
    CAMLreturn (res_v);
}

CAMLprim value ml_os_type (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (SOLARIS_TAG));
}
#elif defined __APPLE__
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

CAMLprim value ml_seticon (value data_v)
{
    CAMLparam1 (data_v);
    CAMLreturn (Val_unit);
}

static long get_nprocs (void)
{
    int n, err;
    size_t size;
    int mib[] = { CTL_HW, HW_NCPU };

    size = sizeof (int);
    err = sysctl (mib, 2, &n, &size, NULL, 0);
    if (err < 0) {
        failwith_fmt ("sysctl (HW_NCPU) failed: %s", strerror (errno));
    }
    return n;
}

CAMLprim value ml_get_nprocs (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (get_nprocs ()));
}

CAMLprim value ml_macosx_host_processor_info (value nprocs_v)
{
    CAMLparam1 (nprocs_v);
    CAMLlocal1 (res_v);
    int i, j = 0;
    int nprocs = Int_val (nprocs_v);
    unsigned int nprocs1;
    kern_return_t kr;
    processor_cpu_load_info_t cpu_load, c;
    mach_msg_type_number_t cpu_msg_count;

    kr = host_processor_info (mach_host_self (), PROCESSOR_CPU_LOAD_INFO,
                              &nprocs1,
                              (processor_info_array_t *) &cpu_load,
                              &cpu_msg_count);
    if (kr != KERN_SUCCESS) {
        failwith_fmt ("host_processor_info failed: %s",
                      mach_error_string (kr));
    }

    if (nprocs1 != nprocs){
        failwith_fmt ("host_processor_info claims CPUs=%d expected %d",
                      nprocs1, nprocs);
    }

    res_v = caml_alloc (nprocs * 4 * Double_wosize, Double_array_tag);
    c = cpu_load;
    for (i = 0; i < nprocs; ++i, ++c) {
        Store_double_field (res_v, j, c->cpu_ticks[CPU_STATE_IDLE]); j += 1;
        Store_double_field (res_v, j, c->cpu_ticks[CPU_STATE_USER]); j += 1;
        Store_double_field (res_v, j, c->cpu_ticks[CPU_STATE_SYSTEM]); j += 1;
        Store_double_field (res_v, j, c->cpu_ticks[CPU_STATE_NICE]); j += 1;
    }

    kr = vm_deallocate (mach_task_self (), (vm_address_t) cpu_load,
                        cpu_msg_count * sizeof (*cpu_load));
    if (kr != KERN_SUCCESS) {
        failwith_fmt ("vm_deallocate failed: %s", mach_error_string (kr));
    }
    CAMLreturn (res_v);
}

CAMLprim value ml_os_type (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (MACOSX_TAG));
}
#else
#error This operating system is not supported
#endif

#if defined __linux__ || defined __sun__
#include <X11/X.h>
#include <X11/Xmd.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

#include <GL/glx.h>

struct X11State {
    Display *dpy;
    Window id;
    Atom property;
    int error;
};

CAMLprim value ml_seticon (value data_v)
{
    CAMLparam1 (data_v);
    static struct X11State static_state;
    struct X11State *s = &static_state;
    void *ptr = String_val (data_v);
    CARD32 *p = ptr;
    unsigned char *data = ptr;

    if (!s->error) {
        if (!s->dpy) {
            s->dpy = XOpenDisplay (NULL);
            if (!s->dpy) {
                goto err0;
            }
            else {
                /* "tiny bit" hackish */
                s->id = glXGetCurrentDrawable ();
                if (s->id == None) {
                    goto err1;
                }

                s->property = XInternAtom (s->dpy, "_NET_WM_ICON", False);
                if (s->property == None){
                    goto err1;
                }

#ifdef DEBUG
                printf ("id = %#x, property = %d\n",
                        (int) s->id, (int) s->property);
#endif
            }
        }
    }
    else {
        CAMLreturn (Val_unit);
    }

    p[0] = 32;
    p[1] = 32;
    XChangeProperty (s->dpy, s->id, s->property, XA_CARDINAL,
                     32, PropModeReplace, data, 32 * 32 + 2);

    CAMLreturn (Val_unit);

 err1:
    XCloseDisplay (s->dpy);
 err0:
    s->error = 1;
    CAMLreturn (Val_unit);
}
#endif

#ifndef _WIN32
CAMLprim value ml_waitalrm (value unit_v)
{
    CAMLparam1 (unit_v);
    sigset_t set;
    int signr, ret, errno_code;

    sigemptyset (&set);
    sigaddset (&set, SIGALRM);

    caml_enter_blocking_section ();
    {
        ret = sigwait (&set, &signr);
        errno_code = errno;
    }
    caml_leave_blocking_section ();

    if (ret) {
        failwith_fmt ("sigwait: %s", strerror (errno_code));
    }
    CAMLreturn (Val_unit);
}

CAMLprim value ml_get_hz (value unit_v)
{
    CAMLparam1 (unit_v);
    long clk_tck;

    clk_tck = sysconf (_SC_CLK_TCK);
    if (clk_tck <= 0) {
        failwith_fmt ("sysconf (SC_CLK_TCK): %s", strerror (errno));
    }
    CAMLreturn (Val_int (clk_tck));
}

CAMLprim value ml_delay (value secs_v)
{
    CAMLparam1 (secs_v);
    failwith ("delay is not implemented on non-Windows");
    CAMLreturn (Val_unit);
}

CAMLprim value ml_nice (value nice_v)
{
    CAMLparam1 (nice_v);
    int niceval = Int_val (nice_v);

#ifdef __linux__
    errno = 0;
#endif
    if (nice (niceval) < 0) {
#ifdef __linux__
        if (errno)
#endif
            failwith_fmt ("nice %d: %s", niceval, strerror (errno));
    }

    CAMLreturn (Val_unit);
}
#endif

#ifndef _WIN32
CAMLprim value ml_windows_processor_times (value nprocs_v)
{
    CAMLparam1 (nprocs_v);
    failwith ("ml_windows_processor_times is not implemented on non-Windows");
    CAMLreturn (Val_unit);
}
#endif

#ifndef __sun__
CAMLprim value ml_solaris_kstat (value nprocs_v)
{
    CAMLparam1 (nprocs_v);
    failwith ("ml_solaris_kstat is not implemented on non-Solaris");
    CAMLreturn (Val_unit);
}
#endif

#ifndef __APPLE__
CAMLprim value ml_macosx_host_processor_info (value nprocs_v)
{
    CAMLparam1 (nprocs_v);
    failwith ("ml_macosx_host_processor_info is not implemented on non-MacOSX");
    CAMLreturn (Val_unit);
}
#endif

#ifndef __linux__
CAMLprim value ml_sysinfo (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLlocal2 (res_v, loads_v);
    long nprocs;

#ifdef _WIN32
    nprocs = glob.nprocs;
#else
    nprocs = get_nprocs ();
#endif

    loads_v = caml_alloc_tuple (3);
    Store_field (loads_v, 0, caml_copy_int64 (0));
    Store_field (loads_v, 1, caml_copy_int64 (0));
    Store_field (loads_v, 2, caml_copy_int64 (0));

    res_v = caml_alloc_tuple (9);
    Store_field (res_v, 0, 0);
    Store_field (res_v, 1, loads_v);
    Store_field (res_v, 2, 0);
    Store_field (res_v, 3, 0);
    Store_field (res_v, 4, 0);
    Store_field (res_v, 5, 0);
    Store_field (res_v, 6, 0);
    Store_field (res_v, 7, 0);
    Store_field (res_v, 8, nprocs);

    CAMLreturn (res_v);
}

#ifndef _WIN32
CAMLprim value ml_idletimeofday (value fd_v, value nprocs_v)
{
    CAMLparam2 (fd_v, nprocs_v);
    failwith_fmt ("idletimeofday is not implemented on non-Linux/Win32");
    CAMLreturn (Val_unit);
}
#endif
#endif

CAMLprim value ml_fixwindow (value window_v)
{
    CAMLparam1 (window_v);
    CAMLreturn (Val_unit);
}

CAMLprim value ml_testpmc (value unit_v)
{
    CAMLparam1 (unit_v);
    int pmcok = 1;

#ifdef _WIN32

    /* Shrug */
#if 0
    __try {
        _asm {
            pushad;
            rdpmc;
            popad;
        }
    }
    __except () {
        pmcok = 0;
        MessageBox (NULL,
                    "Requested PMC based sampling is not available",
                    "Warning",
                    MB_OK | MB_ICONWARNING);
    }
#else
    int response = MessageBox (
        NULL,
        "Requested PMC based sampling might cause the application to crash.\n"
        "Continue trying to use PMC?",
        "Warning",
        MB_YESNO | MB_ICONWARNING);
    pmcok = response == IDYES;
#endif

#endif

    CAMLreturn (Val_bool (pmcok));
}
