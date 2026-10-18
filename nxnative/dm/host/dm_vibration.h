// Portable vibration state shared by the tvOS HID service and controller driver.
#pragma once
#include <stdint.h>

typedef struct {
    float low_amplitude, low_frequency, high_amplitude, high_frequency;
} dm_vibration_value;
typedef struct {
    dm_vibration_value value[2];
    uint64_t generation;
    uint64_t submitted_ns;
} dm_vibration_frame;

int dm_vibration_handles(uint32_t *out, int capacity, uint32_t id, uint32_t style);
int dm_vibration_side(uint32_t handle);
void dm_vibration_info(uint32_t handle, uint32_t info[2]);
int dm_vibration_mounted(uint32_t handle);
int dm_vibration_permitted(void);
void dm_vibration_permit(int enabled);
void dm_vibration_force(int enabled);
void dm_vibration_send(const uint32_t *handles, const dm_vibration_value *values, int count);
void dm_vibration_actual(uint32_t handle, dm_vibration_value *out);

// The driver installs a nonblocking wake callback, and drains frames on its own
// serial queue. Changes of controller/focus invalidate all queued old effects.
void dm_vibration_set_wake(void (*wake)(void));
void dm_vibration_set_available(unsigned sides);
void dm_vibration_set_active(int active);
int dm_vibration_take(dm_vibration_frame *out);
void dm_vibration_snapshot(dm_vibration_frame *out);
uint64_t dm_vibration_generation(void);
// Core Haptics exposes sharpness, not oscillator frequency in Hz.
float dm_vibration_sharpness(float frequency);
