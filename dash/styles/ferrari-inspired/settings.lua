-- settings.lua (Ferrari-inspired): everything you'd want to tweak without touching drawing code.
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

  -- Screen colors, after the onboard shots in screenshots/Ferrari/ (22.00.33 = race).
  colors = {
    background = { 0, 0, 0 },
    grid = { 0.85, 0.85, 0.85 },       -- thin white lines between the cells
    label = { 0.5, 0.5, 0.5 },         -- tiny cell labels (only with `labels = true`)
    text = { 1, 1, 1 },
    green = { 0.35, 0.95, 0.45 },      -- lap time, delta, fuel
    yellow = { 1, 0.85, 0.3 },         -- diff
    rpm = { 1, 0.22, 0.18 },           -- RPM text
    tyreText = { 1, 0.3, 0.22 },
    tyreCold = { 1, 1, 1 },            -- cold tyres: white
    tyreHot = { 1, 0.85, 0.3 },
    best = { 0.75, 0.35, 1 },          -- lap pop-up: new best lap
    ersFull = { 0.3, 0.88, 0.55 },     -- battery bar: green ...
    ersLow = { 0.95, 0.3, 0.2 },       -- ... red for the lowest part (`ersBar.lowZone`)
    ersEmpty = { 0.04, 0.09, 0.08 },   -- empty blocks
    sideBar = { 0.3, 0.88, 0.55 },     -- race: bars left (fuel) and right top (deploy left this lap), ERS green
    regenBar = { 0.55, 0.35, 1 },      -- race: right bar, lower blocks = harvested this lap (purple)
    delta = { 0.62, 0.5, 1 },          -- race: delta text (purple)
    blueText = { 0.4, 0.68, 1 },
    infoLabel = { 0.4, 0.68, 1 },      -- race: blue driver codes bottom right
    tyreBlockText = { 0.06, 0.14, 0.09 },
    charge = { 0.55, 0.35, 1 },        -- purple mode box (race) / CHR bar (quali) in recharge mode
    chargeText = { 1, 1, 1 },
    antistall = { 0.85, 0.08, 0.06 }, -- red ANTISTALL block over the two lower rows
    pitBox = { 1, 0.82, 0.05 },        -- pit limiter, race page: yellow gear cell and pit timer (MODE yellow)
    pitBoxQuali = { 1, 1, 1 },         -- pit limiter, quali page: white box in the top middle ...
    pitStrip = { 0.2, 0.45, 1 },       -- ... with a blue strip under it
    popupLabel = { 1, 1, 1 },          -- pop-up name (white)
  },

  -- Tiny labels above the values (the real wheel has them too, barely readable on camera).
  labels = true,

  -- Race screen after the helmet-cam shots (batch2/22.23.07; 22.16.18 = the first seconds after
  -- the line). Smaller cells, more data. { label, data key, format, color name }.
  -- Format 'name' = PU mode name; color 'fuel' = green under the fuel target, red over it.
  raceLayout = {
    left = {   -- top left, 2 x 2 (row by row)
      { 'SOC', 'ersMode', '%d', 'text' }, { 'EB', 'engineBrake', '%d', 'text' },
      { 'BMIG', 'brakeShape', '%d', 'text' }, { 'POS', 'position', '%d', 'text' },
    },
    centre = { -- the two small cells under the mode name
      { 'BATT', 'ersPercent', '%d', 'yellow' }, { 'DEPL', 'deployLeftPercent', '%d', 'blueText' },
    },
    right = {  -- top right, 2 x 2 (row by row)
      { 'BBAL', 'brakeBias', '%.1f', 'text' }, { 'FUEL/LAP', 'fuelPerLap', '%.2f', 'fuel' },
      { 'VMAX', 'topSpeed', '%d', 'text' }, { 'TARGET', 'fuelTarget', '%.2f', 'green' },
    },
  },
  -- Tyre temperatures as colored blocks (race and quali) that fade with the core temperature:
  -- { °C, color }, rising. Blue when cold, ERS green in the window, red when hot.
  tyreBlocks = {
    { 60, { 0.3, 0.55, 1 } },
    { 80, { 0.3, 0.88, 0.55 } },
    { 100, { 0.3, 0.88, 0.55 } },
    { 120, { 1, 0.25, 0.2 } },
  },
  -- Bottom right: the car ahead and behind with the gap. After crossing the line, for this many
  -- seconds: triangles there for the time gained/lost on them that lap, and the tyres as white
  -- numbers (22.16.18).
  lapSummaryDuration = 15,

  -- Pages in the order of the wheel's page switch.
  pages = { 'race', 'quali' },

  -- Quali page (22.04.49), same format as the race page. Top middle: the RPM.
  -- Rows 3-4: tyre blocks next to the gear, brake temperatures outside. Recharge: the purple CHR
  -- bar covers the top right row. Same cell format as raceLayout.
  qualiLayout = {
    left = {
      { 'SPEED', 'speed', '%d', 'text' }, { 'POS', 'position', '%d', 'text' },
      { 'SOC', 'ersMode', '%d', 'text' }, { 'EB', 'engineBrake', '%d', 'text' },
    },
    centre = {
      { 'BATT', 'ersPercent', '%d', 'yellow' }, { 'DEPL', 'deployLeftPercent', '%d', 'blueText' },
    },
    right = {
      { 'BBAL', 'brakeBias', '%.1f', 'text' }, { 'BMIG', 'brakeShape', '%d', 'text' },
      { 'DIFF', 'diff', '%d %d %d', 'yellow' }, { 'VMAX', 'topSpeed', '%d', 'text' },
    },
  },

  -- Battery bar at the bottom: `blocks` cells; the empty ones are dark blocks with lines between.
  -- The lowest `lowZone` (0..1) is a separate red piece, then the green part; both start with a
  -- cut-off top-left corner (`chamfer` px).
  ersBar = { blocks = 20, lowZone = 0.15, chamfer = 14 },

  -- Launch (standing still, clutch in, in gear): the race screen stays, its background takes a
  -- color that fades with the RPM, green -> red -> blue (22.08.32, 22.08.38, 22.14.42).
  -- { rpm, color }, rising RPM.
  launchScreen = {
    enabled = true,
    stops = {
      { 9000, { 0.1, 0.7, 0.25 } },
      { 10000, { 0.8, 0.08, 0.1 } },
      { 10500, { 0.15, 0.25, 0.95 } },
    },
  },

  -- Pop-ups: the name on the left half, the value in a box that fills the right half
  -- (false = plain value without a box). Box color and text color per setting; text is white.
  -- Big letters (like MODE, 22.47.56): the name right-aligned before the box, the value from its left edge.
  popupColors = {
    puMode = { box = { 1, 0.82, 0.05 }, value = { 0, 0, 0 } },        -- MODE: yellow box, black name (22.47.56)
    brakeBias = { box = { 0.85, 0.1, 0.1 }, value = { 1, 1, 1 } },    -- BBAL: red box
    brakeShape = { box = { 0.5, 0.52, 0.54 }, value = { 1, 1, 1 } }, -- BMIG: grey box (22.13.21)
    diffEntry = { box = { 0.15, 0.4, 0.95 }, value = { 1, 1, 1 } },   -- ENT: blue
    diffMid = { box = { 0.1, 0.6, 0.25 }, value = { 1, 1, 1 } },      -- MID: green
    diffExit = { box = { 0.9, 0.45, 0.05 }, value = { 1, 1, 1 } },    -- EXIT: orange
    ersMode = { box = { 0.5, 0.3, 0.95 }, value = { 1, 1, 1 } },      -- SOC (= STRT): purple
    engineBrake = { box = { 0.85, 0.3, 0.4 }, value = { 1, 1, 1 } },
    default = { box = { 0.5, 0.52, 0.54 }, value = { 1, 1, 1 } },
  },

  -- Names of VRC's PU modes (MODE 1..7), shown instead of the number.
  puModeNames = { 'CHRG', 'QUAL', 'FORM', 'START', 'SLOW', 'RACE', 'RACE+' },

  -- Flags: the gear cell takes the flag color (key = ac.FlagType name).
  flagColors = {
    Caution = { 1, 0.82, 0 },
    FasterCar = { 0.2, 0.45, 1 },
  },

  -- Tyre temperatures (core, °C): below `cold` white, above `hot` yellow, red in between.
  tyres = { cold = 75, hot = 110 },

  fonts = { family = 'Liberation Sans' },

  -- Pop-up when a setting changes: seconds on screen (VRC's pit-menu time wins when available).
  popupDuration = 1.5,
  -- Pop-up letters: at most `size` px, smaller when the text would come closer than `margin`
  -- px to the edges of its half.
  popupText = { size = 240, margin = 50 },
  -- Lap summary after the line (22.01.35), seconds (VRC's pit-menu time wins when available).
  lapPopupDuration = 3,

  -- Shift lights like the Ferrari wheel: the red and blue LEDs fill up progressively with the RPM;
  -- the green ones are only for DRS. Recharge mode: three blue LEDs blink.
  shiftLights = {
    enabled = true,
    count = 15,
    colors = {
      'green', 'green', 'green', 'green', 'green',
      'red', 'red', 'red', 'red', 'red',
      'blue', 'blue', 'blue', 'blue', 'blue',
    },
    -- LEDs 6..15 light one by one from startRpm to shiftRpm (one number, or one per gear 1..8).
    rpmLeds = { 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    startRpm = 10000,
    shiftRpm = 11250,
    shiftFlash = { enabled = false, hz = 8, color = 'blue' },
    limiterFlash = { enabled = false, hz = 12, color = 'blue' },
    -- DRS: LED 1 = available, LED 2 = open.
    drs = { availableLed = 1, activeLed = 2, color = 'green' },
    -- Recharge mode: LEDs 11-13 blink blue (`hz` times per second, like the Red Bull flag LEDs).
    recharge = { leds = { 11, 12, 13 }, color = 'blue', hz = 1 },
    -- Same VRC behaviour as the Red Bull dashboard (see dash/styles/redbull/settings.lua).
    engineSequences = { enabled = true, duration = 2.666, startFirst = 0.666, stallFlash = 0.08, stallGap = 0.4 },
    launch = { enabled = true, topRpm = 10700, step = 50, window = 50, wideFromRpm = 10400, wideWindow = 150 },
    antistall = { enabled = true, hz = 1 },
    -- Pit limiter (22.10.32): every other LED on like antistall, but fixed (3 green, 2 red, 3 blue).
    pitLimiter = {
      enabled = true, rampKmh = 30, overKmh = 2, overBlinkHz = 6,
      static = { green = { 1, 3, 5 }, red = { 7, 9 }, blue = { 11, 13, 15 } },
    },
  },
}
