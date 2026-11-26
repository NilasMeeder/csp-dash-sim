-- core/data.lua: collects everything the dashboard shows into one table, every frame.
--
-- Sources: `car`/`sim` (sdk/lib.lua) and, when running inside the VRC car scripts,
-- VRC's own `can` module (engine state, brake bias, engine braking, diff, ...).
-- Styles only read from here, so they don't need to know where a value came from.

local hasCan, can = pcall(require, 'can')
if not hasCan or type(can) ~= 'table' then can = nil end

local data = {
  hasCan = can ~= nil,
  tyres = { {}, {}, {}, {} }, -- FL, FR, RL, RR
}

local GEAR_TEXT = { [-1] = 'R', [0] = 'N' }

local function bus()
  return can and can.bus or nil
end

local topSpeed, topSpeedLap = 0, nil

-- Three-letter code from a driver name: first letters of the last name ("Marco Velden" -> VEL).
local codes = {}
local function driverCode(index)
  local name = ac.getDriverName(index)
  if not name then return nil end
  if not codes[name] then
    local last = name:match('(%S+)%s*$') or name
    codes[name] = last:sub(1, 3):upper()
  end
  return codes[name]
end

-- Cars right ahead of and behind the own car (by race position): code and gap in seconds.
local function neighbours(d)
  d.aheadName, d.aheadGap, d.behindName, d.behindGap = nil, nil, nil, nil
  local mine = car.racePosition
  for i = 1, sim.carsCount - 1 do
    local other = ac.getCar(i)
    if other then
      if other.racePosition == mine - 1 then
        d.aheadName, d.aheadGap = driverCode(i), math.max(0, ac.getGapBetweenCars(car.index, i))
      elseif other.racePosition == mine + 1 then
        d.behindName, d.behindGap = driverCode(i), math.max(0, -ac.getGapBetweenCars(car.index, i))
      end
    end
  end
end

