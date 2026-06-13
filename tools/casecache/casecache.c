/*
 * casecache3.c — LD_PRELOAD shim for native-Linux Insurgency (Source) dedicated server.
 *
 * v3: build-once, read-only, LOCK-FREE index of the whole game tree.
 *
 * Why: with -workshop the engine mounts ~161 workshop items as loose search paths and, on
 * every exact-case miss, runs dedicated_srv.so's recursive case-insensitive descent
 * (__wrap_fopen -> pathmatch -> Descend -> readdir). One map load = ~15M filesystem syscalls
 * (5.5M getdents64, 3.4M access, 3.1M openat, 2.7M statx) -> minutes-long loads + watchdog
 * crashes. v1 cached only directory listings (still ~9M uncached access/stat/open syscalls).
 * v2 also cached lookups but behind ONE global mutex that all loader threads fought over, so
 * lock contention made it slower.
 *
 * v3 walks GAME_ROOT once at first use into an immutable hash index, then never mutates it.
 * After the one-time build, ALL reads are lock-free (just atomic-published pointers), so:
 *   - open/stat/access resolve case-insensitively in O(1) (engine's exact attempt succeeds for
 *     hits -> it skips its own descent; authoritative ENOENT for misses with no syscall),
 *   - opendir/readdir serve the engine's descent from the frozen index (no getdents),
 * with zero per-op locking.
 *
 * Correctness: the indexed content tree is read-only at runtime. Writable subtrees (EXCLUDE)
 * always pass through to libc with the original path. Files created at runtime via a write
 * open are recorded in a small locked "dirty set"; a read that misses the index but hits the
 * dirty set falls back to a real libc call so newly written files are still found.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <unistd.h>
#include <limits.h>
#include <ctype.h>

#define GAME_ROOT   "/opt/insurgency-server"
#define NBUCKETS    (1u << 19)          /* 524288 buckets */
#ifndef _STAT_VER
#define _STAT_VER   3
#endif

/* Writable/mutable subtrees: never indexed, always passthrough to libc with original path. */
static int is_excluded(const char *p) {
    return strstr(p, "/download") || strstr(p, "/logs") || strstr(p, "/cfg/")
        || strstr(p, "/addons/sourcemod/data") || strstr(p, "/addons/sourcemod/logs")
        || strstr(p, "console.log");
}

/* ---- real libc symbols ---- */
static DIR *(*r_opendir)(const char *);
static DIR *(*r_fdopendir)(int);
static struct dirent  *(*r_readdir)(DIR *);
static struct dirent64*(*r_readdir64)(DIR *);
static int  (*r_closedir)(DIR *);
static void (*r_rewinddir)(DIR *);
static int   (*r_access)(const char *, int);
static int   (*r_open)(const char *, int, ...);
static int   (*r_open64)(const char *, int, ...);
static int   (*r_openat)(int, const char *, int, ...);
static int   (*r_openat64)(int, const char *, int, ...);
static FILE *(*r_fopen)(const char *, const char *);
static FILE *(*r_fopen64)(const char *, const char *);
static int   (*r_xstat)(int, const char *, struct stat *);
static int   (*r_xstat64)(int, const char *, struct stat64 *);
static int   (*r_lxstat)(int, const char *, struct stat *);
static int   (*r_lxstat64)(int, const char *, struct stat64 *);
static int   (*r_stat)(const char *, struct stat *);
static int   (*r_stat64)(const char *, struct stat64 *);
static int   (*r_lstat)(const char *, struct stat *);
static int   (*r_lstat64)(const char *, struct stat64 *);

#define DL(x) r_##x = dlsym(RTLD_NEXT, #x)
static void resolve_syms(void) {
    DL(opendir); DL(fdopendir); DL(readdir); DL(readdir64); DL(closedir); DL(rewinddir);
    DL(access); DL(open); DL(open64); DL(openat); DL(openat64); DL(fopen); DL(fopen64);
    r_xstat=dlsym(RTLD_NEXT,"__xstat"); r_xstat64=dlsym(RTLD_NEXT,"__xstat64");
    r_lxstat=dlsym(RTLD_NEXT,"__lxstat"); r_lxstat64=dlsym(RTLD_NEXT,"__lxstat64");
    DL(stat); DL(stat64); DL(lstat); DL(lstat64);
}

