#ifndef TALYS_ENGINE_H
#define TALYS_ENGINE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double x;
    double y;
    double width;
    double height;
} TalysRect;

typedef struct {
    double inner;
    double outer;
} TalysGapConfig;

typedef uint32_t TalysWindowId;

#define TALYS_DIR_LEFT  0
#define TALYS_DIR_DOWN  1
#define TALYS_DIR_UP    2
#define TALYS_DIR_RIGHT 3

#define TALYS_LAYOUT_DWINDLE      0
#define TALYS_LAYOUT_MASTER_STACK 1
#define TALYS_LAYOUT_MONOCLE      2
#define TALYS_LAYOUT_SCROLLING    3

void talys_engine_init(void);
void talys_engine_reset(void);

void talys_engine_set_gaps(double inner, double outer);

void talys_engine_add_window(TalysWindowId wid);
void talys_engine_remove_window(TalysWindowId wid);
bool talys_engine_has_window(TalysWindowId wid);
void talys_engine_set_min_size(TalysWindowId wid, double width, double height);

void talys_engine_set_focus(TalysWindowId wid);
TalysWindowId talys_engine_get_focus(void);
TalysWindowId talys_engine_focus_direction(uint8_t direction, TalysRect screen_rect);

bool talys_engine_swap_direction(uint8_t direction, TalysRect screen_rect);
bool talys_engine_swap_windows(TalysWindowId a, TalysWindowId b);
void talys_engine_resize_focused(double delta);
bool talys_engine_toggle_float(TalysWindowId wid);
bool talys_engine_is_floating(TalysWindowId wid);
void talys_engine_toggle_fullscreen(void);
bool talys_engine_is_fullscreen(void);

void talys_engine_cycle_layout(void);
uint8_t talys_engine_get_layout_mode(void);
void talys_engine_set_layout_mode(uint8_t mode);

void talys_engine_cycle_column_width(void);
bool talys_engine_consume_or_expel(uint8_t direction);

int talys_engine_calculate_layout(
    TalysRect screen_rect,
    size_t max_count,
    TalysWindowId *out_ids,
    TalysRect *out_rects
);

typedef struct {
    size_t hide_count;
    size_t show_count;
} TalysSwitchResult;

uint8_t talys_engine_get_active_workspace(void);
bool talys_engine_switch_workspace(
    uint8_t target_ws,
    TalysWindowId *out_hide_ids,
    size_t max_hide,
    TalysWindowId *out_show_ids,
    size_t max_show,
    TalysSwitchResult *out_counts
);
bool talys_engine_move_to_workspace(TalysWindowId wid, uint8_t target_ws);
void talys_engine_add_window_to_workspace(TalysWindowId wid, uint8_t target_ws);
// Whether a window would get its minimum size as a tiled window on workspace `ws`.
bool talys_engine_fits_on_workspace(TalysWindowId wid, uint8_t ws, TalysRect screen_rect);
// First workspace after `after` (wrapping, skipping `after` and `skip`) where the window fits; 0 if none.
uint8_t talys_engine_find_room(TalysWindowId wid, uint8_t after, uint8_t skip, TalysRect screen_rect);
size_t talys_engine_get_workspace_window_count(uint8_t ws);

#ifdef __cplusplus
}
#endif

#endif
