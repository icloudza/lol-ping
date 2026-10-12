#!/bin/bash
# Copies the ping/emote assets LolPing ships from a checkout of https://github.com/darrenprx/lolPing.
# Usage: Scripts/import-assets.sh /path/to/lolPing
# The textures, sounds and emotes are © Riot Games (see the upstream LICENSE); they are not covered by this project's licence.
set -euo pipefail

SRC="${1:?usage: import-assets.sh /path/to/lolPing}"
DST="$(cd "$(dirname "$0")/.." && pwd)/App/Resources"

TEXTURES=(pingwheel_retreatrender push pingwheel_pushrender omw all_in pingwheel_allin_render_01 pingwheel_allin_render_02
  assist_me need_vision enemy_missing enemy_vision pingwheel_enemyvisionrender generic_ping pingwheel_basicpingrender
  pingwheel_baitrender vision_cleared pingwheel_visionclearedrender)
SOUNDS=(SRP_12 SRP_9 OnMyWay SRP_4 ComeHere SRP_7 MIA AreaIsWarded Base SRP_11 SRP_6 button)

rm -rf "$DST/textures" "$DST/sounds" "$DST/emotes"
mkdir -p "$DST/textures" "$DST/sounds" "$DST/emotes"

for t in "${TEXTURES[@]}"; do cp "$SRC/assets/textures/$t.png" "$DST/textures/"; done
for s in "${SOUNDS[@]}"; do cp "$SRC/assets/sounds/$s.wav" "$DST/sounds/"; done

# Emotes: the animation and icon as they are; the Ogg Opus sound becomes AAC in an .m4a,
# which Core Audio reads on every macOS this app supports (Ogg is only read by recent ones).
for webp in "$SRC"/assets/emotes/*.webp; do
  slug="$(basename "$webp" .webp)"
  cp "$webp" "$SRC/assets/emotes/$slug.png" "$DST/emotes/"
  if [ -f "$SRC/assets/emotes/$slug.ogg" ]; then
    ffmpeg -nostdin -loglevel error -y -i "$SRC/assets/emotes/$slug.ogg" -c:a aac -b:a 96k "$DST/emotes/$slug.m4a"
  fi
done

echo "textures: $(ls "$DST/textures" | wc -l | tr -d ' ')  sounds: $(ls "$DST/sounds" | wc -l | tr -d ' ')  emotes: $(ls "$DST/emotes"/*.webp | wc -l | tr -d ' ')"
