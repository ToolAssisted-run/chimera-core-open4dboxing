/* boxing-driver.c - 4D Sports Boxing (Open4DBoxing) as a machine stepped one
 * video frame at a time.
 *
 * Open4DBoxing's game_run() is the DOS game as one blocking call: the program
 * recompiled from its machine code, on a runtime that counts the instructions
 * it runs. Its clocks - the timer chip, the BIOS's ticks, DOS's date and time
 * - go by that count (GameHost.cycles: the CPU speed setting, 22,000
 * instructions a millisecond by default, the speed of the DOSBox-X machine it
 * was checked against), and nothing in it reads the host's time, so a run is
 * the same run everywhere. The PC's date and time at the start is a setting. Here game_run runs on a stack of its own
 * (coro.c) and its host is this file:
 *
 * - each video frame the game passes (GameHost.frame) ends the step: the
 *   picture is converted, the sound of the frame rendered (the chips' to the
 *   frame's end, as many samples of the MT-32's), and the game's stack is left
 *   where it is until the next step;
 * - the buttons of the next step reach the game when it continues: a key that
 *   went down or up gives its make or break code to the keyboard controller
 *   (the game's own INT 9 handler reads it), the mouse's buttons and place go
 *   to the mouse driver (INT 33h), as Open4DBoxing's frontend gives them. A
 *   key held is held: the frontend does not repeat keys either.
 *
 * The game is the two floppies' images (disk1.img, disk2.img): Open4DBoxing
 * reads their files from them in memory, unpacks the PKLITE-packed programs as
 * it loads them, and keeps what the game writes apart (files.c). The game came
 * as four programs, one a video card, and with five sound drivers: the build
 * and the sound are settings, and the MT-32 is Munt's libmt32emu with the
 * project's ROMs.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <emulibc.h>
#include <waterbox_settings.h>

#include "boxing-driver.h"
#include "coro.h"

#include "asm2c.h"
#include "camera.h"
#include "disks.h"
#include "game.h"
#include "opl.h"
#include "pit.h"
#include "sb.h"
#include "tandy.h"

/* the MT-32: Munt's libmt32emu, through its C API */
#define MT32EMU_API_TYPE 1
#include <mt32emu.h>

/* ------------------------------------------------------------ the settings */

/* the builds: the program, the frame rate (boxing-driver.h) */
static const struct
{
	const char *id, *file;
	int num, den;
} k_programs[] = {
	{ "mcga", "4DBMCGA.EXE", BOX_RATE_VGA_NUM, BOX_RATE_VGA_DEN },
	{ "ega", "4DBEGA.EXE", BOX_RATE_CGA_NUM, BOX_RATE_CGA_DEN },
	{ "cga", "4DBCGA.EXE", BOX_RATE_CGA_NUM, BOX_RATE_CGA_DEN },
	{ "tandy", "4DBTDY.EXE", BOX_RATE_CGA_NUM, BOX_RATE_CGA_DEN },
};
#define BOX_PROGRAMS ((int)(sizeof k_programs / sizeof k_programs[0]))

/* the sound drivers: the setting, the game's command line's driver (BOX.BAT's
 * "n pc15.drv d" with the driver in its place) */
static const struct
{
	const char *id, *driver;
} k_sounds[] = {
	{ "mt32", "mt15.drv" },
	{ "sb", "sb15.drv" },
	{ "adlib", "ad15.drv" },
	{ "speaker", "pc15.drv" },
	{ "tandy", "td15.drv" },
};
#define BOX_SOUNDS ((int)(sizeof k_sounds / sizeof k_sounds[0]))

/* the project's firmware: the two floppies, and the MT-32's ROMs for its sound
 * (an MT-32 of the first generation, v1.07: the DOSBox-X core's firmware ids
 * and hashes, as the OpenSamurai core's) */
static const char *const k_disks[] = { "disk1.img", "disk2.img" };
static const char *const k_roms[] = { "MT32_CONTROL.ROM", "MT32_PCM.ROM" };

/* ------------------------------------------------------------------ the state */

