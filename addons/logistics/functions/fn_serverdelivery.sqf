/* Author: AAS Team
   Description: Master Route for Slingload Deliveries.
   Dynamically spawns the correct heavy helicopter, attaches the payload via setSlingLoad,
   drops it at the LZ natively, and handles manual "Containerized" repositioning and unpacking.
   Includes STRICT autonomous override, Dynamic Terrain Snap, CTRL+Z Repack, Hold-Actions, Anti-Jank Physics, and Script/Inventory Injection.
   NOW INCLUDES: "Force Rope" toggle for bypassing config restrictions with custom Hover & Slice AI logic.
*/

params ["_caller", "_lzPos", "_execId"];
if (!isServer) exitWith {};

// ==========================================
// --- 1. CORE SETUP & SECURITY ---
// ==========================================
private _playerSide = side group _caller;
if (_playerSide == sideLogic || _playerSide == civilian) then { _playerSide = west; };

private _isComposition = (_execId select [0, 4] == "Comp");

private _varName = format ["AAS_LOG_%1_Name", _execId];
private _varClass = format ["AAS_LOG_%1_Code", _execId]; 
if (!_isComposition) then { _varClass = format ["AAS_LOG_%1_Class", _execId]; };

private _varMult = format ["AAS_LOG_%1_Mult", _execId];
private _supportName = missionNamespace getVariable [_varName, "Delivery"];

