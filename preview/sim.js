// sim.js: simulated lap that drives car/sim/can data, plus one-click scenarios.
//
// Every field has two sources: the simulation, or a manual override set from the
// control panel. Overrides are stored by path ('car.rpm', 'wheels.0.tyrePressure',
// 'sim.raceFlagType', 'can.bus.puMode') and applied after each simulation step.

(function () {
  'use strict';

  // Fields of VRC's can module that the original dashboard reads (field names as used by the car).
  // Value ranges are best guesses from how data.lua/pages.lua use them.
  const CAN_SCHEMA = {
    bus: [
      ['isIgnitionStage1', 'boolean'], ['isIgnitionStage2', 'boolean'], ['isElectronicsBooted', 'boolean'],
      ['isEngineRunning', 'boolean'], ['isStarterCranking', 'boolean'], ['isAntistallActive', 'boolean'],
      ['isPitLimiterActive', 'boolean'], ['isHybridOvertakeActive', 'boolean'], ['isHybridAntiActive', 'boolean'],
      ['driverPreset1Active', 'boolean'], ['driverPreset2Active', 'boolean'],
      ['displayPage', 'integer'], ['displayStyle', 'integer'], ['ledShiftPattern', 'integer'],
      ['steeringWheelStyle', 'integer'], ['ledBrightness', 'integer'], ['displayBacklightBrightness', 'integer'],
      ['displayPopupTime', 'integer'], ['displayLapPopupTime', 'integer'], ['displayPrivacyFilterMult', 'number'],
      ['puMode', 'integer'], ['puTemperature', 'number'], ['engineBrakeSetting', 'integer'],
      ['differentialEntrySetting', 'integer'], ['differentialMidSetting', 'integer'], ['differentialExitHispdSetting', 'integer'],
      ['frontBias', 'number'], ['brakeMigration', 'number'], ['brakeShapeMap', 'integer'], ['brakeBiasLive', 'number'],
      ['fuelMap', 'integer'], ['pedalMap', 'integer'], ['torqueMap', 'integer'], ['tcSlipSetting', 'integer'],
      ['antirollBarFrontPosition', 'integer'], ['antirollBarRearPosition', 'integer'],
      ['fuelUseLastLap', 'number'], ['fuelUseTarget', 'number'], ['lapDelta', 'integer'],
      ['driverTargetLapTime', 'integer'], ['driverTargetStintLaps', 'integer'], ['pitSpeedLimit', 'integer'],
    ].map(([name, type]) => ({ name, type })),
    stream: [
      ['kersInput', 'number'], ['kersChargeMJ', 'number'], ['kersDeployMJ', 'number'], ['kersRegenMJ', 'number'],
    ].map(([name, type]) => ({ name, type })),
  };

  // ---------------------------------------------------------------------------
  // Track: ~4.6 km as straights and corners, turned into a speed profile
  // ---------------------------------------------------------------------------
  const DS = 2; // metres per profile sample
  const SEGMENTS = [
    // [length m, corner min speed km/h (0 = straight), direction (+1 right, -1 left), name]
    [520, 0, 0, 'Start/finish'],
    [80, 95, 1, 'T1'],
    [260, 0, 0],
    [120, 160, -1, 'T2'],
    [100, 185, 1, 'T3'],
    [420, 0, 0],
    [140, 255, 1, 'T4'],
    [300, 0, 0],
    [60, 120, -1, 'T5'],
    [60, 125, 1, 'T6'],
    [680, 0, 0, 'Back straight'],
    [150, 140, -1, 'T7'],
    [220, 0, 0],
    [180, 210, 1, 'T8'],
    [120, 232, -1, 'T9'],
    [360, 0, 0],
    [90, 105, 1, 'T10'],
    [140, 0, 0],
    [110, 175, -1, 'T11'],
    [390, 0, 0, 'Final straight'],
  ];
  const DRS_ZONES = [[60, 500], [2010, 2600]]; // metres from the line (inside the two long straights)

  const MASS_POWER = 950;   // W/kg
  const DRAG_K = 0.00108;   // gives ~345 km/h top speed
  const accelMax = (v) => Math.min(12 + 0.0022 * v * v, MASS_POWER / Math.max(v, 4)) - DRAG_K * v * v;
  const decelMax = (v) => 14 + 0.0045 * v * v + DRAG_K * v * v;
  const latG = (v) => 2.0 + 3.0 * Math.pow(v / 83, 2); // lateral grip in g at speed v (m/s)

  function buildTrack() {
    const n = Math.round(SEGMENTS.reduce((s, x) => s + x[0], 0) / DS);
    const limit = new Float64Array(n).fill(Infinity);
    const curv = new Float64Array(n); // signed 1/R
    let i = 0;
    for (const [len, vmin, dir] of SEGMENTS) {
      const count = Math.round(len / DS);
      for (let k = 0; k < count && i < n; k++, i++) {
        if (vmin) {
          const v = vmin / 3.6;
          limit[i] = v;
          // Ease the curvature in and out over the corner for smoother lateral g.
          const shape = Math.sin(Math.PI * (k + 0.5) / count) * 0.5 + 0.5;
          curv[i] = (dir * (latG(v) * 9.81)) / (v * v) * shape;
        }
      }
    }
    const length = n * DS;

    // Forward (acceleration) and backward (braking) passes, two laps each for wrap-around.
    const v = new Float64Array(n);
    let cur = 20;
    for (let k = 0; k < 2 * n; k++) {
      const j = k % n;
      cur = Math.min(limit[j], Math.sqrt(cur * cur + 2 * accelMax(cur) * DS));
      v[j] = cur;
    }
    cur = v[n - 1];
    for (let k = 2 * n - 1; k >= 0; k--) {
      const j = k % n;
      cur = Math.min(v[j], Math.sqrt(cur * cur + 2 * decelMax(cur) * DS));
      v[j] = cur;
    }

    const gas = new Float64Array(n), brake = new Float64Array(n), longA = new Float64Array(n);
    for (let j = 0; j < n; j++) {
      const v1 = v[j], v2 = v[(j + 1) % n];
      const a = (v2 * v2 - v1 * v1) / (2 * DS);
      longA[j] = a;
      if (a > 0.3) { gas[j] = curv[j] ? 0.75 : 1; }
      else if (a < -1) { brake[j] = Math.min(1, -a / decelMax(v1)); }
      else { gas[j] = curv[j] ? 0.45 : 1; }
    }

    // Reference lap time along the track (with ideal speeds).
    const tAt = new Float64Array(n);
    let t = 0;
    for (let j = 0; j < n; j++) { tAt[j] = t; t += DS / v[j]; }

    return { n, length, limit, curv, v, gas, brake, longA, idealLapTime: t };
  }

  // ---------------------------------------------------------------------------
  // Car constants
  // ---------------------------------------------------------------------------
  const RPM_LIMITER = 11500;
  const RPM_IDLE = 4000;
  const GEAR_TOP_KMH = [0, 98, 132, 163, 194, 226, 259, 294, 348]; // speed at limiter per gear
  const UPSHIFT_RPM = 11480; // VRC's last shift LED comes on at 11500
  const DOWNSHIFT_RPM = 10300;
  // Launch revs: VRC's launch LEDs light 13..15 (the last three) between 10500 and 10550 rpm.
  const LAUNCH_RPM = 10525;
  const LAUNCH_RAMP = 4000;        // rpm/s while building up the revs
  const LAUNCH_HOLD = 3.5;         // s from selecting first gear to pulling away (build-up + hold)
  const STARTUP_IDLE = 3;          // s idling in neutral after the engine starts
  const GENTLE_TIME = 10;          // s of calm driving before racing again
  const GENTLE_UPSHIFT_RPM = 8500; // short-shifting while pulling away
  const BRAKE_DOWNSHIFT_RPM = 11150; // downshift under braking as soon as the lower gear allows it
  const ERS_MAX_MJ = 4;
  const ERS_DEPLOY_KW = [0, 25, 50, 70, 100, 120]; // per mgukDelivery mode
  const ERS_MODE_NAMES = ['None', 'Build', 'Low', 'Balanced', 'High', 'Overtake'];

  function defaultsFor(fields) {
    const o = {};
    for (const f of fields) {
      if (f.type === 'boolean') o[f.name] = false;
      else if (f.type === 'vec3') o[f.name] = { x: 0, y: 0, z: 0 };
      else if (f.type === 'vec2') o[f.name] = { x: 0, y: 0 };
      else if (f.type === 'number' || f.type === 'integer' || /^ac\.[A-Z]\w+$/.test(f.type)) o[f.name] = 0;
    }
    return o;
  }

  class Model {
    constructor(schema) {
      this.schema = schema;
      this.track = buildTrack();
      this.manual = new Map();
      this.scenario = null;
      this.reset();
    }

    reset() {
      const s = this.schema;
      const car = defaultsFor(s.car);
      const sim = defaultsFor(s.sim);
      const wheels = [0, 1, 2, 3].map(() => defaultsFor(s.wheel));
      const can = { bus: defaultsFor(CAN_SCHEMA.bus), stream: defaultsFor(CAN_SCHEMA.stream) };
      this.state = { car, wheels, sim, can };

      Object.assign(car, {
        index: 0, gearCount: 8, rpmLimiter: RPM_LIMITER, gear: 1, rpm: RPM_IDLE,
        drsPresent: true, mgukDelivery: 3, mgukDeliveryCount: ERS_DEPLOY_KW.length, mgukRecovery: 7,
        kersCharge: 0.8, kersMaxKJ: 4000, hasKERS: true,
        currentEngineBrakeSetting: 3, engineBrakeSettingsCount: 11, fuelMap: 1, fuelMapsCount: 4,
        brakeBias: 0.565, tractionControlMode: 0, absMode: 0, tractionControlModes: 0,
        fuel: 100, maxFuel: 110, racePosition: 3, isLapValid: true, isEngineLimiterOn: false,
        waterTemperature: 95, oilTemperature: 105, oilPressure: 5, turboBoost: 3.2,
        engineLifeLeft: 1000, compoundIndex: 1, isAIControlled: false, isConnected: true, physicsAvailable: true,
        isActive: true, isRemote: false, isUserControlled: true,
      });
      Object.assign(sim, {
        raceSessionType: 3, raceFlagType: 0, carsCount: 20, focusedCar: 0, isSessionStarted: true,
        ambientTemperature: 24, roadTemperature: 36, rainIntensity: 0, timeHours: 14, timeMinutes: 0,
        sessionTimeLeft: 45 * 60 * 1000, isOnlineRace: false, isReplayActive: false, fps: 60,
      });
      wheels.forEach((w, i) => Object.assign(w, {
        tyreCoreTemperature: 90, tyreInsideTemperature: 92, tyreMiddleTemperature: 90, tyreOutsideTemperature: 88,
        tyreOptimumTemperature: 95, tyrePressure: 22.5, tyreStaticPressure: 21, tyreWear: 0,
        discTemperature: i < 2 ? 520 : 420, tyreRadius: 0.36, tyreWidth: i < 2 ? 0.305 : 0.405,
      }));
      Object.assign(can.bus, {
        isIgnitionStage1: true, isIgnitionStage2: true, isElectronicsBooted: true, isEngineRunning: true,
        displayPage: 1, ledBrightness: 100, displayBacklightBrightness: 100, displayPopupTime: 10, displayLapPopupTime: 30,
        displayPrivacyFilterMult: 10, puMode: 6, puTemperature: 110, engineBrakeSetting: 3,
        differentialEntrySetting: 5, differentialMidSetting: 6, differentialExitHispdSetting: 7,
        frontBias: 0.565, brakeMigration: 0.02, brakeShapeMap: 3, fuelMap: 1, pedalMap: 1, torqueMap: 1, tcSlipSetting: 0,
        antirollBarFrontPosition: 6, antirollBarRearPosition: 4, fuelUseLastLap: 0, fuelUseTarget: 1.6,
        lapDelta: 1, driverTargetLapTime: 8200, driverTargetStintLaps: 25, pitSpeedLimit: 80,
      });

      this.wasRunning = true;
      this.gentleT = undefined;
      this.dist = 0;           // metres from the line
      this.v = 70;             // m/s
      this.ersMJ = 3.2;
      this.lapTime = 0;
      this.lapIndex = 0;
      this.lapFactor = 1;
      this.timeAt = new Float64Array(this.track.n);
      this.bestAt = null;
      this.lapDeployMJ = 0;
      this.lapRegenMJ = 0;
      this.lapFuelStart = car.fuel;
      this.drsOpen = false;
      this.shiftTimer = 0;
      this.clock = 0;          // simulated seconds (also os.clock in Lua)
      this.mode = 'race';      // race | grid | pit | sweep
      this.gridTimer = 0;
      this.sweepT = 0;
      this.flagHook = null;
    }

    // --- manual overrides --------------------------------------------------------
    get(path) {
      const parts = path.split('.');
      let o = this.state;
      for (const p of parts) { if (o == null) return undefined; o = o[p]; }
      return o;
    }
    set(path, value) {
      const parts = path.split('.');
      let o = this.state;
      for (let i = 0; i < parts.length - 1; i++) o = o[parts[i]];
      o[parts[parts.length - 1]] = value;
    }
    setManual(path, value) { this.manual.set(path, value); this.set(path, value); }
    clearManual(path) { this.manual.delete(path); }
    clearAllManual() { this.manual.clear(); }
    isManual(path) { return this.manual.has(path); }

    // --- simulation ----------------------------------------------------------------
    step(dt) {
      this.clock += dt;
      const { car, sim } = this.state;
      sim.time = this.clock * 1000;
      const totalMin = 14 * 60 + this.clock / 60;
      sim.timeHours = Math.floor(totalMin / 60) % 24;
      sim.timeMinutes = Math.floor(totalMin % 60);
      sim.sessionTimeLeft = Math.max(0, 45 * 60 * 1000 - this.clock * 1000);
      sim.isPaused = false;

      // Engine just started while standing still: idle in neutral, then pull away calmly.
      const running = !!this.state.can.bus.isEngineRunning;
      if (running && !this.wasRunning && this.v < 1 && this.mode !== 'grid' && this.mode !== 'sweep') {
        this.resumeMode = this.mode === 'pit' ? 'pit' : 'race';
        this.mode = 'startup'; this.startupT = 0;
      }
      this.wasRunning = running;

      if (this.mode === 'startup') this.stepStartup(dt);
      else if (this.mode === 'grid') this.stepGrid(dt);
      else if (this.mode === 'sweep') this.stepSweep(dt);
      else this.stepDriving(dt);

      if (this.scenario && this.scenario.tick) this.scenario.tick(this, dt);
      this.hold();
    }

    // Applies manual overrides without advancing the simulation (used while paused).
    hold() {
      for (const [path, value] of this.manual) this.set(path, value);
      this.deriveCan();
    }

    sample(arr) {
      const t = this.track;
      const x = this.dist / DS;
      const i = Math.floor(x) % t.n, j = (i + 1) % t.n, f = x - Math.floor(x);
      return arr[i] * (1 - f) + arr[j] * f;
    }

    stepDriving(dt) {
      const { car } = this.state;
      const t = this.track;
      const pit = this.mode === 'pit';

      // Speed follows the profile: accelerate towards it, brake exactly on it.
      let target = this.sample(t.v) * this.lapFactor;
      if (pit) target = Math.min(target, 80 / 3.6);
      const prevV = this.v;
      // Clutch held (car.clutch < 0.95, AC: 0 = pedal down) or engine off: no drive, the car rolls out.
      const bus = this.state.can.bus;
      this.coast = car.clutch < 0.95 && this.manual.has('car.clutch') || !bus.isEngineRunning;
      if (this.coast) this.v = Math.min(target, Math.max(0, this.v - (0.6 + DRAG_K * this.v * this.v) * dt));
      else if (this.v < target) this.v = Math.min(target, this.v + accelMax(this.v) * this.gentleFactor() * dt);
      else this.v = target;
      if (this.gentleT !== undefined && (this.gentleT += dt) >= GENTLE_TIME) this.gentleT = undefined;
      const longA = (this.v - prevV) / Math.max(dt, 1e-4);
      const prevDist = this.dist;
      this.dist += this.v * dt;
      this.lapTime += dt;

      // Lap time at every DS-metre mark, interpolated within the frame so no mark is skipped
      // (a skipped mark stayed 0 and made the delta jump).
      for (let k = Math.floor(prevDist / DS) + 1; k * DS <= this.dist && k < t.n; k++) {
        this.timeAt[k] = this.lapTime - dt + dt * (k * DS - prevDist) / Math.max(this.dist - prevDist, 1e-9);
      }

      if (this.dist >= t.length) this.completeLap();

      const curv = this.sample(t.curv);
      const accelerating = longA > 0.5;
      const braking = longA < -2;
      car.gas = this.coast ? 0 : pit ? 0.3 : accelerating ? (curv ? 0.8 : 1) * this.gentleFactor() : braking ? 0 : this.sample(t.gas);
      car.brake = braking ? Math.min(1, -longA / decelMax(this.v)) : 0;
      if (!this.manual.has('car.clutch')) car.clutch = 1; // AC/VRC: 1 = engaged (pedal up); lights.lua sees < 0.95 at standstill as clutch held
      car.steer = Math.max(-200, Math.min(200, curv * 2800));
      car.acceleration = { x: (-curv * this.v * this.v) / 9.81, y: 0, z: longA / 9.81 };
      car.speedKmh = this.v * 3.6;
      car.speedMs = this.v;
      car.splinePosition = this.dist / t.length;
      car.currentSector = Math.min(2, Math.floor(car.splinePosition * 3));
      car.lapTimeMs = Math.round(this.lapTime * 1000);
      car.lapCount = this.lapIndex;
      car.distanceDrivenThisLap = this.dist;

      // Delta to best lap at the same position.
      if (this.bestAt) {
        const pos = Math.min(this.dist / DS, t.n - 1);
        const i0 = Math.floor(pos), i1 = Math.min(i0 + 1, t.n - 1);
        car.performanceMeter = this.lapTime - (this.bestAt[i0] + (this.bestAt[i1] - this.bestAt[i0]) * (pos - i0));
        car.estimatedLapTimeMs = Math.round(car.bestLapTimeMs + car.performanceMeter * 1000);
      } else {
        car.performanceMeter = 0;
        car.estimatedLapTimeMs = Math.round(t.idealLapTime * 1000);
      }

      this.stepGearbox(dt);
      this.stepErs(dt, pit);
      this.stepDrs(pit);
      this.stepFuelAndTemps(dt, curv, longA);

      car.isInPitlane = pit;
      car.speedLimiter = pit ? 80 : 0;
      car.speedLimiterInAction = pit && car.speedKmh >= 79.5;
      car.manualPitsSpeedLimiterEnabled = pit;
    }

    completeLap() {
      const { car } = this.state;
      const t = this.track;
      this.dist -= t.length;
      const lapMs = Math.round(this.lapTime * 1000);
      car.previousLapTimeMs = lapMs;
      if (!car.bestLapTimeMs || lapMs < car.bestLapTimeMs) {
        car.bestLapTimeMs = lapMs;
        this.bestAt = Float64Array.from(this.timeAt);
      }
      const used = this.lapFuelStart - car.fuel;
      car.fuelPerLap = used;
      this.state.can.bus.fuelUseLastLap = used;
      this.lapFuelStart = car.fuel;
      this.lapIndex++;
      this.lapTime = this.v > 0 ? this.dist / this.v : 0;
      this.timeAt.fill(0);
      this.lapDeployMJ = 0;
      this.lapRegenMJ = 0;
      car.kersCurrentKJ = 0;
      // A little lap-to-lap variation so the delta moves around.
      this.lapFactor = 0.993 + Math.random() * 0.012;
    }

    stepGearbox(dt) {
      const { car } = this.state;
      const kmh = this.v * 3.6;
      const rpmFor = (g) => (kmh / GEAR_TOP_KMH[g]) * RPM_LIMITER;
      if (car.gear < 1) car.gear = 1;
      if (this.coast) {
        const bus = this.state.can.bus;
        if (!bus.isEngineRunning) { car.rpm = 0; car.gas = 0; }
        else if (this.v < 0.3) {
          // Standing still with the clutch in: the driver holds launch revs (VRC's launch LEDs).
          car.gear = 1; car.gas = 0.6;
          this.launchRevs(dt);
        } else car.rpm += (RPM_IDLE - car.rpm) * Math.min(1, dt * 2.5);
        car.isEngineLimiterOn = false;
        return;
      }
      this.shiftTimer = Math.max(0, this.shiftTimer - dt);
      if (this.shiftTimer === 0) {
        // Driver reacts ~0.1 s after the shift lights are full, then shifts.
        // Pulling away calmly after an engine start: short-shift.
        const upshiftAt = this.gentleT !== undefined ? GENTLE_UPSHIFT_RPM : UPSHIFT_RPM;
        if (car.gear < 8 && rpmFor(car.gear) >= upshiftAt) {
          this.shiftWait = (this.shiftWait || 0) + dt;
          if (this.shiftWait >= 0.1) { car.gear++; this.shiftTimer = 0.12; this.shiftWait = 0; }
        } else this.shiftWait = 0;
        // Braking: downshift aggressively (engine braking), so the revs stay high and the
        // shift lights flash up on every downshift. Otherwise only when the revs get low.
        const braking = car.brake > 0.1;
        if (car.gear > 1 && rpmFor(car.gear - 1) < (braking ? BRAKE_DOWNSHIFT_RPM : DOWNSHIFT_RPM)) {
          car.gear--; this.shiftTimer = braking ? 0.22 : 0.18; this.blip = 0.12;
        }
      }
      // Clutch slip at low speed keeps the revs above idle; fades out by 50 km/h.
      let rpm = Math.max(RPM_IDLE + car.gas * 4500 * Math.max(0, 1 - kmh / 50), rpmFor(car.gear));
      if (this.clutchSlip > 0) { // just launched: drop from the launch revs instead of instantly
        this.clutchSlip -= dt;
        rpm = Math.max(rpm, car.rpm - 6000 * dt);
      }
      // Throttle blip on a downshift: a short rev spike.
      if (this.blip > 0) { this.blip -= dt; rpm += 350 * Math.max(0, this.blip / 0.12); }
      car.rpm = Math.min(RPM_LIMITER, rpm);
      car.isEngineLimiterOn = rpm >= RPM_LIMITER - 15;
    }

    stepErs(dt, pit) {
      const { car, can } = this.state;
      const mode = Math.max(0, Math.min(ERS_DEPLOY_KW.length - 1, car.mgukDelivery | 0));
      let deployKW = 0;
      if (!pit && car.gas > 0.9 && car.speedKmh > 100) deployKW = ERS_DEPLOY_KW[mode] * (car.kersButtonPressed ? 1.5 : 1);
      const lapLimitMJ = car.kersMaxKJ / 1000;
      let deployMJ = (deployKW * dt) / 1000;
      deployMJ = Math.min(deployMJ, this.ersMJ, Math.max(0, lapLimitMJ - this.lapDeployMJ));
      // MGU-K harvests under braking, the MGU-H adds a bit on throttle.
      const regenKW = Math.min(1, car.brake * 2) * 120 * (car.mgukRecovery / 10) + (car.gas > 0.9 ? 32 : car.gas > 0.2 ? 18 : 0);
      const regenMJ = Math.min((regenKW * dt) / 1000, ERS_MAX_MJ - this.ersMJ);

      this.ersMJ = Math.max(0, Math.min(ERS_MAX_MJ, this.ersMJ - deployMJ + regenMJ));
      this.lapDeployMJ += deployMJ;
      this.lapRegenMJ += regenMJ;

      car.kersCharge = this.ersMJ / ERS_MAX_MJ;
      car.kersInput = deployKW > 0 && deployMJ > 0 ? Math.min(1, deployKW / 120) : 0;
      car.kersLoad = Math.min(1, regenKW / 120);
      car.kersCharging = regenMJ > 0;
      car.kersCurrentKJ = this.lapDeployMJ * 1000;
      car.mguhChargingBatteries = car.gas > 0.2 && car.gas < 0.9;

      can.stream.kersInput = car.kersInput;
      can.stream.kersChargeMJ = this.ersMJ;
      can.stream.kersDeployMJ = this.lapDeployMJ;
      can.stream.kersRegenMJ = this.lapRegenMJ;
    }

    stepDrs(pit) {
      const { car } = this.state;
      const inZone = !pit && DRS_ZONES.some(([a, b]) => this.dist >= a && this.dist <= b);
      car.drsAvailable = inZone && this.gentleT === undefined; // not while pulling away after an engine start
      if (!inZone || car.brake > 0.05) this.drsOpen = false;
      else if (car.gas > 0.95) this.drsOpen = true;
      car.drsActive = this.drsOpen && car.drsAvailable;
    }

    stepFuelAndTemps(dt, curv, longA) {
      const { car, wheels, sim } = this.state;
      const fuelMapK = [1.1, 1, 0.92, 0.85][Math.max(0, Math.min(3, car.fuelMap | 0))];
      car.fuel = Math.max(0, car.fuel - (0.004 + 0.026 * car.gas) * fuelMapK * dt);

      const amb = sim.ambientTemperature;
      const v = this.v;
      const lat = -curv * v * v / 9.81; // +g = pushed to the left (right-hand corner)
      for (let i = 0; i < 4; i++) {
        const w = wheels[i];
        const front = i < 2, left = i % 2 === 0;
        const load = (left ? Math.max(0, lat) : Math.max(0, -lat)) * 1.0 + Math.abs(lat) * 0.25;
        let heat = load * 3.6 + v * 0.04;
        if (front) heat += car.brake * 6;
        else heat += Math.max(0, longA / 9.81) * 3;
        const cool = (w.tyreMiddleTemperature - amb) * (0.035 + v * 0.0009);
        const surf = w.tyreMiddleTemperature + (heat - cool) * dt * 1.6;
        w.tyreMiddleTemperature = surf;
        w.tyreInsideTemperature = surf + 4 + (front ? 1 : 0);
        w.tyreOutsideTemperature = surf - 3 + load * 1.5;
        w.tyreCoreTemperature += (surf - w.tyreCoreTemperature) * dt * 0.12;
        w.tyrePressure = w.tyreStaticPressure + (w.tyreCoreTemperature - 20) * 0.022;
        w.tyreWear = Math.min(1, w.tyreWear + (load * 0.6 + 0.15) * dt * 0.00002);

        const discHeat = (front ? 1 : 0.65) * car.brake * v * 1.2;
        const discCool = (w.discTemperature - amb) * (0.01 + v * 0.0006);
        w.discTemperature += (discHeat * 6 - discCool * 4) * dt;
      }

      car.waterTemperature += ((92 + car.gas * 14 - v * 0.04) - car.waterTemperature) * dt * 0.05;
      car.oilTemperature += ((100 + car.gas * 16 - v * 0.03) - car.oilTemperature) * dt * 0.04;
      car.oilPressure = 2 + car.rpm / 2500;
      car.turboBoost = 1 + car.gas * 2.8;
    }

    stepStartup(dt) {
      const { car } = this.state;
      this.startupT += dt;
      const t = this.startupT;
      car.speedKmh = 0; car.speedMs = 0; this.v = 0;
      car.steer = 0; car.acceleration = { x: 0, y: 0, z: 0 }; car.isEngineLimiterOn = false;
      car.drsAvailable = false; car.drsActive = false;
      if (t < STARTUP_IDLE) { // idling in neutral, foot on the brake
        car.gear = 0; car.gas = 0; car.brake = 0.3; car.clutch = 1;
        car.rpm = RPM_IDLE + Math.sin(this.clock * 9) * 40;
      } else if (t < STARTUP_IDLE + LAUNCH_HOLD) { // clutch in, first gear, revs up to the last three LEDs
        car.gear = 1; car.gas = 0.6; car.brake = 0; car.clutch = 0;
        this.launchRevs(dt);
      } else { // pull away; stepDriving ramps the throttle up over GENTLE_TIME
        this.mode = this.resumeMode || 'race';
        this.gentleT = 0;
        this.clutchSlip = 0.8; // s: revs come down gradually as the clutch bites
      }
    }

    // Driver brings the revs up to the launch window and holds them there steadily.
    launchRevs(dt) {
      const car = this.state.car;
      const d = LAUNCH_RPM - car.rpm;
      car.rpm = Math.abs(d) <= LAUNCH_RAMP * dt ? LAUNCH_RPM + Math.sin(this.clock * 11) * 8 : car.rpm + Math.sign(d) * LAUNCH_RAMP * dt;
    }

    // 0.3..1 while pulling away after an engine start, otherwise 1.
    gentleFactor() {
      return this.gentleT === undefined ? 1 : 0.3 + 0.7 * Math.min(1, this.gentleT / GENTLE_TIME);
    }

    stepGrid(dt) {
      const { car } = this.state;
      this.gridTimer += dt;
      car.speedKmh = 0; car.speedMs = 0;
      car.gear = 1;
      car.clutch = 0; // clutch held on the grid: VRC shows its launch LEDs
      car.brake = 0;
      car.steer = 0;
      car.acceleration = { x: 0, y: 0, z: 0 };
      // Driver holds the launch revs while waiting for lights out.
      car.gas = 0.7;
      this.launchRevs(dt);
      car.isEngineLimiterOn = false;
      car.drsAvailable = false; car.drsActive = false;
      car.lapTimeMs = 0;
      this.v = 0;
      this.dist = 0;
      this.lapTime = 0;
      if (this.gridTimer > 6) { // lights out
        this.mode = 'race';
        this.state.sim.raceFlagType = 0;
      }
    }

    stepSweep(dt) {
      const { car } = this.state;
      this.sweepT = (this.sweepT + dt) % 3.2;
      const k = Math.min(1, this.sweepT / 2.8);
      car.rpm = RPM_IDLE + (car.rpmLimiter - RPM_IDLE) * k;
      car.isEngineLimiterOn = k >= 1;
      car.gas = k < 1 ? 1 : 0.5;
      car.brake = 0;
      car.clutch = 1;
      car.speedKmh = (car.rpm / RPM_LIMITER) * GEAR_TOP_KMH[Math.max(1, car.gear)];
      car.drsAvailable = false;
      car.drsActive = false;
    }

    deriveCan() {
      const { car, can } = this.state;
      can.bus.isPitLimiterActive = car.manualPitsSpeedLimiterEnabled;
      can.bus.isHybridOvertakeActive = car.kersButtonPressed;
      if (!this.manual.has('can.bus.frontBias')) can.bus.frontBias = car.brakeBias;
      if (!this.manual.has('can.bus.engineBrakeSetting')) can.bus.engineBrakeSetting = car.currentEngineBrakeSetting;
    }
  }

  // ---------------------------------------------------------------------------
  // Scenarios: one click sets several fields at once. Values stay manual until
  // the scenario is stopped.
  // ---------------------------------------------------------------------------
  const SCENARIOS = [
    {
      id: 'start', name: 'Race start', desc: 'On the grid, hold the revs, lights out after 6 s',
      apply(m) { m.mode = 'grid'; m.gridTimer = 0; m.state.car.rpm = RPM_IDLE; m.state.sim.raceFlagType = 1; m.state.car.lapCount = 0; },
      clear(m) { if (m.mode === 'grid') m.mode = 'race'; m.state.sim.raceFlagType = 0; },
    },
    {
      id: 'sweep', name: 'Shift light sweep', desc: 'RPM 4000 → limiter in a loop (in 4th gear)',
      apply(m) { m.mode = 'sweep'; m.sweepT = 0; m.state.car.gear = 4; },
      clear(m) { m.mode = 'race'; },
    },
    {
      id: 'drs', name: 'DRS zone', desc: 'Jumps to the start of DRS zone 2',
      apply(m) { m.mode = 'race'; m.dist = DRS_ZONES[1][0] - 150; m.v = 62; },
    },
    {
      id: 'pit', name: 'Pit lane + limiter', desc: 'In the pit lane with the limiter on (80 km/h)',
      apply(m) { m.mode = 'pit'; },
      clear(m) { m.mode = 'race'; },
    },
    {
      // In the VRC car overtake is a hold button (KERS_OVERTAKE), separate from STRAT.
      id: 'overtake', name: 'Overtake', desc: 'Overtake button held (STRAT unchanged), low battery',
      apply(m) {
        m.ersMJ = 0.7;
        m.setManual('car.kersButtonPressed', true);
        m.setManual('can.bus.isHybridOvertakeActive', true);
        m.dist = DRS_ZONES[1][0] - 150; m.v = 62;
      },
      clear(m) {
        m.clearManual('car.kersButtonPressed'); m.clearManual('can.bus.isHybridOvertakeActive');
        m.state.car.kersButtonPressed = false; m.state.can.bus.isHybridOvertakeActive = false;
      },
    },
    {
      id: 'lastlap', name: 'Last lap, low fuel', desc: 'White flag, 1.8 l fuel',
      apply(m) { m.state.car.fuel = 1.8; m.setManual('sim.raceFlagType', 14); },
      clear(m) { m.clearManual('sim.raceFlagType'); m.state.sim.raceFlagType = 0; },
    },
    {
      id: 'coldtyres', name: 'Cold tyres after pit stop', desc: 'New tyres at 45 °C, low pressure',
      apply(m) {
        for (const w of m.state.wheels) {
          w.tyreCoreTemperature = 45; w.tyreInsideTemperature = 47; w.tyreMiddleTemperature = 45;
          w.tyreOutsideTemperature = 44; w.tyreWear = 0;
        }
      },
    },
    {
      id: 'hotbrakes', name: 'Overheated brakes', desc: 'Front discs at 1150 °C, rear at 1000 °C',
      apply(m) {
        m.setManual('wheels.0.discTemperature', 1150); m.setManual('wheels.1.discTemperature', 1150);
        m.setManual('wheels.2.discTemperature', 1000); m.setManual('wheels.3.discTemperature', 1000);
      },
      clear(m) { for (let i = 0; i < 4; i++) m.clearManual(`wheels.${i}.discTemperature`); },
    },
  ];

  function startScenario(m, id) {
    stopScenario(m);
    const sc = SCENARIOS.find((s) => s.id === id);
    if (!sc) return;
    m.scenario = sc;
    sc.apply && sc.apply(m);
  }
  function stopScenario(m) {
    if (m.scenario && m.scenario.clear) m.scenario.clear(m);
    m.scenario = null;
  }

  window.Sim = { Model, CAN_SCHEMA, SCENARIOS, startScenario, stopScenario, ERS_MODE_NAMES, DRS_ZONES };
})();
