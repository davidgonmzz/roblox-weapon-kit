--!nonstrict
-- Client-only visual feedback: tracers, muzzle flash, impact sparks and the camera recoil kick.
-- None of this is authoritative. It exists so the gun feels instant; what actually happened is
-- decided by the server (WeaponServer) and confirmed through HitConfirm / AmmoSync.
--
-- Recoil: each shot adds to a target pitch (degrees); the camera is then eased towards that
-- target and the target decays back to zero. Roblox's default camera builds each frame from the
-- camera's CURRENT look direction, so an offset written into camera.CFrame stays there. That is
-- why only the CHANGE since last frame is applied: the view climbs while the kick grows and comes
-- back down by the same amount as it decays, instead of piling up into a permanent aim change.

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Effects = {}

local MAX_KICK = 14 -- degrees: the most the camera can be thrown up
local KICK_DECAY = 6 -- per second: how fast the target falls back to zero
local KICK_FOLLOW = 28 -- per second: how fast the camera chases the target (the "snap" of a kick)

local rng = Random.new()
local targetPitch, targetYaw = 0, 0 -- degrees, what the shots have asked for
local pitch, yaw = 0, 0 -- degrees, what the camera currently shows
local appliedPitch, appliedYaw = 0, 0 -- degrees, how much of that is already in camera.CFrame

local function decoration(part: Part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

-- A short neon streak from a to b that fades out.
function Effects.tracer(a: Vector3, b: Vector3, color: Color3)
	local length = (b - a).Magnitude
	if length < 0.5 then
		return
	end
	local part = Instance.new("Part")
	decoration(part)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.new(0.08, 0.08, length)
	part.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -length / 2)
	part.Parent = Workspace
	TweenService:Create(part, TweenInfo.new(0.1), { Transparency = 1 }):Play()
	Debris:AddItem(part, 0.15)
end

-- A small glowing ball that swells and fades where a bullet landed.
function Effects.impact(position: Vector3, color: Color3)
	local part = Instance.new("Part")
	decoration(part)
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one * 0.3
	part.Position = position
	part.Parent = Workspace
	TweenService:Create(part, TweenInfo.new(0.15), { Size = Vector3.one * 1.2, Transparency = 1 }):Play()
	Debris:AddItem(part, 0.2)
end

-- A flash and a flicker of light at the muzzle.
function Effects.muzzleFlash(position: Vector3, color: Color3)
	local part = Instance.new("Part")
	decoration(part)
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one * 0.7
	part.Position = position
	part.Parent = Workspace
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 3
	light.Range = 10
	light.Parent = part
	TweenService:Create(part, TweenInfo.new(0.07), { Size = Vector3.one * 0.2, Transparency = 1 }):Play()
	TweenService:Create(light, TweenInfo.new(0.07), { Brightness = 0 }):Play()
	Debris:AddItem(part, 0.1)
end

-- Throws the camera up by roughly `degrees` (a little sideways at random).
function Effects.kick(degrees: number)
	targetPitch = math.min(MAX_KICK, targetPitch + degrees)
	targetYaw += rng:NextNumber(-0.3, 0.3) * degrees
end

-- Hooks the recoil into the render loop. Call once.
function Effects.start()
	RunService:BindToRenderStep("WeaponKitRecoil", Enum.RenderPriority.Camera.Value + 1, function(dt)
		-- Frame-rate independent exponential easing.
		local follow = 1 - math.exp(-KICK_FOLLOW * dt)
		local decay = math.exp(-KICK_DECAY * dt)
		pitch += (targetPitch - pitch) * follow
		yaw += (targetYaw - yaw) * follow
		targetPitch *= decay
		targetYaw *= decay
		local dPitch, dYaw = pitch - appliedPitch, yaw - appliedYaw
		if math.abs(dPitch) < 1e-4 and math.abs(dYaw) < 1e-4 then
			return
		end
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CFrame = camera.CFrame * CFrame.Angles(math.rad(dPitch), math.rad(dYaw), 0)
			appliedPitch, appliedYaw = pitch, yaw
		end
	end)
end

return Effects