/* ---- immutable index ---- */
struct ent { const char *name; unsigned char d_type; };
struct node {
    const char *cf;        /* case-folded absolute path (key) */
    const char *real;      /* real absolute path */
    unsigned char is_dir;
    struct ent *ents;      /* dir entries (is_dir only) */
    int n_ents;
    struct node *next;
};
static struct node **idx;          /* NBUCKETS buckets, published once */
static volatile int idx_ready = 0; /* set 1 after build completes (publish) */
static int g_enabled = 1;          /* CASECACHE_DISABLE=1 -> pure passthrough (fail-safe kill switch) */
static unsigned long g_nodes = 0;  /* index size, for the startup log line */

static uint32_t hash_cf(const char *s) {
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (unsigned char)*s; h *= 16777619u; }
    return h & (NBUCKETS - 1);
}
static char *cfdup(const char *s) {           /* lower-cased copy */
    size_t n = strlen(s); char *o = malloc(n + 1);
    for (size_t i = 0; i < n; i++) o[i] = (char)tolower((unsigned char)s[i]);
    o[n] = 0; return o;
}
static const struct node *idx_find(const char *cf_path) {
    struct node *n = idx[hash_cf(cf_path)];
    for (; n; n = n->next) if (strcmp(n->cf, cf_path) == 0) return n;
    return NULL;
}
/* case-fold a query path into buf */
static int cf_into(const char *s, char *buf, size_t bufsz) {
    size_t n = strlen(s); if (n >= bufsz) return -1;
    for (size_t i = 0; i < n; i++) buf[i] = (char)tolower((unsigned char)s[i]);
    buf[n] = 0; return 0;
}

