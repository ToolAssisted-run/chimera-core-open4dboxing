/* boxing-driver.h - 4D Sports Boxing (Open4DBoxing) as a machine that is
 * stepped.
 *
 * The same driver is compiled for the miniBox guest and for the native
 * reference (run-native); wbx-entry.c puts the guest ABI on top of it.
 *
 * Wire format (waterbox.config "input.buttons" and "input.axes", same order):
 * the mouse's two buttons, then the keys the game reads - the numeric keypad
 * (the human boxer's default controls, the keyboard's second set: 8 forward,
 * 2 back, 4 and 6 sideways, the corners diagonally), Enter, Space, Backspace,
 * Esc, Tab, both Shifts (the right one is the second set's other button, the
 * left the first set's), Ctrl and Alt (the game's Ctrl commands), the letters
 * (the manual's question, a boxer's name; Q W E / A D / Z X C the first set's
 * directions) and the digits; then the mouse's place, in the picture's
 * pixels. The arrow keys reach the game as the keypad's (its keyboard table
 * is indexed by the scan code alone), so they are not buttons of their own.
 */
#ifndef BOXING_DRIVER_H
#define BOXING_DRIVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum BoxButton
{
	/* the mouse */
	BOX_BTN_MOUSE_LEFT,
	BOX_BTN_MOUSE_RIGHT,
	/* the numeric keypad */
	BOX_BTN_KEYPAD_8,
	BOX_BTN_KEYPAD_2,
	BOX_BTN_KEYPAD_4,
	BOX_BTN_KEYPAD_6,
	BOX_BTN_KEYPAD_7,
	BOX_BTN_KEYPAD_9,
	BOX_BTN_KEYPAD_1,
	BOX_BTN_KEYPAD_3,
	BOX_BTN_KEYPAD_5,
	BOX_BTN_KEYPAD_0,
	/* the other keys the game reads */
	BOX_BTN_ENTER,
	BOX_BTN_SPACE,
	BOX_BTN_BACKSPACE,
	BOX_BTN_ESC,
	BOX_BTN_TAB,
	BOX_BTN_LEFT_SHIFT,
	BOX_BTN_RIGHT_SHIFT,
	BOX_BTN_CTRL,
	BOX_BTN_ALT,
	/* the letters */
	BOX_BTN_A,
	BOX_BTN_B, BOX_BTN_C, BOX_BTN_D, BOX_BTN_E, BOX_BTN_F, BOX_BTN_G, BOX_BTN_H, BOX_BTN_I, BOX_BTN_J,
	BOX_BTN_K, BOX_BTN_L, BOX_BTN_M, BOX_BTN_N, BOX_BTN_O, BOX_BTN_P, BOX_BTN_Q, BOX_BTN_R, BOX_BTN_S,
	BOX_BTN_T, BOX_BTN_U, BOX_BTN_V, BOX_BTN_W, BOX_BTN_X, BOX_BTN_Y, BOX_BTN_Z,
	/* the digits */
	BOX_BTN_0,
	BOX_BTN_1, BOX_BTN_2, BOX_BTN_3, BOX_BTN_4, BOX_BTN_5, BOX_BTN_6, BOX_BTN_7, BOX_BTN_8, BOX_BTN_9,
	BOX_BTN_COUNT
};

enum BoxAxis
{
	BOX_AXIS_MOUSE_X,   /* 0-319: the picture's column */
	BOX_AXIS_MOUSE_Y,   /* 0-199: its row */
	BOX_AXIS_COUNT
};
#define BOX_MOUSE_X_NEUTRAL 160
#define BOX_MOUSE_Y_NEUTRAL 100

#define BOX_VIDEO_WIDTH 320
#define BOX_VIDEO_HEIGHT 200

/* A step is one video frame of the build that runs (Open4DBoxing's game.c,
 * frame_tick): the VGA's 25175000 / 359200 = 70.086 Hz for the MCGA build, the
 * EGA's, CGA's and Tandy's 14318180 / 238944 = 59.92 Hz for the others. */
#define BOX_RATE_VGA_NUM 25175000
#define BOX_RATE_VGA_DEN 359200
#define BOX_RATE_CGA_NUM 14318180
#define BOX_RATE_CGA_DEN 238944

/* stereo (the MT-32's), 44100 frames a second; a step's is a frame's, 630 or 736 */
#define BOX_AUDIO_RATE 44100
#define BOX_AUDIO_MAX_SAMPLES 4096

/* 0 on failure, with the reason in err */
int boxdrv_init(char *err, int errsize);
void boxdrv_set_button(int index, int down);
void boxdrv_set_axis(int index, int32_t value);
/* runs the program to the end of its next video frame */
void boxdrv_frame(int render);
const uint32_t *boxdrv_video(void);
const int16_t *boxdrv_audio(int *samples);   /* stereo frames, left then right */
uint64_t boxdrv_frames(void);
void boxdrv_rate(int *num, int *den);
/* the program ended (the player left the game): every step after is a frame of nothing */
int boxdrv_exited(void);
/* the build that runs: 0 the MCGA program, 1 EGA, 2 CGA, 3 Tandy */
int boxdrv_program(void);

/* files.c: the game's files. The project's are mounted under their names and
 * read as they are (the two floppies' images; the MT-32's ROMs); what the game
 * writes (its boxers, its Hall of Fame, a saved career, the system panel's
 * defaults) lives in guest memory. The names the game may look up in its
 * directory are these. */
void files_set_known(const char *const *names, int count);

/* game-state.c: the domains and the property table */
int boxdrv_domain_count(void);
const char *boxdrv_domain_name(int i);
uint8_t *boxdrv_domain_ptr(int i);
int64_t boxdrv_domain_size(int i);
int boxdrv_domain_writable(int i);
const char *boxdrv_game_properties(void);
void gamestate_from_game(void);
void gamestate_to_game(void);

#ifdef __cplusplus
}
#endif

#endif
