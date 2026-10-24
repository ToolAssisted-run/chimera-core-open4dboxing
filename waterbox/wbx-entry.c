/* wbx-entry.c - the chimera guest ABI over boxing-driver.
 *
 * Compiles identically for the guest (miniBox emulibc) and for the native
 * reference (native-shim/emulibc.h), which is what makes the equivalence gate
 * a real proof: the same driver, the same exports, one in the sandbox and one
 * out of it.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <emulibc.h>

#include "boxing-driver.h"

static char g_load_error[1024];

/* A button changed through SetButton is held until it changes again; the
 * packed mask of FrameAdvance covers the first 64 (the function keys F8-F10
 * are buttons 64-66: SetButton's alone - Chimera drives a core of more than 64
 * buttons through SetButton, and may still pack the first 64). A step sees
 * their union. */
static uint8_t g_set_buttons[BOX_BTN_COUNT];

/* Turbo: the picture is not converted. Only the conversion - the game draws
 * its screen whatever happens, because what it draws is part of the game. */
ECL_INVISIBLE int chimera_render_enabled = 1;

ECL_EXPORT const char *GetLoadError(void) { return g_load_error; }

ECL_EXPORT int Init(void)
{
	g_load_error[0] = '\0';
	return boxdrv_init(g_load_error, (int)sizeof g_load_error);
}

/* every button is a key or a mouse button the game reads, whatever the settings */
ECL_EXPORT int IsButtonActive(int32_t index) { return index >= 0 && index < BOX_BTN_COUNT; }

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BOX_BTN_COUNT) g_set_buttons[index] = state ? 1 : 0;
}

/* the mouse's place, in the picture's pixels (input.axes) */
ECL_EXPORT void SetAxis(int32_t index, int32_t value) { boxdrv_set_axis(index, value); }

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	for (int i = 0; i < BOX_BTN_COUNT; i++)
		boxdrv_set_button(i, g_set_buttons[i] | (i < 64 && ((packed >> i) & 1)));
	boxdrv_frame(chimera_render_enabled);
}

ECL_EXPORT void SetRenderingEnabled(int on) { chimera_render_enabled = on != 0; }

ECL_EXPORT uint32_t *GetVideoBgra(void) { return (uint32_t *)boxdrv_video(); }
ECL_EXPORT int GetVideoWidth(void) { return BOX_VIDEO_WIDTH; }
ECL_EXPORT int GetVideoHeight(void) { return BOX_VIDEO_HEIGHT; }
/* 320x200 on a 4:3 monitor */
ECL_EXPORT int GetDisplayAspectX(void) { return 4; }
ECL_EXPORT int GetDisplayAspectY(void) { return 3; }

ECL_EXPORT int16_t *GetAudio(void)
{
	int n;
	return (int16_t *)boxdrv_audio(&n);
}

ECL_EXPORT int GetAudioSampleCount(void)
{
	int n;
	boxdrv_audio(&n);
	return n;
}

/* a step is one video frame of the build that runs: 70.086 Hz on the VGA,
 * 59.92 on the EGA, the CGA and the Tandy */
ECL_EXPORT int GetVsyncNumerator(void)
{
	int num, den;
	boxdrv_rate(&num, &den);
	return num;
}
ECL_EXPORT int GetVsyncDenominator(void)
{
	int num, den;
	boxdrv_rate(&num, &den);
	return den;
}

/* The game reads the keyboard through its own interrupt handler and the mouse
 * whenever it likes: every step is one it could have read them in. */
ECL_EXPORT int InputWasRead(void) { return 1; }

/* memory domains: Game State, then the DOS machine's memory in place */
ECL_EXPORT int GetMemoryDomainCount(void) { return boxdrv_domain_count(); }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return boxdrv_domain_name(i); }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return boxdrv_domain_ptr(i); }
ECL_EXPORT int64_t GetMemoryDomainSize(int i) { return boxdrv_domain_size(i); }
ECL_EXPORT int GetMemoryDomainWritable(int i) { return boxdrv_domain_writable(i); }

/* chimera docs/game-cores.md: the property table */
ECL_EXPORT const char *GetGameProperties(void) { return boxdrv_game_properties(); }

/* the machine's own clock: video frames, for harnesses that compare machines */
ECL_EXPORT uint64_t GetCycleCount(void) { return boxdrv_frames(); }
