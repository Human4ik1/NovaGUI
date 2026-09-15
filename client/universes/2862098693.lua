--[[
  Project Delta universe redirect (UniverseId 2862098693).
  Repo path: client/universes/2862098693.lua

  Every map of the game (lobby + all raid maps, each with its own PlaceId)
  funnels into the single maintained module. The hub executes this chunk;
  whatever function it returns gets called with the hub api — here we just
  forward to the canonical place file.
]]

local MODULE_URL = "https://raw.githubusercontent.com/Human4ik1/NovaGUI/main/client/places/7336302630.lua"

return loadstring(game:HttpGet(MODULE_URL))()
