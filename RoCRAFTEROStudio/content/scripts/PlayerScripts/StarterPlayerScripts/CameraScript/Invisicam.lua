-- Invisicam Version 2.5 (Occlusion Series)
-- For the latest standalone version see id=183837794
-- OnlyTwentyCharacters

local Invisicam = {}

---------------
-- Constants --
---------------

local FADE_TARGET = 0.75
local FADE_RATE = 0.1

local MODE = {
	CUSTOM = 1, -- Whatever you want!
	LIMBS = 2, -- Track limbs
	MOVEMENT = 3, -- Track movement
	CORNERS = 4, -- Char model corners
	CIRCLE1 = 5, -- Circle of casts around character
	CIRCLE2 = 6, -- Circle of casts around character, camera relative
	LIMBMOVE = 7, -- LIMBS mode + MOVEMENT mode
}

Invisicam.MODE = MODE

local STARTING_MODE = MODE.LIMBS

local LIMB_TRACKING_SET = {
	['Head'] = true,
	['Left Arm'] = true,
	['Right Arm'] = true,
	['Left Leg'] = true,
	['Right Leg'] = true,
	['LeftLowerArm'] = true,
	['RightLowerArm'] = true,
	['LeftLowerLeg'] = true,
	['RightLowerLeg'] = true
}

local CORNER_FACTORS = {
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, -1, -1),
	Vector3.new(-1, 1, -1)
}

local CIRCLE_CASTS = 10
local MOVE_CASTS = 3

---------------
-- Variables --
---------------

local RunService = game:GetService('RunService')
local PlayersService = game:GetService('Players')
local Player = PlayersService.LocalPlayer

local Camera = nil
local Character = nil
local Torso = nil

local Mode = nil
local BehaviorFunction = nil

local childAddedConn = nil
local childRemovedConn = nil

local Behaviors = {} -- Map of modes to behavior fns
local SavedHits = {} -- Objects currently being faded in/out
local TrackedLimbs = {} -- Used in limb-tracking casting modes

---------------
--| Utility |--
---------------

local math_min = math.min
local math_max = math.max
local math_cos = math.cos
local math_sin = math.sin
local math_pi = math.pi

local Vector3_new = Vector3.new

local function AssertTypes(param, ...)
	local allowedTypes = {}
	local typeString = ''
	for _, typeName in pairs({...}) do
		allowedTypes[typeName] = true
		typeString = typeString .. (typeString == '' and '' or ' or ') .. typeName
	end
	local theType = type(param)
	assert(allowedTypes[theType], typeString .. " type expected, got: " .. theType)
end

-----------------------
--| Local Functions |--
-----------------------

