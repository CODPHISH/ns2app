# Wonder Apple TV host build

Experimental unsigned host for Apple TV 4K third generation (A15), tvOS 26+.
Target requested: tvOS 27.0.1. No target-device validation has been performed.
Use Actions → Build Wonder tvOS host → Run workflow. This branch is independent of the Silksong iOS host on main.
This repository and its artifacts contain no game code, resources, keys, fonts or translated game shaders.
The host alone cannot run the game; game data is added locally with scripts/wonder_actions.py pack in the WSL project.
720p game rendering, 1080p presentation, one system-paired extended gamepad (including DualSense).
Saves use purgeable tvOS cache; this preview does not provide durable cloud saves.
Two known upstream AGL compute shaders remain untranslated; effects using them are unverified.
Runtime sources: https://github.com/seedds/nxnative and BC decoder from https://github.com/seedds/d2r-mobile.
Source license notices are retained.
