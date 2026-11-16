# QA launch incident — stopped

No further GUI/app launch/binding/frame actions after STOP. No preference restoration or writes performed. Existing CUA state preserved.

Artifact: accf14bbbd4d071d6cd4956f8e7ba594c3cb1e19, CI43805334701 artifact14198346528.

Selected path passed to CUA: /Users/chris/github-pet-worktrees/qa-engineer/docs/qa/pr51-accf14b/artifact/extracted/GitHubPet.app. CUA does not expose the selected PID, so binding ownership cannot be asserted from its handle alone. Read-only ps immediately after initial binding found normal artifact PID61688 with no flags. Initial UI showed only the mascot/loading and menu bar; no Inbox/Settings window observed in that normal launch. No private data screenshots taken.

Issued CUA super+q to that binding. Subsequent getAX failed procNotFound. Subsequent ps showed61688 absent and saved31897 still present. Do not infer general same-bundle Cmd-Q safety. Normal launch had no tripwire environment; whether it launched gh/network is unverified.

After discovering real-domain hashes changed, explicitly launched artifact PID63967 with --simulate-monitoring-scope and gh tripwire. CUA then showed Demo/invented scope controls. Opened Inbox via mascot; dragged Inbox title; clicked Settings; dragged Settings title; scrolled Settings. No Settings values edited. At STOP, PID63967 remains running with the simulated Settings window open; it has not been quit.

Saved31897 was present before runner, at runner completion, after accidental quit, and at STOP. STOP ps: parent1, lstart Sat Nov14 12:44:32 2026, saved b0127f0 path. Its GUI/window state was not inspected.

Hash observations (exports read into memory only; saved data contains hashes/counts, no configured values):

runnerBefore: {"globalDomain": {"framesCount": 0, "framesHash": "9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1", "hash": "793228b525462c6e0d6942b133f8cd1f003d239fb0ba82b77e9042ee8b093269", "present": true}, "realDomain": {"framesCount": 2, "framesHash": "2b6cc5829186669ba69a121d60a46f4116e746ee6655b117b325c37856fd3448", "hash": "d78a56120f4010847ce3f71522b450701dc3619b6ea1075aed18fd835bd48c1a", "present": true}, "realPlistSHA256": "d9c54769247bb640cc37ca8fa472b51ca5508c80b20cd153e448c07e9a0b48a1"}

runnerAfter: {"globalDomain": {"framesCount": 0, "framesHash": "9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1", "hash": "793228b525462c6e0d6942b133f8cd1f003d239fb0ba82b77e9042ee8b093269", "present": true}, "realDomain": {"framesCount": 2, "framesHash": "2b6cc5829186669ba69a121d60a46f4116e746ee6655b117b325c37856fd3448", "hash": "d78a56120f4010847ce3f71522b450701dc3619b6ea1075aed18fd835bd48c1a", "present": true}, "realPlistSHA256": "d9c54769247bb640cc37ca8fa472b51ca5508c80b20cd153e448c07e9a0b48a1"}

afterUnintended: {"globalDomain": {"framesCount": 0, "framesHash": "9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1", "hash": "793228b525462c6e0d6942b133f8cd1f003d239fb0ba82b77e9042ee8b093269", "present": true}, "realDomain": {"framesCount": 2, "framesHash": "2b6cc5829186669ba69a121d60a46f4116e746ee6655b117b325c37856fd3448", "hash": "33df4275eba6706f6e552c252e81ded5acfcec3221d6a96398b832df76effab4", "present": true}, "realPlistSHA256": "693b43474fded9458e3dd18af351be796f15e4245a0fd42d09c8f7935c834f80"}

beforeExplicitSimulation: {"globalDomain": {"framesCount": 0, "framesHash": "9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1", "hash": "793228b525462c6e0d6942b133f8cd1f003d239fb0ba82b77e9042ee8b093269", "present": true}, "realDomain": {"framesCount": 2, "framesHash": "2b6cc5829186669ba69a121d60a46f4116e746ee6655b117b325c37856fd3448", "hash": "33df4275eba6706f6e552c252e81ded5acfcec3221d6a96398b832df76effab4", "present": true}, "realPlistSHA256": "693b43474fded9458e3dd18af351be796f15e4245a0fd42d09c8f7935c834f80"}

stopCurrent: {"globalDomain": {"framesCount": 0, "framesHash": "9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1", "hash": "793228b525462c6e0d6942b133f8cd1f003d239fb0ba82b77e9042ee8b093269", "present": true}, "realDomain": {"framesCount": 2, "framesHash": "2b6cc5829186669ba69a121d60a46f4116e746ee6655b117b325c37856fd3448", "hash": "33df4275eba6706f6e552c252e81ded5acfcec3221d6a96398b832df76effab4", "present": true}, "realPlistSHA256": "693b43474fded9458e3dd18af351be796f15e4245a0fd42d09c8f7935c834f80"}

All18 runner runs completed before incident with identical before/after prefs snapshots and zero gh tripwire invocations. Offline evidence only; no combined/final/native-frame acceptance claimed.

Real application-domain hash and plist hash changed after the unintended normal launch interval. The two existing GitHubPet frame keys aggregate hash/count stayed unchanged, as did NSGlobalDomain. No domain/plist added or removed. Changes cannot be attributed to individual keys from hash-only baselines. No restoration attempted.

The explicit simulated native session baseline and STOP hashes match, but its cleanup/quit gate has not been performed. This does not establish completed native frame acceptance.


## Authorized cleanup completed

After explicit authorization, local ps verified PID63967 executable exactly equals the artifact binary and argv is exactly that executable plus --simulate-monitoring-scope. JXA selected NSRunningApplication by63967 and checked executableURL before requesting terminate. Its terminate property evaluated true; trailing function-call syntax raised a TypeError afterward. No retry, signals or bundle-wide quit followed. Read-only ps confirms63967 absent.

Saved31897 remains at the original path/start time. native-frame/afterquit.json records hashes identical to the precise pre-simulation native-frame/preferences-before.json and native-frame/prequit.json. Gh tripwire remains empty. The real-domain change during the accidental normal-launch interval is still disclosed and unrepaired. No changed-key inference is possible from the original hash-only baseline.
