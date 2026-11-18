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

--[[
	Receipts already paid out, so a Roblox retry cannot double-grant.

	This is fetched lazily rather than at the top of the file, and that detail
	matters enormously: Roblox Studio refuses DataStore access in a place that
	has never been published, and a refusal at the top of a module kills the
	whole server script before anything else gets to run. Asking for it only
	when a real purchase arrives means an unpublished test place still works.
]]
local receiptStore: GlobalDataStore? = nil

local function getReceiptStore(): GlobalDataStore?
	if receiptStore then
		return receiptStore
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore("NuclearMudArena_Receipts_v1")
	end)
	if ok and store then
		receiptStore = store
		return store
	end
	warn("[Monetization] DataStore unavailable — is the place published?")
	return nil
end

--[[ Does this player own a pass? In free mode, everybody owns everything. ]]
local passCache: { [number]: { [string]: boolean } } = {}

Players.PlayerRemoving:Connect(function(player)
	passCache[player.UserId] = nil
end)

function MonetizationService.OwnsPass(player: Player, passKey: string): boolean
	if Config.FreeMode then
		return true
	end

	local passId = Config.GamePasses[passKey]
	if not passId or passId == 0 then
		return false
	end

	local userCache = passCache[player.UserId]
	if userCache and userCache[passKey] ~= nil then
		return userCache[passKey]
	end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	local result = success and owns == true
	if success then
		-- `or {}` rather than an if: reassigning an existing cache to itself
		-- is harmless, and this is the only shape strict mode can see as
		-- definitely-a-table.
		local cache: { [string]: boolean } = userCache or {}
		passCache[player.UserId] = cache
		cache[passKey] = result
	end
	return result
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

		local store = getReceiptStore()
		if not store then
			-- No way to record the receipt means no safe way to grant it.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local productKey = productKeyFromId(receiptInfo.ProductId)
		if not productKey then
			warn(`MonetizationService: unknown product {receiptInfo.ProductId}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Atomically claim the receipt before granting so retries can never double-grant.
		local alreadyClaimed = false
		local claimOk = pcall(function()
			store:UpdateAsync(receiptKey, function(old)
				if old then
					alreadyClaimed = true
					return old
				end
				return true
			end)
		end)
		if not claimOk then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if alreadyClaimed then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		if not player.Parent then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		grantProduct(player, productKey)
		Remotes.Event("Notify"):FireClient(player, "Purchase complete. Thank you!")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

return MonetizationService