static struct
{
	coro *co;
	GameHost host;
	int program;
	int mt32;                 /* the sound is the MT-32's */
	char cmdline[32];
	int exited, exit_code;
	uint64_t frames;          /* video frames shown */
	/* the buttons, and the mouse's place as asked and as the driver was last given it */
	uint8_t held[BOX_BTN_COUNT];
	uint8_t want[BOX_BTN_COUNT];
	int32_t axis[BOX_AXIS_COUNT];
	int32_t given[BOX_AXIS_COUNT];
	/* what the step hands out */
	int render;
	int audio_n;
	int16_t audio[2 * BOX_AUDIO_MAX_SAMPLES];
	uint32_t video[BOX_VIDEO_WIDTH * BOX_VIDEO_HEIGHT];
} g;

static mt32emu_context g_mt32;

/* --------------------------------------------------------------------- input */

/* What each key button is on the PC's keyboard: its scan code (set 1) */
static const uint8_t k_scan[BOX_BTN_COUNT] = {
	[BOX_BTN_KEYPAD_8] = 0x48, [BOX_BTN_KEYPAD_2] = 0x50, [BOX_BTN_KEYPAD_4] = 0x4B, [BOX_BTN_KEYPAD_6] = 0x4D,
	[BOX_BTN_KEYPAD_7] = 0x47, [BOX_BTN_KEYPAD_9] = 0x49, [BOX_BTN_KEYPAD_1] = 0x4F, [BOX_BTN_KEYPAD_3] = 0x51,
	[BOX_BTN_KEYPAD_5] = 0x4C, [BOX_BTN_KEYPAD_0] = 0x52,
	[BOX_BTN_ENTER] = 0x1C, [BOX_BTN_SPACE] = 0x39, [BOX_BTN_BACKSPACE] = 0x0E, [BOX_BTN_ESC] = 0x01,
	[BOX_BTN_TAB] = 0x0F, [BOX_BTN_LEFT_SHIFT] = 0x2A, [BOX_BTN_RIGHT_SHIFT] = 0x36, [BOX_BTN_CTRL] = 0x1D,
	[BOX_BTN_ALT] = 0x38,
	[BOX_BTN_A] = 0x1E, [BOX_BTN_B] = 0x30, [BOX_BTN_C] = 0x2E, [BOX_BTN_D] = 0x20, [BOX_BTN_E] = 0x12,
	[BOX_BTN_F] = 0x21, [BOX_BTN_G] = 0x22, [BOX_BTN_H] = 0x23, [BOX_BTN_I] = 0x17, [BOX_BTN_J] = 0x24,
	[BOX_BTN_K] = 0x25, [BOX_BTN_L] = 0x26, [BOX_BTN_M] = 0x32, [BOX_BTN_N] = 0x31, [BOX_BTN_O] = 0x18,
	[BOX_BTN_P] = 0x19, [BOX_BTN_Q] = 0x10, [BOX_BTN_R] = 0x13, [BOX_BTN_S] = 0x1F, [BOX_BTN_T] = 0x14,
	[BOX_BTN_U] = 0x16, [BOX_BTN_V] = 0x2F, [BOX_BTN_W] = 0x11, [BOX_BTN_X] = 0x2D, [BOX_BTN_Y] = 0x15,
	[BOX_BTN_Z] = 0x2C,
	[BOX_BTN_0] = 0x0B, [BOX_BTN_1] = 0x02, [BOX_BTN_2] = 0x03, [BOX_BTN_3] = 0x04, [BOX_BTN_4] = 0x05,
	[BOX_BTN_5] = 0x06, [BOX_BTN_6] = 0x07, [BOX_BTN_7] = 0x08, [BOX_BTN_8] = 0x09, [BOX_BTN_9] = 0x0A,
	[BOX_BTN_F1] = 0x3B, [BOX_BTN_F2] = 0x3C, [BOX_BTN_F3] = 0x3D, [BOX_BTN_F4] = 0x3E, [BOX_BTN_F5] = 0x3F,
	[BOX_BTN_F6] = 0x40, [BOX_BTN_F7] = 0x41, [BOX_BTN_F8] = 0x42, [BOX_BTN_F9] = 0x43, [BOX_BTN_F10] = 0x44,
};

static int modifier(int b) { return b == BOX_BTN_LEFT_SHIFT || b == BOX_BTN_RIGHT_SHIFT || b == BOX_BTN_CTRL || b == BOX_BTN_ALT; }

