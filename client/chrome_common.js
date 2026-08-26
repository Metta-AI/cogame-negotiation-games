// negotiation-games broadcast chrome.
//
// PROVENANCE: this file is the CHROME HALF of cogame-babel's
// client/renderer.js (version 0.1.4), copied across and wrapped in an IIFE
// that exports `window.NegChrome`. The functions carried over are
// assetUrl, loadImages, seatColor, hexToRgb, shade, rgba, ellipsize,
// roundRect, escapeHtml, clampName, isBaselineFiller, makeNameMap,
// applyNames, makeEffects, blockHead, renderFeed, buildScrub,
// bindFeedToggle, attachLive and attachReplay. Their bodies are NOT edited
// except for three changes, which are the whole diff:
//
//   1. every game-specific call site (describeEvent, stateToView, draw,
//      updateScorebug, updateEndscreen, phaseText, matchHeader, and the
//      feed/scrub grouping babel hard-coded to rounds and pairs) is
//      redirected to a hook object the game block registers with
//      NegChrome.register({...});
//   2. buildScrub emits <button class="beat-marker …" type="button"
//      aria-label="…"> instead of <div>, each wired to seek to that event
//      (unlabelled divs that never seek passed every static grep on
//      cogame-tandem, 2026-08-23);
//   3. relayout() is added (it writes --band and --hudscale on :root) and
//      attachReplay takes an onFirstFrame option.
//
// After creation this file is frozen: the game block never edits it.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };

  // The hook object the game block registers. Every game-specific decision
  // the chrome used to make inline now goes through here.
  var H = {};

  function register(hooks) {
    Object.keys(hooks || {}).forEach(function (key) { H[key] = hooks[key]; });
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    if (!pending) { done(images); return; }
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the newest event of each kind landed, so the stage can slide an
  // offer in and hold a stamp. `quiet` (a scrub jump) lands the whole
  // prefix at once, so only the newest event animates.
  function makeEffects() {
    var seen = 0;
    var at = {};
    var resets = null;
    return {
      absorb: function (events, quiet) {
        var now = Date.now();
        if (!resets) resets = H.effectResetKinds || [];
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (resets.indexOf(event.kind) >= 0) at = {};
          at[event.kind] = animate ? now : null;
        }
      },
      reset: function () { seen = 0; at = {}; },
      view: function () { return { effects: { at: at, seen: seen } }; }
    };
  }

  // ---- Event feed ----------------------------------------------------------

  function blockOf(event, previous) {
    return H.blockOf ? H.blockOf(event, previous) :
      (event.kind === "start" ? -1 : (event.match || 0));
  }

  function blockHead(block, events) {
    return H.blockHead ? H.blockHead(block, events) :
      (block < 0 ? "SETUP" : "MATCH " + (block + 1));
  }

  // Renders the full transcript grouped into one section per match.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    if (!element) return;
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = H.feedReset ? H.feedReset() : {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = blockOf(event, i > 0 ? events[i - 1] : null);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' +
          escapeHtml(blockHead(block, events)) + "</div>";
        lastBlock = block;
      }
      var text = H.describeEvent ? H.describeEvent(event, nameMap, ctx) :
        JSON.stringify(event);
      var cls = "feed-line feed-" + event.kind +
        (H.feedClass ? " " + H.feedClass(event, nameMap, ctx) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      var extras = H.extraFeedLines ?
        (H.extraFeedLines(event, nameMap, ctx) || []) : [];
      for (var e = 0; e < extras.length; e++) {
        html += '<div class="feed-line ' + extras[e].cls +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(extras[e].text) + "</div>";
      }
    }
    element.innerHTML = html;
    if (H.feedDone) H.feedDone(events, nameMap, limit, ctx);

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- Transport -----------------------------------------------------------

  // Measures the transport band and publishes it on :root so no overlay
  // ever lands inside it, plus a HUD scale every chrome font size and pad
  // is expressed in. Runs on load, on every resize, and after the feed is
  // toggled.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = transport ?
      Math.round(transport.getBoundingClientRect().height) : 0;
    var stage = document.getElementById("stage");
    var width = stage ? stage.getBoundingClientRect().width :
      (window.innerWidth || 960);
    var scale = Math.max(0.72, Math.min(width / 960, 1.25));
    root.style.setProperty("--band", band + "px");
    root.style.setProperty("--hudscale", (Math.round(scale * 1000) / 1000));
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
        relayout();
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
      relayout();
    };
    refresh();
  }

  // Scrubber: a click/drag-to-seek track with one span per match and a
  // labelled, clickable button per beat.
  function buildScrub(container, events, onSeek) {
    if (!container) return { update: function () {} };
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = blockOf(event, i > 0 ? events[i - 1] : null);
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var beat = H.beat ? H.beat(event, i, events) : null;
      if (!beat) return;
      // A labelled BUTTON that actually seeks: unlabelled divs that never
      // seek passed every static grep on cogame-tandem.
      var marker = document.createElement("button");
      marker.type = "button";
      marker.className = "beat-marker " + beat.kind +
        (typeof beat.seat === "number" ?
          " seat" + (beat.seat % COLORS.length) : "");
      marker.setAttribute("aria-label", beat.label || beat.kind);
      marker.title = beat.label || beat.kind;
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      marker.addEventListener("click", function (evt) {
        evt.stopPropagation();
        onSeek(i + 1);
      });
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  // ---- Drivers -------------------------------------------------------------

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    loadImages(assetBase, H.assets || [], function (images) {
      var painter = H.makeRenderer(ctx, canvas, images);
      onReady(painter);
    });
  }

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.now = Date.now();
    if (H.stateToView) H.stateToView(view, state, nameMap);
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is behind
      // a seat) and a redacted state, so their map degrades to the aliases.
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              renderFeed(options.feed, latest.events || [], nameMap,
                undefined);
              if (options.clock && H.matchHeader) {
                options.clock.textContent =
                  H.matchHeader(latest, latest, nameMap);
              }
              if (H.updateScorebug) {
                H.updateScorebug(options.scorebug, latest, nameMap);
              }
            }
            if (data.type === "final" && H.updateEndscreen) {
              H.updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload, onFirstFrame}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var announced = false;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], table: null, phase: "", matchesPlayed: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
          // Every seek dismisses the endcard before the repaint, so it can
          // never sit over a frame the viewer scrubbed back to.
          if (H.updateEndscreen) {
            H.updateEndscreen(options.endscreen, payload.results, false,
              nameMap);
          }
        }
        effects.absorb(events.slice(0, index), jumped);
        renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock && H.matchHeader) {
          options.clock.textContent =
            H.matchHeader(currentState(), config, nameMap);
        }
        if (H.updateScorebug) {
          H.updateScorebug(options.scorebug, currentState(), nameMap);
        }
        if (H.updateEndscreen) {
          H.updateEndscreen(options.endscreen, payload.results,
            index >= events.length && events.length > 0, nameMap);
        }
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at so the offer
        // gets read and the stamp gets seen before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = H.stepMs ? H.stepMs(shown) : 600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        if (!announced) {
          // FIRST DRAWN FRAME. The host learns the viewer is ready from
          // here and nowhere else: a bare requestAnimationFrame at the call
          // site let softmax.com sample an unpainted shell (chorus,
          // 2026-08-24).
          announced = true;
          if (options.onFirstFrame) options.onFirstFrame();
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  window.addEventListener("resize", relayout);
  window.addEventListener("load", relayout);

  window.NegChrome = {
    register: register,
    assetUrl: assetUrl,
    loadImages: loadImages,
    seatColor: seatColor,
    hexToRgb: hexToRgb,
    shade: shade,
    rgba: rgba,
    ellipsize: ellipsize,
    roundRect: roundRect,
    escapeHtml: escapeHtml,
    clampName: clampName,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    makeEffects: makeEffects,
    blockHead: blockHead,
    renderFeed: renderFeed,
    buildScrub: buildScrub,
    bindFeedToggle: bindFeedToggle,
    attachLive: attachLive,
    attachReplay: attachReplay,
    relayout: relayout,
    COLORS: COLORS,
    COLOR_HEX: COLOR_HEX
  };

  window.NegotiationRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();
