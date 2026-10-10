// The game loops' clock (index.js and embed.js): animation-frame timestamps
// locked to a grid of the display's refreshes.
//
// The loops run a game frame each time an accumulator of elapsed time passes
// a frame's step. With the accumulator near the step, a timestamp a little
// early or late decides 0 frames or 2 for that refresh, and browsers do not
// stamp exactly at the refresh: Safari rounds to whole milliseconds (16 and
// 17 ms intervals at 60 Hz), Chrome to 0.1 ms with ±0.4 ms of spread. On a
// 60 Hz screen that was 33-60 uneven refreshes a minute at 1x and 60-100 at
// 2x, measured by replaying 20 s of each browser's real timestamps.
//
// So a callback within jitter of a whole number of refreshes after the last
// counts as exactly that many, nudged 5% of the way toward its own time, so
// game time stays within a few ms of real time. Anything else (a new or
// variable refresh rate, a stall, a resume after a pause) is taken as it
// comes and restarts the grid there; 8 off-grid callbacks in a row relearn
// the refresh interval.
//
// Classic script in the browser (window.FrameGrid); node context for tests.
(function (g) {
  // A clock: next(timestamp, iv) returns the time to add for a callback at
  // `timestamp`, `iv` after the last one (0 on the first after a pause).
  const create = () => {
    let period = 0;     // the display's refresh interval, learnt
    let samples = 0;
    let odd = 0;        // callbacks in a row off the grid
    let clock = 0;      // the grid time of the last callback
    const next = (timestamp, iv) => {
      if (!(iv > 0 && iv < 100) || clock === 0) { clock = timestamp; return iv; }
      const since = timestamp - clock;
      if (period === 0) { period = since; samples = 1; clock = timestamp; return since; }
      const k = Math.round(since / period);
      const err = since - k * period;
      if (k < 1 || k > 4 || Math.abs(err) > Math.min(3, period * 0.4)) {
        if (++odd >= 8) { period = 0; odd = 0; }
        clock = timestamp;
        return since;
      }
      odd = 0;
      period += (err / k) * Math.max(0.01, 1 / ++samples);
      const step = k * period + err * 0.05;
      clock += step;
      return step;
    };
    return { next, period: () => period };
  };

  g.FrameGrid = { create };
})(typeof window !== "undefined" ? window : globalThis);
