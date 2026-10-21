-- Frontend witness for the 4D Sports Boxing package: the project's movie
-- plays inside Chimera to a frame count, then the memory domains are hashed
-- for the gate to compare with the native reference's, and the game.*
-- functions are tried against the same bytes.
--
-- The job comes from the file named by MINIHAWK_JOB:
--   frames=<the frame count to stop at>
--   meta=<path for the result>
--   save=<1: save the project at the end>
--   props=<1: try the game.* functions>
--   health=<Blue.Health's offset in Conventional Memory, as the native
--           reference read it from the core's property table>

local meta = {}
local function finish(status, detail)
	local lines = { "status=" .. status, "detail=" .. (detail or "") }
	for k, v in pairs(meta) do
		if k ~= "path" then lines[#lines + 1] = k .. "=" .. tostring(v) end
	end
	table.sort(lines)
	if meta.path then
		local f = assert(io.open(meta.path, "wb"))
		f:write(table.concat(lines, "\n") .. "\n")
		f:close()
	end
	client.exit()
end

local job = {}
for line in io.lines(os.getenv("MINIHAWK_JOB")) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end
meta.path = job.meta

if emu.getsystemid() ~= "4DSportsBoxing" then finish("ERROR", "wrong system id: " .. tostring(emu.getsystemid())) end

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

-- to the frame count asked for, whichever frame the project opened at (a
-- project run pauses at the end of its movie, so one frame more never comes)
local frames = tonumber(job.frames) or 100
while emu.framecount() < frames do
	emu.frameadvance()
end
meta.frames = emu.framecount()
meta.lag = emu.lagcount()

for key, domain in pairs({ gs = "Game State", cm = "Conventional Memory", vm = "Video Memory" }) do
	memory.usememorydomain(domain)
	meta["hash_" .. key] = memory.hash_region(0, memory.getcurrentmemorydomainsize(), domain)
end

if job.save == "1" then
	local ok, err = pcall(function() movie.save() end)
	meta.saved = ok and "1" or tostring(err)
end

if job.props == "1" then
	if game == nil or game.list == nil then
		meta.game_list = "absent"
	else
		local ok, err = pcall(function()
			local at = tonumber(job.health)
			meta.game_list = #game.list()
			meta.health = game.get("Blue.Health")
			meta.health_bytes = memory.read_s16_le(at, "Conventional Memory")
			meta.health_set = tostring(game.set("Blue.Health", 4321))
			meta.health_after = game.get("Blue.Health")
			meta.health_bytes_after = memory.read_s16_le(at, "Conventional Memory")
			meta.frame_set = tostring(game.set("Frame", 5))
			meta.unknown = tostring(game.get("No Such Property"))
			meta.question = game.get("Manual Question.Boxer")
			meta.question_label = tostring(game.describe("Manual Question.Boxer").label)
		end)
		if not ok then meta.game_error = tostring(err) end
	end
end

finish("OK", "")
