#!/usr/bin/env python3
"""Generate the Maxima app icon as SVG.

Two concentric arc rings on a superellipse ("squircle") plate: the outer ring is
the weekly All-models limit, the inner one Fable. Both sweep clockwise from 12
o'clock, so the unfilled remainder reads as headroom.
"""
import math
import sys

SIZE = 1024          # canvas
ART = 824            # Big Sur artwork area, centred
CX = CY = SIZE / 2
HALF = ART / 2

OUTER_R, INNER_R = 280, 168
STROKE = 80
OUTER_SWEEP = 0.70   # fraction of the circle
INNER_SWEEP = 0.45


def squircle(cx, cy, half, n=5.6, steps=720):
    """Superellipse path. n=5 lands very close to Apple's continuous corners."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(ct) ** (2 / n), ct)
        y = cy + half * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M " + " L ".join(pts) + " Z"


def arc(cx, cy, r, start_deg, sweep_deg):
    a0, a1 = math.radians(start_deg), math.radians(start_deg + sweep_deg)
    x0, y0 = cx + r * math.cos(a0), cy + r * math.sin(a0)
    x1, y1 = cx + r * math.cos(a1), cy + r * math.sin(a1)
    large = 1 if abs(sweep_deg) > 180 else 0
    return f"M {x0:.2f} {y0:.2f} A {r} {r} 0 {large} 1 {x1:.2f} {y1:.2f}"


def build(bg_top, bg_bottom, outer_a, outer_b, inner_a, inner_b):
    plate = squircle(CX, CY, HALF)
    outer = arc(CX, CY, OUTER_R, -90, 360 * OUTER_SWEEP)
    inner = arc(CX, CY, INNER_R, -90, 360 * INNER_SWEEP)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="{bg_top}"/>
      <stop offset="1" stop-color="{bg_bottom}"/>
    </linearGradient>
    <linearGradient id="outerFill" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{outer_a}"/>
      <stop offset="1" stop-color="{outer_b}"/>
    </linearGradient>
    <linearGradient id="innerFill" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{inner_a}"/>
      <stop offset="1" stop-color="{inner_b}"/>
    </linearGradient>
    <!-- Top-lit plate. A linear wash, not a radial: a radial large enough to
         light the top corners leaves a visible disc edge across the plate. -->
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity="0.03"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="20"
                    flood-color="#000000" flood-opacity="0.28"/>
    </filter>
  </defs>

  <g filter="url(#drop)">
    <path d="{plate}" fill="url(#plate)"/>
  </g>
  <path d="{plate}" fill="url(#sheen)"/>

  <!-- tracks -->
  <circle cx="{CX}" cy="{CY}" r="{OUTER_R}" fill="none"
          stroke="#ffffff" stroke-opacity="0.14" stroke-width="{STROKE}"/>
  <circle cx="{CX}" cy="{CY}" r="{INNER_R}" fill="none"
          stroke="#ffffff" stroke-opacity="0.14" stroke-width="{STROKE}"/>

  <!-- fills -->
  <path d="{outer}" fill="none" stroke="url(#outerFill)"
        stroke-width="{STROKE}" stroke-linecap="round"/>
  <path d="{inner}" fill="none" stroke="url(#innerFill)"
        stroke-width="{STROKE}" stroke-linecap="round"/>

  <!-- edge definition -->
  <path d="{plate}" fill="none" stroke="#ffffff" stroke-opacity="0.10" stroke-width="2"/>
</svg>
'''


# bg_top, bg_bottom, outer_a, outer_b, inner_a, inner_b.
# Cool on purpose: orange and red are the app's warning and critical states, so
# the icon stays out of that range and those remain the only warm signal.
PALETTE = ("#1E293B", "#020617", "#7DD3FC", "#38BDF8", "#D8B4FE", "#C084FC")

# Considered and rejected:
#   indigo  ("#4338CA", "#1E1B4B", "#67E8F9", "#22D3EE", "#C4B5FD", "#A78BFA")
#   teal    ("#115E59", "#042F2E", "#5EEAD4", "#2DD4BF", "#A7F3D0", "#6EE7B7")

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "maxima.svg"
    with open(target, "w") as fh:
        fh.write(build(*PALETTE))
    print(target)