/* ---- index build (uses REAL libc only) ---- */
static void idx_put(struct node *nd) {
    uint32_t b = hash_cf(nd->cf);
    nd->next = idx[b]; idx[b] = nd;
    g_nodes++;
}
static void build_walk(const char *real) {
    DIR *d = r_opendir(real);
    if (!d) return;
    /* collect entries */
    size_t cap = 8, n = 0;
    struct ent *ents = malloc(cap * sizeof(*ents));
    struct dirent *e;
    while ((e = r_readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (n == cap) { cap *= 2; ents = realloc(ents, cap * sizeof(*ents)); }
        ents[n].name = strdup(e->d_name);
        ents[n].d_type = e->d_type;
        n++;
    }
    r_closedir(d);
    /* register this dir node */
    struct node *dn = calloc(1, sizeof(*dn));
    dn->cf = cfdup(real); dn->real = strdup(real); dn->is_dir = 1;
    dn->ents = ents; dn->n_ents = (int)n;
    idx_put(dn);
    /* register children + recurse into subdirs */
    char child[PATH_MAX];
    for (size_t i = 0; i < n; i++) {
        int isdir;
        if (ents[i].d_type == DT_DIR) isdir = 1;
        else if (ents[i].d_type == DT_UNKNOWN) {
            struct stat st; snprintf(child, sizeof child, "%s/%s", real, ents[i].name);
            isdir = (r_stat ? r_stat(child, &st) : r_xstat(_STAT_VER, child, &st)) == 0 && S_ISDIR(st.st_mode);
        } else isdir = 0;
        snprintf(child, sizeof child, "%s/%s", real, ents[i].name);
        if (is_excluded(child)) continue;        /* don't index writable subtrees */
        if (isdir) {
            build_walk(child);                    /* recurse (registers the subdir node) */
        } else {
            struct node *fn = calloc(1, sizeof(*fn));
            fn->cf = cfdup(child); fn->real = strdup(child); fn->is_dir = 0;
            idx_put(fn);
        }
    }
}

/* Index a single directory's listing (non-recursive). Used for GAME_ROOT's ancestors (/, /opt),
 * which the engine's case-insensitive resolution walks from the filesystem root on every lookup. */
static void index_one(const char *real) {
    DIR *d = r_opendir(real); if (!d) return;
    size_t cap = 8, n = 0; struct ent *ents = malloc(cap * sizeof(*ents));
    struct dirent *e;
    while ((e = r_readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (n == cap) { cap *= 2; ents = realloc(ents, cap * sizeof(*ents)); }
        ents[n].name = strdup(e->d_name); ents[n].d_type = e->d_type; n++;
    }
    r_closedir(d);
    struct node *dn = calloc(1, sizeof(*dn));
    dn->cf = cfdup(real); dn->real = strdup(real); dn->is_dir = 1; dn->ents = ents; dn->n_ents = (int)n;
    idx_put(dn);
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void do_init(void) {
    resolve_syms();
    /* Fail-safe kill switch: with CASECACHE_DISABLE set, the shim is a pure passthrough
     * (every interposed call forwards to libc unchanged). Lets ops disable it without a rebuild. */
    if (getenv("CASECACHE_DISABLE")) { g_enabled = 0; idx_ready = 1; return; }
    idx = calloc(NBUCKETS, sizeof(*idx));
    index_one("/");      /* ancestors of GAME_ROOT: the descent walks case-insensitively from "/" */
    index_one("/opt");
    /* ASSUMPTION: the game tree under GAME_ROOT is static at runtime (workshop content is baked
     * into the image at build time; no runtime volume). The index is built ONCE, here. Files the
     * srcds process itself creates later are caught by the dirty-set; but if runtime workshop
     * UPDATES are ever enabled (the engine rewriting steamapps/workshop/content), the index would
     * go stale and could return false ENOENT for the new files -- disable updates or rebuild the
     * image in that case. */
    build_walk(GAME_ROOT);
    __sync_synchronize();
    idx_ready = 1;
    char m[160];
    int len = snprintf(m, sizeof m, "[casecache] active: indexed %lu nodes under %s\n", g_nodes, GAME_ROOT);
    (void)!write(2, m, len);   /* raw write, not stdio, to avoid reentrancy during init */
}
static inline void init(void) { pthread_once(&once, do_init); }

/* ---- dirty set: runtime-created files (rare; small mutex) ---- */
struct dnode { char *cf; struct dnode *next; };
static struct dnode *dirty[4096];
static pthread_mutex_t dirty_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int dirty_nonempty = 0;   /* gate: stays 0 during read-only loads -> lock-free */
static void dirty_add(const char *path) {
    /* Only track writes that could shadow an authoritative index miss: i.e. files created at
     * runtime UNDER the indexed tree. Writes outside GAME_ROOT, or to excluded (logs/cfg/...)
     * subtrees, are passthrough on read anyway, so tracking them would needlessly flip the
     * lock-free gate (routine log writes would otherwise re-introduce per-miss lock contention). */
    if (!path || path[0] != '/') return;
    if (strncmp(path, GAME_ROOT, sizeof(GAME_ROOT) - 1) != 0) return;
    if (is_excluded(path)) return;
    char cf[PATH_MAX]; if (cf_into(path, cf, sizeof cf)) return;
    uint32_t b = hash_cf(cf) & 4095;
    pthread_mutex_lock(&dirty_lock);
    for (struct dnode *p = dirty[b]; p; p = p->next) if (!strcmp(p->cf, cf)) { pthread_mutex_unlock(&dirty_lock); return; }
    struct dnode *nd = malloc(sizeof *nd); nd->cf = strdup(cf); nd->next = dirty[b]; dirty[b] = nd;
    dirty_nonempty = 1;
    pthread_mutex_unlock(&dirty_lock);
}
static int dirty_has(const char *cf) {
    uint32_t b = hash_cf(cf) & 4095;
    pthread_mutex_lock(&dirty_lock);
    for (struct dnode *p = dirty[b]; p; p = p->next) if (!strcmp(p->cf, cf)) { pthread_mutex_unlock(&dirty_lock); return 1; }
    pthread_mutex_unlock(&dirty_lock);
    return 0;
}

/* Resolve a path for a READ op.
 * return 1: hit, *out = real path; 0: authoritative ENOENT; -1: passthrough original. */
static int resolve(const char *path, char *out, size_t outsz) {
    if (!g_enabled) return -1;
    if (!path || path[0] != '/') return -1;
    if (strncmp(path, GAME_ROOT, sizeof(GAME_ROOT) - 1) != 0) return -1;
    if (is_excluded(path)) return -1;
    char cf[PATH_MAX]; if (cf_into(path, cf, sizeof cf)) return -1;
    const struct node *nd = idx_find(cf);
    if (nd) { if (strlen(nd->real) >= outsz) return -1; strcpy(out, nd->real); return 1; }
    if (dirty_nonempty && dirty_has(cf)) return -1;  /* runtime-created: lock-free unless any write happened */
    /* Authoritative-miss check. The index holds EVERY dir+file under GAME_ROOT, so walk up to
     * the deepest indexed ancestor directory: if it lacks the next path component, the path
     * cannot exist -> ENOENT (no syscall). Only if a component IS present but its subtree wasn't
     * indexed (a genuine build gap) do we defer to libc. This is the common case the engine hits
     * when probing `<search-path>/maps|materials|...` for items that don't contain that subdir. */
    char tmp[PATH_MAX]; if (strlen(cf) >= sizeof tmp) return -1; strcpy(tmp, cf);
    for (;;) {
        char *s = strrchr(tmp, '/');
        if (!s || s == tmp) break;
        *s = 0;
        const char *child = s + 1;
        const struct node *an = idx_find(tmp);
        if (an) {
            if (!an->is_dir) return -1;
            for (int i = 0; i < an->n_ents; i++)
                if (strcmp(an->ents[i].name, child) == 0) return -1;  /* present but deeper unindexed: build gap */
            return 0;                                                 /* component absent -> ENOENT */
        }
    }
    return -1;                            /* no indexed ancestor: passthrough original */
}

/* ---- DIR wrapper ---- */
#define WMAGIC 0xCA5ECAC5u
struct wdir {
    uint32_t magic;
    int cached;              /* 1: iterate index node; 0: passthrough */
    DIR *real;
    const struct node *nd; int idx;
    struct dirent de; struct dirent64 de64;
};

DIR *opendir(const char *path) {
    init();
    struct wdir *w = malloc(sizeof *w);
    if (!w) return r_opendir(path);
    w->magic = WMAGIC; w->idx = 0;
    char cf[PATH_MAX];
    if (g_enabled && path[0]=='/' && !is_excluded(path) && cf_into(path, cf, sizeof cf)==0) {
        const struct node *nd = idx_find(cf);   /* serves any indexed dir, incl. / and /opt */
        if (nd && nd->is_dir) { w->cached = 1; w->nd = nd; w->real = NULL; return (DIR*)w; }
    }
    DIR *r = r_opendir(path);
    if (!r) { free(w); return NULL; }
    w->cached = 0; w->real = r; return (DIR*)w;
}
DIR *fdopendir(int fd) {
    init(); DIR *r = r_fdopendir(fd); if (!r) return NULL;
    struct wdir *w = malloc(sizeof *w); if (!w) return r;
    w->magic = WMAGIC; w->cached = 0; w->real = r; return (DIR*)w;
}
static inline struct wdir *as_w(DIR *d){ struct wdir *w=(struct wdir*)d; return (w && w->magic==WMAGIC)?w:NULL; }

struct dirent *readdir(DIR *d) {
    struct wdir *w = as_w(d);
    if (!w) { init(); return r_readdir(d); }
    if (!w->cached) return r_readdir(w->real);
    if (w->idx >= w->nd->n_ents) return NULL;
    struct ent *e = &w->nd->ents[w->idx++];
    memset(&w->de, 0, sizeof w->de);
    w->de.d_ino = 1; w->de.d_off = w->idx; w->de.d_reclen = sizeof w->de; w->de.d_type = e->d_type;
    strncpy(w->de.d_name, e->name, sizeof(w->de.d_name)-1);
    return &w->de;
}
struct dirent64 *readdir64(DIR *d) {
    struct wdir *w = as_w(d);
    if (!w) { init(); return r_readdir64(d); }
    if (!w->cached) return r_readdir64(w->real);
    if (w->idx >= w->nd->n_ents) return NULL;
    struct ent *e = &w->nd->ents[w->idx++];
    memset(&w->de64, 0, sizeof w->de64);
    w->de64.d_ino = 1; w->de64.d_off = w->idx; w->de64.d_reclen = sizeof w->de64; w->de64.d_type = e->d_type;
    strncpy(w->de64.d_name, e->name, sizeof(w->de64.d_name)-1);
    return &w->de64;
}
int closedir(DIR *d){ struct wdir *w=as_w(d); if(!w){init();return r_closedir(d);} int rc=0; if(!w->cached) rc=r_closedir(w->real); free(w); return rc; }
void rewinddir(DIR *d){ struct wdir *w=as_w(d); if(!w){init();r_rewinddir(d);return;} if(!w->cached){r_rewinddir(w->real);return;} w->idx=0; }

/* ---- file ops ---- */
static int is_wmode(const char *m){ return m && (strchr(m,'w')||strchr(m,'a')||strchr(m,'+')); }

int access(const char *path, int mode) {
    init();
    if (mode & W_OK) { dirty_add(path); return r_access(path, mode); }
    char t[PATH_MAX]; int rr = resolve(path, t, sizeof t);
    /* Answer existence/readability from the index without a syscall. For X_OK (execute) we can't
     * vouch for the mode bits, so fall through to a real check on the resolved path. */
    if (rr==1) return (mode & X_OK) ? r_access(t, mode) : 0;
    if (rr==0) { errno=ENOENT; return -1; }
    return r_access(path, mode);
}
#define OPEN_BODY(realfn) \
    init(); mode_t mode=0; \
    if (flags & O_CREAT){ va_list ap; va_start(ap,flags); mode=va_arg(ap,int); va_end(ap);} \
    if (flags & (O_WRONLY|O_RDWR|O_CREAT)) { dirty_add(path); return realfn(path, flags, mode);} \
    char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); \
    if (rr==1) return realfn(t, flags, mode); \
    if (rr==0) { errno=ENOENT; return -1; } \
    return realfn(path, flags, mode);
int open(const char *path, int flags, ...)   { OPEN_BODY(r_open) }
int open64(const char *path, int flags, ...) { OPEN_BODY(r_open64) }

int openat(int dfd, const char *path, int flags, ...) {
    init(); mode_t mode=0;
    if (flags & O_CREAT){ va_list ap; va_start(ap,flags); mode=va_arg(ap,int); va_end(ap);}
    if (flags & (O_WRONLY|O_RDWR|O_CREAT)) { dirty_add(path); return r_openat(dfd,path,flags,mode);}
    char t[PATH_MAX]; int rr=resolve(path,t,sizeof t);   /* resolve() no-ops on relative paths */
    if (rr==1) return r_openat(dfd,t,flags,mode);
    if (rr==0) { errno=ENOENT; return -1; }
    return r_openat(dfd,path,flags,mode);
}
int openat64(int dfd, const char *path, int flags, ...) {
    init(); mode_t mode=0;
    if (flags & O_CREAT){ va_list ap; va_start(ap,flags); mode=va_arg(ap,int); va_end(ap);}
    if (flags & (O_WRONLY|O_RDWR|O_CREAT)) { dirty_add(path); return r_openat64(dfd,path,flags,mode);}
    char t[PATH_MAX]; int rr=resolve(path,t,sizeof t);
    if (rr==1) return r_openat64(dfd,t,flags,mode);
    if (rr==0) { errno=ENOENT; return -1; }
    return r_openat64(dfd,path,flags,mode);
}
FILE *fopen(const char *path, const char *mode) {
    init();
    if (is_wmode(mode)) { dirty_add(path); return r_fopen(path,mode); }
    char t[PATH_MAX]; int rr=resolve(path,t,sizeof t);
    if (rr==1) return r_fopen(t,mode);
    if (rr==0) { errno=ENOENT; return NULL; }
    return r_fopen(path,mode);
}
FILE *fopen64(const char *path, const char *mode) {
    init();
    if (is_wmode(mode)) { dirty_add(path); return r_fopen64(path,mode); }
    char t[PATH_MAX]; int rr=resolve(path,t,sizeof t);
    if (rr==1) return r_fopen64(t,mode);
    if (rr==0) { errno=ENOENT; return NULL; }
    return r_fopen64(path,mode);
}
#define STAT_BODY(verfn, plainfn, BUFT) \
    init(); char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); \
    const char *p = (rr==1)? t : path; \
    if (rr==0) { errno=ENOENT; return -1; } \
    if (plainfn) return plainfn(p, buf); \
    return verfn(_STAT_VER, p, buf);
int __xstat(int ver, const char *path, struct stat *buf)    { init(); char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); const char*p=(rr==1)?t:path; if(rr==0){errno=ENOENT;return -1;} return r_xstat?r_xstat(ver,p,buf):r_stat(p,buf); }
int __xstat64(int ver, const char *path, struct stat64 *buf){ init(); char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); const char*p=(rr==1)?t:path; if(rr==0){errno=ENOENT;return -1;} return r_xstat64?r_xstat64(ver,p,buf):r_stat64(p,buf); }
int __lxstat(int ver, const char *path, struct stat *buf)   { init(); char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); const char*p=(rr==1)?t:path; if(rr==0){errno=ENOENT;return -1;} return r_lxstat?r_lxstat(ver,p,buf):r_lstat(p,buf); }
int __lxstat64(int ver, const char *path, struct stat64 *buf){init(); char t[PATH_MAX]; int rr=resolve(path,t,sizeof t); const char*p=(rr==1)?t:path; if(rr==0){errno=ENOENT;return -1;} return r_lxstat64?r_lxstat64(ver,p,buf):r_lstat64(p,buf); }
int stat(const char *path, struct stat *buf)    { STAT_BODY(r_xstat,   r_stat,   struct stat) }
int stat64(const char *path, struct stat64 *buf){ STAT_BODY(r_xstat64, r_stat64, struct stat64) }
int lstat(const char *path, struct stat *buf)   { STAT_BODY(r_lxstat,  r_lstat,  struct stat) }
int lstat64(const char *path, struct stat64 *buf){STAT_BODY(r_lxstat64,r_lstat64,struct stat64) }
