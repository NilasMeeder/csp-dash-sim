// bridge.js: runs the dashboard script in Fengari and connects it to the canvas.
//
// One LuaRuntime = one fresh Lua state (shim + dashboard). Hot reload builds a new
// runtime; the old one keeps drawing until the new one has loaded without errors.

(function () {
  'use strict';
  const { lua, lauxlib, lualib, to_luastring } = fengari;

  // How a field type from sdk/lib.lua is pushed into Lua.
  function fieldKind(type) {
    if (type === 'integer') return 'int';
    if (type === 'number') return 'num';
    if (type === 'boolean') return 'bool';
    if (type === 'vec3' || type === 'vec2') return type;
    if (/^ac\.[A-Za-z]+$/.test(type) && !/^ac\.State/.test(type) && type !== 'ac.DrivableCamera') return 'int'; // enums
    return null;
  }

  function makePlan(fields) {
    return fields
      .map((f) => ({ name: f.name, key: to_luastring(f.name), kind: fieldKind(f.type) }))
      .filter((f) => f.kind);
  }

  const KEY_X = to_luastring('x'), KEY_Y = to_luastring('y'), KEY_Z = to_luastring('z');

  // Writes obj's values into the Lua table on top of the stack.
  function pushFields(L, plan, obj) {
    for (const f of plan) {
      const v = obj[f.name];
      if (v === undefined || v === null) continue;
      switch (f.kind) {
        case 'int': lua.lua_pushinteger(L, Math.trunc(Number(v)) | 0); break;
        case 'num': lua.lua_pushnumber(L, Number(v)); break;
        case 'bool': lua.lua_pushboolean(L, !!v); break;
        case 'vec3': case 'vec2':
          lua.lua_getfield(L, -1, f.key);
          if (lua.lua_type(L, -1) === lua.LUA_TTABLE) {
            lua.lua_pushnumber(L, +v.x || 0); lua.lua_setfield(L, -2, KEY_X);
            lua.lua_pushnumber(L, +v.y || 0); lua.lua_setfield(L, -2, KEY_Y);
            if (f.kind === 'vec3') { lua.lua_pushnumber(L, +v.z || 0); lua.lua_setfield(L, -2, KEY_Z); }
          }
          lua.lua_pop(L, 1);
          continue;
      }
      lua.lua_setfield(L, -2, f.key);
    }
  }

  function readArg(L, i) {
    switch (lua.lua_type(L, i)) {
      case lua.LUA_TNUMBER: return lua.lua_tonumber(L, i);
      case lua.LUA_TSTRING: return lua.lua_tojsstring(L, i);
      case lua.LUA_TBOOLEAN: return lua.lua_toboolean(L, i);
      default: return null;
    }
  }

  function tracebackHandler(L) {
    let msg;
    if (lua.lua_type(L, 1) === lua.LUA_TSTRING) msg = lua.lua_tostring(L, 1);
    else msg = lauxlib.luaL_tolstring(L, 1);
    lauxlib.luaL_traceback(L, L, msg, 1);
    return 1;
  }

  // Splits "dash/x.lua:12: message\nstack traceback:..." into parts for the overlay.
  function parseError(text) {
    const [first, ...rest] = String(text).split('\n');
    const m = first.match(/^([^:\s]+\.lua):(\d+):\s*(.*)$/);
    return {
      file: m ? m[1] : null,
      line: m ? Number(m[2]) : null,
      message: m ? m[3] : first,
      traceback: rest.join('\n').replace(/^stack traceback:\n?/, ''),
      raw: String(text),
    };
  }

  class LuaRuntime {
    constructor({ bundle, schema, canSchema, width, height, hooks }) {
      this.bundle = bundle;
      this.width = width;
      this.height = height;
      this.hooks = hooks; // { log(kind, text), debug(key, value), clock() }
      this.plans = {
        car: makePlan(schema.car),
        wheel: makePlan(schema.wheel),
        sim: makePlan(schema.sim),
        canBus: makePlan(canSchema.bus),
        canStream: makePlan(canSchema.stream),
      };
      this.schema = schema;
      this.frame = null;
    }

    // Loads shim + dashboard. Throws a parsed error on failure.
    start() {
      const L = (this.L = lauxlib.luaL_newstate());
      lualib.luaL_openlibs(L);
      const reg = (name, fn) => { lua.lua_pushjsfunction(L, fn); lua.lua_setglobal(L, to_luastring(name)); };

      reg('__js_draw', (L) => {
        const n = lua.lua_gettop(L);
        const c = new Array(n);
        for (let i = 1; i <= n; i++) c[i - 1] = readArg(L, i);
        if (this.frame) this.frame.push(c);
        return 0;
      });
      reg('__js_measure', (L) => {
        const [w, h] = Render.measure(lua.lua_tojsstring(L, 1), lua.lua_tonumber(L, 2), lua.lua_tojsstring(L, 3));
        lua.lua_pushnumber(L, w);
        lua.lua_pushnumber(L, h);
        return 2;
      });
      reg('__js_imageSize', (L) => {
        const [w, h] = Render.imageSize(lua.lua_tojsstring(L, 1));
        lua.lua_pushnumber(L, w);
        lua.lua_pushnumber(L, h);
        return 2;
      });
      reg('__js_log', (L) => { this.hooks.log(lua.lua_tojsstring(L, 1), lua.lua_tojsstring(L, 2)); return 0; });
      reg('__js_debug', (L) => { this.hooks.debug(lua.lua_tojsstring(L, 1), lua.lua_tojsstring(L, 2)); return 0; });
      reg('__js_clock', (L) => { lua.lua_pushnumber(L, this.hooks.clock()); return 1; });

      lua.lua_pushinteger(L, this.width); lua.lua_setglobal(L, to_luastring('__DISPLAY_W'));
      lua.lua_pushinteger(L, this.height); lua.lua_setglobal(L, to_luastring('__DISPLAY_H'));

      lua.lua_createtable(L, 0, Object.keys(this.bundle.files).length);
      for (const [path, src] of Object.entries(this.bundle.files)) {
        lua.lua_pushstring(L, to_luastring(src));
        lua.lua_setfield(L, -2, to_luastring(path));
      }
      lua.lua_setglobal(L, to_luastring('__bundle'));

      // Data files (.lut/.2dlut) for ac.DataLUT*.load().
      const data = this.bundle.data || {};
      lua.lua_createtable(L, 0, Object.keys(data).length);
      for (const [path, src] of Object.entries(data)) {
        lua.lua_pushstring(L, to_luastring(src));
        lua.lua_setfield(L, -2, to_luastring(path));
      }
      lua.lua_setglobal(L, to_luastring('__bundle_data'));

      // Known field names per class, for helpful warnings.
      lua.lua_createtable(L, 0, 3);
      for (const cls of ['car', 'wheel', 'sim']) {
        lua.lua_createtable(L, 0, this.schema[cls].length);
        for (const f of this.schema[cls]) { lua.lua_pushboolean(L, true); lua.lua_setfield(L, -2, to_luastring(f.name)); }
        lua.lua_setfield(L, -2, to_luastring(cls));
      }
      lua.lua_setglobal(L, to_luastring('__preview_known'));

      this.run(this.bundle.shim, '@preview/csp-shim.lua');

      // Vector fields need a vec3/vec2 object to write into; VRC's can module data lives in __preview_can.
      const vecInit = [];
      for (const [cls, target] of [['car', 'car'], ['sim', 'sim']]) {
        for (const f of this.plans[cls]) {
          if (f.kind === 'vec3' || f.kind === 'vec2') vecInit.push(`rawset(${target}, '${f.name}', ${f.kind}())`);
        }
      }
      for (const f of this.plans.wheel) {
        if (f.kind === 'vec3' || f.kind === 'vec2') {
          vecInit.push(`for i = 0, 3 do rawset(car.wheels[i], '${f.name}', ${f.kind}()) end`);
        }
      }
      vecInit.push('__preview_can = { bus = {}, stream = {} }');
      this.run(vecInit.join('\n'), '=preview-init');

      this.call('__preview_load', (L) => { lua.lua_pushstring(L, to_luastring(this.bundle.entry)); return 1; });
    }

    run(code, chunkname) {
      const L = this.L;
      lua.lua_pushjsfunction(L, tracebackHandler);
      const h = lua.lua_gettop(L);
      if (lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring(chunkname)) !== lua.LUA_OK) {
        const err = lua.lua_tojsstring(L, -1);
        lua.lua_settop(L, h - 1);
        throw parseError(err);
      }
      const status = lua.lua_pcall(L, 0, 0, h);
      if (status !== lua.LUA_OK) {
        const err = lua.lua_tojsstring(L, -1);
        lua.lua_settop(L, h - 1);
        throw parseError(err);
      }
      lua.lua_settop(L, h - 1);
    }

    call(globalName, pushArgs) {
      const L = this.L;
      lua.lua_pushjsfunction(L, tracebackHandler);
      const h = lua.lua_gettop(L);
      lua.lua_getglobal(L, to_luastring(globalName));
      const nargs = pushArgs ? pushArgs(L) : 0;
      const status = lua.lua_pcall(L, nargs, 0, h);
      if (status !== lua.LUA_OK) {
        const err = lua.lua_tojsstring(L, -1);
        lua.lua_settop(L, h - 1);
        throw parseError(err);
      }
      lua.lua_settop(L, h - 1);
    }

    pushState(state) {
      const L = this.L;
      lua.lua_getglobal(L, to_luastring('car'));
      pushFields(L, this.plans.car, state.car);
      lua.lua_getfield(L, -1, to_luastring('wheels'));
      for (let i = 0; i < 4; i++) {
        lua.lua_rawgeti(L, -1, i);
        pushFields(L, this.plans.wheel, state.wheels[i]);
        lua.lua_pop(L, 1);
      }
      lua.lua_pop(L, 2);

      lua.lua_getglobal(L, to_luastring('sim'));
      pushFields(L, this.plans.sim, state.sim);
      lua.lua_pop(L, 1);

      lua.lua_getglobal(L, to_luastring('__preview_can'));
      lua.lua_getfield(L, -1, to_luastring('bus'));
      pushFields(L, this.plans.canBus, state.can.bus);
      lua.lua_pop(L, 1);
      lua.lua_getfield(L, -1, to_luastring('stream'));
      pushFields(L, this.plans.canStream, state.can.stream);
      lua.lua_pop(L, 2);
    }

    // Runs one update. Returns the finished Render.Frame, or throws a parsed error.
    step(dt, state) {
      this.pushState(state);
      this.frame = new Render.Frame();
      try {
        this.call('__preview_frame', (L) => { lua.lua_pushnumber(L, dt); return 1; });
        return this.frame;
      } finally {
        this.frame = null;
      }
    }
  }

  window.Bridge = { LuaRuntime, parseError };
})();
