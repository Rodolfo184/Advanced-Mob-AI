local MobAI = {}

local TS = game:GetService("TweenService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local RS = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local SSS = game:GetService("ServerScriptService")
local Debris = game:GetService("Debris")

local RM = RS:WaitForChild("ReplicateModules")
local Modules = SSS:WaitForChild("Modules")

local statAssignor = require(Modules:WaitForChild("StatAssignor"))
local AchievementManager = require(Modules:WaitForChild("AchievementManager"))
local NotificationHandler = require(RM:WaitForChild("NotificationHandler"))
local CombatController = require(RS.Modules:WaitForChild("CombatController")) 

local MobSettings = require(ServerStorage:WaitForChild("Modules"):WaitForChild("mobSettings"))

local remotes = RS:FindFirstChild("Remotes")
local combatEffect = remotes:FindFirstChild("CombatEffect")

local sellSound = SoundService:WaitForChild("Sell")
local VFXFolder = RS:FindFirstChild("VFX")

-- constants
local THREAT_CHECK_INTERVAL = 0.1
local HITBOX_CHECK_RADIUS = 15
local BLOCK_ON_DMG_CHANCE = 0.6
local BLOCK_ON_HITBOX_CHANCE = 0.7
local THREAT_TIMEOUT = 0.6
local ATK_VARIANCE = {min = 0.75, max = 1.25}
local CIRCLE_SWITCH_CHANCE = 0.15
local COMBO_PATTERN_RESET = 0.3

local function flashRed(character)
	local highlight = Instance.new("Highlight")
	highlight.Name = "DangerHighlight"
	highlight.FillColor = Color3.new(1, 0, 0)
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = character
	Debris:AddItem(highlight, 0.4)
end

local function cloneSFX(character, sfxName)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local combatSounds = SoundService:FindFirstChild("SFX") and SoundService.SFX:FindFirstChild("Combat")
	local sourceSound = combatSounds and combatSounds:FindFirstChild(sfxName)

	if not sourceSound or not sourceSound:IsA("Sound") then return end

	local soundClone = sourceSound:Clone()
	soundClone.Parent = rootPart
	soundClone:Play()
	Debris:AddItem(soundClone, 1.5)
end

local function spawnBlood(targetChar)
	if not VFXFolder then return end

	local bloodCategory = VFXFolder:FindFirstChild("Blood")
	local sourceAttachment = bloodCategory and bloodCategory:FindFirstChild("Attachment") 
	local torso = targetChar:FindFirstChild("Torso") or targetChar:FindFirstChild("UpperTorso")

	if not sourceAttachment or not torso then return end

	local attachmentClone = sourceAttachment:Clone()
	attachmentClone.Parent = torso 

	task.delay(0.05, function()
		for _, child in pairs(attachmentClone:GetChildren()) do
			if child:IsA("ParticleEmitter") then 
				child:Emit(30) 
			end
		end
	end)

	Debris:AddItem(attachmentClone, 2)
end

local function spawnBlockFX(targetChar)
	if not VFXFolder then return end

	local container = VFXFolder:FindFirstChild("BlockHit") 
	local rootPart = targetChar:FindFirstChild("HumanoidRootPart")

	if not container or not rootPart then return end

	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("Attachment") then continue end

		local attachmentClone = child:Clone()
		attachmentClone.Parent = rootPart 
		attachmentClone.CFrame = CFrame.new(0, 0, -3)

		for _, particle in ipairs(attachmentClone:GetChildren()) do
			if particle:IsA("ParticleEmitter") then 
				particle:Emit(particle:GetAttribute("EmitCount") or 5) 
			end
		end
		Debris:AddItem(attachmentClone, 1)
	end
end

local function newAnimHandler()
	local handler = { _tracks = {}, _cur = nil }

	function handler:load(animator, name, id, looped)
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local track = animator:LoadAnimation(anim)
		track.Looped = looped or false

		if name == "Idle" then
			track.Priority = Enum.AnimationPriority.Idle
		elseif name == "Walk" then
			track.Priority = Enum.AnimationPriority.Movement
		elseif name == "Block" then
			track.Priority = Enum.AnimationPriority.Action4
		else
			track.Priority = Enum.AnimationPriority.Action
		end

		self._tracks[name] = track
		return anim 
	end

	function handler:play(name, fade, force)
		local track = self._tracks[name]
		if not track then return end

		-- don't interrupt a melee swing unless forced
		if not force and self._cur and self._cur:match("M%d") and track.IsPlaying then
			return
		end

		fade = fade or 0.2
		for animName, activeTrack in pairs(self._tracks) do
			if animName ~= name and animName ~= "Idle" and activeTrack.IsPlaying then 
				activeTrack:Stop(fade) 
			end
		end

		if not track.IsPlaying then 
			track:Play(fade)
		end
		self._cur = name
	end

	function handler:stop(name, fade)
		local track = self._tracks[name]
		if not track then return end

		if name ~= "Idle" then
			track:Stop(fade or 0.2)
		end
		if self._cur == name then 
			self._cur = "Idle" 
		end
	end

	function handler:current() return self._cur end

	function handler:cleanup()
		for _, track in pairs(self._tracks) do 
			track:Stop(0.5) 
		end
		table.clear(self._tracks)
		self._cur = nil
	end

	return handler
end

-- ai state

local function makeAIState()
	return {
		state = "idle",
		combo = 1,
		lastSwing = 0,
		circleDir = 1,
		lastStrafeTick = 0,
		isStrafing = false,
		atkVariant = math.random(1, 3),
		stunTick = 0,
		block = {
			on = false,
			endTime = 0,
			advanceWhileBlocking = false,
		},
		fight = {
			active = false,
			prevHP = 0,
			threat = false,
			threatTime = 0,
		}
	}
end

local function enterBlock(ai, ctrl, stats, mob)
	ai.block.on = true
	ai.fight.threat = true
	ai.fight.threatTime = os.clock()
	ai.block.advanceWhileBlocking = math.random() < 0.3
	ai.block.endTime = os.clock() + (math.random(8, 15) / 10)

	mob:SetAttribute("Blocking", true)
	ctrl.Blocking = true
	ctrl.CurrentBlockConfig = {
		damageReduction = stats.BlockDmgReduction,
		postureOnBlock = stats.BlockPostureOnHit,
		guardBreakStun = 2.0
	}

	if VFXFolder then
		local rootPart = mob:FindFirstChild("HumanoidRootPart")
		local container = VFXFolder:FindFirstChild("Block") or VFXFolder:FindFirstChild("BlockHit")
		if container and rootPart then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Attachment") then
					local clone = child:Clone()
					clone.Name = "HoldingBlockVFX"
					clone.Parent = rootPart
					clone.CFrame = CFrame.new(0, 0, -3)
					for _, p in ipairs(clone:GetChildren()) do
						if p:IsA("ParticleEmitter") then
							p.Enabled = true
						end
					end
				end
			end
		end
	end
end

local function exitBlock(ai, ctrl, mob, anims)
	ai.block.on = false
	ai.fight.threat = false
	ai.block.advanceWhileBlocking = false

	mob:SetAttribute("Blocking", false)
	ctrl.Blocking = false

	if anims then anims:stop("Block", 0.1) end

	local rootPart = mob:FindFirstChild("HumanoidRootPart")
	if rootPart then
		for _, child in ipairs(rootPart:GetChildren()) do
			if child.Name == "HoldingBlockVFX" then
				for _, p in ipairs(child:GetChildren()) do
					if p:IsA("ParticleEmitter") then
						p.Enabled = false
					end
				end
				Debris:AddItem(child, 1)
			end
		end
	end
end

function MobAI.findTarget(root, range)
	local bestTarget = nil
	local shortestDist = range

	for _, plr in pairs(Players:GetPlayers()) do
		local character = plr.Character
		if not character then continue end

		local humanoid = character:FindFirstChild("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")

		if humanoid and rootPart and humanoid.Health > 0 then
			local distance = (root.Position - rootPart.Position).Magnitude
			if distance < shortestDist then 
				shortestDist = distance
				bestTarget = rootPart 
			end
		end
	end
	return bestTarget
end

local function playerSwingingNear(root, targetChar, radius)
	radius = radius or HITBOX_CHECK_RADIUS
	local targetCombat = CombatController.fromCharacter(targetChar)

	if not targetCombat then return false end
	if targetCombat.State ~= "attacking" and targetCombat.State ~= "combo_window" then return false end

	local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
	return targetRoot and (root.Position - targetRoot.Position).Magnitude <= radius
end

local function handleMovement(humanoid, root, target, distance, ai, stats)
	if not target then
		humanoid:MoveTo(root.Position)
		return "Idle"
	end

	-- target is in range, face it
	if distance <= stats.AttackDist then
		humanoid:MoveTo(root.Position)
		local lookAt = Vector3.new(target.Position.X, root.Position.Y, target.Position.Z)
		root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, lookAt), 0.4)
		return "Idle"
	end

	-- target escaped follow range
	if distance > stats.FollowRange then
		humanoid:MoveTo(root.Position)
		return "Idle"
	end

	-- strafing
	if ai.block.on and not ai.block.advanceWhileBlocking then
		local angle = math.rad(70) * ai.circleDir
		local lookCF = CFrame.lookAt(target.Position, root.Position)
		local offsetCF = lookCF * CFrame.Angles(0, angle, 0)
		humanoid:MoveTo(target.Position + offsetCF.LookVector * 6)

		if math.random() < 0.25 then ai.circleDir = -ai.circleDir end
		return "Block"
	end

	local now = tick()
	if now - ai.lastStrafeTick > 0.8 then
		ai.lastStrafeTick = now
		ai.isStrafing = (math.random() < stats.AggressionLevel + 0.3)
	end

	-- aggressive circling behavior before attacking
	if distance < stats.AttackDist + 8 and ai.isStrafing then
		local angle = math.rad(65) * ai.circleDir
		local lookCF = CFrame.lookAt(target.Position, root.Position)
		local offsetCF = lookCF * CFrame.Angles(0, angle, 0)
		humanoid:MoveTo(target.Position + offsetCF.LookVector * (stats.AttackDist + 4))

		if math.random() < 0.2 then ai.circleDir = -ai.circleDir end
	else
		-- direct approach
		humanoid:MoveTo(target.Position)
	end

	return "Walk"
