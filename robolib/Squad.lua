require("config.config")
require("util")
require("robolib.util")
require("stdlib/log/logger")
require("stdlib/game")
require("prototypes.DroidUnitList")


commands = {
	assemble = 1,   -- starting state, and post-retreat/pre-hunt state
	move = 2,       -- not really useful, don't use this much..
	follow = 3,     -- when set, the SQUAD_AI function should command the squad/s to follow player
	guard = 4,      -- when set, the SQUAD_AI function should command squad to stay around
	patrol = 5,     -- when set, SQUAD_AI will deal with moving them sequentially from patrol point A to B
	hunt = 6,       -- when set, SQUAD_AI will send to nearest enemy
}

global.SquadTemplate = {squadID= 0, player=true, unitGroup = true, members = {size = 0}, home = true, force = true, surface = true, radius=DEFAULT_SQUAD_RADIUS, patrolPoint1 = true, patrolPoint2 = true, currentCommand = "none"} -- this is the empty squad table template

global.patrolState = {lastPole = nil,currentPole = nil,nextPole = nil,movingToNext = false}


function createNewSquad(tableIN, player, entity)

    if not global.uniqueSquadId then
        global.uniqueSquadId = {}
    end

    if not (global.uniqueSquadId[entity.force.name])  then
        global.uniqueSquadId[entity.force.name] = 1
    end

    --get next unique ID number and increment it
    local squadRef = global.uniqueSquadId[entity.force.name]
    global.uniqueSquadId[entity.force.name] = global.uniqueSquadId[entity.force.name] + 1

    local newsquad = shallowcopy(global.SquadTemplate)

    newsquad.player = player
    newsquad.force = entity.force
    newsquad.home = entity.position
    newsquad.surface = entity.surface
    newsquad.unitGroup = entity.surface.create_unit_group({position=entity.position, force=entity.force}) --use the entity who is causing the new squad to be formed, for position.
    newsquad.squadID = squadRef
    newsquad.patrolPoint1 = newsquad.home
    newsquad.patrolPoint2 = newsquad.home
    newsquad.members = {size = -1}
    newsquad.command = commands.assemble

    tableIN[squadRef] = newsquad

    local tick = getLeastFullTickTable(entity.force) --get the least utilised tick in the tick table

    table.insert(global.updateTable[entity.force.name][tick], squadRef) --insert this squad reference to the least used tick for running its AI
    LOGGER.log(string.format( "Added squadref %d for AI update to tick table index %d", squadRef, tick) )
    return squadRef
end


-- add member using the appropriate squad table reference
-- probably obtained by them being the nearest squad to the player,
-- or when a fresh squad is spawned
function addMemberToSquad(squad, soldier)
	if squad and soldier then
		table.insert(squad.members, soldier)
		squad.unitGroup.add_member(soldier)
		--catch for initial condition
		if (squad.members.size == -1) then
			squad.members.size = 0
		end

		squad.members.size = squad.members.size + 1
	else
		Game.print_force(soldier.force.name, "Tried to addMember to invalid table!")
	end
end


function mergeSquads(squadA, squadB)
	-- confirm that these can reasonably be merged
	if squadA.player ~= squadB.player or
		squadA.force ~= squadB.force
	then return nil end

	squadB.unitGroup.destroy()  -- do this first to see if it helps us move members over
	for key, soldier in pairs(squadB.members) do
		if key ~= "size" then
			if soldier and soldier.valid then
				addMemberToSquad(squadA, soldier)
			end
		end
	end

	checkMembersAreInGroup(squadA)
	deleteSquad(squadB)
	return squadA
end


--input is table of squads (global.Squads[force.name]), and player to find closest to
function getClosestSquad(tableIN, player, maxRange)

    local leastDist = maxRange
    local leastDistSquadID = nil

    for key, squad in pairs(tableIN) do
        --player.print("checking soldiers are in unitgroup...")
        checkMembersAreInGroup(squad)
        local distance = util.distance(player.position, squad.unitGroup.position)
        if distance <= leastDist then
            leastDistSquadID = squad.squadID
            leastDist = distance
        end

    end

    if (leastDist == maxRange or leastDistSquadID == nil) then
        --player.print("getClosestSquad - no squad found or squad too far away")
        return nil
    end

    --player.print(string.format("closest squad found: %d tiles away from player", leastDist))
    return leastDistSquadID
end