// ==========================================
// --- 2. ECONOMY & COOLDOWN CHECK ---
// ==========================================
private _econPreset = missionNamespace getVariable ["AAS_Econ_Preset_Core", 0];
private _baseCost = switch (_econPreset) do {
    case 0: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_Custom", "0"]) };
    case 1: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_Antistasi", "1000"]) };
    case 3: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_Overthrow", "2500"]) };
    case 4: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_Warlords", "300"]) };
    case 5: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_DUWS", "15"]) };
    case 6: { parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_Antistasi", "1000"]) };
    default { 0 };
};

private _cost = 0;
if (_econPreset == 2) then {
    _cost = [
        parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_KPLib_S", "150"]),
        parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_KPLib_A", "0"]),
        parseNumber (missionNamespace getVariable ["AAS_LOG_Cost_Base_KPLib_F", "150"])
    ];
} else {
    private _mult = parseNumber (missionNamespace getVariable [_varMult, "1.0"]);
    _cost = round (_baseCost * _mult);
};

// --- DUAL COOLDOWN VALIDATION ---
private _globalLastUse = missionNamespace getVariable ["AAS_LOG_LastUse_Delivery_Global", -99999];
if (serverTime < (_globalLastUse + 60)) exitWith {
    private _timeLeft = 1 max round (((_globalLastUse + 60) - serverTime));
    (format ["HQ: Heavy lift airspace is crowded. Available in %1 seconds.", _timeLeft]) remoteExec ["systemChat", _caller];
};

private _itemCdTime = parseNumber (missionNamespace getVariable ["AAS_LOG_Cooldown_Delivery", "600"]);
private _itemLastUseVar = format ["AAS_LOG_LastUse_Delivery_%1", _execId];
private _itemLastUse = missionNamespace getVariable [_itemLastUseVar, -99999];

if (serverTime < (_itemLastUse + _itemCdTime)) exitWith {
    private _timeLeft = 1 max round (((_itemLastUse + _itemCdTime) - serverTime) / 60);
    (format ["HQ: %1 is currently unavailable. Ready in %2 mins.", _supportName, _timeLeft]) remoteExec ["systemChat", _caller];
};

private _econCode = missionNamespace getVariable ["AAS_LOG_Econ_Code", ""];
private _econPass = [_caller, _cost, _econPreset, _econCode] call aas_core_fnc_setEconomyPreset;
if (isNil "_econPass" || {!_econPass}) exitWith {};

missionNamespace setVariable ["AAS_LOG_LastUse_Delivery_Global", serverTime, true];
missionNamespace setVariable [_itemLastUseVar, serverTime, true];

// --- HQ APPROVAL COMMS (3 Second Delay) ---
[_caller] spawn {
    params ["_caller"];
    sleep 3;
    private _hqComms = [
        ["log_hq1", "HQ: Copy that, logistics mission approved. ETA 2 minutes, be ready."],
        ["log_hq2", "HQ: Roger that, we are sending the delivery to your position."],
        ["log_hq3", "HQ: Logistic delivery has been dispatched. Clear the area, over."]
    ];
    private _selected = selectRandom _hqComms;
    (_selected select 1) remoteExec ["systemChat", _caller];
    [_selected select 0] remoteExec ["playSound", _caller];
};

// ==========================================
// --- 3. SMART PARSER HELPER ---
// ==========================================
private _fnc_parseClass = {
    params ["_rawSetting"];
    private _class = _rawSetting;
    private _loadout = false;
    private _trimmed = (_rawSetting splitString " ") joinString "";
    
    if ((_trimmed select [0,1] == "[") && {(_trimmed select [(count _trimmed) - 1, 1] == "]")}) then {
        private _parsed = call compile _rawSetting;
        if (_parsed isEqualType []) then {
            _class = _parsed select 0;
            if (count _parsed > 1) then { _loadout = _parsed select 1; };
        };
    };
    [_class, _loadout]
};

// ==========================================
// --- 4. PARSE SETTINGS & SPAWN LOGIC ---
// ==========================================
private _isContainerized = false;
private _rawHeliClass = "";
private _targetClass = "";
private _targetLoadout = false;

// --- DYNAMIC TOGGLE READ ---
private _forceRope = missionNamespace getVariable [format ["AAS_LOG_%1_ForceRope", _execId], false];

if (_isComposition) then {
    _isContainerized = true;
    _rawHeliClass = missionNamespace getVariable ["AAS_LOG_Comp_Heli", "B_Heli_Transport_03_F"];
    _targetClass = missionNamespace getVariable [_varClass, ""]; 
} else {
    _isContainerized = missionNamespace getVariable [format ["AAS_LOG_%1_Container", _execId], false];
    _rawHeliClass = missionNamespace getVariable [format ["AAS_LOG_%1_Heli", _execId], "B_Heli_Transport_03_F"];
    
    private _rawPayloadClass = missionNamespace getVariable [_varClass, ""];
    private _payloadParsed = [_rawPayloadClass] call _fnc_parseClass;
    _targetClass = _payloadParsed select 0;
    _targetLoadout = _payloadParsed select 1;
};

private _heliParsed = [_rawHeliClass] call _fnc_parseClass;
private _heliClass = _heliParsed select 0;

private _helipad = createVehicle ["Land_HelipadEmpty_F", _lzPos, [], 0, "NONE"];

private _spawnDist = 1750; 
private _spawnPos = _lzPos getPos [_spawnDist, random 360];
_spawnPos set [2, 100]; 

// 4a. Spawn Helicopter
private _heliData = [_spawnPos, _spawnPos getDir _lzPos, _heliClass, _playerSide] call BIS_fnc_spawnVehicle;
private _heli = _heliData select 0;
private _heliGroup = _heliData select 2;

_heli allowDamage false;
_heli setCaptive true; 
_heliGroup setBehaviour "CARELESS";
_heliGroup setCombatMode "BLUE";
_heliGroup setSpeedMode "FULL";

{ 
    _x allowDamage false;
    _x setCaptive true; 
    _x addRating 100000; 
    [_x] joinSilent _heliGroup; 
    
    _x disableAI "AUTOTARGET";
    _x disableAI "TARGET";
    _x disableAI "SUPPRESSION";
    _x disableAI "AUTOCOMBAT";
} forEach crew _heli;

_heli flyInHeight 70; 

// 4b. Spawn Payload & Slingload it immediately
private _payloadObj = objNull;

if (_isContainerized) then {
    _payloadObj = createVehicle ["B_Slingload_01_Cargo_F", [_spawnPos select 0, _spawnPos select 1, 80], [], 0, "NONE"];
    clearItemCargoGlobal _payloadObj; clearWeaponCargoGlobal _payloadObj; clearMagazineCargoGlobal _payloadObj; clearBackpackCargoGlobal _payloadObj;
    _payloadObj setMass 500;
} else {
    _payloadObj = createVehicle [_targetClass, [_spawnPos select 0, _spawnPos select 1, 80], [], 0, "NONE"];
    if (_targetLoadout isNotEqualTo false) then {
        if (_targetLoadout isEqualType []) then { _payloadObj setUnitLoadout _targetLoadout; };
        if (_targetLoadout isEqualType "") then { _payloadObj call compile _targetLoadout; };
    };
    
    if (getNumber (configFile >> "CfgVehicles" >> typeOf _payloadObj >> "isUav") == 1) then {
        createVehicleCrew _payloadObj;
        private _turretGroup = group (crew _payloadObj select 0);
        private _newGroup = createGroup _playerSide;
        (crew _payloadObj) joinSilent _newGroup;
        deleteGroup _turretGroup;
    };
    
    // FIX: Save original mass before altering it for slingloading
    _payloadObj setVariable ["AAS_Orig_Mass", getMass _payloadObj, true];
    _payloadObj setMass 500;
};

_payloadObj allowDamage false;

// --- DYNAMIC HOOKUP (VANILLA OR FORCE ROPES) ---
if (_forceRope) then {
    private _ropeLength = 15;
    ropeCreate [_heli, [0, 0, -2], _payloadObj, [1.5, 1.5, 0], _ropeLength];
    ropeCreate [_heli, [0, 0, -2], _payloadObj, [-1.5, 1.5, 0], _ropeLength];
    ropeCreate [_heli, [0, 0, -2], _payloadObj, [1.5, -1.5, 0], _ropeLength];
    ropeCreate [_heli, [0, 0, -2], _payloadObj, [-1.5, -1.5, 0], _ropeLength];
    
    // TRANSIT FIX: Cap transit speed so the custom pendulum doesn't flip the heli
    _heli limitSpeed 110; 
} else {
    _heli setSlingLoad _payloadObj;
};

// 4c. Waypoints - THE BAIT
private _wpMove = _heliGroup addWaypoint [_lzPos, 0];
_wpMove setWaypointType "MOVE";
_wpMove setWaypointSpeed "FULL";

// ==========================================
// --- 5. EXECUTION THREAD ---
// ==========================================
// FIX: Added _forceRope to passed parameters
[_heli, _heliGroup, _payloadObj, _isContainerized, _forceRope, _targetClass, _targetLoadout, _helipad, _lzPos, _playerSide, _execId, _caller] spawn {
    params ["_heli", "_heliGroup", "_payloadObj", "_isContainerized", "_forceRope", "_targetClass", "_targetLoadout", "_helipad", "_lzPos", "_playerSide", "_execId", "_caller"];
    
    // --- APPROACH COMMS (Trigger at 400m) ---
    waitUntil { sleep 0.5; (_heli distance2D _lzPos < 400) || !alive _heli };
    
    if (alive _heli) then {
        private _pilotComms = [
            ["log_delivery1", "PILOT: KILO 1 approaching drop-off zone. Keep clear."],
            ["log_delivery2", "PILOT: Drop-off zone on sight. Approaching."],
            ["log_delivery3", "PILOT: This is GOLF 3, approaching drop zone. Please keep clear."],
            ["log_delivery4", "PILOT: LIMA 6 on approach to drop the cargo."],
            ["log_delivery5", "PILOT: Chopper to Ground Team, we are bringing your equipment to the drop-off zone."]
        ];
        private _selected = selectRandom _pilotComms;
        (_selected select 1) remoteExec ["systemChat", _caller];
        [_selected select 0] remoteExec ["playSound", _caller];
    };

    // --- THE SWITCH (Drop Cargo Logic) ---
    private _despawnPos = _lzPos getPos [3000, random 360];
    if (_forceRope) then {
        
        // 1. APPROACH PHASE: AI waypoints bring it close
        waitUntil { sleep 0.5; (_heli distance2D _lzPos < 150) || !alive _heli };
        
        if (alive _heli) then {
            while {(count (waypoints _heliGroup)) > 0} do { deleteWaypoint ((waypoints _heliGroup) select 0); };
            
            // 2. GUIDED GLIDE: Smooth velocity control replaces doMove
            // Speed is proportional to distance — fast when far, crawling when close
            _heli flyInHeight 32;
            _heli forceSpeed 1000; // Remove AI speed cap so it doesn't fight our velocity
            
            private _glideTimeout = serverTime + 60;
            while { alive _heli && (_heli distance2D _lzPos > 5) && serverTime < _glideTimeout } do {
                private _dist = _heli distance2D _lzPos;
                private _dir = _heli getDir _lzPos;
                
                // Smooth speed curve: 10 m/s at 150m, ~2 m/s at 10m, floor of 1.5 m/s
                private _speed = ((_dist / 5) min 8) max 3.5;
                
                private _vx = (sin _dir) * _speed;
                private _vy = (cos _dir) * _speed;
                
                // Altitude correction — gently steer toward 45m AGL above the LZ
                private _targetAlt = (getTerrainHeightASL _lzPos) + 32;
                private _currentAlt = (getPosASL _heli) select 2;
                private _vz = ((_targetAlt - _currentAlt) * 0.3) max -2 min 2;
                
                _heli setVelocity [_vx, _vy, _vz];
                sleep 0.1;
            };
            
            if (alive _heli) then {
                // 3. DECELERATION: Ease to a stop over 2 seconds instead of instant freeze
                private _vel = velocity _heli;
                for "_i" from 1 to 20 do {
                    private _factor = 1 - (_i / 20);
                    _heli setVelocity [
                        (_vel select 0) * _factor,
                        (_vel select 1) * _factor,
                        ((_vel select 2) * _factor) max -0.3
                    ];
                    sleep 0.1;
                };
                
                // 4. HOVER LOCK: Now the AI takes over for a clean stationary hover
                _heli setVelocity [0, 0, 0];
                doStop _heli;
                _heli forceSpeed 0;
                
                // Let the payload pendulum settle
                sleep 4;
                
                // 5. THE WINCH: Unspool ropes
                { ropeUnwind [_x, 5, 150] } forEach ropes _heli;
                
                // Wait until payload touches ground
                private _dropTimeout = serverTime + 40;
                waitUntil { sleep 0.25; isTouchingGround _payloadObj || ((getPos _payloadObj) select 2 < 1) || serverTime > _dropTimeout || !alive _heli };
                
                // 6. Slice the custom ropes
                { ropeDestroy _x } forEach ropes _heli;
                
                // 7. EVACUATION: Reset and move away
                _heli forceSpeed 1000;
                _heli flyInHeight 150;
                _heli doMove _despawnPos;
                
                private _wpLeave = _heliGroup addWaypoint [_despawnPos, 0];
                _wpLeave setWaypointType "MOVE";
                _wpLeave setWaypointSpeed "FULL";
            };
        };
        
    } else {
        // VANILLA DROP MANEUVER (UNHOOK)
        waitUntil { sleep 0.25; (_heli distance2D _lzPos < 120) || !alive _heli };
        
        if (alive _heli) then {
            while {(count (waypoints _heliGroup)) > 0} do { deleteWaypoint ((waypoints _heliGroup) select 0); };
            
            private _wpDrop = _heliGroup addWaypoint [_lzPos, 0];
            _wpDrop setWaypointType "UNHOOK";
            _wpDrop setWaypointSpeed "FULL";
            
            private _wpLeave = _heliGroup addWaypoint [_despawnPos, 0];
            _wpLeave setWaypointType "MOVE";
            _wpLeave setWaypointSpeed "FULL";
        };
    };

    // --- DETACHMENT VERIFICATION ---
    if (_forceRope) then {
        waitUntil { sleep 1; (count ropes _heli == 0) || !alive _heli };
    } else {
        waitUntil { sleep 1; (isNull (getSlingLoad _heli)) || !alive _heli };
    };
    
    _heli flyInHeight 150;

    if (alive _payloadObj) then {
        waitUntil { sleep 1; (isTouchingGround _payloadObj) || ((getPos _payloadObj) select 2 < 2) };
    };

    // =========================================================================
    // --- CONTAINER INITIALIZATION, UNPACK, & REPACK ENGINES ---
    // =========================================================================
    if (_isContainerized && alive _payloadObj) then {
        
        // --- 1. ACTION INJECTOR ENGINE ---
        if (isNil "aas_logistics_fnc_InitContainerActions") then {
            missionNamespace setVariable ["aas_logistics_fnc_InitContainerActions", {
                params ["_container", "_tClass", "_tLoadout", "_pSide", "_execId"];
                _container setVariable ["AAS_Is_Moving", false, true];

                // 1. Instant Reposition Action
                [
                    _container,
                    [
                        "<t color='#FFFF00'>[ Reposition Container ]</t>", 
                        {
                            params ["_target", "_caller", "_actionId", "_arguments"];
                            if (_target getVariable ["AAS_Is_Moving", false]) exitWith {};
                            
                            _target setVariable ["AAS_Is_Moving", true, true];
                            _target attachTo [_caller, [0, 4.5, 2.5]]; 
                            
                            _caller addAction ["<t color='#FF0000'>[ Drop Container ]</t>", {
                                params ["_unit", "_caller2", "_id", "_targetBox"];
                                detach _targetBox;
                                _targetBox setVariable ["AAS_Is_Moving", false, true];
                                
                                private _pos = getPosATL _targetBox;
                                _targetBox setPosATL [_pos select 0, _pos select 1, 0];
                                _caller2 removeAction _id;
                            }, _target, 6, true, true, "", "true"];
                        }, 
                        nil, 1.5, true, true, "", 
                        "!(_target getVariable ['AAS_Is_Moving', false]) && (_this distance _target < 5)"
                    ]
                ] remoteExec ["addAction", 0, _container];

                // 2. Hold-to-Unpack Action Wheel
                [
                    _container, 
                    "<t color='#00FF00'>[ Hold to Unpack ]</t>", 
                    "\a3\ui_f\data\IGUI\Cfg\holdactions\holdAction_unbind_ca.paa", 
                    "\a3\ui_f\data\IGUI\Cfg\holdactions\holdAction_unbind_ca.paa", 
                    "!(_target getVariable ['AAS_Is_Moving', false]) && (_this distance _target < 5)", 
                    "true", 
                    {}, 
                    {}, 
                    {
                        params ["_target", "_caller", "_actionId", "_arguments"];
                        _arguments params ["_tClassStr", "_tLoadStr", "_plSide", "_eId"];
                        
                        [_target] remoteExec ["removeAllActions", 0, _target];
                        [_target, _tClassStr, _tLoadStr, _plSide, _eId] remoteExec ["aas_logistics_fnc_UnpackContainer", 2];
                    }, 
                    {}, 
                    [_tClass, _tLoadout, _pSide, _execId],
                    5, 
                    1.5, 
                    true, 
                    false
                ] remoteExec ["BIS_fnc_holdActionAdd", 0, _container];
            }, true];
        };

        // --- 2. UNPACK ENGINE ---
        if (isNil "aas_logistics_fnc_UnpackContainer") then {
            missionNamespace setVariable ["aas_logistics_fnc_UnpackContainer", {
                params ["_container", "_targetClassStr", "_targetLoadout", "_playerSide", ["_execId", ""]];
                if (!isServer) exitWith {};
                
                private _origPos = getPosATL _container;
                private _origDir = getDir _container;
                deleteVehicle _container; 
                
                // > COMPOSITION UNPACK (ADVANCED MULTI-TIER ENGINE)
                if (_targetClassStr select [0, 2] == "[[") then {
                    private _compArray = call compile _targetClassStr;
                    
                    private _anchorPos = [_origPos select 0, _origPos select 1, 0];
                    private _anchor = createVehicle ["Land_HelipadEmpty_F", _anchorPos, [], 0, "CAN_COLLIDE"];
                    _anchor setDir _origDir;
                    
                    private _spawnedObjs = [];
                    private _masterObj = objNull;
                    
                    {
                        // Safely reads arrays up to 8 parameters
                        _x params ["_className", "_relPos", "_relDir", ["_parentIdx", -1], ["_isSimple", false], ["_textures", []], ["_initCode", ""], ["_inventory", []]];
                        private _isAdvanced = (count _x > 3);
                        private _obj = objNull;
                        
                        // FAILSAFE: Internal Overrides
                        if (_initCode != "" || _inventory isNotEqualTo []) then { _isSimple = false; };
                        
                        // 1. Spawning Method (Simple vs Simulated)
                        if (_isSimple) then {
                            _obj = createSimpleObject [_className, [0,0,0]];
                        } else {
                            _obj = createVehicle [_className, [0,0,100], [], 0, "CAN_COLLIDE"];
                            _obj enableSimulationGlobal false; 
                            _obj allowDamage false;
                        };
                        
                        // 2. Texture Application
                        if (count _textures > 0) then {
                            { if (_x != "") then { _obj setObjectTextureGlobal [_forEachIndex, _x]; }; } forEach _textures;
                        };

                        // 2.5 INTERNAL Script & Inventory Injection
                        if (_initCode != "") then {
                            if ((_initCode select [0, 1]) == '"' && (_initCode select [count _initCode - 1, 1]) == '"') then {
                                _initCode = _initCode select [1, (count _initCode) - 2];
                            };
                            [_obj, _initCode] spawn {
                                params ["_o", "_code"];
                                sleep 2;
                                [_o] call compile _code;
                            };
                        };
                        
                        if (_inventory isNotEqualTo []) then {
                            clearWeaponCargoGlobal _obj; clearMagazineCargoGlobal _obj; clearItemCargoGlobal _obj; clearBackpackCargoGlobal _obj;
                            _inventory params ["_weaps", "_mags", "_items", "_packs"];
                            { _obj addWeaponCargoGlobal [_x, (_weaps select 1) select _forEachIndex]; } forEach (_weaps select 0);
                            { _obj addMagazineCargoGlobal [_x, (_mags select 1) select _forEachIndex]; } forEach (_mags select 0);
                            { _obj addItemCargoGlobal [_x, (_items select 1) select _forEachIndex]; } forEach (_items select 0);
                            { _obj addBackpackCargoGlobal [_x, (_packs select 1) select _forEachIndex]; } forEach (_packs select 0);
                        };
                        
                        // -------------------------------------------------------------
                        // 3. PLACEMENT & ATTACHMENT LOGIC (FIXED FOR TERRAIN SNAPPING)
                        // -------------------------------------------------------------
                        if (_parentIdx != -1) then {
                            // Child Object (Inside the House)
                            private _parentObj = _spawnedObjs select _parentIdx;
                            _obj attachTo [_parentObj, _relPos];
                            if (_relDir isEqualType []) then { _obj setVectorDirAndUp _relDir; } else { _obj setDir _relDir; };
                        } else {
                            private _worldPos = _anchor modelToWorld _relPos;
                            
                            if (_forEachIndex == 0) then {
                                // MASTER OBJECT
                                _obj setPosATL [_worldPos select 0, _worldPos select 1, 0];
                                if (_relDir isEqualType []) then {
                                    private _wDir = _anchor vectorModelToWorld (_relDir select 0);
                                    _obj setVectorDirAndUp [_wDir, surfaceNormal getPos _obj];
                                } else {
                                    _obj setDir ((getDir _anchor) + _relDir);
                                    _obj setVectorUp surfaceNormal getPos _obj; 
                                };
                            } else {
                                // DETERMINE IF HOUSE OR STANDARD PROP
                                if (_isAdvanced && _forEachIndex == 1) then {
                                    // HOUSE: Keep absolute ASL height (Leveled to Horizon)
                                    private _targetASL = (getPosASL _anchor select 2) + (_relPos select 2);
                                    _obj setPosASL [_worldPos select 0, _worldPos select 1, _targetASL];
                                    
                                    if (_relDir isEqualType []) then {
                                        private _wDir = _anchor vectorModelToWorld (_relDir select 0);
                                        private _wUp = _anchor vectorModelToWorld (_relDir select 1);
                                        _obj setVectorDirAndUp [_wDir, _wUp];
                                    } else {
                                        _obj setDir ((getDir _anchor) + _relDir);
                                        _obj setVectorUp [0,0,1]; 
                                    };
                                    _obj setVariable ["AAS_Is_Simple", true];
                                } else {
                                    // EXTERNAL PROP / SIMPLE COMP: Snap to Terrain Slope (ATL)
                                    _obj setPosATL [_worldPos select 0, _worldPos select 1, _relPos select 2];
                                    
                                    if (_relDir isEqualType []) then {
                                        private _wDir = _anchor vectorModelToWorld (_relDir select 0);
                                        private _wUp = _anchor vectorModelToWorld (_relDir select 1);
                                        _obj setVectorDirAndUp [_wDir, _wUp];
                                    } else {
                                        _obj setDir ((getDir _anchor) + _relDir);
                                        _obj setVectorUp surfaceNormal getPos _obj; 
                                    };
                                };
                            };
                        };
                        
                        if (!_isSimple && {getNumber (configFile >> "CfgVehicles" >> typeOf _obj >> "isUav") == 1}) then {
                            createVehicleCrew _obj;
                            private _tGroup = group (crew _obj select 0);
                            private _nGroup = createGroup _playerSide;
                            (crew _obj) joinSilent _nGroup;
                            deleteGroup _tGroup;
                        };
                        
                        _obj setVariable ["AAS_Is_Simple", _isSimple];
                        _spawnedObjs pushBack _obj;
                        if (_forEachIndex == 0) then { _masterObj = _obj; };
                        
                    } forEach _compArray;
                    
                    deleteVehicle _anchor;
                    
                    [_spawnedObjs, _masterObj] spawn {
                        params ["_objs", "_masterObj"];
                        sleep 5; 
                        {
                            if (!isNull _x && _x != _masterObj && !(_x getVariable ["AAS_Is_Simple", false])) then { 
                                _x enableSimulationGlobal true; 
                            };
                        } forEach _objs;
                        
                        sleep 10; 
                        {
                            if (!isNull _x && _x != _masterObj) then { _x allowDamage true; };
                        } forEach _objs;
                    };
                    
                    if (!isNull _masterObj) then {
                        _masterObj setVariable ["AAS_Comp_Objects", _spawnedObjs, true];
                        _masterObj setVariable ["AAS_Comp_Data", [_targetClassStr, _targetLoadout, _playerSide, _origPos, _origDir, _execId], true];

                        [
                            _masterObj, 
                            "<t color='#FF8800'>[ Hold to Repack (1m) ]</t>", 
                            "\a3\ui_f\data\IGUI\Cfg\holdactions\holdAction_connect_ca.paa", 
                            "\a3\ui_f\data\IGUI\Cfg\holdactions\holdAction_connect_ca.paa", 
                            "_this distance _target < 6 && !isNil {_target getVariable 'AAS_Comp_Data'}", 
                            "true", 
                            {}, 
                            {}, 
                            {
                                params ["_target", "_caller", "_actionId", "_arguments"];
                                [_target] remoteExec ["aas_logistics_fnc_RepackComposition", 2];
                            }, 
                            {}, 
                            [], 
                            5, 
                            1.5, 
                            true, 
                            false
                        ] remoteExec ["BIS_fnc_holdActionAdd", 0, _masterObj];
                        
                        [_masterObj] spawn {
                            params ["_mObj"];
                            sleep 60;
                            if (!isNull _mObj) then {
                                _mObj setVariable ["AAS_Comp_Objects", nil, true];
                                _mObj setVariable ["AAS_Comp_Data", nil, true];
                                _mObj allowDamage true; 
                            };
                        };
                        
                        // --- EXTERNAL CBA INIT INJECTION ---
                        private _varInit = format ["AAS_LOG_%1_Init", _execId];
                        private _compInitCode = missionNamespace getVariable [_varInit, ""];
                        
                        if (_compInitCode != "") then {
                            [_spawnedObjs, _compInitCode] spawn {
                                params ["_allObjs", "_code"];
                                sleep 2; 
                                _allObjs call compile _code;
                            };
                        };
                    };
                
                } else {
                    private _realVehicle = createVehicle [_targetClassStr, _origPos, [], 0, "NONE"];
                    _realVehicle setDir _origDir;
                    _realVehicle allowDamage false; 
                    
                    if (getNumber (configFile >> "CfgVehicles" >> typeOf _realVehicle >> "isUav") == 1) then {
                        createVehicleCrew _realVehicle;
                        private _turretGroup = group (crew _realVehicle select 0);
                        private _newGroup = createGroup _playerSide;
                        (crew _realVehicle) joinSilent _newGroup;
                        deleteGroup _turretGroup;
                    };
                    
                    if (_targetLoadout isNotEqualTo false) then {
                        if (_targetLoadout isEqualType []) then { _realVehicle setUnitLoadout _targetLoadout; };
                        if (_targetLoadout isEqualType "") then { _realVehicle call compile _targetLoadout; };
                    };
                    
                    [_realVehicle] spawn {
                        sleep 15; 
                        if (alive (_this select 0)) then { (_this select 0) allowDamage true; };
                    };
                };
            }, true];
        };

        if (isNil "aas_logistics_fnc_RepackComposition") then {
            missionNamespace setVariable ["aas_logistics_fnc_RepackComposition", {
                params ["_masterObj"];
                if (!isServer) exitWith {};

                [_masterObj] spawn {
                    params ["_masterObj"];
                    
                    private _spawnedObjs = _masterObj getVariable ["AAS_Comp_Objects", []];
                    private _compData = _masterObj getVariable ["AAS_Comp_Data", []];
                    _compData params ["_tClassStr", "_tLoadout", "_pSide", "_origPos", "_origDir", ["_execId", ""]]; 

                    {
                        if (!isNull _x) then { 
                            { deleteVehicle _x } forEach (crew _x select { !isPlayer _x });
                            deleteVehicle _x; 
                        };
                    } forEach _spawnedObjs;

                    private _newContainer = createVehicle ["B_Slingload_01_Cargo_F", _origPos, [], 0, "NONE"];
                    _newContainer setDir _origDir;
                    clearItemCargoGlobal _newContainer; clearWeaponCargoGlobal _newContainer; clearMagazineCargoGlobal _newContainer; clearBackpackCargoGlobal _newContainer;
                    _newContainer setMass 500;
                    _newContainer allowDamage false;

                    [_newContainer, _tClassStr, _tLoadout, _pSide, _execId] call aas_logistics_fnc_InitContainerActions;
                };
            }, true];
        };

        [_payloadObj, _targetClass, _targetLoadout, _playerSide, _execId] call aas_logistics_fnc_InitContainerActions;

    } else {
        if (alive _payloadObj) then {
            [_payloadObj] spawn {
                sleep 15;
                if (alive (_this select 0)) then { 
                    (_this select 0) allowDamage true; 
                    
                    // FIX: Retrieve and restore the original mass
                    private _origMass = (_this select 0) getVariable ["AAS_Orig_Mass", -1];
                    if (_origMass != -1) then {
                        (_this select 0) setMass _origMass;
                    };
                };
            };
        };
    };

    deleteVehicle _helipad;
    waitUntil { sleep 5; (_heli distance2D _lzPos > 2500) || !alive _heli };
    
    if (alive _heli) then {
        { deleteVehicle _x } forEach crew _heli;
        deleteVehicle _heli;
    };
    deleteGroup _heliGroup;
};