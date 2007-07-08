#define _XOPEN_SOURCE 700
#define _GNU_SOURCE
#include <caml/fail.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/signals.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

#include <alloca.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/time.h>
#include <sys/time.h>
#include <sys/sysinfo.h>
#include <signal.h>
#include <string.h>
#include <errno.h>

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


CAMLprim value ml_waitalrm (value unit_v)
{
    CAMLparam1 (unit_v);
    sigset_t set;
    int signr;

    sigemptyset (&set);
    sigaddset (&set, SIGALRM);
    if (sigwait (&set, &signr)) {
        failwith_fmt ("sigwait: %s", strerror (errno));
    }
    CAMLreturn (Val_unit);
}

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
        failwith_fmt ("alloca: %s", strerror (errno));
    }

    m = read (fd, buf, n);
    if (n - m) {
        failwith_fmt ("read [n=%zu, m=%zi]: %s", n, m, strerror (errno));
    }

    res_v = caml_alloc (nprocs * Double_wosize, Double_array_tag);
    for (i = 0; i < nprocs; ++i) {
        double d = buf[i].tv_sec + buf[i].tv_usec * 1e-6;

        Store_double_field (res_v, i, d);
    }
    CAMLreturn (res_v);
}

CAMLprim value ml_get_hz (value unit_v)
{
    CAMLparam1 (unit_v);
    CAMLreturn (Val_int (sysconf (_SC_CLK_TCK)));
}

CAMLprim value ml_nice (value nice_v)
{
    CAMLparam1 (nice_v);
    int niceval = Int_val (nice_v);

    if (!nice (niceval)) {
        failwith_fmt ("nice %d: %s", niceval, strerror (errno));
    }

    CAMLreturn (Val_unit);
}
