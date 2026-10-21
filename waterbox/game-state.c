/* game-state.c - 4D Sports Boxing's memory and properties (chimera
 * docs/game-cores.md).
 *
 * Open4DBoxing keeps the DOS machine's memory as the program had it: the
 * megabyte a segment addresses, the program loaded at its original segment
 * and its data where the real game had it. That is a domain in place, read and
 * written where the game has it, so a watch on an address found in the
 * original game's memory is a watch on the same thing here; the VGA's memory
 * (A000-BFFF, where the CGA's and the Tandy's are too) and the EGA's four
 * planes are domains beside it. The Game State block holds what is the core's:
 * the frames shown, whether the game ended, the build that runs.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "boxing-driver.h"

#include "types.h"
#include "vga.h"

/* ------------------------------------------------------ the Game State block */

#pragma pack(push, 1)
typedef struct
{
	uint32_t frames;   /* +0 video frames shown */
	uint8_t ended;     /* +4 the player left the game */
	uint8_t build;     /* +5 0 MCGA, 1 EGA, 2 CGA, 3 Tandy */
} game_state;
#pragma pack(pop)

static game_state g_state;

void gamestate_from_game(void)
{
	g_state.frames = (uint32_t)boxdrv_frames();
	g_state.ended = (uint8_t)boxdrv_exited();
	g_state.build = (uint8_t)boxdrv_program();
}

/* nothing in the block is the game's to be told */
void gamestate_to_game(void) {}

/* ------------------------------------------------------------------ domains */

typedef struct
{
	const char *name;
	uint8_t *ptr;
	int64_t size;
	int writable;
} domain;

static domain g_domains[5];
static int g_ndomains;

static void domains_init(void)
{
	if (g_ndomains) return;
	g_domains[g_ndomains++] = (domain){ "Game State", (uint8_t *)&g_state, sizeof g_state, 0 };
	/* the 640 KB DOS gives its program, its data segment among them */
	g_domains[g_ndomains++] = (domain){ "Conventional Memory", g_mem, 0xA0000, 1 };
	/* A000-BFFF: the VGA's 256 colours, the CGA's and the Tandy's screens */
	g_domains[g_ndomains++] = (domain){ "Video Memory", g_mem + 0xA0000, 0x20000, 1 };
	/* the EGA's four planes (the EGA build's screens, behind A000) */
	g_domains[g_ndomains++] = (domain){ "EGA Planes", &vga.plane[0][0], sizeof vga.plane, 1 };
}

int boxdrv_domain_count(void)
{
	domains_init();
	return g_ndomains;
}

const char *boxdrv_domain_name(int i)
{
	domains_init();
	return i >= 0 && i < g_ndomains ? g_domains[i].name : "";
}

uint8_t *boxdrv_domain_ptr(int i)
{
	domains_init();
	return i >= 0 && i < g_ndomains ? g_domains[i].ptr : NULL;
}

int64_t boxdrv_domain_size(int i)
{
	domains_init();
	return i >= 0 && i < g_ndomains ? g_domains[i].size : 0;
}

int boxdrv_domain_writable(int i)
{
	domains_init();
	return i >= 0 && i < g_ndomains && g_domains[i].writable;
}

/* -------------------------------------------------------------------- table */

static char g_table[16 * 1024];
static int g_len;