--input is table of squads (global.Squads[force.name]), and position to find closest to
function getClosestSquadToPos(tableIN, position, maxRange, ignore_squad, only_with_squad_command)

    local leastDist = maxRange
	local closest_squad = nil

    for key, squad in pairs(tableIN) do
        if squad and squad.unitGroup and squad.unitGroup.valid then
			if ignore_squad and squad == ignore_squad then
				goto continue
			end
			if only_with_squad_command and only_with_squad_command ~= squad.command then
				goto continue
			end
            local distance = util.distance(position, squad.unitGroup.position)
            if distance <= leastDist then
                closest_squad = squad
                leastDist = distance
            end
        end
		::continue::
    end

    if (leastDist >= maxRange or closest_squad == nil) then
        LOGGER.log("getClosestSquadToPos - no squad found or squad too far away")
        return nil
    end

    --game.players[1].print(string.format("closest squad found: %d tiles away from given position, ID %d", leastDist, leastDistSquadID))
    return closest_squad
end


-- checks that all entities in the "members" sub table are present in the unitgroup
function checkMembersAreInGroup(squad)
    if not squad then LOGGER.log("tried to check a squad that doesn't exist!") return end
    -- removeNilsFromTable(squad.members)

    --make sure the unitgroup is even available, if it's not there for some reason, create it.
    if not squad.unitGroup or not squad.unitGroup.valid then
        --LOGGER.log("unitgroup was invalid, making a new one")
        local pos
        for key, unit in pairs(squad.members) do
            if key ~= "size" and unit and unit.valid then
                pos = unit.position
            end
        end

        if pos ~= nil then
            local surface = getSquadSurface(squad)
            squad.unitGroup = surface.create_unit_group({position=pos, force=squad.force})
        else
            return --gtfo, there is something wrong here
        end
    end

    ::retryCheckMembership::
    for key, soldier in pairs(squad.members) do

        if(key ~= "size") then
            if not soldier then
                table.remove(squad.members, key)
            elseif not table.contains(squad.unitGroup.members, soldier) then
                if soldier.valid then

                    if soldier.surface == squad.unitGroup.surface then
                        --tableIN.player.print(string.format("adding soldier to squad ID %d's unitgroup", tableIN.squadID))
                        squad.unitGroup.add_member(soldier)
                    else
                        --LOGGER.log("Destroying unit group, and creating a replacement on the correct surface")
                        squad.unitGroup.destroy()
                        soldier.surface.create_unit_group({position=soldier.position, force=soldier.force})
                        --goto retryCheckMembership
                    end
                else
                    --LOGGER.log(string.format("removing member from squad id %d member list", tableIN.squadID))
                    table.remove(squad.members, key)
                end
            end
        end
    end

    --now that we've been removing and adding members, lets do a re-count of squad members.
    squad.members.size = table.countValidElements(squad.members) -- refresh the member count in the squad to accurately reflect the number of soldiers in there.
end


function trimSquad(squad, print_msg)
    if squad then
        --player.print(string.format("squad %s, id %d, member size %d", squad, squad.squadID, squad.members.size))
        local removeThisSquad = true
		if squad.members then
			-- removeNilsFromTable(squad.members)
			squad.numMembers = table.countValidElements(squad.members)
			if squad.numMembers > 0 then removeThisSquad = false end
		end

        if removeThisSquad then
			deleteSquad(squad, print_msg)
			return false
		end
    end
	return true
end


function deleteSquad(squad, print_msg)
	print_msg = print_msg or PRINT_SQUAD_DEATH_MESSAGES  -- default value for argument

	squad.members = nil -- get rid of members table first

	if squad.unitGroup and squad.unitGroup.valid then
		squad.unitGroup.destroy()
	end
	if squad.unitGroup then squad.unitGroup = nil end

	if print_msg == 1 then
		-- using stdlib, print message to entire force
		Game.print_force(squad.force, string.format("Squad %d is no more...", squad.squadID))
	end
	LOGGER.log(string.format("Squad id %d from force %s has died/lost all its members...", squad.squadID, squad.force.name))

	-- table.remove(global.Squads[squadForce.name], squad.squadID)
	global.Squads[squad.force.name][squad.squadID] = nil  --set the entire squad itself to nil
	-- removeNilsFromTable(global.Squads[squad.force.name])
end


function trimSquads(forces)
    for _, force in pairs(forces) do
        if global.Squads and global.Squads[force.name] then
            for key, squad in pairs(global.Squads[force.name]) do
				trimSquad(squad)
            end
        end
    end
end


