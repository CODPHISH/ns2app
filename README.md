# Silksong iOS host build

Experimental unsigned native host for iPhone 13 Pro (A15), iOS 26+.
Use Actions → Build Silksong iOS host → Run workflow in a public repository.
Download silksong-ios-host, extract it, then use the original WSL ns2app project:

```sh
python3 scripts/silksong_actions.py pack --work /path/to/private-work --host /path/to/host.zip
```

This repository and artifact contain no game code, game resources, keys or translated game shaders.
The host alone cannot launch the game. Game data is added locally and the user signs/sideloads the result.
Device compatibility and the Unity VR geometry shader remain unverified.
Runtime sources derive from https://github.com/seedds/nxnative and BC decoding from https://github.com/seedds/d2r-mobile; source license notices are retained.