static void add(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void add(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(g_table + g_len, sizeof g_table - (size_t)g_len, fmt, ap);
	va_end(ap);
	if (n > 0) g_len += n;
}

/* one property: name, domain, offset, type, group, extra JSON members (or "") */
static int g_first = 1;
static void prop(const char *name, const char *dom, long off, const char *type, const char *group, const char *extra)
{
	add("%s\n    { \"name\": \"%s\", \"domain\": \"%s\", \"offset\": %ld, \"type\": \"%s\", \"group\": \"%s\"%s%s }",
		g_first ? "" : ",", name, dom, off, type, group, extra[0] ? ", " : "", extra);
	g_first = 0;
}

/* The MCGA build's data segment, 3173h (Open4DBoxing's docs/FINDINGS.md): the
 * fight's two boxers at DS:BA12 (blue) and DS:BB06 (red), 0xF4 bytes each -
 * word 6 set while the boxer is down, words 7, 8 and 9 its stamina, health and
 * endurance (the bars under its name: P, D and O; 16384 when fresh); the
 * round's punches thrown and landed at DS:A488 and A48A (the red boxer's 0x74
 * on); the manual's question asked about boxer DS:9756; the C library's
 * random state at DS:8472. The other builds keep them elsewhere. */
#define MCGA_DS 0x31730L

static void boxer(const char *who, long at, long stats)
{
	char name[64], extra[256];
	snprintf(name, sizeof name, "%s.Health", who);
	snprintf(extra, sizeof extra, "\"description\": \"The %s boxer's health, the D bar: 16384 fresh; a landed punch takes from it, below 1 floors him\"", who);
	prop(name, "Conventional Memory", MCGA_DS + at + 0x10, "s16", who, extra);
	snprintf(name, sizeof name, "%s.Stamina", who);
	snprintf(extra, sizeof extra, "\"description\": \"The %s boxer's stamina, the P bar: 16384 fresh; a punch thrown and a block cost it\"", who);
	prop(name, "Conventional Memory", MCGA_DS + at + 0x0E, "s16", who, extra);
	snprintf(name, sizeof name, "%s.Endurance", who);
	snprintf(extra, sizeof extra, "\"description\": \"The %s boxer's endurance, the O bar against his maximum: 10 a punch thrown, and drained by lost health\"", who);
	prop(name, "Conventional Memory", MCGA_DS + at + 0x12, "s16", who, extra);
	snprintf(name, sizeof name, "%s.Down", who);
	snprintf(extra, sizeof extra, "\"writable\": false, \"description\": \"Set while the %s boxer is down\"", who);
	prop(name, "Conventional Memory", MCGA_DS + at + 0x0C, "u16", who, extra);
	snprintf(name, sizeof name, "%s.Punches Thrown", who);
	prop(name, "Conventional Memory", MCGA_DS + stats, "u16", who, "\"description\": \"In the round, as the round's statistics count them\"");
	snprintf(name, sizeof name, "%s.Punches Landed", who);
	prop(name, "Conventional Memory", MCGA_DS + stats + 2, "u16", who, "\"description\": \"In the round, as the round's statistics count them\"");
}

static void table_init(void)
{
	if (g_len) return;
	add("{ \"properties\": [");

	prop("Frame", "Game State", 0, "u32", "Game", "\"writable\": false, \"description\": \"Video frames shown: 70.086 a second on the VGA, 59.92 on the EGA, the CGA and the Tandy\"");
	prop("Ended", "Game State", 4, "bool", "Game", "\"writable\": false, \"description\": \"The player left the game (its EXIT)\"");
	prop("Build", "Game State", 5, "u8", "Game",
		"\"writable\": false, \"values\": { \"0\": \"MCGA\", \"1\": \"EGA\", \"2\": \"CGA\", \"3\": \"Tandy\" }, \"description\": \"The program that runs, as the Video setting chose it\"");
	if (boxdrv_program() == 0)
	{
		boxer("Blue", 0xBA12, 0xA488);
		boxer("Red", 0xBB06, 0xA488 + 0x74);
		prop("Manual Question.Boxer", "Conventional Memory", MCGA_DS + 0x9756, "u16", "Game",
			"\"values\": { \"0\": \"Lars Lugnut\", \"1\": \"Hammer McGee\", \"2\": \"Blam Blam\", \"3\": \"Glump Fistwhistle\", "
			"\"4\": \"Lefty Enright\", \"5\": \"Weegie Wonka\", \"6\": \"Clinch Roberts\", \"7\": \"Mac the ouch\", "
			"\"8\": \"Butch McKenna\", \"9\": \"ow\" }, \"description\": \"The name the manual's question asks for, chosen when it is "
			"asked (9, the champion's face, wants the ow of Stan Chow: the original's own slip)\"");
		prop("Random.State", "Conventional Memory", MCGA_DS + 0x8472, "u32", "Game",
			"\"description\": \"The C library's rand() state (x = x * 0x343FD + 0x269EC3), never seeded: the game's randomness is how many times it ran\"");
	}

	add("\n  ]\n}\n");
}

const char *boxdrv_game_properties(void)
{
	table_init();
	return g_table;
}
