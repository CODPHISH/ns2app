#pragma once
@class GCController;
// Called on the main queue. Core Haptics work is confined to a separate queue.
void front_tv_haptics_select(GCController *controller);
void front_tv_haptics_active(int active);
void front_tv_haptics_reset(void);
