import std/[json, os]
import negotiation/qualification
let args = commandLineParams()
doAssert args.len == 2, "usage: check_episode TRAJECTORY REPLAY"
verifyEpisode(readFile(args[0]), parseFile(args[1]))
echo "complete episode qualified"
