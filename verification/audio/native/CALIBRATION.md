# Native audio fixture calibration

These are fixture corrections, separate from product fixes. Emulator media volume
was preserved; the Android fixture amplitude and SDL observer were unchanged.
All failed runs remain failed and are retained in `api35-before-*` directories.

The first build-13 run exposed a product readiness parser defect: successful PCM
blocks arrived, but an OSC title prefix prevented exact READY recognition. Build
14 normalizes bounded terminal controls before matching the complete marker.

Two build-14 runs then exposed gain assumptions in the fixture. The output route
submitted a pure 997 Hz tone at approximately 0.001478 amplitude, below the initial
0.002 threshold. Playback duplication captures before Android output-volume
attenuation: 997 Hz then measured approximately 0.062574, with about 0.000456
response at 1499 Hz (0.73%). The observer uses a 100 ms rectangular Goertzel window;
these non-bin-centered frequencies have finite-window spectral leakage. An
absolute absence bound of 0.00002 was inappropriate across the two gains.

Final checks require at least six blocks from the exact current audio PID, zero
dropped frames, and these controls:

- Each requested frequency exceeds eight times its measured silence floor and
  an absolute 0.00002 floor, and exceeds 25% of block RMS.
- An absent frequency stays below 2% of the requested frequency. This distinguishes
  the observed sidelobe from the actual second tone; it does not require either
  tone to dominate when both are requested.
- Stops return RMS below three times the measured silence baseline, with a
  0.00002 numerical floor. Initial silence admission remains bounded at 0.0001.
- Mac and Mac + Phone each have their own measured silence/stop controls.
- Actual OCR-derived AppKit clicks require fresh frequency/display-bound Android
  tone-start receipts, and new Android tone failures reject the run.

Only aggregate successfully queued PCM is stored. These checks establish routing
and SDL submission, not physical speaker or handset audibility.

## Retained failed attempts

| Directory | Build | Failure |
|---|---|---|
| api35-before-1793381175840818000 | 13 | Timeout: audio UI Mac output initialized |
| api35-before-1793381284970438000 | 14 | Timeout: aggregate PCM mac-A-997 |
| api35-before-1793381401013132000 | 14 | Timeout: aggregate PCM macAndPhone-A-997 |
