# Wonder Apple TV host build

Experimental unsigned host for Apple TV 4K third generation (A15), tvOS 26+.
Target requested: tvOS 27.0.1. No target-device validation has been performed.
Use Actions → Build Wonder tvOS host → Run workflow. This branch is independent of the Silksong iOS host on main.
This repository and its artifacts contain no game code, resources, keys, fonts or translated game shaders.
The host alone cannot run the game; game data is added locally with scripts/wonder_actions.py pack in the WSL project.
720p game rendering, 1080p presentation, one system-paired extended gamepad (including DualSense).
DualSense haptics preserve left/right and low/high-band envelopes through Core Haptics; frequency maps to sharpness.
Saves use purgeable tvOS cache; this preview does not provide durable cloud saves.
All 16,268 shader entries translate locally, including the repaired dynamic-offset AGL compute shaders.
Metal compilation and rendering of those private shaders still require device validation.
Runtime sources: https://github.com/seedds/nxnative and BC decoder from https://github.com/seedds/d2r-mobile.
Source license notices are retained.
