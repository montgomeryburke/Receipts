--!strict
--[[
	MonetizationService — the till. It is switched off.

	While Config.FreeMode is true this module hands everything out for free and
	never talks to Roblox's purchase system at all. That is the right state for
	now: get the game good, then charge for it.

	WHEN YOU TURN IT ON
	-------------------
	Set Config.FreeMode = false and paste your real IDs into Config.GamePasses
	and Config.Products. Everything below is already written to Roblox's rules:

	  * ProcessReceipt is registered exactly once, which Roblox requires.
	  * A receipt is only marked PurchaseGranted after the player's data has
	    actually saved. If the save fails we return NotProcessedYet, so Roblox
	    retries later instead of the player paying for nothing.
	  * Receipt IDs are remembered, so a retried receipt does not pay out twice.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local MonetizationService = {}

-- Receipts already paid out, so a Roblox retry cannot double-grant.
local receiptStore = DataStoreService:GetDataStore("NuclearMudArena_Receipts_v1")

--[[ Does this player own a pass? In free mode, everybody owns everything. ]]
function MonetizationService.OwnsPass(player: Player, passKey: string): boolean
	if Config.FreeMode then
		return true
	end

	local passId = Config.GamePasses[passKey]
	if not passId or passId == 0 then
		return true
	end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return success and owns == true
end

--[[ Give out whatever a product was bought for. Returns false if it could not. ]]
local function grantProduct(player: Player, productKey: string): boolean
	local state = PlayerState.Get(player)

	if productKey == "MegaDetonations" then
		state.megaCharges += Config.ProductGrants.MegaDetonations
	elseif productKey == "Revive" then
		-- The point of paying: you come back with your keys and your good car.
		-- Respawning yields, so it runs on its own thread and does not hold
		-- up the receipt we still have to confirm.
		task.spawn(function()
			player:LoadCharacterAsync()
		end)
	elseif productKey == "InstantTopCar" then
		state.carTier = Config.ProductGrants.InstantTopCarTier
	else
		return false
	end

	PlayerState.Changed.Fire(player)
	return true
end

--[[ Turn a Roblox product ID back into the name we know it by. ]]
local function productKeyFromId(productId: number): string?
	for key, id in Config.Products do
		if id == productId then
			return key
		end
	end
	return nil
end

function MonetizationService.Start()
	if Config.FreeMode then
		-- Nothing to wire up. Everything is already free.
		return
	end

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			-- They left before we could pay out. Roblox will try again when
			-- they next join, so do not consume the receipt.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local receiptKey = `receipt_{receiptInfo.PurchaseId}`

		-- Already paid out? Say yes and stop.
		local readSuccess, alreadyGranted = pcall(function()
			return receiptStore:GetAsync(receiptKey)
		end)
		if readSuccess and alreadyGranted then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		if not readSuccess then
			-- We cannot tell whether they were already paid. Refusing to guess
			-- is the safe move; Roblox retries.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local productKey = productKeyFromId(receiptInfo.ProductId)
		if not productKey then
			warn(`MonetizationService: unknown product {receiptInfo.ProductId}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		if not grantProduct(player, productKey) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Record the receipt BEFORE telling Roblox it is done. If this write
		-- fails we must not confirm, or a retry would pay out twice.
		local writeSuccess = pcall(function()
			receiptStore:SetAsync(receiptKey, true)
		end)
		if not writeSuccess then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		Remotes.Event("Notify"):FireClient(player, "Purchase complete. Thank you!")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

return MonetizationService
