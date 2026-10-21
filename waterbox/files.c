/* files.c - the game's files, as the sandbox can give them.
 *
 * Open4DBoxing finds a file by listing a directory (opendir/readdir, the DOS
 * names in any case) and opens <dir>/<name>: the floppies' images in the game
 * directory (disks.c), and in its write directory the files the game wrote
 * (dos.c: its boxers, its Hall of Fame, a saved career, the system panel's
 * defaults - a file of the disks is copied there before it is written, and
 * found there first after). It deletes one with remove(). miniBox has no
 * directories and no files but the ones a project mounts, under their bare
 * names. So the link wraps the five calls (sources.mk) and they come here:
 *
 * - a directory lists the names the core knows the project mounted (the two
 *   images, files_set_known) and the files the game has written;
 * - a file opened to read is one the game wrote, if it did, and otherwise the
 *   mounted file of that name;
 * - a file opened to write lives in guest memory, so a savestate carries it -
 *   as the game's disk would, in a DOS machine's savestate;
 * - a file removed is one the game wrote (a mounted one stays).
 *
 * Natively (the reference) the work directory holds the same files under the
 * same names, and everything goes the same way.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/types.h>

#include "boxing-driver.h"

FILE *__real_fopen(const char *path, const char *mode);

/* a cookie's seek offset: glibc's is off64_t, musl's off_t (both 64 bits) */
#ifdef __GLIBC__
typedef off64_t cookie_off;
#else
typedef off_t cookie_off;
#endif

/* ------------------------------------------------------------ written files */

/* The game writes few and small files: BCDATA1.DAT and BCDATA2.DAT (its
 * boxers and the Main Event, 2 KB each) and CONFIG1.DAT (the system panel's
 * defaults, 8 bytes); the Gym exports a boxer to drive A: or B:, which the
 * machine does not have. */
#define SAVED_FILES 16
#define SAVED_FILE_MAX 16384

static struct
{
	char name[16];
	int used;
	long len;
	uint8_t data[SAVED_FILE_MAX];
} g_saved[SAVED_FILES];

static const char *base_name(const char *path)
{
	const char *slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

static int saved_index(const char *name, int create)
{
	for (int i = 0; i < SAVED_FILES; i++)
		if (g_saved[i].used && !strcasecmp(g_saved[i].name, name)) return i;
	if (!create || strlen(name) >= sizeof g_saved[0].name) return -1;
	for (int i = 0; i < SAVED_FILES; i++)
	{
		if (g_saved[i].used) continue;
		g_saved[i].used = 1;
		g_saved[i].len = 0;
		strcpy(g_saved[i].name, name);
		return i;
	}
	return -1;
}

/* an open written file: which one, and where */
static struct
{
	int used, file;
	long pos;
} g_open[SAVED_FILES];

static ssize_t mem_read(void *c, char *buf, size_t n)
{
	const int h = (int)(intptr_t)c;
	const long len = g_saved[g_open[h].file].len;
	long pos = g_open[h].pos;
	if (pos >= len) return 0;
	if ((long)n > len - pos) n = (size_t)(len - pos);
	memcpy(buf, g_saved[g_open[h].file].data + pos, n);
	g_open[h].pos = pos + (long)n;
	return (ssize_t)n;
}

static ssize_t mem_write(void *c, const char *buf, size_t n)
{
	const int h = (int)(intptr_t)c;
	const int f = g_open[h].file;
	const long pos = g_open[h].pos;
	if (pos + (long)n > SAVED_FILE_MAX) return -1;   /* a disk full */
	if (pos > g_saved[f].len) memset(g_saved[f].data + g_saved[f].len, 0, (size_t)(pos - g_saved[f].len));
	memcpy(g_saved[f].data + pos, buf, n);
	g_open[h].pos = pos + (long)n;
	if (g_open[h].pos > g_saved[f].len) g_saved[f].len = g_open[h].pos;
	return (ssize_t)n;
}

static int mem_seek(void *c, cookie_off *off, int whence)
{
	const int h = (int)(intptr_t)c;
	const long base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? g_open[h].pos : g_saved[g_open[h].file].len;
	if (base + *off < 0) return -1;
	g_open[h].pos = (long)(base + *off);
	*off = g_open[h].pos;
	return 0;
}

static int mem_close(void *c)
{
	g_open[(int)(intptr_t)c].used = 0;
	return 0;
}

static FILE *mem_open(int file, const char *mode)
{
	for (int h = 0; h < SAVED_FILES; h++)
	{
		if (g_open[h].used) continue;
		g_open[h].used = 1;
		g_open[h].file = file;
		g_open[h].pos = mode[0] == 'a' ? g_saved[file].len : 0;
		cookie_io_functions_t io = { mem_read, mem_write, mem_seek, mem_close };
		FILE *f = fopencookie((void *)(intptr_t)h, mode, io);
		if (!f) g_open[h].used = 0;
		return f;
	}
	return NULL;
}

FILE *__wrap_fopen(const char *path, const char *mode)
{
	const char *name = base_name(path);
	const int writes = strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+');
	int file = saved_index(name, writes);
	if (file >= 0)
	{
		if (mode[0] == 'w') g_saved[file].len = 0;
		return mem_open(file, mode);
	}
	if (writes) return NULL;
	return __real_fopen(name, mode);
}

int __wrap_remove(const char *path)
{
	const int i = saved_index(base_name(path), 0);
	if (i < 0) return -1;
	for (int h = 0; h < SAVED_FILES; h++)
		if (g_open[h].used && g_open[h].file == i) return -1;   /* (DOS keeps an open file) */
	g_saved[i].used = 0;
	return 0;
}

/* ---------------------------------------------------------- the directory */

static const char *const *g_known;
static int g_known_count;

void files_set_known(const char *const *names, int count)
{
	g_known = names;
	g_known_count = count;
}

/* one listing at a time is all the game ever has open */
static struct
{
	int open, next;
	struct dirent entry;
} g_dir;

DIR *__wrap_opendir(const char *path)
{
	(void)path;
	if (g_dir.open) return NULL;
	g_dir.open = 1;
	g_dir.next = 0;
	return (DIR *)&g_dir;
}

struct dirent *__wrap_readdir(DIR *d)
{
	if ((void *)d != (void *)&g_dir) return NULL;
	for (;;)
	{
		const int k = g_dir.next++;
		const char *name;
		if (k < g_known_count) name = g_known[k];
		else if (k < g_known_count + SAVED_FILES)
		{
			const int i = k - g_known_count;
			if (!g_saved[i].used) continue;
			name = g_saved[i].name;
		}
		else return NULL;
		memset(&g_dir.entry, 0, sizeof g_dir.entry);
		snprintf(g_dir.entry.d_name, sizeof g_dir.entry.d_name, "%s", name);
		return &g_dir.entry;
	}
}

int __wrap_closedir(DIR *d)
{
	if ((void *)d != (void *)&g_dir) return -1;
	g_dir.open = 0;
	return 0;
}