local function LimbBehavior(castPoints)
	for limb, _ in pairs(TrackedLimbs) do
		castPoints[#castPoints + 1] = limb.Position
	end
end

local function MoveBehavior(castPoints)
	for i = 1, MOVE_CASTS do
		local position, velocity = Torso.Position, Torso.Velocity
		local horizontalSpeed = Vector3_new(velocity.X, 0, velocity.Z).Magnitude / 2
		local offsetVector = (i - 1) * Torso.CFrame.lookVector * horizontalSpeed
		castPoints[#castPoints + 1] = position + offsetVector
	end
end

local function CornerBehavior(castPoints)
	local cframe = Torso.CFrame
	local centerPoint = cframe.p
	local rotation = cframe - centerPoint
	local halfSize = Character:GetExtentsSize() / 2 --NOTE: Doesn't update w/ limb animations
	castPoints[#castPoints + 1] = centerPoint
	for i = 1, #CORNER_FACTORS do
		castPoints[#castPoints + 1] = centerPoint + (rotation * (halfSize * CORNER_FACTORS[i]))
	end
end

local function CircleBehavior(castPoints)
	local cframe = nil
	if Mode == MODE.CIRCLE1 then
		cframe = Torso.CFrame
	else
		local camCFrame = Camera.CoordinateFrame
		cframe = camCFrame - camCFrame.p + Torso.Position
	end
	castPoints[#castPoints + 1] = cframe.p
	for i = 0, CIRCLE_CASTS - 1 do
		local angle = (2 * math_pi / CIRCLE_CASTS) * i
		local offset = 3 * Vector3_new(math_cos(angle), math_sin(angle), 0)
		castPoints[#castPoints + 1] = cframe * offset
	end
end

local function LimbMoveBehavior(castPoints)
	LimbBehavior(castPoints)
	MoveBehavior(castPoints)
end

local function OnCharacterAdded(character)
	if childAddedConn then
		childAddedConn:disconnect()
		childAddedConn = nil
	end
	if childRemovedConn then
		childRemovedConn:disconnect()
		childRemovedConn = nil
	end

	Character = character
	
	TrackedLimbs = {}
	local function childAdded(child)
		if child:IsA('BasePart') and LIMB_TRACKING_SET[child.Name] then
			TrackedLimbs[child] = true
		end
	end
	
	local function childRemoved(child)
		TrackedLimbs[child] = nil
	end	
	
	childAddedConn = character.ChildAdded:connect(childAdded)
	childRemovedConn = character.ChildRemoved:connect(childRemoved)
	
	for _, child in pairs(Character:GetChildren()) do
		childAdded(child)
	end
end

local function OnWorkspaceChanged(property)
	if property == 'CurrentCamera' then
		local newCamera = workspace.CurrentCamera
		if newCamera then
			Camera = newCamera
		end
	end
end

-----------------------
-- Exposed Functions --
-----------------------

-- Update. Called every frame after the camera movement step
function Invisicam:Update()
	-- Make sure we still have a Torso
	if not Torso then
		local humanoid = Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Torso then
			Torso = humanoid.Torso
		else
			-- Not set up with Humanoid? Try and see if there's one in the Character at all:
			Torso = Character:FindFirstChild("HumanoidRootPart")
			if not Torso then
				-- Bail out, since we're relying on Torso existing
				return
			end
		end
		local ancestryChangedConn;
		ancestryChangedConn = Torso.AncestryChanged:connect(function(child, parent)
			if child == Torso and not parent then 
				Torso = nil
				if ancestryChangedConn and ancestryChangedConn.Connected then
					ancestryChangedConn:Disconnect()
					ancestryChangedConn = nil
				end
			end
		end)
	end

	-- Make a list of world points to raycast to
	local castPoints = {}
	BehaviorFunction(castPoints)
	
	-- Cast to get a list of objects between the camera and the cast points
	local currentHits = {}
	local ignoreList = {Character}
	local function add(hit)
		currentHits[hit] = true
		if not SavedHits[hit] then
			SavedHits[hit] = hit.LocalTransparencyModifier
		end
	end

	local hitParts = Camera:GetPartsObscuringTarget(castPoints, ignoreList)
	for i = 1, #hitParts do
		local hitPart = hitParts[i]
		add(hitPart)
		for _, child in pairs(hitPart:GetChildren()) do
			if child:IsA('Decal') or child:IsA('Texture') then
				add(child)
			end
		end
	end
	
	-- Fade out objects that are in the way, restore those that aren't anymore
	for hit, originalFade in pairs(SavedHits) do
		local currentFade = hit.LocalTransparencyModifier
		if currentHits[hit] then -- Fade
			if currentFade < FADE_TARGET then
				hit.LocalTransparencyModifier = math_min(currentFade + FADE_RATE, FADE_TARGET)
			end
		else -- Restore
			if currentFade > originalFade then
				hit.LocalTransparencyModifier = math_max(originalFade, currentFade - FADE_RATE)
			else
				SavedHits[hit] = nil
			end
		end
	end
end

function Invisicam:SetMode(newMode)
	AssertTypes(newMode, 'number')
	for modeName, modeNum in pairs(MODE) do
		if modeNum == newMode then
			Mode = newMode
			BehaviorFunction = Behaviors[Mode]
			return
		end
	end
	error("Invalid mode number")
end

function Invisicam:SetCustomBehavior(func)
	AssertTypes(func, 'function')
	Behaviors[MODE.CUSTOM] = func
	if Mode == MODE.CUSTOM then
		BehaviorFunction = func
	end
end

-- Want to turn off Invisicam? Be sure to call this after.
function Invisicam:Cleanup()
	for hit, originalFade in pairs(SavedHits) do
		hit.LocalTransparencyModifier = originalFade
	end
end

---------------------
--| Running Logic |--
---------------------

-- Connect to the current and all future cameras
workspace.Changed:connect(OnWorkspaceChanged)
OnWorkspaceChanged('CurrentCamera')

Player.CharacterAdded:connect(OnCharacterAdded)
if Player.Character then
	OnCharacterAdded(Player.Character)
end

Behaviors[MODE.CUSTOM] = function() end -- (Does nothing until SetCustomBehavior)
Behaviors[MODE.LIMBS] = LimbBehavior
Behaviors[MODE.MOVEMENT] = MoveBehavior
Behaviors[MODE.CORNERS] = CornerBehavior
Behaviors[MODE.CIRCLE1] = CircleBehavior
Behaviors[MODE.CIRCLE2] = CircleBehavior
Behaviors[MODE.LIMBMOVE] = LimbMoveBehavior

Invisicam:SetMode(STARTING_MODE)

return Invisicam