function data.update(dt)
  local d = data
  local b = bus()
  local stream = can and can.stream or nil

  -- Driving
  d.gear = car.gear
  d.gearText = GEAR_TEXT[car.gear] or tostring(car.gear)
  d.speed = car.speedKmh
  d.rpm = car.rpm
  d.rpmLimiter = car.rpmLimiter > 0 and car.rpmLimiter or 11500
  d.limiter = car.isEngineLimiterOn
  d.gas = car.gas
  d.brake = car.brake
  d.clutch = car.clutch -- 1 = pedal released (as VRC's lights.lua reads it)

  -- Engine state (VRC simulates ignition/start; plain cars are always "running")
  d.ignition = not b or b.isIgnitionStage2
  d.engineRunning = not b or b.isEngineRunning
  d.antistall = b and b.isAntistallActive or false
  -- Launch: standing still with the clutch in (VRC's grid start condition, clutch 1 = released)
  d.launch = d.engineRunning and car.speedKmh < 1 and car.clutch < 0.95

  -- Lap
  d.position = car.racePosition
  d.lap = car.lapCount + 1
  -- Top speed of the current lap (starts again at the line).
  if topSpeedLap ~= d.lap then topSpeed, topSpeedLap = 0, d.lap end
  topSpeed = math.max(topSpeed, car.speedKmh)
  d.topSpeed = topSpeed
  neighbours(d)
  d.sector = car.currentSector + 1
  d.lapTimeMs = car.lapTimeMs
  d.lastLapMs = car.previousLapTimeMs
  d.bestLapMs = car.bestLapTimeMs
  d.estimatedLapMs = car.estimatedLapTimeMs
  -- Delta like VRC: estimated lap time vs the reference chosen in the pit menu (lapDelta:
  -- 0 previous lap, 1 best lap, 2 driver target lap). Without VRC: car.performanceMeter (vs best).
  d.delta = car.performanceMeter
  if b and b.lapDelta and car.bestLapTimeMs > 0 then
    local ref = b.lapDelta == 2 and (b.driverTargetLapTime or 0) * 10
      or b.lapDelta == 1 and car.bestLapTimeMs or car.previousLapTimeMs
    local estimated = car.bestLapTimeMs + car.performanceMeter * 1000
    d.delta = ref > 0 and math.clamp((estimated - ref) / 1000, -99.99, 99.99) or 0
  end
  -- Predicted lap time: best lap plus the live delta to it (0 until there is a best lap).
  d.predictedLapMs = car.bestLapTimeMs > 0 and car.bestLapTimeMs + car.performanceMeter * 1000 or 0
  d.lapValid = car.isLapValid

  -- ERS. VRC streams per-lap deploy/harvest in MJ (4 MJ deploy, 2 MJ harvest limits).
  d.ersCharge = car.kersCharge
  d.ersPercent = math.floor(car.kersCharge * 100 + 0.5)
  if stream then
    d.ersDeployLap = math.saturate(stream.kersDeployMJ / 4)
    d.ersRegenLap = math.saturate(stream.kersRegenMJ / 2)
  else
    d.ersDeployLap = car.kersMaxKJ > 0 and math.saturate(car.kersCurrentKJ / car.kersMaxKJ) or 0
    d.ersRegenLap = 0
  end
  d.ersDeployMJ = d.ersDeployLap * 4
  d.ersRegenMJ = d.ersRegenLap * 2
  d.ersDeployLeft = 1 - d.ersDeployLap
  d.deployLeftPercent = math.floor(d.ersDeployLeft * 100 + 0.5)
  d.ersDeploying = car.kersInput > 0.01
  d.ersHarvesting = car.kersCharging
  d.ersMode = car.mgukDelivery + 1
  d.ersModeCount = car.mgukDeliveryCount
  d.ersRecovery = car.mgukRecovery
  d.overtake = car.kersButtonPressed or (b and b.isHybridOvertakeActive) or false

  -- Driver settings (VRC values when available)
  d.brakeBias = (b and b.frontBias or car.brakeBias) * 100
  d.brakeMigration = b and b.brakeMigration and b.brakeMigration * 100 or nil
  d.brakeShape = b and b.brakeShapeMap or nil
  d.engineBrake = (b and b.engineBrakeSetting or car.currentEngineBrakeSetting) + 1
  d.diffEntry = b and b.differentialEntrySetting + 1 or nil
  d.diffMid = b and b.differentialMidSetting + 1 or nil
  d.diffExit = b and b.differentialExitHispdSetting + 1 or nil
  d.puMode = b and b.puMode or nil
  d.recharge = d.puMode == 1 -- VRC PU mode 1 = Recharge
  d.fuelMap = b and b.fuelMap or car.fuelMap
  d.tc = car.tractionControlMode
  d.abs = car.absMode
  d.vrcPage = b and b.displayPage or nil -- 1 race, 2 quali, 3 start, 4 pit
  d.preset1 = b and b.driverPreset1Active or false
  d.preset2 = b and b.driverPreset2Active or false
  -- Pop-up times from VRC's pit menu (stored in 0.1 s); nil = the dashboard's own setting.
  d.popupTime = b and b.displayPopupTime and b.displayPopupTime * 0.1 or nil
  d.lapPopupTime = b and b.displayLapPopupTime and b.displayLapPopupTime * 0.1 or nil

  -- Fuel
  d.fuel = car.fuel
  d.fuelMax = car.maxFuel
  d.fuelLevel = car.maxFuel > 0 and math.saturate(car.fuel / car.maxFuel) or 0
  d.fuelPerLap = car.fuelPerLap > 0 and car.fuelPerLap or (b and b.fuelUseLastLap or 0)
  d.fuelLapsLeft = d.fuelPerLap > 0 and car.fuel / d.fuelPerLap or nil
  d.fuelTarget = b and b.fuelUseTarget or nil

  d.distanceKm = car.distanceDrivenSessionKm

  -- Temperatures
  d.boost = car.turboBoost
  d.water = car.waterTemperature
  d.oil = car.oilTemperature
  d.engineTemp = b and b.puTemperature or car.waterTemperature -- VRC's PU temperature
  for i = 1, 4 do
    local w = car.wheels[i - 1]
    local t = d.tyres[i]
    t.core = w.tyreCoreTemperature
    t.inner = w.tyreInsideTemperature
    t.middle = w.tyreMiddleTemperature
    t.outer = w.tyreOutsideTemperature
    t.surface = (w.tyreInsideTemperature + w.tyreMiddleTemperature + w.tyreOutsideTemperature) / 3
    t.optimum = w.tyreOptimumTemperature
    t.pressure = w.tyrePressure
    t.wear = w.tyreWear
    t.disc = w.discTemperature
  end

  -- DRS
  d.drsPresent = car.drsPresent
  d.drsAvailable = car.drsAvailable
  d.drsActive = car.drsActive

  -- Pit
  d.inPitlane = car.isInPitlane
  d.pitLimiter = car.manualPitsSpeedLimiterEnabled or (b and b.isPitLimiterActive) or false
  d.pitSpeedLimit = car.speedLimiter > 0 and car.speedLimiter or (b and b.pitSpeedLimit or 80)
  d.limiterInAction = car.speedLimiterInAction

  -- Session
  d.flag = sim.raceFlagType
  d.session = sim.raceSessionType
  d.sessionTimeLeftMs = sim.sessionTimeLeft
  d.airTemp = sim.ambientTemperature
  d.trackTemp = sim.roadTemperature
  d.clock = os.clock()
end

return data
