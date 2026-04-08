local MobSettings = {
	Skeleton = {
		Health = 100, 
		Damage = 15, 
		Speed = 12,
		FollowRange = 30, 
		StopRange = 15,
		AttackDist = 5,
		AttackRate = 0.55,
		ComboResetTime = 1.2,
		PatrolRadius = 30,
		xp = 30,
		respawnTime = 20,
		reward = 400,
		PostureDamage = 15, 
		AggressionLevel = 0.4, 
		BlockDmgReduction = 0.75,
		BlockPostureOnHit = 20,
		CritChance = 0.15, 
		FeintChance = 0.10, 
		Anims = {
			M1 = "rbxassetid://91401695466601",
			M2 = "rbxassetid://82141550254555",
			M3 = "rbxassetid://137520384257449",
			Walk = "rbxassetid://102166523559299",
			Idle = "rbxassetid://131856234142576",
			Block = "rbxassetid://101306228488116"
		}
	},
	TheGreatSkeleton = {
		Health = 450, 
		Damage = 25, 
		Speed = 10,
		FollowRange = 60, 
		StopRange = 15,
		AttackDist = 15,
		AttackRate = 0.55,
		ComboResetTime = 1.2,
		PatrolRadius = 30,
		xp = 130,
		respawnTime = 200,
		reward = 5500,
		PostureDamage = 35,
		AggressionLevel = 1, 
		BlockDmgReduction = 1,
		BlockPostureOnHit = 20,
		CritChance = 0.35,
		FeintChance = 0.25,
		Anims = {
			M1 = "rbxassetid://91401695466601",
			M2 = "rbxassetid://82141550254555",
			M3 = "rbxassetid://137520384257449",
			Walk = "rbxassetid://102166523559299",
			Idle = "rbxassetid://131856234142576",
			Block = "rbxassetid://101306228488116"
		}
	},
}

return MobSettings
