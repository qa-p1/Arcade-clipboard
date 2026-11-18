/* Arcade runtime memory trim, the C twin of arcade_link::runtime::trim (RT-5,
 * AUDIT/memory.md W0). Header-only; Qt and Flutter apps call
 * arcade_trim() after startup and after each hide.
 *
 * Gives freed heap back (malloc_trim) and drops resident pages of this
 * process's read-only file mappings (code r-xp, data r--p) that hold only the
 * file's own bytes; they refault from the page cache. A mapping with any
 * private copy (RELRO, text relocations) is never touched: /proc/self/smaps
 * must show Anonymous and Swap 0. Linux only; elsewhere it does nothing. */
#ifndef ARCADE_TRIM_H
#define ARCADE_TRIM_H

#if defined(__linux__)
#include <malloc.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

/* The smaps entry being read: a clean read-only file mapping is dropped once
 * its last field is read (or the next entry starts). */
struct arcade_trim_vma {
    unsigned long start, end;
    int candidate, copied;
};

static inline void arcade_trim_finish(struct arcade_trim_vma *vma)
{
    if (vma->candidate && !vma->copied && vma->end > vma->start)
        madvise((void *)vma->start, vma->end - vma->start, MADV_DONTNEED);
    vma->candidate = 0;
}

static inline void arcade_trim(void)
{
    malloc_trim(0);
    FILE *smaps = fopen("/proc/self/smaps", "re");
    if (!smaps)
        return;
    char line[4096];
    struct arcade_trim_vma vma = {0, 0, 0, 0};
    while (fgets(line, sizeof line, smaps)) {
        unsigned long start = 0, end = 0, kb = 0;
        char perms[8] = "";
        if (sscanf(line, "%lx-%lx %7s", &start, &end, perms) == 3) {
            arcade_trim_finish(&vma);
            const char *path = strchr(line, '/');
            vma.start = start;
            vma.end = end;
            vma.copied = 0;
            vma.candidate = path && !strstr(line, "(deleted)")
                && (strncmp(perms, "r-xp", 4) == 0 || strncmp(perms, "r--p", 4) == 0);
        } else if (sscanf(line, "Anonymous: %lu", &kb) == 1 || sscanf(line, "Swap: %lu", &kb) == 1) {
            if (kb)
                vma.copied = 1;
        }
    }
    fclose(smaps);
    arcade_trim_finish(&vma);
}

/* W3b: page out this process's private memory while the app is hidden: the
 * heap and anonymous memory, and the pages of private file mappings (written
 * ones such as RELRO go to swap, clean ones are read back from the file).
 * MADV_PAGEOUT never changes contents. Stacks, guard pages and the kernel's
 * mappings are left alone. */
static inline void arcade_page_out_hidden(void)
{
#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif
    FILE *maps = fopen("/proc/self/maps", "re");
    if (!maps)
        return;
    char line[4096];
    while (fgets(line, sizeof line, maps)) {
        unsigned long start = 0, end = 0;
        char perms[8] = "";
        char name[256] = "";
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %255s", &start, &end, perms, name) < 3)
            continue;
        if (perms[3] != 'p' || perms[0] == '-')
            continue;
        if (name[0] == '[' && strcmp(name, "[heap]") != 0 && strncmp(name, "[anon", 5) != 0)
            continue;
        madvise((void *)start, end - start, MADV_PAGEOUT);
    }
    fclose(maps);
}
#else
static inline void arcade_trim(void) {}
static inline void arcade_page_out_hidden(void) {}
#endif

#endif