end

local function fireDmgIndicators(victimModel, attackerModel, dmg)
	combatEffect:FireAllClients("damageIndicator", victimModel, attackerModel, math.floor(dmg))

	local victimPlr = Players:GetPlayerFromCharacter(victimModel)
	if victimPlr then
		combatEffect:FireClient(victimPlr, "playerDamageIndicator", math.floor(dmg))
	end
end

local function doAttack(target, stats, ai, anims, root, ctrl)
	local isCrit = stats.CritChance > 0 and math.random() < stats.CritChance
	local isFeint = stats.FeintChance > 0 and math.random() < stats.FeintChance

	if isCrit then
		flashRed(root.Parent)
		anims:play("Idle", 0.1)
		task.wait(0.35)  
	else
		-- mix up the combo 
		if math.random() < 0.4 then ai.combo = math.random(1, 3) end
		if ai.atkVariant == 1 and ai.combo == 1 then ai.combo = 2 end
	end

	local animName = isCrit and "M3" or ("M" .. ai.combo)
	anims:play(animName, 0.1, true)

	if isFeint and not isCrit then
		task.delay(0.2, function()
			anims:stop(animName)
		end)
		ai.lastSwing = tick()
		return
	end

	task.wait(0.3)

	-- hitbox cast
	local boxCFrame = root.CFrame * CFrame.new(0, 0, -3.5)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params:AddToFilter({root.Parent})

	local hitParts = workspace:GetPartBoundsInBox(boxCFrame, Vector3.new(5, 6, 5), params)
	local processedModels = {}

	for _, hit in pairs(hitParts) do
		local victimModel = hit:FindFirstAncestorOfClass("Model")
		if not victimModel or processedModels[victimModel] then continue end

		local victimHum = victimModel:FindFirstChild("Humanoid")
		if not victimHum or victimHum.Health <= 0 then continue end

		processedModels[victimModel] = true

		local victimRoot = victimModel:FindFirstChild("HumanoidRootPart")
		local hitFromFront = true

		if victimRoot then
			local direction = (root.Position - victimRoot.Position) * Vector3.new(1,0,1)
			if direction.Magnitude > 0 then
				hitFromFront = victimRoot.CFrame.LookVector:Dot(direction.Unit) > -0.1
			end
		end

		local targetCombat = CombatController.fromCharacter(victimModel)

		if isCrit and victimModel:GetAttribute("Blocking") and hitFromFront then
			-- crit breaks block
			if targetCombat then
				targetCombat:applyBlockPosture(stats.PostureDamage * 2, stats.Damage)
				cloneSFX(victimModel, "Hit")
				spawnBlood(victimModel)
				victimHum:TakeDamage(stats.Damage)
				fireDmgIndicators(victimModel, root.Parent, stats.Damage)
			end

		elseif victimModel:GetAttribute("Blocking") and hitFromFront then
			-- normal hit against a block
			cloneSFX(victimModel, "Block")
			spawnBlockFX(victimModel)
			if targetCombat then
				local cfg = targetCombat.CurrentBlockConfig
				local reduction = cfg and cfg.damageReduction or 0.75
				local reducedDamage = stats.Damage * (1 - reduction)

				targetCombat:applyBlockPosture(stats.PostureDamage, stats.Damage)
				fireDmgIndicators(victimModel, root.Parent, reducedDamage)
			end

		elseif victimModel:GetAttribute("Parrying") and hitFromFront then
			-- target successfully parried the mob
			local targetCombatParry = CombatController.fromCharacter(victimModel)
			if targetCombatParry then targetCombatParry:recoverPosture(15) end

			ctrl.StunType = "parry"
			ctrl:stun(1.0)
			ai.state = "stunned"
			anims:stop(animName, 0.1)

			local parryPos = victimRoot and (victimRoot.CFrame * CFrame.new(0, 0, -2.5)).Position or Vector3.zero
			combatEffect:FireAllClients("parrySuccess", victimModel, root.Parent, parryPos)
			cloneSFX(victimModel, "Block")

		else
			-- clean hit
			victimHum:TakeDamage(stats.Damage)
			cloneSFX(victimModel, "Hit")
			spawnBlood(victimModel)
			fireDmgIndicators(victimModel, root.Parent, stats.Damage)
		end
	end

	ai.lastSwing = tick()
	if not isCrit then ai.combo = (ai.combo % 3) + 1 end
	if math.random() < COMBO_PATTERN_RESET then ai.atkVariant = math.random(1, 3) end
