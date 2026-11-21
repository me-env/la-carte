# Round 5: lost data points → structure, time as the axis

`render.py` (seeded mulberry32) writes every file; `sheet.png` compares all variants with Vyst.
Two kinds of points, never mixed up:
- **Structure (nodes):** always land *exactly* on the construction below. Time shows only through one size
  progression and how much grain is left around each node. Nodes never touch: the pitch is always larger than the
  sum of neighbouring radii plus ≥ 14 px.
- **Texture (grain):** r 1.8–4.2 px at 1024, white, random but seeded. It only thins out over time and never
  pretends to be structure.
Animation: nodes start scattered and arrive in time order (`order`); grain stays put. Frames: t = 0.1, 0.55, 1.
Small files (≤ 58 px): same construction, fewer and bigger points (grain r 13–16, nodes as noted).

All units are px at 1024. Tile #151514, ink #F2F2F0; light: #F9FAF5 / #1C1C1C. No pink.

| Variant | Construction | Rhythm rule | Node size rule | Grain rule |
|---|---|---|---|---|
| v1-columns | 7 columns, x 170 → 854, one baseline y = 512 | gaps grow ×1.32 | r linear 12 → 36 (small 22 → 44) | per column 90 → 0 (linear), vertical σ 210 · 0.75^j |
| v2-calendar | 7 × 5 grid (small 5 × 4), centred | pitch 112 (small 150) both ways | r linear 8 → 30 in reading order (small 18 → 40) | per cell 30 → 0, σ 44 |
| v3-curve | y = 760 − 460(1 − e^(−3.2u)), x = 160 + 704u | 15 nodes (small 8) at equal arc length (~68 / ~145) | r linear 7 → 20 (small 20 → 34) | per node 40 → 0, σ_y 120 → 0 |
| v4-clock | 12 nodes on R = 300 + centre node | pitch 157 (30°) | r linear 10 → 30 clockwise (small 22 → 42), centre 30 (44) | per node 60 → 0, σ 50 |
| v5-point | grain cloud x 150–470, then nodes on y = 512 | constant edge gap 22 (small 34) | r ×1.4 per step: 10 → 53.8 (small 26 → 71.4) | σ_y 230 → 0 linearly to x = 470 |
| v6-ticks | 8 ticks (small 5) of 7 nodes, x 180 → 850 | gaps ×1.32; vertical pitch 44 (small 64) | r linear 6 → 15 per tick (small 15 → 24) | per node 8 → 0, σ 22 × 26 |
| v7-hourglass | 3 rows × 9 nodes (small 7), x 232 → 792, bottom row y = 800 | pitch 70 both ways (small 93) | r constant 20 (small 28) | column above the top row, ≥ 40 px clear, half-normal σ 170 upward |
