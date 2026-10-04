Bubble = Bubble or {}
local B = Bubble

B.name = "Bubble"
B.version = "0.1.2"

-- Central event dispatch. Every module registers through B.RegisterEvent
-- instead of calling :RegisterEvent/:SetScript itself, so there's exactly
-- one OnEvent per event name no matter how many modules care about it.
-- Handlers take no arguments and read the globals (event, arg1, arg2, ...)
-- themselves -- this client's OnEvent script receives no arguments; see
-- DEVELOPING.md hard rule #6.
local handlers = {}
local dispatcher = CreateFrame("Frame", "BubbleEventDispatcher")

function B.RegisterEvent(evt, fn)
  if not handlers[evt] then
    handlers[evt] = {}
    dispatcher:RegisterEvent(evt)
  end
  table.insert(handlers[evt], fn)
end

dispatcher:SetScript("OnEvent", function()
  local list = handlers[event]
  if not list then return end
  for i = 1, table.getn(list) do
    list[i]()
  end
end)

-- DEVELOPING.md hard rule #9: SavedVariables are nil until ADDON_LOADED fires
-- for THIS addon's name -- reading/writing BubbleCharDB before that (e.g.
-- at file scope) would silently operate on nil. Modules queue their DB
-- setup here instead of touching SavedVariables directly at load time,
-- same pattern as Aegis_Exchange.OnLoad.
local onLoadQueue = {}
function B.OnLoad(fn)
  table.insert(onLoadQueue, fn)
end

B.RegisterEvent("ADDON_LOADED", function()
  if arg1 ~= "Bubble" then return end
  -- The DB itself is initialized centrally here, once, rather than each
  -- module that touches it doing its own `BubbleCharDB = BubbleCharDB or
  -- {}` -- harmless if repeated, but one canonical place is cleaner than
  -- several. Individual fields (overlay position, settings) are still
  -- each module's own concern.
  BubbleCharDB = BubbleCharDB or {}
  for i = 1, table.getn(onLoadQueue) do
    onLoadQueue[i]()
  end
end)
