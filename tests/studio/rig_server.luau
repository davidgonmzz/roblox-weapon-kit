--!nonstrict
-- Studio only (never shipped): the server half of pose_audit's A.useRig. Run once per Play session from
-- a Server execute_luau / command bar: require(game.ReplicatedStorage.WeaponKitDev.rig_server)().
-- It swaps the calling player's avatar for a fresh rig built from a HumanoidDescription (R15 or R6), in
-- the same spot; the kit gives the new character its weapons like any respawn.

return function()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local fn = ReplicatedStorage:FindFirstChild("PoseAuditRig") or Instance.new("RemoteFunction")
	fn.Name = "PoseAuditRig"
	fn.Parent = ReplicatedStorage
	fn.OnServerInvoke = function(player, spec)
		local desc = if spec.mine
			then Players:GetHumanoidDescriptionFromUserId(player.UserId)
			else Instance.new("HumanoidDescription")
		for key, value in spec.scales or {} do
			desc[key] = value
		end
		local old = player.Character
		local root = old and old:FindFirstChild("HumanoidRootPart")
		local model = Players:CreateHumanoidModelFromDescription(
			desc,
			if spec.r6 then Enum.HumanoidRigType.R6 else Enum.HumanoidRigType.R15
		)
		if spec.motor6d then
			-- a classic R15 rig (no avatar joint upgrade): every AnimationConstraint becomes a Motor6D
			for _, joint in model:GetDescendants() do
				if joint:IsA("AnimationConstraint") and joint.Attachment0 and joint.Attachment1 then
					local motor = Instance.new("Motor6D")
					motor.Name = joint.Name
					motor.Part0 = joint.Attachment0.Parent
					motor.Part1 = joint.Attachment1.Parent
					motor.C0 = joint.Attachment0.CFrame
					motor.C1 = joint.Attachment1.CFrame
					motor.Parent = joint.Parent
					joint:Destroy()
				elseif joint:IsA("BallSocketConstraint") then
					joint:Destroy()
				end
			end
		end
		if spec.custom then
			-- a rig the pose doesn't know (a creature with claws): its left hand has another name
			local hand = model:FindFirstChild("LeftHand")
			if hand then
				hand.Name = "LeftClaw"
			end
		end
		model.Name = player.Name
		model:PivotTo(if root then root.CFrame else CFrame.new(0, 5, 0))
		player.Character = model
		model.Parent = workspace
		if old then
			old:Destroy()
		end
		return true
	end
	return "PoseAuditRig ready"
end