end

function MobAI.init(mob: Model, spawnPoint)
	local head = mob:FindFirstChild("Head")
	if not head then return end

	local mobName = mob.Name
	local humanoid: Humanoid = mob:WaitForChild("Humanoid")
	local root = mob:WaitForChild("HumanoidRootPart")

	local stats = MobSettings[mobName] or MobSettings.Skeleton

	for _, part in pairs(mob:GetDescendants()) do
		if part:IsA("BasePart") then 
			part.CanCollide = false
			part.Massless = true 
		end
	end
	root.CanCollide = true
	root.Anchored = false

	local depthKill = workspace:WaitForChild("MainMap"):WaitForChild("WasteLand"):WaitForChild("Arena"):WaitForChild("Depth")
	root.Touched:Connect(function(hit)
		if hit:IsDescendantOf(depthKill) then 
			mob:PivotTo(spawnPoint.CFrame + Vector3.new(0, 4, 0)) 
		end
	end)

	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local anims = newAnimHandler()
	local animRefs = {} 

	for name, id in pairs(stats.Anims) do
		local looped = (name == "Idle" or name == "Walk" or name == "Block")
		animRefs[#animRefs+1] = anims:load(animator, name, id, looped)
	end

	humanoid.MaxHealth = stats.Health
	humanoid.Health = stats.Health
	humanoid.WalkSpeed = stats.Speed
	mob.Parent = workspace
	mob:PivotTo(spawnPoint.CFrame + Vector3.new(0, 4, 0))

	if root:CanSetNetworkOwnership() then root:SetNetworkOwner(nil) end

	local ctrl = CombatController.new(mob)
	local ai = makeAIState()
	ai.fight.prevHP = humanoid.Health

	mob:SetAttribute("Posture", 0)
	local originalApply = ctrl.applyBlockPosture
	if originalApply then
		function ctrl:applyBlockPosture(postureDmg, dmg)
			originalApply(self, postureDmg, dmg)
			local cur = mob:GetAttribute("Posture") or 0
			mob:SetAttribute("Posture", cur + (postureDmg or 15))
		end
	end

	task.wait(0.1)
	anims:play("Idle", 0.1)

	local lastHitboxCheck = 0

	local threatThread = task.spawn(function()
		while mob and mob.Parent and humanoid.Health > 0 do
			task.wait(THREAT_CHECK_INTERVAL)

			local target = MobAI.findTarget(root, stats.FollowRange)
			if not target then 
				if ai.block.on then exitBlock(ai, ctrl, mob, anims) end
				continue 
			end

			local targetChar = target.Parent
			local distance = (root.Position - target.Position).Magnitude

			if humanoid.Health < ai.fight.prevHP then
				ai.fight.prevHP = humanoid.Health
				if not ai.block.on and ai.state ~= "attacking" and math.random() < BLOCK_ON_DMG_CHANCE then
					enterBlock(ai, ctrl, stats, mob)
					anims:play("Block", 0.1, true)
				end
			end

			if distance < stats.AttackDist + 8 and tick() - lastHitboxCheck > 0.2 then
				lastHitboxCheck = tick()

				if playerSwingingNear(root, targetChar) and ai.state ~= "attacking" then
					if not ai.block.on and math.random() < BLOCK_ON_HITBOX_CHANCE then
						enterBlock(ai, ctrl, stats, mob)
						anims:play("Block", 0.1, true)
					end
				end
			end

			if ai.block.on and os.clock() >= ai.block.endTime then
				exitBlock(ai, ctrl, mob, anims)
			end
		end
	end)

	local mainThread = task.spawn(function()
		while mob and mob.Parent and humanoid.Health > 0 do
			task.wait(0.05)
			local now = tick()

			local currentPosture = ctrl.Posture or mob:GetAttribute("Posture") or 0
			if currentPosture >= 100 then
				mob:SetAttribute("Posture", 0)
				if ai.block.on then exitBlock(ai, ctrl, mob, anims) end
				ai.state = "stunned"
				ai.stunTick = tick()
				if ctrl.stun then ctrl:stun(2.0) end
				spawnBlockFX(mob) 
				anims:play("Idle", 0.1) 
				continue
			end

			if ai.state == "stunned" then
				if tick() - ai.stunTick >= 2.0 then
					ai.state = "idle"
				else
					continue
				end
			end

			if currentPosture > 0 and not ai.block.on then
				mob:SetAttribute("Posture", math.max(0, currentPosture - 1.5)) 
			end

			local target = MobAI.findTarget(root, stats.FollowRange)

			if target then
				ai.fight.active = true
				local distance = (root.Position - target.Position).Magnitude
				local intendedAnim = handleMovement(humanoid, root, target, distance, ai, stats)

				-- attack if in range
				if distance <= stats.AttackDist and not ai.block.on and ai.state ~= "attacking" then
					local cooldown = stats.AttackRate * math.random(ATK_VARIANCE.min * 100, ATK_VARIANCE.max * 100) / 100
					if now - ai.lastSwing >= cooldown then
						ai.state = "attacking"
						doAttack(target, stats, ai, anims, root, ctrl)
						ai.state = "idle"
					elseif anims:current() ~= intendedAnim and not ai.block.on then
						anims:play(intendedAnim, 0.2)
					end
				elseif ai.block.on then
					if anims:current() ~= "Block" then anims:play("Block", 0.2) end
				elseif anims:current() ~= intendedAnim then
					anims:play(intendedAnim, 0.2)
				end

				if now - ai.lastSwing > stats.ComboResetTime then ai.combo = 1 end
			else
				if ai.fight.active then
					ai.fight.active = false
					ai.combo = 1
					if ai.block.on then exitBlock(ai, ctrl, mob, anims) end
				end

				ai.state = "idle"
				humanoid:MoveTo(root.Position)
				task.wait(math.random(2, 4))
			end
		end
	end)

	local bleedConn = humanoid.HealthChanged:Connect(function()
		if not (ai.block.on and mob:GetAttribute("Blocking")) then
			spawnBlood(mob)
		end
	end)

	local hpConn = nil
	local hpDisplay = head:FindFirstChild("healthDisplay")
	if hpDisplay then
		hpDisplay.bg.TextLabel.Text = math.floor(humanoid.Health).."/"..math.floor(humanoid.MaxHealth)

		hpConn = humanoid.HealthChanged:Connect(function(hp)
			hpDisplay.bg.TextLabel.Text = math.floor(humanoid.Health).."/"..math.floor(humanoid.MaxHealth)
			local tween = TS:Create(hpDisplay.bg.health, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {
				Size = UDim2.fromScale((hp / humanoid.MaxHealth) * 0.83, 0.41)
			})
			tween:Play()
			tween.Completed:Wait()
			tween:Destroy()
		end)
	end

	humanoid.Died:Once(function()
		task.cancel(threatThread)
		task.cancel(mainThread)

		local creatorTag = humanoid:FindFirstChild("creator")
		if creatorTag and creatorTag.Value then
			local killerPlayer = creatorTag.Value
			statAssignor.add(killerPlayer, "XP", stats.xp or 30)
			statAssignor.add(killerPlayer, "Elds", stats.reward or 400)

			if sellSound then sellSound:Play() end
			NotificationHandler.ShowReward(killerPlayer, stats.reward or 400, false)
			AchievementManager.IncrementProgress(killerPlayer, mobName)
		end

		if hpConn then hpConn:Disconnect() end
		if bleedConn then bleedConn:Disconnect() end
		anims:cleanup()
		if ctrl then ctrl:Destroy() end

		task.wait(2)
		mob:Destroy()
		for _, animRef in pairs(animRefs) do animRef:Destroy() end
		table.clear(animRefs)

		task.wait(stats.respawnTime or 20)
		local masterMob = ServerStorage.Mobs:FindFirstChild(mobName)
		if masterMob then 
			MobAI.init(masterMob:Clone(), spawnPoint) 
		end
	end)
end

return MobAI
