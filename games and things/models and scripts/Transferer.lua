game.ReplicatedFirst:RemoveDefaultLoadingScreen()
wait()
local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")

local Gui = script.LoadingGui:Clone()

Gui.Parent = PlayerGui
