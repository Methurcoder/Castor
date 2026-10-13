# Motion evaluation baseline

Output of `swift run -c release arils-motion-eval` with two `say` clips (Kyoko, Eddy; 24 kHz).
"Before" is the engine at `04d92a7` measured with the same harness; — means the feature did not exist.
Numbers are guard rails, not ground truth for "alive": re-run after motion changes and explain any regression.
With 6 seeds, rare-event counts (micro-actions, per-phase blink rates) move by about ±30 % between unrelated changes; rates and ratios are steadier.

| area | metric | before | after |
|---|---|---|---|
| Idle | blinks / min (human rest ≈ 15–20) | 20.0 | 21.6 |
| Idle | inter-blink interval CV (human ≈ 0.6–1.0) | 0.52 | 0.72 |
| Idle | partial-blink ratio (human ≈ 0.1–0.4) | 0.00 | 0.16 |
| Idle | saccades / s without a target | 0.20 | 0.44 |
| Idle | head yaw periodicity (lower = less loop-like) | 0.10 | 0.03 |
| Gaze | large-saccade duration ms (human ≈ 50–100) | 120 | 71 |
| Gaze | eyes cover 75 % of a jump (ms) | 189 | 119 |
| Gaze | large saccades with a blink (human ≈ 0.2–0.5) | 0.11 | 0.40 |
| Gaze | eyes lead, then recentre as head arrives | 0.004 | 0.075 |
| Phases | phase guessed from 2 s of body motion (chance 0.25) | 0.27 | 0.78 |
| Phases | … same, legacy host mapping (energy + isSpeaking) | — | 0.48 |
| Phases | blinks / min thinking | 19.5 | 18.0 |
| Phases | blinks / min speaking (procedural) | 18.0 | 21.5 |
| Phases | head yaw+roll speed speaking ÷ idle (human > 1.5) | 0.95 | 1.70 |
| Transition | runs where posture responds to idle → thinking | 0.00 | 1.00 |
| Transition | time to 50 % of new posture (ms) | 0 | 417 |
| Speech | head speed talking ÷ idle, real speech | 1.13 | 4.06 |
| Speech | nods per minute of speech | 0.0 | 20.7 |
| Speech | utterances starting with a look-away | 0.17 | 0.67 |
| Speech | blinks / min talking (human ≈ 20–30) | 21.3 | 24.1 |
| Listening | backchannel nods / min | — | 11.5 |
| Listening | nods within 0.9 s of a user pause | — | 1.00 |
| Lip sync | shipping meter path: mouth lag ms | 108 | 108 |
| Lip sync | shipping meter path: mouth at −18 dB ÷ 0 dB | 0.21 | 1.08 |
| Lip sync | PCM tap: envelope correlation | 0.913 | 0.912 |
| Lip sync | PCM tap: mouth closed in pauses | 0.76 | 0.74 |
| Lip sync | PCM tap: open/close cycles ÷ syllables | 0.52 | 0.52 |
| Lip sync | PCM tap: mouth at −18 dB ÷ 0 dB | 0.16 | 0.98 |
| Lip sync | timeline: mouth lag ms (− = leads) | — | -50 |
| Lip sync | timeline: envelope correlation | — | 0.975 |
| Lip sync | timeline: mouth closed in pauses | — | 1.00 |
| Lip sync | timeline: open/close cycles ÷ syllables | — | 0.89 |
| Lip sync | timeline: mouth at −18 dB ÷ 0 dB | — | 1.00 |
| Frame rate | 99th-pct max Δ 30/60/120 fps (fraction of range) | 0.013 | 0.012 |
| Frame rate | worst max Δ 30/60/120 fps | 0.281 | 0.146 |

Personality presets (after):

| preset | latency ms | overshoot | blinks/min watching | gaze averted |
|---|---|---|---|---|
| standard | 417 | 0.015 | 21.7 | 0.061 |
| shy | 619 | 0.077 | 27.7 | 0.156 |
| lively | 269 | 0.000 | 25.3 | 0.036 |
| calm | 453 | 0.005 | 18.5 | 0.054 |
| clumsy | 656 | 0.140 | 22.8 | 0.070 |

Micro-actions per 10 min (after):

| action | unattended | user present every 20 s |
|---|---|---|
| glance | 8.5 | 10.3 |
| weightShift | 19.2 | 17.0 |
| sigh | 2.7 | 0.0 |
| yawn | 1.2 | 0.0 |
| doze | 1.5 | 0.0 |
