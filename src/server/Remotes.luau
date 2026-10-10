--!strict
-- The ReplicatedStorage "WeaponKitRemotes" folder every kit remote lives in. Whichever server module asks
-- first creates the folder, so load order doesn't matter; asking again returns the same remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local function get(name: string, className: string): Instance
	local folder = ReplicatedStorage:FindFirstChild("WeaponKitRemotes") or Instance.new("Folder")
	folder.Name = "WeaponKitRemotes"
	folder.Parent = ReplicatedStorage
	local r = folder:FindFirstChild(name) or Instance.new(className)
	r.Name = name
	r.Parent = folder
	return r
end

function Remotes.event(name: string): RemoteEvent
	return get(name, "RemoteEvent") :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return get(name, "RemoteFunction") :: RemoteFunction
end

return Remotes
