// negotiation-games GAME BLOCK.
//
// This file is the game half only: the bargaining-table stage, the feed
// lines, the scorebug / endcard / matchbar / valuestrip painters and the
// NegChrome.register call that wires them into the inherited broadcast
// chrome (client/chrome_common.js, which owns the drivers, the feed
// renderer, the scrubber and the transport).
//
// It deliberately declares NO identifier that appears in NegChrome's export
// list — a hoisted `function markBeat` in the game block shadowed the chrome
// alias on cogame-tandem (2026-08-23) and CI greps for it. Everything the
// chrome provides is reached through `C.`.
//
// The state object it draws (one frame, from the Nim sim):
//   {seats:[{name,score,points,matches,deals,giveaway,fallbacks,role,notes} x3],
//    match, matches, matchesPlayed, kind, itemNames:["books","hats","balls"],
//    table: null | {a,b,opener,pool[3],values[2][3],turn,maxTurns,actor,
//                   standing:null|{side,take[3],worth[2]},
//                   offers:[{turn,side,take[3],worth[2],text,scripted}],
//                   messages[2], outcome:"open|deal|no_deal", payoff[2]},
//    phase, gameDone, reason}
// Spectators see BOTH seats' private valuations; the seats never do.
(function () {
  "use strict";

  var C = window.NegChrome;
  var HEX = C.COLOR_HEX;
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var ITEM_HEX = ["#c9603f", "#4f86c6", "#5fb36a"];
  var ITEM_SHORT = ["BOOKS", "HATS", "BALLS"];
  var FACE = "'rajdhani', system-ui, sans-serif";

  // ---- small helpers -------------------------------------------------------

  function negFont(px, weight) {
    return (weight || 600) + " " + Math.round(px) + "px " + FACE;
  }

  // Centred text, clamped so the whole measured box stays inside the canvas.
  // A canvas accepts a draw at a negative coordinate in silence, which is
  // how four speech bubbles became four slivers on cogchemists; the viewer
  // smoke's --strict-text-bounds is the gate and this is the guard.
  function negLabel(ctx, text, x, y, opts) {
    var o = opts || {};
    var w = ctx.canvas.width;
    var h = ctx.canvas.height;
    ctx.save();
    ctx.font = o.font || negFont(12);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    var px = Number((ctx.font.match(/(\d+)px/) || [0, 12])[1]) || 12;
    var label = C.ellipsize(ctx, String(text === undefined ? "" : text),
      Math.max(16, o.maxWidth || (w - 10)));
    var half = ctx.measureText(label).width / 2 + 2;
    var cx = Math.max(half + 3, Math.min(x, w - half - 3));
    var cy = Math.max(px * 0.7 + 3, Math.min(y, h - px * 0.7 - 3));
    if (o.shadow !== false) {
      ctx.shadowColor = "rgba(0,0,0,0.85)";
      ctx.shadowBlur = 4;
    }
    ctx.fillStyle = o.color || PAPER;
    ctx.fillText(label, cx, cy);
    ctx.restore();
    return label;
  }

  // ---- the remark band -----------------------------------------------------
  //
  // A seat's public remark is a SENTENCE, capped server-side at
  // MaxMessageLen runes (src/negotiation/sim.nim). Ellipsis is a design
  // choice for labels and a defect for sentences, so the remark is never
  // cut: it gets a band whose line count is measured from that cap in the
  // font it is drawn in, reserved whether or not anyone is speaking, and it
  // wraps inside it. The band's WIDTH is what the seat's half of the stage
  // allows; its HEIGHT and its font size are derived from the cap.
  var MAX_MESSAGE_RUNES = 200;

  // The worst case the cap admits: MAX_MESSAGE_RUNES of the widest glyph
  // this face draws, in words, so wrapping waste is measured too.
  var TALK_SAMPLE = (function () {
    var out = "";
    while (out.length < MAX_MESSAGE_RUNES) out += "MMMMMMMM ";
    return out.slice(0, MAX_MESSAGE_RUNES);
  })();

  // Greedy word wrap measured in the ctx's current font. A word wider than
  // the box is hard-split, so no text is ever dropped.
  function negWrapLines(ctx, text, maxWidth) {
    var words = String(text).split(/\s+/);
    var lines = [];
    var line = "";
    for (var i = 0; i < words.length; i++) {
      var word = words[i];
      if (!word) continue;
      while (word.length > 1 && ctx.measureText(word).width > maxWidth) {
        var cut = word.length;
        while (cut > 1 && ctx.measureText(word.slice(0, cut)).width > maxWidth) {
          cut -= 1;
        }
        if (line) { lines.push(line); line = ""; }
        lines.push(word.slice(0, cut));
        word = word.slice(cut);
      }
      var candidate = line ? line + " " + word : word;
      if (line && ctx.measureText(candidate).width > maxWidth) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    if (line) lines.push(line);
    return lines;
  }

  // How many lines the cap needs at `boxW`, and the largest font at which
  // they still fit in `maxHeight`. Nothing here is sized by eye.
  function negTalkBand(ctx, boxW, scale, maxHeight) {
    var px = 10.5 * scale;
    var lines = 1;
    ctx.save();
    for (var guard = 0; guard < 24; guard++) {
      ctx.font = negFont(px);
      lines = negWrapLines(ctx, TALK_SAMPLE, boxW).length;
      if (lines * px * 1.32 <= maxHeight || px <= 6) break;
      px -= 0.5;
    }
    ctx.restore();
    return {
      px: px, lineH: px * 1.32, lines: lines, height: lines * px * 1.32
    };
  }

  function negChip(ctx, text, x, y, accent, scale) {
    ctx.save();
    ctx.font = negFont(11 * scale, 700);
    var pad = 6 * scale;
    var bw = Math.min(ctx.measureText(text).width + pad * 2,
      ctx.canvas.width - 8);
    var bh = 17 * scale;
    var cx = Math.max(bw / 2 + 3, Math.min(x, ctx.canvas.width - bw / 2 - 3));
    var cy = Math.max(bh / 2 + 3, Math.min(y, ctx.canvas.height - bh / 2 - 3));
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    C.roundRect(ctx, cx - bw / 2, cy - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.restore();
    negLabel(ctx, text, cx, cy, {
      font: negFont(11 * scale, 700), color: INK, shadow: false,
      maxWidth: bw - pad
    });
  }

  // ---- item art (canvas primitives, never bare text) -----------------------

  function negBook(ctx, cx, cy, size) {
    var w = size * 0.72;
    var h = size;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.fillStyle = ITEM_HEX[0];
    ctx.strokeStyle = C.shade(ITEM_HEX[0], 0.5);
    ctx.lineWidth = Math.max(1, size * 0.06);
    C.roundRect(ctx, -w / 2, -h / 2, w, h, size * 0.09);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = "rgba(242, 232, 216, 0.9)";
    ctx.fillRect(w / 2 - size * 0.16, -h / 2 + size * 0.08,
      size * 0.11, h - size * 0.16);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.75)";
    ctx.lineWidth = Math.max(1, size * 0.05);
    ctx.beginPath();
    ctx.moveTo(-w / 2 + size * 0.14, -h * 0.18);
    ctx.lineTo(w / 2 - size * 0.26, -h * 0.18);
    ctx.moveTo(-w / 2 + size * 0.14, h * 0.05);
    ctx.lineTo(w / 2 - size * 0.26, h * 0.05);
    ctx.stroke();
    ctx.restore();
  }

  function negHat(ctx, cx, cy, size) {
    ctx.save();
    ctx.translate(cx, cy);
    ctx.fillStyle = ITEM_HEX[1];
    ctx.strokeStyle = C.shade(ITEM_HEX[1], 0.5);
    ctx.lineWidth = Math.max(1, size * 0.06);
    // crown
    C.roundRect(ctx, -size * 0.28, -size * 0.46, size * 0.56, size * 0.6,
      size * 0.1);
    ctx.fill();
    ctx.stroke();
    // brim
    ctx.beginPath();
    ctx.ellipse(0, size * 0.16, size * 0.5, size * 0.14, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
    // band
    ctx.fillStyle = "rgba(42, 31, 22, 0.45)";
    ctx.fillRect(-size * 0.28, -size * 0.02, size * 0.56, size * 0.12);
    ctx.restore();
  }

  function negBall(ctx, cx, cy, size) {
    ctx.save();
    ctx.beginPath();
    ctx.arc(cx, cy, size * 0.42, 0, Math.PI * 2);
    ctx.fillStyle = ITEM_HEX[2];
    ctx.fill();
    ctx.strokeStyle = C.shade(ITEM_HEX[2], 0.5);
    ctx.lineWidth = Math.max(1, size * 0.06);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx - size * 0.13, cy - size * 0.14, size * 0.13, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(242, 232, 216, 0.42)";
    ctx.fill();
    ctx.restore();
  }

  function negItem(ctx, type, cx, cy, size) {
    if (type === 0) negBook(ctx, cx, cy, size);
    else if (type === 1) negHat(ctx, cx, cy, size);
    else negBall(ctx, cx, cy, size);
  }

  // ---- stage ---------------------------------------------------------------

  function negShare(table, side) {
    // What `side` currently holds on the table: the standing offer's split
    // if one stands, otherwise nothing claimed yet.
    var pool = table.pool || [0, 0, 0];
    if (!table.standing) return null;
    var take = table.standing.take || [0, 0, 0];
    if (table.standing.side === side) return take.slice();
    return [pool[0] - take[0], pool[1] - take[1], pool[2] - take[2]];
  }

  function negCog(ctx, images, seat, index, x, y, size, opts) {
    var colour = C.seatColor(index);
    var sprite = images["soldier_" + colour + "_front.png"];
    ctx.save();
    ctx.globalAlpha = opts.dim ? 0.35 : 1;
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, x - size / 2, y - size / 2, size, size);
    } else {
      ctx.fillStyle = HEX[colour];
      ctx.fillRect(x - size / 3, y - size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();
    if (opts.acting) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(x, y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
  }

  function negPoolRow(ctx, x, y, w, counts, tint, scale, wrap) {
    // Draws one side's share as actual items. Icons never go below 10 px.
    var items = [];
    for (var t = 0; t < 3; t++) {
      for (var n = 0; n < (counts ? counts[t] : 0); n++) items.push(t);
    }
    if (!items.length) return;
    var rows = wrap ? 2 : 1;
    var perRow = Math.ceil(items.length / rows);
    var size = Math.max(10, Math.min(30 * scale,
      (w - 6) / Math.max(perRow, 1) - 4 * scale));
    var gap = size + 5 * scale;
    for (var i = 0; i < items.length; i++) {
      var row = Math.floor(i / perRow);
      var col = i % perRow;
      var count = Math.min(perRow, items.length - row * perRow);
      var cx = x + (col - (count - 1) / 2) * gap;
      var cy = y + (row - (rows - 1) / 2) * (size + 6 * scale);
      ctx.save();
      ctx.shadowColor = C.rgba(tint, 0.55);
      ctx.shadowBlur = 8 * scale;
      negItem(ctx, items[i], cx, cy, size);
      ctx.restore();
    }
  }

  // ---- transient effects ---------------------------------------------------
  //
  // The chrome hands the painter `view.effects.at[kind]`: when the newest
  // event of each kind landed, or null when it must not animate (a scrub
  // jump lands a whole prefix at once). `effectResetKinds: ["match"]` wipes
  // the table at the start of every match.

  function negAge(view, kind) {
    var at = view.effects && view.effects.at ? view.effects.at[kind] : null;
    if (!at) return -1;
    return Math.max(0, (view.now || Date.now()) - at);
  }

  // 1 once the entrance has played out — and immediately, when the chrome
  // says this event must not animate.
  function negEntrance(view, kind, ms) {
    var age = negAge(view, kind);
    if (age < 0) return 1;
    var t = Math.min(1, age / ms);
    return 1 - (1 - t) * (1 - t);
  }

  function negStamp(ctx, table, scale, entrance) {
    var w = ctx.canvas.width;
    var h = ctx.canvas.height;
    var deal = table.outcome === "deal";
    var payoff = table.payoff || [0, 0];
    ctx.save();
    // The stamp lands rather than blinks on, and then holds until the next
    // match's `match` event resets the effect table.
    ctx.globalAlpha = 0.15 + 0.85 * entrance;
    ctx.save();
    ctx.translate(w / 2, h * 0.5);
    ctx.rotate(-0.12);
    var bw = Math.min(w * 0.78, 460 * scale);
    var bh = Math.min(h * 0.42, 150 * scale);
    ctx.fillStyle = "rgba(18, 13, 9, 0.72)";
    ctx.strokeStyle = deal ? HEX.green : HEX.red;
    ctx.lineWidth = 5 * scale;
    C.roundRect(ctx, -bw / 2, -bh / 2, bw, bh, 10 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.restore();
    var lines = [];
    if (deal) {
      lines.push(payoff[0] + " – " + payoff[1]);
      var splitA = negShare(table, 0);
      var splitB = negShare(table, 1);
      if (splitA && splitB) {
        lines.push("SPLIT " + splitA.join(" · ") + "  vs  " +
          splitB.join(" · ") + "   (" + ITEM_SHORT.join(" · ") + ")");
      }
    } else {
      lines.push("0 – 0");
      lines.push(table.maxTurns + " TURNS, NO AGREEMENT");
    }
    negLabel(ctx, deal ? "DEAL" : "NO DEAL", w / 2, h * 0.5 - bh * 0.24, {
      font: negFont(Math.min(52 * scale, w * 0.12), 700),
      color: deal ? HEX.green : HEX.red,
      maxWidth: w * 0.7
    });
    negLabel(ctx, lines[0], w / 2, h * 0.5 + bh * 0.08, {
      font: negFont(Math.min(22 * scale, w * 0.055), 700),
      color: PAPER, maxWidth: w * 0.7
    });
    if (lines.length > 1) {
      negLabel(ctx, lines[1], w / 2, h * 0.5 + bh * 0.33, {
        font: negFont(Math.min(13 * scale, w * 0.032), 600),
        color: PAPER, maxWidth: w * 0.66
      });
    }
    ctx.restore();
  }

  function negStage(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var scale = Math.max(0.62, Math.min(w / 960, 1.2));
    var narrow = w < 420;
    var seats = view.seats || [];
    var table = view.table;

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(0, 0, w, h);

    if (!table) {
      negLabel(ctx, "THE TABLE IS SET", w / 2, h * 0.46,
        { font: negFont(Math.min(26 * scale, w * 0.07), 700), color: AMBER });
      negLabel(ctx, "waiting for the first match", w / 2, h * 0.56,
        { font: negFont(13 * scale), color: GHOST });
      return;
    }

    var sides = [table.a, table.b];
    var cog = Math.max(30, Math.min(92 * scale, w * 0.14, h * 0.26));
    var cogY = h * 0.30;
    var xs = [w * 0.15, w * 0.85];

    // The remark band, reserved before anything is drawn into it: the pool
    // row below it starts under the band, so the stage does not jump when a
    // remark lands and the pool never sits on top of one.
    var talkW = w * 0.3;
    var talkTop = cogY + cog * 0.72 + 24 * scale;
    var band = negTalkBand(ctx, talkW, scale,
      Math.max(24 * scale, h * 0.66 - 20 * scale - talkTop));
    var rowY = Math.min(h * 0.72,
      Math.max(h * 0.66, talkTop + band.height + 20 * scale));

    // The two negotiating cogs, facing each other across the table.
    for (var s = 0; s < 2; s++) {
      var seatIndex = sides[s];
      var seat = seats[seatIndex] || {};
      negCog(ctx, images, seat, seatIndex, xs[s], cogY, cog, {
        acting: table.actor === seatIndex && table.outcome === "open",
        dim: false
      });
      negLabel(ctx, C.clampName(seat.name || ""), xs[s], cogY + cog * 0.72, {
        font: negFont(14 * scale, 700),
        color: HEX[C.seatColor(seatIndex)],
        maxWidth: w * 0.28
      });
      var values = (table.values || [])[s] || [0, 0, 0];
      var strip = narrow ?
        (values[0] + "·" + values[1] + "·" + values[2]) :
        ("books ×" + values[0] + " · hats ×" + values[1] +
          " · balls ×" + values[2] + " = 10");
      negLabel(ctx, strip, xs[s], cogY + cog * 0.72 + 15 * scale, {
        font: negFont(11 * scale), color: PAPER, maxWidth: w * 0.3
      });
      var talk = (table.messages || [])[s] || "";
      if (talk) {
        ctx.save();
        ctx.font = negFont(band.px);
        var talkLines = negWrapLines(ctx, "“" + talk + "”", talkW);
        ctx.restore();
        for (var t = 0; t < talkLines.length; t++) {
          negLabel(ctx, talkLines[t], xs[s],
            talkTop + band.lineH * (t + 0.5), {
              font: negFont(band.px), color: GHOST, maxWidth: talkW
            });
        }
      }
    }

    // The pool, split into the two shares the standing offer would give.
    var shareA = negShare(table, 0);
    var shareB = negShare(table, 1);
    if (!table.standing) {
      negPoolRow(ctx, w / 2, rowY, w * 0.62, table.pool,
        HEX[C.seatColor(sides[0])], scale, narrow);
      negLabel(ctx, "POOL: " + (table.pool || []).join(" · ") + "  (" +
        ITEM_SHORT.join(" · ") + ")", w / 2, rowY + h * 0.16, {
        font: negFont(11 * scale), color: GHOST, maxWidth: w * 0.8
      });
    } else {
      // A new offer slides in from the seat that made it and then holds:
      // the standing split stays lit while the other seat thinks.
      var entrance = negEntrance(view, "offer", 320);
      var slide = (1 - entrance) * w * 0.06 *
        (table.standing.side === 0 ? -1 : 1);
      ctx.save();
      ctx.globalAlpha = 0.4 + 0.6 * entrance;
      negPoolRow(ctx, w * 0.27 + slide, rowY, w * 0.4, shareA,
        HEX[C.seatColor(sides[0])], scale, narrow);
      negPoolRow(ctx, w * 0.73 + slide, rowY, w * 0.4, shareB,
        HEX[C.seatColor(sides[1])], scale, narrow);
      var worth = table.standing.worth || [0, 0];
      var byside = table.standing.side === 0 ?
        [worth[0], worth[1]] : [worth[1], worth[0]];
      negChip(ctx, "worth " + byside[0], w * 0.27 + slide, rowY + h * 0.16,
        HEX[C.seatColor(sides[0])], scale);
      negChip(ctx, "worth " + byside[1], w * 0.73 + slide, rowY + h * 0.16,
        HEX[C.seatColor(sides[1])], scale);
      ctx.restore();
      ctx.save();
      ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
      ctx.lineWidth = 2;
      ctx.setLineDash([5, 6]);
      ctx.beginPath();
      ctx.moveTo(w / 2, rowY - h * 0.13);
      ctx.lineTo(w / 2, rowY + h * 0.12);
      ctx.stroke();
      ctx.restore();
    }

    // The seat sitting this match out.
    for (var k = 0; k < (seats.length || 0); k++) {
      if (k === table.a || k === table.b) continue;
      negCog(ctx, images, seats[k], k, w * 0.5, h * 0.14,
        Math.max(22, cog * 0.5), { dim: true, acting: false });
      negLabel(ctx, "SITTING OUT", w * 0.5, h * 0.14 + cog * 0.38, {
        font: negFont(9.5 * scale, 700), color: GHOST, maxWidth: w * 0.3
      });
    }

    if (table.outcome && table.outcome !== "open") {
      negStamp(ctx, table, scale, negEntrance(view, "matchEnd", 260));
    }
  }

  // ---- readouts ------------------------------------------------------------

  function negPhase(state, nameMap) {
    var table = state && state.table;
    if (!table) return "";
    if (table.outcome === "deal") {
      return "DEAL " + (table.payoff || [0, 0]).join("–");
    }
    if (table.outcome === "no_deal") return "NO DEAL";
    if (typeof table.actor !== "number" || table.actor < 0) return "";
    var who = nameMap ? nameMap.seat(table.actor) :
      ((state.seats || [])[table.actor] || {}).name || "";
    return C.clampName(who).toUpperCase() + " TO MOVE";
  }

  function negHeader(state, config, nameMap) {
    if (!state) return "";
    var parts = [];
    var total = state.matches || (config && config.matches) || 0;
    negScheduled = Math.max(negScheduled, total);
    if (state.gameDone || state.done) {
      parts.push("FINAL");
      parts.push((state.matchesPlayed || 0) + " MATCH" +
        ((state.matchesPlayed || 0) === 1 ? "" : "ES"));
      return parts.join(" · ");
    }
    var shown = (typeof state.match === "number" && state.match >= 0) ?
      state.match + 1 : 0;
    parts.push("MATCH " + shown + (total ? " / " + total : ""));
    var table = state.table;
    if (table && table.outcome === "open" && table.turn) {
      parts.push("TURN " + table.turn + " / " + table.maxTurns);
    }
    var phase = negPhase(state, nameMap);
    if (phase) parts.push(phase);
    return parts.join(" · ");
  }

  function negScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var table = state.table;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var idle = !!table && index !== table.a && index !== table.b;
      var pips = "";
      var played = Math.min(seat.matches || 0, 12);
      for (var p = 0; p < played; p++) {
        pips += '<span class="plate-pip' +
          (p < (seat.deals || 0) ? "" : " hollow") + '"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + C.seatColor(index) +
        (idle ? " idle" : "") + '">' +
        '<span class="plate-name">' + C.escapeHtml(C.clampName(plateName)) +
        "</span>" +
        (table && table.actor === index && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + (seat.points || 0) + "</span>" +
        '<span class="plate-label">pts</span>' +
        '<span class="plate-sub">' + (seat.score || 0).toFixed(2) + "</span>" +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
    var strip = document.getElementById("valuestrip");
    if (strip) {
      var text = "";
      if (table) {
        [table.a, table.b].forEach(function (seatIndex, s) {
          var values = (table.values || [])[s] || [0, 0, 0];
          text += '<span class="vs-seat ' + C.seatColor(seatIndex) + '">' +
            C.escapeHtml(C.clampName(nameMap ? nameMap.seat(seatIndex) :
              (state.seats[seatIndex] || {}).name || "")) +
            ": books ×" + values[0] + " · hats ×" + values[1] +
            " · balls ×" + values[2] + "</span>";
        });
      }
      if (strip.dataset.html !== text) {
        strip.dataset.html = text;
        strip.innerHTML = text;
      }
    }
  }

  function negReason(results) {
    if (results && results.reason === "deadline") {
      return "episode deadline: scored on " + (results.matchesPlayed || 0) +
        " of " + (results.maxMatches || results.matchesPlayed || 0) +
        " matches";
    }
    return "";
  }

  function negEndcard(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results) {
      container.dataset.built = "";
      return;
    }
    if (container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var points = results.points || [];
    var deals = results.deals || [];
    var giveaway = results.giveaway || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (points[b] || 0) - (points[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdict = !level && topIndex >= 0 ?
      C.escapeHtml(names[topIndex]) + " TAKES THE TABLE" : "ALL LEVEL";
    var reason = negReason(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.matchesPlayed || 0) +
      " MATCH" + ((results.matchesPlayed || 0) === 1 ? "" : "ES") + "</div>" +
      '<div class="end-verdict ' +
      (!level && topIndex >= 0 ? C.seatColor(topIndex) : "") + '">' +
      verdict + "</div>" +
      (reason ? '<div class="end-reason">' + C.escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">pts</span>' +
      '<span class="end-head">deals</span>' +
      '<span class="end-head">giveaway</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + C.seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' +
        C.escapeHtml(names[i] || "") + "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(points[i] || 0) +
        cell(deals[i] || 0) +
        cell((giveaway[i] || 0).toFixed(1));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // ---- feed ----------------------------------------------------------------

  function negTake(take, itemNames) {
    var names = itemNames || ["books", "hats", "balls"];
    var singular = ["book", "hat", "ball"];
    var parts = [];
    for (var i = 0; i < 3; i++) {
      var n = (take || [])[i] || 0;
      if (n > 0) parts.push(n + " " + (n === 1 ? singular[i] : names[i]));
    }
    return parts.length ? parts.join(", ") : "nothing";
  }

  // "Sprocket 25 pts (0.62) · Gizmo 18 pts (0.45) · …" — the same points and
  // score the results carry, accumulated from the feed's own matchEnd
  // payoffs (score = points / (10 · matches that seat played)).
  function negFinalTotals(ctx, nameMap) {
    var parts = [];
    Object.keys(ctx.points).map(Number).sort(function (a, b) {
      return a - b;
    }).forEach(function (seat) {
      var played = ctx.played[seat] || 0;
      var score = played ? ctx.points[seat] / (10 * played) : 0;
      parts.push(C.clampName(nameMap.seat(seat)) + " " + ctx.points[seat] +
        " pts (" + score.toFixed(2) + ")");
    });
    return parts.join(" · ");
  }

  function negText(event, nameMap, ctx) {
    var who = function (i) { return C.clampName(nameMap.seat(i)); };
    var gear = event.scripted ? " ⚙" : "";
    switch (event.kind) {
      case "start":
        return "Three cogs at the table. Every pool is worth 10 to each of " +
          "them — under different, private values.";
      case "match":
        ctx.match = event;
        return "Pool: " + negTake(event.pool) + ". " +
          who(event.opener) + " opens.";
      case "offer":
        return who(event.seat) + " offers: takes " + negTake(event.take) +
          " — worth " + (event.worth || [0, 0])[0] + " to " +
          who(event.seat) + ", " + (event.worth || [0, 0])[1] + " to " +
          who(event.other) + gear;
      case "accept":
        return who(event.seat) + " ACCEPTS — DEAL " +
          (event.payoff || [0, 0]).join("–") + gear;
      case "matchEnd":
        var settled = (ctx.match && ctx.match.seats) || [];
        var paid = event.payoff || [0, 0];
        for (var s = 0; s < settled.length && s < 2; s++) {
          ctx.points[settled[s]] = (ctx.points[settled[s]] || 0) +
            (paid[s] || 0);
          ctx.played[settled[s]] = (ctx.played[settled[s]] || 0) + 1;
        }
        if (event.outcome === "deal") {
          return "Match settled — " + (event.payoff || [0, 0]).join("–");
        }
        return "NO DEAL — " + event.turn + " turns, 0–0";
      case "end":
        return "Final — " + negFinalTotals(ctx, nameMap) +
          (event.text === "deadline" ? " (episode deadline)." : ".");
      default:
        return JSON.stringify(event);
    }
  }

  function negFeedClass(event) {
    if (event.kind === "offer" || event.kind === "accept") {
      return "seat" + (event.seat % 6) +
        (event.kind === "accept" ? " feed-score" : "");
    }
    if (event.kind === "matchEnd") {
      return event.outcome === "deal" ? "feed-deal" : "feed-nodeal";
    }
    if (event.kind === "end") return "feed-rwin";
    return "";
  }

  function negExtras(event, nameMap, ctx) {
    var lines = [];
    if (event.kind !== "offer" && event.kind !== "accept") return lines;
    if (event.text) {
      lines.push({
        cls: "feed-say",
        text: C.clampName(nameMap.seat(event.seat)) + ": “" +
          nameMap.text(event.text) + "”"
      });
    }
    if (event.notes && event.notes !== ctx.notes[event.seat]) {
      ctx.notes[event.seat] = event.notes;
      lines.push({
        cls: "feed-note",
        text: C.clampName(nameMap.seat(event.seat)) + " notes: " +
          nameMap.text(event.notes)
      });
    }
    return lines;
  }

  // How many matches the schedule holds, read off the config the clock is
  // painted from and off every state's `matches`. The bar is one chip per
  // SCHEDULED match: in a `deadline` episode the matches that never started
  // emit no `match` event, and they are exactly the ones a viewer needs to
  // see as pending.
  var negScheduled = 0;

  // The matchbar: one chip per scheduled match, filled as matches settle.
  // Built from the feed pass (chrome_common calls feedDone at the end of
  // renderFeed, before the scorebug painter).
  function negMatchbar(events, nameMap, limit) {
    var bar = document.getElementById("matchbar");
    if (!bar) return;
    var total = negScheduled;
    var chips = {};
    events.forEach(function (event, i) {
      if (event.kind === "match") total = Math.max(total, event.match + 1);
      if (event.kind === "matchEnd" && i < limit) {
        chips[event.match] = event.outcome === "deal" ?
          { cls: "deal", text: "DEAL " + (event.payoff || []).join("–") } :
          { cls: "nodeal", text: "NO DEAL" };
      }
    });
    var html = "";
    for (var m = 0; m < total; m++) {
      var chip = chips[m] || { cls: "pending", text: "M" + (m + 1) };
      html += '<span class="mb-chip ' + chip.cls + '">' +
        C.escapeHtml(chip.text) + "</span>";
    }
    if (bar.dataset.html !== html) {
      bar.dataset.html = html;
      bar.innerHTML = html;
    }
  }

  // ---- registration --------------------------------------------------------

  C.register({
    assets: ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "arena_floor.png"],
    effectResetKinds: ["match"],
    makeRenderer: function (ctx, canvas, images) {
      return {
        draw: function (view) { negStage(ctx, canvas, images, view); }
      };
    },
    stateToView: function (view, state) {
      view.table = state.table || null;
      view.match = typeof state.match === "number" ? state.match : -1;
      view.matches = state.matches || 0;
      negScheduled = Math.max(negScheduled, view.matches);
      view.matchesPlayed = state.matchesPlayed || 0;
      view.phase = state.phase || "";
      view.reason = state.reason || "";
    },
    blockOf: function (event) {
      return event.kind === "start" ? -1 :
        (typeof event.match === "number" ? event.match : 0);
    },
    blockHead: function (block, events) {
      if (block < 0) return "SETUP";
      for (var i = 0; i < events.length; i++) {
        if (events[i].kind === "match" && events[i].match === block) {
          return "MATCH " + (block + 1);
        }
      }
      return "MATCH " + (block + 1);
    },
    beat: function (event) {
      switch (event.kind) {
        case "offer":
          return { kind: "offer", seat: event.seat,
            label: "Match " + (event.match + 1) + ", turn " + event.turn +
              " — offer" };
        case "accept":
          return { kind: "accept", seat: event.seat,
            label: "Match " + (event.match + 1) + ", turn " + event.turn +
              " — accepts" };
        case "matchEnd":
          return event.outcome === "deal" ?
            { kind: "deal", label: "Match " + (event.match + 1) + " — deal " +
              (event.payoff || []).join("–") } :
            { kind: "nodeal", label: "Match " + (event.match + 1) +
              " — no deal" };
        case "end":
          return { kind: "end", label: "Final" };
        default:
          return null;
      }
    },
    // Dwell per beat. The floor is 420 ms: `viewer_smoke --soak` samples the
    // readouts over a 2 s tail and fails a replay whose readouts did not
    // move in it, and an accept and its matchEnd render the same frame (the
    // accept already settles the match), so a slow beat can put two
    // identical readouts either side of that window.
    stepMs: function (shown) {
      if (!shown) return 420;
      if (shown.kind === "offer") return 620;
      if (shown.kind === "accept") return 800;
      if (shown.kind === "matchEnd") return 900;
      if (shown.kind === "match") return 700;
      if (shown.kind === "end") return 900;
      return 420;
    },
    feedReset: function () {
      return { notes: {}, match: null, points: {}, played: {} };
    },
    describeEvent: negText,
    feedClass: negFeedClass,
    extraFeedLines: negExtras,
    feedDone: function (events, nameMap, limit) {
      negMatchbar(events, nameMap, limit);
    },
    phaseText: negPhase,
    matchHeader: negHeader,
    updateScorebug: negScorebug,
    updateEndscreen: negEndcard
  });
})();
