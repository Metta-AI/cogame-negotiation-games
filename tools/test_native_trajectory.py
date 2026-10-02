"""Qualify native request/response, retry, fallback, privacy, and replay joins."""
import json
import re
import sys
from pathlib import Path

binary, output, revision, sdk = sys.argv[1:]
sys.path.insert(0, str(Path(sdk) / "tools"))
from native_fixture import qualify

def action(user):
    return {"action": "accept"} if "ACCEPT IS LEGAL NOW: yes" in user else {"action": "offer", "take": {"books":0,"hats":0,"balls":0}}

qualify(binary, {'seed': 17, 'sampled': True, 'turnDelayMs': 0, 'player_connect_timeout_seconds': 3, 'episodeTimeoutSeconds': 120, 'maxOutputTokens': 900, 'llmTimeoutSeconds': 5, 'tokens': ['0', '1', '2'], 'players': [{'name': 'fixture-0'}, {'name': 'fixture-1'}, {'name': 'fixture-2'}], 'matches': 3, 'maxTurns': 2}, action, output, revision)
