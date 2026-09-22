"""Integrate actual native C-writer JSON with Lua's C1 observer (no game).

The player fixture is produced by player_sensor_selftest --reimu-fixture
using the user's real pl00.sht; the Enemy fixture uses a synthetic raw object
through the production collector/writer. Neither game data nor generated
fixtures belong in the release. Run after native fixtures have been generated.
"""
import argparse
import json
import os
from pathlib import Path
import sys

project = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / "work" / "lua-test-python"))
from lupa.lua51 import LuaRuntime  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--player", type=Path, default=project / "work/reimu-c1-static-3.5/reimu-player-fixture.json")
parser.add_argument("--enemy", type=Path, default=project / "work/reimu-c1-static-3.5/reimu-enemy-fixture.json")
args = parser.parse_args()
player = json.loads(args.player.read_text(encoding="utf-8-sig"))
enemy = json.loads(args.enemy.read_text(encoding="utf-8-sig"))
os.chdir(project / "src/ai")
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().native_player = lua.table_from(player, recursive=True)
lua.globals().native_enemy = lua.table_from(enemy, recursive=True)
lua.execute(r'''
local observer=dofile('bloom_observer.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local p=native_player
p.x,p.y,p.life,p.currentCharge,p.currentChargeMax,p.chargeSpeed=12,320,10,0,100,10
local c=native_enemy
local e={id=c.id,enabled=true,x=c.x,y=c.y,vx=0,vy=0,isSpirit=true,
  isActivatedSpirit=true,isBoss=false,isLily=false,isPseudoEnemy=false,combat=c}
local w={player=p,enemies={e},bullets={}}
check(#p.sensor.c1Profile.shots==4,'native writer lost actual Reimu templates')
for i,s in ipairs(p.sensor.c1Profile.shots) do
  check(s.templateIndex==i and s.movementModelVersion==1 and s.damage==30,
    'native movement/damage contract differs from observer')
end
for _,side in ipairs({1,2}) do
  player_side=side;c.side=side
  local o=observer.observe(w,{}, {c1_release_delay_updates=30})
  check(o.c1.kill_model and o.c1.combat_valid and o.c1.has_ignition,
    'actual native fields did not fund activated HP20 on side '..side)
  check(o.stats.c1_motion_steps>160,'native positive fixture did not exercise homing')
  c.hp=61
  o=observer.observe(w,{}, {c1_release_delay_updates=30})
  check(not o.c1.has_ignition,'four actual damage30 shots exceeded activated 60HP budget')
  c.hp=20;c.valid=false
  check(not observer.observe(w,{},{}).c1.combat_valid,'native invalid combat was trusted')
  c.valid=true
end
print('reimu_c1_native_fixture_test: PASS ('..checks..' assertions; native C writer to Lua, no game process)')
''')