void boxdrv_set_button(int index, int down)
{
	if (index >= 0 && index < BOX_BTN_COUNT) g.want[index] = down ? 1 : 0;
}

void boxdrv_set_axis(int index, int32_t value)
{
	static const int32_t max[BOX_AXIS_COUNT] = { BOX_VIDEO_WIDTH - 1, BOX_VIDEO_HEIGHT - 1 };
	if (index < 0 || index >= BOX_AXIS_COUNT) return;
	g.axis[index] = value < 0 ? 0 : value > max[index] ? max[index] : value;
}

/* The buttons that changed, as the keyboard and the mouse would have given
 * them: the modifiers that went down first, then the rest in the panel's
 * order, then the modifiers that came up - so Shift, Ctrl or Alt pressed with
 * a key on one step is down before it, and let go after it. The mouse moves
 * only when its place changed (a mouse sends nothing while it lies still, and
 * the game may place the pointer itself): to the place asked, its motion
 * counted, as the frontend moves it. Runs on the game's stack, where the
 * frontend's input arrives in Open4DBoxing's own frontend: between frames. */
static void apply_buttons(void)
{
	for (int pass = 0; pass < 3; pass++)
		for (int b = 0; b < BOX_BTN_COUNT; b++)
		{
			if (g.want[b] == g.held[b]) continue;
			const int down = g.want[b];
			if ((pass == 0 && !(modifier(b) && down)) || (pass == 1 && modifier(b)) || (pass == 2 && !(modifier(b) && !down)))
				continue;
			g.held[b] = g.want[b];
			if (b == BOX_BTN_MOUSE_LEFT || b == BOX_BTN_MOUSE_RIGHT)
			{
				const u16 bit = b == BOX_BTN_MOUSE_LEFT ? 1 : 2;
				if (down) asm_mouse.buttons |= bit;
				else asm_mouse.buttons &= (u16)~bit;
			}
			else if (b >= BOX_BTN_F1 && b <= BOX_BTN_F10 && camera_get())
				camera_key(b - BOX_BTN_F1, down);   /* the cosmetic camera's, the game never sees them */
			else
				game_key(k_scan[b], false, down);
		}
	if (g.axis[BOX_AXIS_MOUSE_X] != g.given[BOX_AXIS_MOUSE_X] || g.axis[BOX_AXIS_MOUSE_Y] != g.given[BOX_AXIS_MOUSE_Y])
	{
		g.given[BOX_AXIS_MOUSE_X] = g.axis[BOX_AXIS_MOUSE_X];
		g.given[BOX_AXIS_MOUSE_Y] = g.axis[BOX_AXIS_MOUSE_Y];
		/* the driver's place: 0-639 by 0-199 in the game's 320x200 modes */
		const int x = g.axis[BOX_AXIS_MOUSE_X] * 2, y = g.axis[BOX_AXIS_MOUSE_Y];
		asm_mouse.dx = (i16)(asm_mouse.dx + (x - asm_mouse.x));
		asm_mouse.dy = (i16)(asm_mouse.dy + (y - asm_mouse.y));
		asm_mouse.x = (u16)x;
		asm_mouse.y = (u16)y;
		asm_mouse_clamp();
	}
}

/* ------------------------------------------------------------------ the frame */

/* the picture: the game's 320x200 (its EGA, CGA and Tandy modes rendered to the
 * same indexes by Open4DBoxing) through the DAC's 6-bit colours */
static void convert_frame(void)
{
	const uint8_t *screen = game_screen();
	const uint8_t (*dac)[3] = game_palette();
	for (int i = 0; i < BOX_VIDEO_WIDTH * BOX_VIDEO_HEIGHT; i++)
	{
		const uint8_t *c = dac[screen[i]];
		const uint32_t r = (uint32_t)((c[0] & 63) << 2 | (c[0] & 63) >> 4);
		const uint32_t gr = (uint32_t)((c[1] & 63) << 2 | (c[1] & 63) >> 4);
		const uint32_t b = (uint32_t)((c[2] & 63) << 2 | (c[2] & 63) >> 4);
		g.video[i] = 0xFF000000u | r << 16 | gr << 8 | b;
	}
}

