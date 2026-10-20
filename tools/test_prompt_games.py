"""Complete bargaining episodes through the production language bridge."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import TextIO, cast

WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)
ROOT = Path(__file__).resolve().parents[1]


def play(bridge: Path, variant: str, seed: int, wording: str, prompt_seed: int) -> list:
    process = subprocess.Popen(
        [str(bridge), str(ROOT / "coworld_manifest_template.json"), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdin, stdout, stderr = (
        cast(TextIO, process.stdin),
        cast(TextIO, process.stdout),
        cast(TextIO, process.stderr),
    )

    def request(body: dict) -> dict:
        stdin.write(json.dumps(body) + "\n")
        stdin.flush()
        line = stdout.readline()
        assert line, stderr.read()
        return json.loads(line)

    obs = request(
        {
            "kind": "reset",
            "players": 3,
            "seed": seed,
            "promptVariant": wording,
            "promptSeed": prompt_seed,
            "split": "evaluation",
        }
    )
    selected = WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
    transcript = []
    notes = {}
    while obs["kind"] != "terminal":
        system, user = (message["content"] for message in obs["messages"])
        view = obs["semantic_view"]
        metadata = view.pop("prompt_template")
        assert metadata == {
            "bank": "negotiation-games-rules-v2",
            "variant": selected,
            "selection": wording,
            "seed": prompt_seed,
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
            "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
        }
        assert view["notes"] == notes.get(obs["seat"], "")
        for seat, private in notes.items():
            if seat != obs["seat"]:
                assert private not in user and private not in json.dumps(
                    view, ensure_ascii=False
                )
        teacher = request({"kind": "teacher"})
        action = json.loads(teacher["response"])
        action["notes"] = f"PRIVATE-{obs['seat']}-秘密🦉-{obs['decision_id']}"
        action["message"] = "Public bargain 🦉"
        response = request(
            {
                "kind": "step",
                "decision_id": obs["decision_id"],
                "response": json.dumps(action, ensure_ascii=False),
            }
        )
        assert response["kind"] == "accepted" and response["action"] == action
        notes[obs["seat"]] = action["notes"]
        transcript.append((obs, teacher, action))
        obs = response["observation"]
    transcript.append(obs)
    stdin.close()
    assert process.wait(timeout=30) == 0, stderr.read()
    return transcript


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bridge", type=Path)
    args = parser.parse_args()
    count = 0
    for variant in ("standard", "sprint"):
        for seed in (1,):
            canonical = None
            for wording, prompt_seed in [(w, 0) for w in WORDINGS] + [("mixed", 4)]:
                transcript = play(args.bridge, variant, seed, wording, prompt_seed)
                for row in transcript[:-1]:
                    row[0]["messages"][0]["content"] = row[0]["messages"][0][
                        "content"
                    ].split("OUTPUT FORMAT:", 1)[1]
                if canonical is None:
                    canonical = transcript
                else:
                    assert transcript == canonical, (
                        variant,
                        seed,
                        wording,
                        prompt_seed,
                    )
                count += 1
        print(
            variant,
            "complete games preserve rules, private views, Unicode actions and scores",
            flush=True,
        )
    for wording, split in (
        (wording, split)
        for wording in WORDINGS[-2:]
        for split in (None, "train", "typo")
    ):
        result = subprocess.run(
            [
                str(args.bridge),
                str(ROOT / "coworld_manifest_template.json"),
                "standard",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 3,
                    "seed": 1,
                    **({"split": split} if split is not None else {}),
                    "promptVariant": wording,
                }
            )
            + "\n",
            check=False,
            capture_output=True,
            text=True,
        )
        assert (
            result.returncode != 0
            and "held-out wording requires an explicit evaluation split" in result.stderr
        )
    print(f"PASS {count} complete bargaining games", flush=True)


if __name__ == "__main__":
    main()
