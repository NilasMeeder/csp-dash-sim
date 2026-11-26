-- settings.lua (Red Bull-inspired): everything you'd want to tweak without touching drawing code.
-- Pure data (no logic), so a future editor could generate this file.
-- Colors are { r, g, b } from 0 to 1, or a name from `palette`.

return {
  -- Visible part of the 1024x1024 display texture (VRC draws in the lower 1024x576).
  display = { x = 0, y = 448, w = 1024, h = 576 },

  palette = {
    green = { 0.1, 1, 0.2 },
    red = { 1, 0.08, 0.05 },
    blue = { 0.15, 0.35, 1 },
  },

  -- Screen colors.
  colors = {
    background = { 0, 0, 0 },
    text = { 1, 1, 1 },
    gear = { 0.82, 0.9, 1 },
    dim = { 0.55, 0.6, 0.7 },          -- labels, units
    line = { 0.22, 0.24, 0.3 },        -- separators
    barBackground = { 0.06, 0.08, 0.14 },
    ersBar = { 0.55, 0.2, 1 },         -- left bar: battery charge
    fuelBar = { 0.1, 0.8, 0.3 },       -- right bar: fuel level, liters above it
    fail = { 0.3, 0.55, 1 },
    ok = { 0.15, 0.85, 0.35 },
    pit = { 1, 0.15, 0.1 },            -- small "PIT LIMITER" text
    tyreCold = { 0.3, 0.55, 1 },
    tyreHot = { 1, 0.15, 0.1 },
  },

  -- Pop-up colors per setting: box (false = no box), label text, value. `default` for the rest.
  popupColors = {
    -- Plain white names, colored values (like the real wheel: MODE value green).
    ersMode = { box = false, label = { 1, 1, 1 }, value = { 0.65, 0.35, 1 } },              -- STRT
    puMode = { box = false, label = { 1, 1, 1 }, value = { 0.15, 0.85, 0.35 } },            -- MODE (engine)
    brakeBias = { box = false, label = { 1, 1, 1 }, value = { 1, 1, 1 } },                  -- BBAL
    brakeShape = { box = false, label = { 1, 1, 1 }, value = { 1, 0.6, 0.15 } },            -- BMIG
    engineBrake = { box = false, label = { 1, 1, 1 }, value = { 0.2, 0.9, 1 } },            -- EB
    diffEntry = { box = false, label = { 1, 1, 1 }, value = { 1, 0.88, 0.2 } },             -- ENTRY
    diffMid = { box = false, label = { 1, 1, 1 }, value = { 1, 0.45, 0.75 } },              -- MID
    diffExit = { box = false, label = { 1, 1, 1 }, value = { 1, 0.35, 0.3 } },              -- EXIT
    default = { box = false, label = { 1, 1, 1 }, value = { 1, 1, 1 } },
  },

  -- Pages in the order of the wheel's page switch (like VRC's race / quali / start).
  pages = { 'race', 'quali', 'home', 'setup' },

  -- Lap pop-up after crossing the line: seconds on screen (VRC's pit-menu time wins when available).
  lapPopupDuration = 3,


  -- Tyre temperatures in the corners of the race page (core temperature, °C):
  -- below `cold` blue, above `hot` red, in between white.
  tyres = { cold = 75, hot = 110 },

  -- Settings between the tyre temperatures on the left and right of the race page:
  -- { label, key in core/data.lua, format }, top to bottom; '' = no label. A row can also be
  -- a list of cells side by side (left to right).
  raceSide = {
    left = { { 'STRT', 'ersMode', '%d' }, { 'MODE', 'puMode', '%d' } },
    right = { { '', 'brakeBias', '%.1f' }, { '', 'engineTemp', '%d°' } },
  },
  -- Rows of small settings at the bottom of the race page (plain, no colors, no lines), e.g.
  -- { { 'ENTRY', 'diffEntry', '%d' }, { 'MID', 'diffMid', '%d' } }. Empty like the real wheel.
  raceInfo = {},
  -- Quali page, same places: STRT and the deploy left this lap, BBAL without a label
  -- (the battery % is already next to the left bar) and the predicted lap time.
  -- Format 'lap' = a lap time (1:22.843).
  qualiSide = {
    left = { { 'STRT', 'ersMode', '%d' }, { 'DEPL', 'deployLeftPercent', '%d%%' } },
    right = { { '', 'brakeBias', '%.1f' }, { 'PRED', 'predictedLapMs', 'lap' } },
  },

  -- Flags on the race page (key = ac.FlagType name): plain white text naming the flag.
  -- Flags not listed here aren't shown.
  flags = {
    Caution = 'YELLOW FLAG',
    FasterCar = 'BLUE FLAG',
    OneLapLeft = 'LAST LAP',
    Finished = 'FINISH',
    Stop = 'BLACK FLAG',
  },

  -- Setup page: all wheel settings in a plain grid, two per row (left | right): { label, key, format }.
  setupGrid = {
    { 'BBAL', 'brakeBias', '%.1f' }, { 'EB', 'engineBrake', '%d' },
    { 'BMIG', 'brakeShape', '%d' }, { 'ENTRY', 'diffEntry', '%d' },
    { 'STRT', 'ersMode', '%d' }, { 'MID', 'diffMid', '%d' },
    { 'MODE', 'puMode', '%d' }, { 'EXIT', 'diffExit', '%d' },
  },

  -- Grid at the bottom of the home page, two per row (left | right): { label, key, format }.
  homeGrid = {
    { 'Water', 'water', '%d°' }, { 'Oil', 'oil', '%d°' },
    { 'Air', 'airTemp', '%d°' }, { 'Track', 'trackTemp', '%d°' },
    { 'Fuel', 'fuel', '%.1f L' }, { 'Battery', 'ersPercent', '%d%%' },
  },

  -- Fonts by family name, like VRC (the .ttf files are in content/fonts of the VRC download).
  fonts = { family = 'Liberation Sans' },

  -- Pop-up when a setting changes: seconds on screen (VRC's pit-menu time wins when available).
  popupDuration = 1.5,

  -- Shift lights: the 15 LEDs above the screen.
  shiftLights = {
    -- false = keep VRC's own shift lights in AC (the preview still shows ours).
    enabled = true,
    count = 15,
    -- Color of each LED when lit, left to right.
    colors = {
      'green', 'green', 'green', 'green', 'green',
      'red', 'red', 'red', 'red', 'red',
      'blue', 'blue', 'blue', 'blue', 'blue',
    },
    -- Block-Block: each block comes on as a whole at its RPM (one number, or one per gear 1..8).
    -- The last block's RPM is the shift point (VRC's shift beep uses it).
    blocks = {
      { leds = { 6, 7, 8, 9, 10 }, rpm = { 10000, 10300, 10500, 10650, 10750, 10850, 10900, 10950 } },
      { leds = { 11, 12, 13, 14, 15 }, rpm = 11250 },
    },
    -- Only used without `blocks`: LEDs one by one from startRpm to shiftRpm.
    rpmLeds = { 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    startRpm = 10000,
    shiftRpm = 11250,
    -- No blinking at the shift point or on the rev limiter.
    shiftFlash = { enabled = false, hz = 8, color = 'blue' },
    limiterFlash = { enabled = false, hz = 12, color = 'blue' },
    -- DRS like VRC's own LEDs: LED 1 = available, LED 2 = open.
    drs = { availableLed = 1, activeLed = 2, color = 'green' },
    -- Driver presets like VRC: LED 4 = preset 1 or 2 active, LED 5 = preset 2.
    presets = { 4, 5 },
    -- Pit limiter: the outer LEDs light up, then fill towards the middle over the last
    -- `rampKmh` before the limit (all on at the limit). More than `overKmh` over: blink.
    pitLimiter = { enabled = true, rampKmh = 30, overKmh = 2, overBlinkHz = 6 },
    -- VRC's engine start/stall sequences: start = LEDs 4-8 for `startFirst` s, then 1-5;
    -- stall = all LEDs for `stallFlash` s, dark until `stallGap`, then LEDs 6-10. Total `duration` s.
    engineSequences = { enabled = true, duration = 2.666, startFirst = 0.666, stallFlash = 0.08, stallGap = 0.4 },
    -- VRC's launch lights (standing still, clutch in): LED i is lit in the `window` of RPM below
    -- topRpm - step * (16 - i); from wideFromRpm the window is wideWindow.
    launch = { enabled = true, topRpm = 10700, step = 50, window = 50, wideFromRpm = 10400, wideWindow = 150 },
    -- Antistall like VRC: odd/even LEDs alternate, every half second at hz = 1.
    antistall = { enabled = true, hz = 1 },
    -- Recharge mode (MODE 1): the middle LEDs of the red row stay lit.
    recharge = { leds = { 7, 8, 9 }, color = 'red' },
    -- Flag zone: these LEDs blink (`hz` times per second) during the listed flags (ac.FlagType names).
    -- Left, middle and right LED of the red row, for every flag shown on screen.
    flag = { leds = { 6, 8, 10 }, color = 'red', hz = 1, flags = { 'Caution', 'FasterCar', 'OneLapLeft', 'Finished', 'Stop' } },
  },
}