/* The frame's sound, mixed as Open4DBoxing's frontend mixes it: the PC
 * speaker's first (it writes), the AdLib's, the Tandy's and the Sound
 * Blaster's added, each to the frame's end on the game's clock; mono, the same
 * on both sides. The MT-32's is stereo and is added to it. */
static void render_audio(void)
{
	static int16_t mono[BOX_AUDIO_MAX_SAMPLES];
	memset(mono, 0, sizeof mono);
	const uint64_t t = game_now();
	int n = pit_render(t, BOX_AUDIO_RATE, mono, BOX_AUDIO_MAX_SAMPLES), m;
	if ((m = opl_render(t, BOX_AUDIO_RATE, mono, BOX_AUDIO_MAX_SAMPLES)) > n) n = m;
	if ((m = tandy_render(t, BOX_AUDIO_RATE, mono, BOX_AUDIO_MAX_SAMPLES)) > n) n = m;
	if ((m = sb_render(t, BOX_AUDIO_RATE, mono, BOX_AUDIO_MAX_SAMPLES)) > n) n = m;
	for (int k = 0; k < n; k++) g.audio[2 * k] = g.audio[2 * k + 1] = mono[k];
	if (g_mt32 && n > 0)
	{
		static int16_t mt[2 * BOX_AUDIO_MAX_SAMPLES];
		mt32emu_render_bit16s(g_mt32, mt, (mt32emu_bit32u)n);
		for (int k = 0; k < 2 * n; k++)
		{
			const int v = g.audio[k] + mt[k];
			g.audio[k] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
		}
	}
	g.audio_n = n;
}

/* GameHost.frame: a video frame has passed. The step ends here; the game's
 * stack waits, and when the next step comes its buttons arrive before the
 * game goes on. */
static bool host_frame(void *ctx, uint64_t frame)
{
	(void)ctx, (void)frame;
	g.frames++;
	if (g.render) convert_frame();
	render_audio();
	coro_yield(g.co);
	apply_buttons();
	return true;
}

/* ------------------------------------------------------------------ the MT-32 */

/* The MT15 driver's MIDI, a byte at a time with its time on the game's clock
 * (PIT ticks): the MT-32 takes it at that time and plays it into the samples
 * the frame renders - as Open4DBoxing's frontend does. */
static mt32emu_report_handler_version MT32EMU_C_CALL mt32_version(mt32emu_report_handler_i i)
{
	(void)i;
	return MT32EMU_REPORT_HANDLER_VERSION_0;
}
/* what Munt would print (its LCD's messages, its debug reports): to nobody -
 * the guest's console is the frontend's */
static void MT32EMU_C_CALL mt32_debug(void *instance, const char *fmt, va_list list) { (void)instance; (void)fmt; (void)list; }
static void MT32EMU_C_CALL mt32_lcd(void *instance, const char *message) { (void)instance; (void)message; }
static const mt32emu_report_handler_i_v0 k_mt32_reports = { .getVersionID = mt32_version, .printDebug = mt32_debug, .showLCDMessage = mt32_lcd };

static long read_all(const char *name, uint8_t **data)
{
	FILE *f = fopen(name, "rb");
	if (!f) return -1;
	fseek(f, 0, SEEK_END);
	const long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	*data = n > 0 ? malloc((size_t)n) : NULL;
	const long got = *data ? (long)fread(*data, 1, (size_t)n, f) : -1;
	fclose(f);
	return got == n ? n : -1;
}

static int mt32_open(char *err, int errsize)
{
	mt32emu_report_handler_i reports = { &k_mt32_reports };
	g_mt32 = mt32emu_create_context(reports, NULL);
	for (int i = 0; i < 2; i++)
	{
		uint8_t *data;
		const long n = read_all(k_roms[i], &data);
		/* Munt keeps the data as given, it does not copy it: the buffers live
		 * as long as the machine */
		if (n < 0 || mt32emu_add_rom_data(g_mt32, data, (size_t)n, NULL) < 0)
		{
			snprintf(err, (size_t)errsize, "The MT-32 did not take %s: it is not an MT-32 ROM Munt knows.", k_roms[i]);
			return 0;
		}
	}
	mt32emu_set_stereo_output_samplerate(g_mt32, BOX_AUDIO_RATE);
	if (mt32emu_open_synth(g_mt32) != MT32EMU_RC_OK)
	{
		snprintf(err, (size_t)errsize, "The MT-32 could not start with these ROMs.");
		return 0;
	}
	return 1;
}

