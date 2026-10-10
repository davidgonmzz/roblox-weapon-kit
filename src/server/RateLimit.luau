--!strict
-- Token-bucket rate limiter for remotes, one bucket per player, plus validators for the numbers
-- and vectors a client sends (NaN / inf / absurd values are dropped before they reach a raycast
-- or a CFrame).
--
--   local limit = RateLimit.new(5, 10)         -- 5 calls/second sustained, bursts of up to 10
--   if not limit:allow(player) then return end -- at the top of a remote handler
--   RateLimit.isNumber(x, 0, 100)              -- finite number in range (min / max optional)
--   RateLimit.isVector3(v, 1e5)                -- real Vector3, every component finite, |v| <= bound
--
-- Buckets are removed when a player leaves. A player who is no longer in the game is always refused.

local Players = game:GetService("Players")

type Bucket = { tokens: number, last: number }

local Limiter = {}
Limiter.__index = Limiter

export type Limiter =
	typeof(setmetatable({} :: { rate: number, burst: number, buckets: { [Player]: Bucket } }, Limiter))

local RateLimit = {}

local limiters: { Limiter } = {}

Players.PlayerRemoving:Connect(function(player)
	for _, limiter in limiters do
		limiter.buckets[player] = nil
	end
end)

function RateLimit.new(ratePerSecond: number, burst: number): Limiter
	local limiter = setmetatable({ rate = ratePerSecond, burst = burst, buckets = {} :: { [Player]: Bucket } }, Limiter)
	table.insert(limiters, limiter)
	return limiter
end

-- True if this player may call now (and spends one token); false if they are over the limit.
function Limiter.allow(self: Limiter, player: Player): boolean
	if player.Parent ~= Players then
		return false -- already gone: don't create a bucket nobody will clean up
	end
	local now = os.clock()
	local bucket = self.buckets[player]
	if not bucket then
		bucket = { tokens = self.burst, last = now }
		self.buckets[player] = bucket
	end
	bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.last) * self.rate)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- A real, finite number (not NaN, not +-inf), optionally within [min, max].
function RateLimit.isNumber(value: any, min: number?, max: number?): boolean
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	return (min == nil or value >= min) and (max == nil or value <= max)
end

-- A real Vector3 with finite components whose length is at most maxMagnitude.
function RateLimit.isVector3(value: any, maxMagnitude: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	return RateLimit.isNumber(v.X, -maxMagnitude, maxMagnitude)
		and RateLimit.isNumber(v.Y, -maxMagnitude, maxMagnitude)
		and RateLimit.isNumber(v.Z, -maxMagnitude, maxMagnitude)
		and v.Magnitude <= maxMagnitude
end

return RateLimit
