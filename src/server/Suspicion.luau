--!nonstrict
-- The one place every server-side check reports to. WeaponServer reports refused shots and aim
-- flags, Movement reports speed / teleport / fly / jump / noclip / fling, Range reports a crate
-- prompt used from too far away. Each report is counted per player and per reason, with one warn
-- in the server log when a player's total reaches WARN_AT.
--
--   Suspicion.report(player, reason, detail?)  count one flag; detail is free text for your log
--   Suspicion.onFlag(fn)                       fn(player, reason, detail, reasonCount, totalCount)
--                                              runs on every flag. THIS is where a game plugs in its
--                                              own policy (kick, temp ban, webhook). Default: nothing.
--                                              Returns a function that removes the hook again.
--   Suspicion.total(player)                    flags so far, and { [reason] = count }
--
-- No kicks or bans happen by default: false alarms exist (lag, odd maps), and a kit should not
-- ban anyone on a guess. Flags are for review; decide in onFlag how much each reason is worth.
--
-- Demo only (Config.DEMO_CHEAT_PANEL): the Rejected remote tells the player WHY they were
-- flagged: (reason, reasonCount, totalCount). It is not even created when the flag is off: a
-- real game should never explain its anti-cheat to the player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(script.Parent.Remotes)

local Suspicion = {}

local WARN_AT = 25 -- flags from one player before the one-time warn in the log

local rejectedRemote
if Config.DEMO_CHEAT_PANEL then
	rejectedRemote = Remotes.event("Rejected")
end

-- [Player] = { total = flags so far, reasons = { [reason] = count } }. Never saved.
local states = {}
local hooks = {} -- fn(player, reason, detail, reasonCount, totalCount)

function Suspicion.report(player: Player, reason: string, detail: string?)
	if player.Parent ~= Players then
		return -- already gone: don't create state nobody will clean up
	end
	local s = states[player]
	if not s then
		s = { total = 0, reasons = {} }
		states[player] = s
	end
	s.total += 1
	local n = (s.reasons[reason] or 0) + 1
	s.reasons[reason] = n

	if rejectedRemote then
		rejectedRemote:FireClient(player, reason, n, s.total) -- demo HUD only
	end
	if s.total == WARN_AT then
		local parts = {}
		for name, count in s.reasons do
			table.insert(parts, name .. "=" .. count)
		end
		table.sort(parts)
		warn(
			string.format(
				"[WeaponKit] Suspicion: %s reached %d flags (%s)",
				player.Name,
				s.total,
				table.concat(parts, ", ")
			)
		)
	end
	-- A hook is the game's code: it may yield (a webhook) or fail, which must not stop the check
	-- that reported, so each runs in its own thread (over a copy: a hook may remove itself).
	for _, fn in table.clone(hooks) do
		task.spawn(fn, player, reason, detail, n, s.total)
	end
end

function Suspicion.onFlag(fn: (Player, string, string?, number, number) -> ()): () -> ()
	table.insert(hooks, fn)
	return function()
		local index = table.find(hooks, fn)
		if index then
			table.remove(hooks, index)
		end
	end
end

function Suspicion.total(player: Player): (number, { [string]: number })
	local s = states[player]
	if not s then
		return 0, {}
	end
	return s.total, table.clone(s.reasons)
end

Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)

return Suspicion
