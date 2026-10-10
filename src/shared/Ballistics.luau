--!strict
-- Shot maths used by both sides. The SERVER uses it for the real pellets; the client only uses
-- it to draw plausible tracers at once, before the server's answer arrives. It is pure maths with
-- no secrets, so sharing it can't help an exploiter: what a client draws never decides a hit.

local Ballistics = {}

-- `direction` (unit) tilted by a random angle up to `degrees`, spread evenly over the cone
-- (square root on the radius: uniform over the disc, not bunched in the middle).
function Ballistics.spread(direction: Vector3, degrees: number, rng: Random): Vector3
	if degrees <= 0 then
		return direction
	end
	-- lookAt needs an "up" that isn't parallel to the aim, or it returns a broken CFrame.
	local up = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local tilt = math.rad(degrees) * math.sqrt(rng:NextNumber())
	local roll = rng:NextNumber() * math.pi * 2
	return (CFrame.lookAt(Vector3.zero, direction, up) * CFrame.Angles(0, 0, roll) * CFrame.Angles(tilt, 0, 0)).LookVector
end

return Ballistics