static void host_midi(void *ctx, uint8_t byte, uint64_t t)
{
	(void)ctx;
	if (g_mt32)
		mt32emu_parse_stream_at(g_mt32, &byte, 1, mt32emu_convert_output_to_synth_timestamp(g_mt32, (mt32emu_bit32u)(t * BOX_AUDIO_RATE / 1193182)));
}

static void game_body(void)
{
	g.exit_code = game_run(&g.host);
	g.exited = 1;
}

/* ------------------------------------------------------------------ settings */

/* days since 1970-01-01 of a date (the proleptic Gregorian calendar) */
static int64_t days_from_civil(int64_t y, int m, int d)
{
	y -= m <= 2;
	const int64_t era = (y >= 0 ? y : y - 399) / 400;
	const int64_t yoe = y - era * 400;
	const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

/* the start: "YYYY-MM-DD HH:MM:SS", as seconds since 1970 on the PC's own
 * clock (GameHost.startTime: local time, no zone), or -1 */
static int64_t parse_clock(const char *s)
{
	int y, mo, d, h, mi, se;
	char tail;
	static const int mdays[] = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
	if (sscanf(s, "%d-%d-%d %d:%d:%d%c", &y, &mo, &d, &h, &mi, &se, &tail) != 6) return -1;
	if (y < 1980 || y > 2099 || mo < 1 || mo > 12 || d < 1 || d > mdays[mo - 1] || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 59)
		return -1;
	if (mo == 2 && d == 29 && (y % 4 || (y % 100 == 0 && y % 400))) return -1;
	return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

/* Every file the settings call for is there, and the floppies hold the build
 * chosen. What is in them is the project's: an image of its own (another dump,
 * one changed) is taken as it is, and Chimera pins ITS hash in the project
 * (user-decided, 2026-09-29: a game core's firmware may be custom). The images
 * must be FAT12 floppies with the program on them. */
static int check_files(char *err, int errsize)
{
	for (int i = 0; i < 2; i++)
	{
		FILE *f = fopen(k_disks[i], "rb");
		if (!f)
		{
			snprintf(err, (size_t)errsize, "4D Sports Boxing needs %s - add it as the project's firmware.", k_disks[i]);
			return 0;
		}
		fclose(f);
	}
	if (g.mt32)
		for (int i = 0; i < 2; i++)
		{
			FILE *f = fopen(k_roms[i], "rb");
			if (!f)
			{
				snprintf(err, (size_t)errsize, "4D Sports Boxing needs %s for the MT-32's sound - add it as the project's firmware.", k_roms[i]);
				return 0;
			}
			fclose(f);
		}
	files_set_known(k_disks, 2);
	DosFile *files;
	char why[1024];
	const int n = disks_load(".", &files, why, sizeof why);
	if (n < 0)
	{
		snprintf(err, (size_t)errsize, "The floppies' images could not be read: %s", why[0] == '.' && why[1] == '/' ? why + 2 : why);
		return 0;
	}
	int found = 0;
	for (int i = 0; i < n; i++)
		if (!strcmp(files[i].name, k_programs[g.program].file)) found = 1;
	disks_free(files, n);
	if (!found)
	{
		snprintf(err, (size_t)errsize, "%s is not on the floppies' images: they are not 4D Sports Boxing's.", k_programs[g.program].file);
		return 0;
	}
	return 1;
}

int boxdrv_init(char *err, int errsize)
{
	memset(&g, 0, sizeof g);
	g.axis[BOX_AXIS_MOUSE_X] = g.given[BOX_AXIS_MOUSE_X] = BOX_MOUSE_X_NEUTRAL;
	g.axis[BOX_AXIS_MOUSE_Y] = g.given[BOX_AXIS_MOUSE_Y] = BOX_MOUSE_Y_NEUTRAL;

	char text[64];
	if (wbx_setting_str("video", text, sizeof text) < 0) strcpy(text, "mcga");
	g.program = -1;
	for (int i = 0; i < BOX_PROGRAMS; i++)
		if (!strcmp(text, k_programs[i].id)) g.program = i;
	if (g.program < 0)
	{
		snprintf(err, (size_t)errsize, "the video setting is %s; it is mcga, ega, cga or tandy", text);
		return 0;
	}

	/* the MT-32 unless the project says otherwise (user-decided, 2026-09-29:
	 * game cores default to the MT-32) */
	if (wbx_setting_str("sound", text, sizeof text) < 0) strcpy(text, "mt32");
	int sound = -1;
	for (int i = 0; i < BOX_SOUNDS; i++)
		if (!strcmp(text, k_sounds[i].id)) sound = i;
	if (sound < 0)
	{
		snprintf(err, (size_t)errsize, "the sound setting is %s; it is mt32, sb, adlib, speaker or tandy", text);
		return 0;
	}
	g.mt32 = !strcmp(k_sounds[sound].id, "mt32");
	snprintf(g.cmdline, sizeof g.cmdline, "n %s d", k_sounds[sound].driver);

	if (wbx_setting_str("clock_start", text, sizeof text) < 0) strcpy(text, "1991-07-30 14:47:00");
	const int64_t start = parse_clock(text);
	if (start < 0)
	{
		snprintf(err, (size_t)errsize, "the start date and time is \"%s\"; it is written YYYY-MM-DD HH:MM:SS, from 1980", text);
		return 0;
	}

	/* the PC's speed, as DOSBox's cycles (instructions a millisecond): the
	 * game's frames take its time, its fight's logic its timer's ticks; at
	 * 220,000 every frame fits in one of the timer's 10 ms ticks */
	const long cycles = wbx_setting_long("cpu_speed", 22000);

	/* the cosmetic camera (Open4DBoxing's camera.h): F1-F10 choose the camera
	 * shown, and the game never sees them, so a movie plays the same with the
	 * cameras as without them (the MCGA program only; the others ignore it) */
	camera_set(wbx_setting_bool("cosmetic_camera", 0) != 0);
	if (cycles < 1000 || cycles > 10000000)
	{
		snprintf(err, (size_t)errsize, "the CPU speed is %ld; it goes from 1000 to 10000000 instructions a millisecond", cycles);
		return 0;
	}

	if (!check_files(err, errsize)) return 0;
	if (g.mt32 && !mt32_open(err, errsize)) return 0;

	g.host = (GameHost) {
		/* the floppies' images, mounted by their names; the game's writes in
		 * guest memory (files.c) */
		.gameDir = ".",
		.writeDir = ".",
		.program = k_programs[g.program].file,
		.cmdline = g.cmdline,
		.frame = host_frame,
		.midi = g.mt32 ? host_midi : NULL,
		.ctx = NULL,
		.cycles = (uint32_t)cycles,
		.startTime = start,
	};
	/* the game's whole run on its own stack: the DOS program keeps its state in
	 * the emulated megabyte, and the C stack is only the call chain */
	g.co = coro_create(game_body, 8u << 20);
	if (!g.co)
	{
		snprintf(err, (size_t)errsize, "no memory for the game's stack");
		return 0;
	}
	return 1;
}

/* ------------------------------------------------------------------ the step */

void boxdrv_frame(int render)
{
	gamestate_to_game();
	g.render = render;
	g.audio_n = 0;
	if (!g.exited)
	{
		/* the first step starts the game, which takes its buttons before it
		 * begins; every later one continues it where the last frame ended,
		 * and it takes them there (host_frame) */
		if (g.frames == 0) apply_buttons();
		coro_resume(g.co);
	}
	gamestate_from_game();
}

const uint32_t *boxdrv_video(void) { return g.video; }

const int16_t *boxdrv_audio(int *samples)
{
	*samples = g.audio_n;
	return g.audio;
}

uint64_t boxdrv_frames(void) { return g.frames; }
int boxdrv_exited(void) { return g.exited; }
int boxdrv_program(void) { return g.program; }

void boxdrv_rate(int *num, int *den)
{
	*num = k_programs[g.program < 0 ? 0 : g.program].num;
	*den = k_programs[g.program < 0 ? 0 : g.program].den;
}