function revealChunksBySquad(squad)
    if squad and squad.unitGroup and squad.unitGroup.valid then
        if squad.members.size > 0 then  --if there are troops in a valid group in a valid squad.
            local position = squad.unitGroup.position

            --this area should give approx 3x3 chunks revealed
            local area = {left_top = {position.x-32, position.y-32}, right_bottom = {position.x+32, position.y+32}}

            local surface = getSquadSurface(squad)

            if not surface then
                LOGGER.log(string.format("ERROR: Surface for squad ID %d is missing or can't be determined! revealSquadChunks", squad.squadID))
                return
            end
            squad.force.chart(surface, area) --reveal the chunk they are in.
        end
    end
end


function grabArtifactsBySquad(squad)
    local force = squad.force
    local chest = global.lootChests[force.name]
    if not chest or not chest.valid then return end

    if squad and squad.unitGroup and squad.unitGroup.valid then
        if squad.members.size > 0 then  --if there are troops in a valid group in a valid squad.
            local surface = getSquadSurface(squad)
            if not surface then
                LOGGER.log(string.format("ERROR: Surface for squad ID %d is missing or can't be determined! grabArtifacts", squad.squadID))
                return
            end

            local position = squad.unitGroup.position
            local areaToCheck = {left_top = {position.x-ARTIFACT_GRAB_RADIUS, position.y-ARTIFACT_GRAB_RADIUS}, right_bottom = {position.x+ARTIFACT_GRAB_RADIUS, position.y+ARTIFACT_GRAB_RADIUS}}
            local itemList = surface.find_entities_filtered{area=areaToCheck, type="item-entity"}
            local artifactList = {}
            for _, item in pairs(itemList) do
                if item.valid and item.stack.valid then

                    if string.find(item.stack.name,"artifact") then
                        table.insert(artifactList, {name = item.stack.name, count = item.stack.count}) --inserts the LuaSimpleStack table (of name and count) to the artifacts list for later use

                        item.destroy()

                    end
                end
            end

            if artifactList ~= {} then
                --player.print(string.format("Squad ID %d found %d artifacts!", squad.squadID , artifactCount))
                --player.insert({name="alien-artifact", count = artifactCount})
                local cannotInsert = false
                for _, itemStack in pairs(artifactList) do
                    if(chest.can_insert(itemStack)) then
                        chest.insert(itemStack)
                    else
                        cannotInsert = true
                    end
                end
                if cannotInsert then
                    Game.print_force(force, "Your loot chest is too full! Cannot add more until there is room!")
                end
            end
        end
    end
end


function handleDroidSpawned(event)
    local entity = event.created_entity
    local player = game.players[event.player_index]
    local force = entity.force
    --player.print(string.format("Processing new entity %s spawned by player %s", entity.name, player.name) )
    local position = entity.position

    --if this is the first time we are using the player's tables, make it
    if not global.Squads[force.name] then
        global.Squads[force.name] = {}
    end

	local squadref = nil
    local closest_squad = getClosestSquadToPos(global.Squads[force.name], entity.position, SQUAD_CHECK_RANGE)
	if closest_squad then
		squadref = closest_squad.squadID
	end
    if(getSquadSurface(global.Squads[force.name][squadref]) ~= entity.surface) then
        squadref = nil  --we cannot allow a squad to be joined if it's on the wrong surface
    end

    if not squadref then
        --if we didnt find a squad nearby, create one
        squadref = createNewSquad(global.Squads[force.name], player, entity)
    end

    addMemberToSquad(global.Squads[force.name][squadref], entity)
    --checkMembersAreInGroup(global.Squads[player.force.name][squadref])

    --code to handle adding new member to a squad that is guarding/patrolling
    if event.guard == true then
        local squadOfInterest = global.Squads[force.name][squadref]
        if squadOfInterest.command ~= commands.guard then
            squadOfInterest.command = commands.guard
            squadOfInterest.home = event.guardPos
            --game.players[1].print(string.format("Setting guard squad to wander around %s", event.guardPos))

            --check if the squad it just joined is patrolling, if it is, don't force any more move commands because it will be disruptive!

            if not squadOfInterest.patrolState or (squadOfInterest.patrolState and squadOfInterest.patrolState.currentWaypoint == -1) then
                --Game.print_force(entity.force, "Setting move command to squad home..." )
                squadOfInterest.unitGroup.set_command({type=defines.command.wander, destination = squadOfInterest.home, distraction=defines.distraction.by_enemy})
                squadOfInterest.unitGroup.start_moving()
            end
        end
    end
end
